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
        ) { [weak self, weak player] _, change in
            guard let self,
                  let player,
                  let item = change.newValue as? AVPlayerItem,
                  player.currentItem === item else {
                return
            }
            Task { @MainActor [self, item] in
                guard self.player.currentItem === item else {
                    return
                }
                guard let precisePlayer =
                    self.player as? MeloXAudioPlayer,
                    let preciseTimeline =
                        precisePlayer.preciseTimeline(for: item)
                else {
                    return
                }
                self.mediaTimeline = preciseTimeline
                self.itemStatusObserver?.invalidate()
                self.seekableTimeRangesObserver?.invalidate()
                self.installObservers(for: item)
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
        let item = playbackItem.item
        autoMixEqualizerState.reset()
        itemIdentifier = identifier
        mediaTimeline = playbackItem.timeline
        installObservers(for: item)
        player.replaceCurrentItem(with: item)
        (player as? MeloXAudioPlayer)?.preparePreciseIfNeeded(
            for: item
        )
    }

    private func installObservers(for item: AVPlayerItem) {
        itemStatusObserver?.invalidate()
        seekableTimeRangesObserver?.invalidate()

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
        currentItemObserver?.invalidate()
        currentItemObserver = nil
        itemIdentifier = nil
        mediaTimeline = AudioPlaybackMediaTimeline()
        player.pause()
        player.replaceCurrentItem(with: nil)
        player.rate = 0
    }
}
