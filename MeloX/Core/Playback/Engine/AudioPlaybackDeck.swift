import AVFoundation

@MainActor
final class AudioPlaybackDeck {
    let player: AVPlayer
    let autoMixEqualizerState =
        SharedAutoMixEqualizerState()

    var onItemStatusChanged: ((AVPlayerItem) -> Void)?
    var onSeekableTimeRangesChanged: ((AVPlayerItem) -> Void)?
    var onPreciseMetadataReady: ((AVPlayerItem) -> Void)?
    var onMetadataFailure: ((AVPlayerItem, Error) -> Void)?
    private(set) var itemIdentifier: Int?
    private(set) var mediaTimeline =
        AudioPlaybackMediaTimeline()

    private var itemStatusObserver: NSKeyValueObservation?
    private var seekableTimeRangesObserver: NSKeyValueObservation?
    private var metadataTask: Task<Void, Never>?
    private(set) var isPreciseMetadataReady = false

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
        player.currentItem?.cancelPendingSeeks()
        player.cancelPendingPrerolls()
        autoMixEqualizerState.reset()
        itemStatusObserver?.invalidate()
        seekableTimeRangesObserver?.invalidate()
        itemIdentifier = identifier
        // The timeline remains non-publishable until precise metadata resolves.
        mediaTimeline = AudioPlaybackMediaTimeline()
        isPreciseMetadataReady = false
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
                self.applyMetadata(metadata, to: item)
            } catch is CancellationError {
                return
            } catch {
                guard let self, let item,
                      !Task.isCancelled,
                      self.player.currentItem === item else {
                    return
                }
                self.onMetadataFailure?(item, error)
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
        isPreciseMetadataReady = false
        onPreciseMetadataReady = nil
        onMetadataFailure = nil
        player.pause()
        cancelCurrentAssetLoading()
        player.currentItem?.cancelPendingSeeks()
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

    private func applyMetadata(
        _ metadata: AudioPlaybackItemMetadata,
        to item: AVPlayerItem
    ) {
        guard player.currentItem === item else { return }
        mediaTimeline = metadata.timeline
        item.audioMix = metadata.audioMix
        isPreciseMetadataReady = true
        onPreciseMetadataReady?(item)
        // Metadata can finish after the item became ready. Re-run the status
        // path so pending seeks and playback state consume the corrected
        // timeline immediately.
        onItemStatusChanged?(item)
    }

}
