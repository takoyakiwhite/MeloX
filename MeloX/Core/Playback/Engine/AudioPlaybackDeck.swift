import AVFoundation

@MainActor
final class AudioPlaybackDeck {
    let player: AVPlayer
    let autoMixEqualizerState =
        SharedAutoMixEqualizerState()

    var onItemStatusChanged: ((AVPlayerItem) -> Void)?
    var onSeekableTimeRangesChanged: ((AVPlayerItem) -> Void)?
    private(set) var itemIdentifier: Int?
    private(set) var mediaTimeline =
        AudioPlaybackMediaTimeline()

    private var itemStatusObserver: NSKeyValueObservation?
    private var seekableTimeRangesObserver: NSKeyValueObservation?

    init() {
        player = MeloXAudioPlayer()
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
        itemStatusObserver?.invalidate()
        seekableTimeRangesObserver?.invalidate()
        itemIdentifier = identifier
        mediaTimeline = playbackItem.timeline
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
        (player as? MeloXAudioPlayer)?.preparePreciseTimingIfNeeded(
            for: item
        )
    }

    var currentPlaybackTime: TimeInterval? {
        refreshPreciseTimelineIfAvailable()
        guard player.currentItem != nil else { return nil }
        return mediaTimeline.playbackPosition(
            forMediaTime: player.currentTime()
        )
    }

    var playbackDuration: TimeInterval? {
        refreshPreciseTimelineIfAvailable()
        guard let item = player.currentItem else { return nil }
        if let precise = preciseTimingSnapshot,
           let duration = precise.duration {
            return duration
        }
        return mediaTimeline.playbackDuration(
            forMediaDuration: item.duration
        )
    }

    func mediaTime(
        forPlaybackPosition position: TimeInterval
    ) -> CMTime {
        refreshPreciseTimelineIfAvailable()
        return mediaTimeline.mediaTime(
            forPlaybackPosition: position
        )
    }

    func clear() {
        autoMixEqualizerState.reset()
        (player as? MeloXAudioPlayer)?.preciseStateReset()
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        seekableTimeRangesObserver?.invalidate()
        seekableTimeRangesObserver = nil
        itemIdentifier = nil
        mediaTimeline = AudioPlaybackMediaTimeline()
        player.pause()
        player.replaceCurrentItem(with: nil)
        player.rate = 0
    }

    private var preciseTimingSnapshot:
        MeloXAudioPlayer.PreciseTimingSnapshot? {
        guard let item = player.currentItem,
              let precisePlayer = player as? MeloXAudioPlayer else {
            return nil
        }
        return precisePlayer.preciseTimingSnapshot(for: item)
    }

    private func refreshPreciseTimelineIfAvailable() {
        guard let precise = preciseTimingSnapshot else { return }
        mediaTimeline = precise.timeline
    }
}
