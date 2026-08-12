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
    private(set) var mediaTimelineRevision = 0

    private var itemStatusObserver: NSKeyValueObservation?
    private var seekableTimeRangesObserver: NSKeyValueObservation?
    private var preciseTimingTask: Task<Void, Never>?
    private var preciseTimingURL: URL?
    private var preciseTimingGeneration = 0

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
        preciseTimingGeneration &+= 1
        itemStatusObserver?.invalidate()
        seekableTimeRangesObserver?.invalidate()
        itemIdentifier = identifier
        mediaTimeline = playbackItem.timeline
        mediaTimelineRevision &+= 1
        isPreciseTimingReady = false
        preciseTimingURL = playbackItem.preciseTimingURL
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
    }

    /// Loads the precise media timeline only when lyrics actually need it.
    /// Playback itself never waits for this asset.
    func requestPreciseTiming() {
        startPreciseTimingLoad()
    }

    private func startPreciseTimingLoad() {
        guard !isPreciseTimingReady,
              preciseTimingTask == nil,
              let url = preciseTimingURL,
              let expectedItem = player.currentItem else {
            return
        }

        let generation = preciseTimingGeneration
        preciseTimingTask = Task { [weak self] in
            for attempt in 0..<3 {
                guard !Task.isCancelled else { break }

                if let preciseTimeline =
                    await Self.loadPreciseTimeline(from: url) {
                    guard !Task.isCancelled,
                          let self,
                          generation == self.preciseTimingGeneration,
                          self.player.currentItem === expectedItem else {
                        break
                    }
                    self.mediaTimeline = preciseTimeline
                    self.mediaTimelineRevision &+= 1
                    self.isPreciseTimingReady = true
                    self.preciseTimingTask = nil
                    self.onPreciseTimingReady?()
                    return
                }

                guard attempt < 2 else { break }
                do {
                    try await Task.sleep(
                        for: .milliseconds(
                            attempt == 0 ? 200 : 500
                        )
                    )
                } catch {
                    break
                }
            }

            guard let self,
                  generation == self.preciseTimingGeneration else {
                return
            }
            self.preciseTimingTask = nil
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
        preciseTimingGeneration &+= 1
        preciseTimingURL = nil
        isPreciseTimingReady = false
        itemIdentifier = nil
        mediaTimeline = AudioPlaybackMediaTimeline()
        mediaTimelineRevision &+= 1
        player.pause()
        player.replaceCurrentItem(with: nil)
        player.rate = 0
    }
}
