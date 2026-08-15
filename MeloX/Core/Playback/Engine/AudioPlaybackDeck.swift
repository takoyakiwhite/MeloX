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
    private var currentItemObserver: NSKeyValueObservation?

    init() {
        player = MeloXAudioPlayer()
        player.automaticallyWaitsToMinimizeStalling = true
        player.networkResourcePriority = .high
        player.preventsDisplaySleepDuringVideoPlayback = false

        currentItemObserver = player.observe(
            \.currentItem,
            options: [.new]
        ) { [weak self] _, change in
            guard let self,
                  let item = change.newValue as? AVPlayerItem,
                  let precisePlayer = self.player as? MeloXAudioPlayer else {
                return
            }
            Task { @MainActor [self, item, precisePlayer] in
                guard self.player.currentItem === item,
                      let timeline = precisePlayer.preciseTimelineForCurrentItem() else {
                    return
                }
                // A precise item is already prepared before activation. Only
                // update the timeline here; do not re-enter the item-status
                // state machine while a seek is in progress.
                self.mediaTimeline = timeline
            }
        }
    }

    deinit {
        currentItemObserver?.invalidate()
    }

    func replaceCurrentItem(
        with playbackItem: PreparedAudioPlaybackItem,
        identifier: Int?
    ) {
        autoMixEqualizerState.reset()
        installObservers(
            for: playbackItem.item,
            timeline: playbackItem.timeline,
            identifier: identifier,
            preserveEqualizerState: false
        )
        player.replaceCurrentItem(with: playbackItem.item)
        (player as? MeloXAudioPlayer)?.preparePreciseIfNeeded(
            for: playbackItem.item
        )
    }

    private func installObservers(
        for item: AVPlayerItem,
        timeline: AudioPlaybackMediaTimeline,
        identifier: Int? = nil,
        preserveEqualizerState: Bool
    ) {
        if !preserveEqualizerState {
            autoMixEqualizerState.reset()
        }
        itemStatusObserver?.invalidate()
        seekableTimeRangesObserver?.invalidate()
        itemStatusObserver = nil
        seekableTimeRangesObserver = nil
        if let identifier {
            itemIdentifier = identifier
        }
        mediaTimeline = timeline

        itemStatusObserver = item.observe(
            \.status,
            options: [.initial, .new]
        ) { [weak self, weak item] _, _ in
            guard let self, let item else { return }
            Task { @MainActor [self, item] in
                guard self.player.currentItem === item else { return }
                self.onItemStatusChanged?(item)
            }
        }
        seekableTimeRangesObserver = item.observe(
            \.seekableTimeRanges,
            options: [.initial, .new]
        ) { [weak self, weak item] _, _ in
            guard let self, let item else { return }
            Task { @MainActor [self, item] in
                guard self.player.currentItem === item else { return }
                self.onSeekableTimeRangesChanged?(item)
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
}
