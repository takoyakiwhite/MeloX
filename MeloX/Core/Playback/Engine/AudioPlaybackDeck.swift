import AVFoundation

@MainActor
final class AudioPlaybackDeck {
    let player: AVPlayer
    let autoMixEqualizerState =
        SharedAutoMixEqualizerState()

    var onItemStatusChanged: ((AVPlayerItem) -> Void)?
    var onSeekableTimeRangesChanged: ((AVPlayerItem) -> Void)?
    var onPreciseTimingReady: (() -> Void)?
    private(set) var itemIdentifier: Int?
    private(set) var mediaTimeline =
        AudioPlaybackMediaTimeline()
    private(set) var isPreciseTimingReady = false

    private var itemStatusObserver: NSKeyValueObservation?
    private var seekableTimeRangesObserver: NSKeyValueObservation?
    private var preciseTimingTask: Task<Void, Never>?

    init() {
        player = AVPlayer()
        player.automaticallyWaitsToMinimizeStalling = true
        player.networkResourcePriority = .high
        player.preventsDisplaySleepDuringVideoPlayback = false
    }

    func replaceCurrentItem(
        with playbackItem: PreparedAudioPlaybackItem,
        identifier: Int?
    ) {
        let item = playbackItem.item
        autoMixEqualizerState.reset()
        preciseTimingTask?.cancel()
        preciseTimingTask = nil
        itemStatusObserver?.invalidate()
        seekableTimeRangesObserver?.invalidate()
        itemIdentifier = identifier
        mediaTimeline = playbackItem.timeline
        isPreciseTimingReady = false
        itemStatusObserver = item.observe(
            \.status,
            options: [.initial, .new]
        ) { [weak self, weak item] _, _ in
            guard let self, let item else { return }
            Task { @MainActor [self, item] in
                guard self.player.currentItem === item else {
                    return
                }
                self.onItemStatusChanged?(item)
            }
        }
        seekableTimeRangesObserver = item.observe(
            \.seekableTimeRanges,
            options: [.initial, .new]
        ) { [weak self, weak item] _, _ in
            guard let self, let item else { return }
            Task { @MainActor [self, item] in
                guard self.player.currentItem === item else {
                    return
                }
                self.onSeekableTimeRangesChanged?(item)
            }
        }
        player.replaceCurrentItem(with: item)

        if let url = playbackItem.preciseTimingURL {
            let expectedItem = item
            preciseTimingTask = Task { [weak self] in
                let preciseTimeline = await Self.loadPreciseTimeline(from: url)
                guard !Task.isCancelled,
                      let self,
                      let preciseTimeline,
                      self.player.currentItem === expectedItem else {
                    return
                }
                self.mediaTimeline = preciseTimeline
                self.isPreciseTimingReady = true
                self.onPreciseTimingReady?()
            }
        }
    }

    var currentPlaybackTime: TimeInterval? {
        guard player.currentItem != nil else { return nil }
        return mediaTimeline.playbackPosition(
            forMediaTime: player.currentTime()
        )
    }

    var playbackDuration: TimeInterval? {
        guard let item = player.currentItem else { return nil }
        return mediaTimeline.playbackDuration(
            forMediaDuration: item.duration
        )
    }

    func mediaTime(
        forPlaybackPosition position: TimeInterval
    ) -> CMTime {
        mediaTimeline.mediaTime(
            forPlaybackPosition: position
        )
    }

    deinit {
        preciseTimingTask?.cancel()
    }

    private static func loadPreciseTimeline(
        from url: URL
    ) async -> AudioPlaybackMediaTimeline? {
        let asset = AVURLAsset(
            url: url,
            options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: true
            ]
        )
        do {
            guard let audioTrack = try await asset.loadTracks(
                withMediaType: .audio
            ).first else {
                return nil
            }
            let timeRange = try await audioTrack.load(.timeRange)
            return AudioPlaybackMediaTimeline(
                audioTrackTimeRange: timeRange
            )
        } catch is CancellationError {
            return nil
        } catch {
            return nil
        }
    }

    func clear() {
        autoMixEqualizerState.reset()
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        seekableTimeRangesObserver?.invalidate()
        seekableTimeRangesObserver = nil
        preciseTimingTask?.cancel()
        preciseTimingTask = nil
        isPreciseTimingReady = false
        itemIdentifier = nil
        mediaTimeline = AudioPlaybackMediaTimeline()
        player.pause()
        player.replaceCurrentItem(with: nil)
        player.rate = 0
    }
}
