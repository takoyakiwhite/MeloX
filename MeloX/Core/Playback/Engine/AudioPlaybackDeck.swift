import AVFoundation

@MainActor
final class AudioPlaybackDeck {
    let player: AVPlayer
    let autoMixEqualizerState =
        SharedAutoMixEqualizerState()

    var onItemStatusChanged: ((AVPlayerItem) -> Void)?
    var onSeekableTimeRangesChanged: ((AVPlayerItem) -> Void)?
    var onPreciseMetadataReady: ((AVPlayerItem) -> Void)?
    private(set) var itemIdentifier: Int?
    private(set) var mediaTimeline =
        AudioPlaybackMediaTimeline()

    private var itemStatusObserver: NSKeyValueObservation?
    private var seekableTimeRangesObserver: NSKeyValueObservation?
    private var metadataTask: Task<Void, Never>?
    private var metadataRecoveryTask: Task<Void, Never>?
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
        metadataRecoveryTask?.cancel()
        metadataRecoveryTask = nil
        cancelCurrentAssetLoading()
        player.currentItem?.cancelPendingSeeks()
        player.cancelPendingPrerolls()
        autoMixEqualizerState.reset()
        itemStatusObserver?.invalidate()
        seekableTimeRangesObserver?.invalidate()
        itemIdentifier = identifier
        // Until precise track metadata is available, asset time zero is the
        // safe timeline. The metadata task below updates this only if the item
        // is still current.
        mediaTimeline = AudioPlaybackMediaTimeline()
        // A fallback media-zero timeline is immediately usable for ordinary
        // playback and progress publication. It is not precise and therefore
        // is never sufficient to start an AutoMix transition.
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
                self.applyMetadata(
                    metadata,
                    to: item
                )
                if metadata.timeline.isFallback {
                    self.startMetadataRecovery(
                        item: item,
                        loader: metadataLoader
                    )
                }
                return
            } catch is CancellationError {
                // Expected when next/previous/quality changes replace the item.
                return
            } catch {
                guard let self, let item,
                      !Task.isCancelled,
                      self.player.currentItem === item else {
                    return
                }

                // Keep the fallback timeline active. Ordinary playback can
                // continue immediately; precise timing is retried only in the
                // metadata path. AutoMix remains blocked on isPreciseMetadataReady.
                self.startMetadataRecovery(
                    item: item,
                    loader: metadataLoader
                )
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
        metadataRecoveryTask?.cancel()
        metadataRecoveryTask = nil
        autoMixEqualizerState.reset()
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        seekableTimeRangesObserver?.invalidate()
        seekableTimeRangesObserver = nil
        itemIdentifier = nil
        mediaTimeline = AudioPlaybackMediaTimeline()
        isPreciseMetadataReady = false
        onPreciseMetadataReady = nil
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
        metadataRecoveryTask?.cancel()
        metadataRecoveryTask = nil
        mediaTimeline = metadata.timeline
        item.audioMix = metadata.audioMix
        isPreciseMetadataReady = !metadata.timeline.isFallback
        if isPreciseMetadataReady {
            onPreciseMetadataReady?(item)
        }
        // Metadata can finish after the item became ready. Re-run the status
        // path so pending seeks and playback state consume the corrected
        // timeline immediately.
        onItemStatusChanged?(item)
    }

    private func startMetadataRecovery(
        item: AVPlayerItem,
        loader: @MainActor @escaping () async throws ->
            AudioPlaybackItemMetadata
    ) {
        metadataRecoveryTask?.cancel()
        metadataRecoveryTask = Task { @MainActor [weak self, weak item] in
            let delays: [Duration] = [
                .milliseconds(150),
                .milliseconds(400),
                .milliseconds(900),
                .milliseconds(1800)
            ]

            for delay in delays {
                do {
                    try await Task.sleep(for: delay)
                    try Task.checkCancellation()
                } catch {
                    return
                }

                guard let self, let item,
                      self.player.currentItem === item else {
                    return
                }

                do {
                    let metadata = try await loader()
                    guard !Task.isCancelled,
                          self.player.currentItem === item else {
                        return
                    }
                    self.applyMetadata(
                        metadata,
                        to: item
                    )
                    if !metadata.timeline.isFallback {
                        return
                    }
                    // A fallback result means the request completed, but it
                    // did not establish a precise track timeline. Continue to
                    // the next bounded retry instead of treating fallback as
                    // final.
                } catch is CancellationError {
                    return
                } catch {
                    // Keep the already-usable fallback timeline and allow the
                    // next bounded retry. If all retries fail, AVPlayer's own
                    // media clock remains the authoritative fallback.
                }
            }
        }
    }
}
