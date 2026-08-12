import AVFoundation

enum PreciseTimingError: LocalizedError {
    case notPrecise
    case noAudioTrack
    case invalidTimeRange
    case unavailable

    var errorDescription: String? {
        switch self {
        case .notPrecise:
            "媒体资源未提供精确时间信息。"
        case .noAudioTrack:
            "精准时间资源中未找到音频轨道。"
        case .invalidTimeRange:
            "精准时间资源的音频时间范围无效。"
        case .unavailable:
            "精准时间信息暂时不可用。"
        }
    }
}

@MainActor
final class AudioPlaybackDeck {
    let player: AVPlayer
    let autoMixEqualizerState =
        SharedAutoMixEqualizerState()

    var onItemStatusChanged: ((AVPlayerItem) -> Void)?
    var onSeekableTimeRangesChanged: ((AVPlayerItem) -> Void)?
    var onPreciseTimingReady: (() -> Void)?
    var onPreciseTimingFailed: ((Error) -> Void)?
    private(set) var itemIdentifier: Int?
    private(set) var mediaTimeline =
        AudioPlaybackMediaTimeline()
    private(set) var isPreciseTimingReady = false
    private(set) var mediaTimelineRevision = 0

    private var itemStatusObserver: NSKeyValueObservation?
    private var seekableTimeRangesObserver: NSKeyValueObservation?
    private var preciseTimingTask: Task<Void, Never>?
    private var preciseTimingURL: URL?
    private var preciseTimingFailure: Error?
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
        preciseTimingFailure = nil
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
        startPreciseTimingLoad(using: preciseTimingURL, force: false)
    }

    /// Retries precise timing with a freshly resolved playback URL. The active
    /// player item is not replaced; only the independent timing asset is
    /// refreshed. This avoids delaying playback while recovering from an
    /// expired or CDN-specific timing request.
    func retryPreciseTiming(using url: URL) {
        preciseTimingURL = url
        preciseTimingFailure = nil
        isPreciseTimingReady = false
        startPreciseTimingLoad(using: url, force: true)
    }

    private func startPreciseTimingLoad(
        using url: URL?,
        force: Bool
    ) {
        guard (force || !isPreciseTimingReady),
              preciseTimingTask == nil,
              let url,
              let expectedItem = player.currentItem else {
            return
        }

        let generation = preciseTimingGeneration
        preciseTimingTask = Task { [weak self] in
            let retryDelays: [UInt64] = [
                0, 500, 1_000, 2_000, 4_000
            ]
            var lastError: Error?

            for attempt in 0..<retryDelays.count {
                guard !Task.isCancelled else { break }

                if retryDelays[attempt] > 0 {
                    do {
                        try await Task.sleep(
                            for: .milliseconds(retryDelays[attempt])
                        )
                    } catch {
                        break
                    }
                }

                do {
                    let preciseTimeline =
                        try await Self.loadPreciseTimeline(from: url)

                    guard !Task.isCancelled,
                          let self,
                          generation == self.preciseTimingGeneration,
                          self.player.currentItem === expectedItem else {
                        break
                    }

                    // Only replace the active timeline after all precise
                    // timing properties have been validated.
                    self.mediaTimeline = preciseTimeline
                    self.mediaTimelineRevision &+= 1
                    self.preciseTimingFailure = nil
                    self.isPreciseTimingReady = true
                    self.preciseTimingTask = nil
                    self.onPreciseTimingReady?()
                    return
                } catch is CancellationError {
                    break
                } catch {
                    lastError = error
                }
            }

            guard let self,
                  generation == self.preciseTimingGeneration else {
                return
            }
            self.preciseTimingTask = nil
            guard !Task.isCancelled,
                  self.player.currentItem === expectedItem else {
                return
            }
            let error = lastError ?? PreciseTimingError.unavailable
            self.preciseTimingFailure = error
            self.isPreciseTimingReady = false
            self.onPreciseTimingFailed?(error)
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
    ) async throws -> AudioPlaybackMediaTimeline {
        let asset = AVURLAsset(
            url: url,
            options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: true
            ]
        )

        async let duration = asset.load(.duration)
        async let providesPreciseTiming =
            asset.load(.providesPreciseDurationAndTiming)
        let durationValue = try await duration
        let isPrecise = try await providesPreciseTiming

        guard isPrecise,
              durationValue.isNumeric,
              durationValue.seconds.isFinite,
              durationValue.seconds > 0 else {
            throw PreciseTimingError.notPrecise
        }

        guard let audioTrack = try await asset.loadTracks(
            withMediaType: .audio
        ).first else {
            throw PreciseTimingError.noAudioTrack
        }

        let timeRange = try await audioTrack.load(.timeRange)
        guard timeRange.isValid,
              timeRange.duration.isNumeric,
              timeRange.duration.seconds > 0,
              timeRange.start.seconds.isFinite else {
            throw PreciseTimingError.invalidTimeRange
        }

        return AudioPlaybackMediaTimeline(
            audioTrackTimeRange: timeRange
        )
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
        preciseTimingFailure = nil
        isPreciseTimingReady = false
        itemIdentifier = nil
        mediaTimeline = AudioPlaybackMediaTimeline()
        mediaTimelineRevision &+= 1
        player.pause()
        player.replaceCurrentItem(with: nil)
        player.rate = 0
    }
}
