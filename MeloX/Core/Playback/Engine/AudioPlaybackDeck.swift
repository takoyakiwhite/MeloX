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
    private var metadataTask: Task<Void, Never>?

    init() {
        player = AVPlayer()
        player.automaticallyWaitsToMinimizeStalling = true
        player.networkResourcePriority = .high
        player.preventsDisplaySleepDuringVideoPlayback = false
    }

    func replaceCurrentItem(
        with playbackItem: PreparedAudioPlaybackItem,
        identifier: Int?,
        metadataLoader: (@MainActor () async throws ->
            AudioPlaybackItemMetadata)? = nil
    ) {
        let item = playbackItem.item
        metadataTask?.cancel()
        metadataTask = nil
        cancelCurrentAssetLoading()
        player.cancelPendingPrerolls()
        autoMixEqualizerState.reset()
        itemStatusObserver?.invalidate()
        seekableTimeRangesObserver?.invalidate()
        itemIdentifier = identifier
        // Until precise track metadata is available, asset time zero is the
        // safe timeline. The metadata task below updates this only if the item
        // is still current.
        mediaTimeline = AudioPlaybackMediaTimeline()
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

        guard let metadataLoader else { return }
        metadataTask = Task { @MainActor [weak self, weak item] in
            do {
                let metadata = try await metadataLoader()
                guard let self, let item,
                      !Task.isCancelled,
                      self.player.currentItem === item else {
                    return
                }
                self.mediaTimeline = metadata.timeline
                item.audioMix = metadata.audioMix
                // Metadata can finish after the item became ready. Re-run the
                // status path so pending seeks and playback state can consume
                // the corrected timeline.
                self.onItemStatusChanged?(item)
            } catch is CancellationError {
                // Expected when next/previous/quality changes replace the item.
            } catch {
                // Metadata is an optimization. AVPlayerItem remains responsible
                // for reporting actual playback failures.
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
        metadataTask?.cancel()
        metadataTask = nil
        autoMixEqualizerState.reset()
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        seekableTimeRangesObserver?.invalidate()
        seekableTimeRangesObserver = nil
        itemIdentifier = nil
        mediaTimeline = AudioPlaybackMediaTimeline()
        player.pause()
        cancelCurrentAssetLoading()
        player.cancelPendingPrerolls()
        player.replaceCurrentItem(with: nil)
        player.rate = 0
    }

    private func cancelCurrentAssetLoading() {
        guard let asset = player.currentItem?.asset
            as? AVURLAsset else {
            return
        }
        asset.cancelLoading()
    }
}
