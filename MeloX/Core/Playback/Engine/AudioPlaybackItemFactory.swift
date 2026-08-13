@preconcurrency import AVFoundation

@MainActor
final class AudioPlaybackItemFactory {
    private let equalizerProcessor:
        AudioEqualizerProcessor

    init(
        equalizerConfiguration:
            AudioEqualizerConfiguration
    ) {
        equalizerProcessor = AudioEqualizerProcessor(
            configuration: equalizerConfiguration
        )
    }

    /// Creates the player item without synchronously waiting for AVFoundation
    /// to inspect the remote media. This is important for network sources when
    /// precise duration/timing is requested: AVFoundation may need to parse a
    /// large portion of the resource before the timing metadata is available.
    /// The player can start its normal item loading immediately instead.
    func makeItem(
        for source: PlaybackSource,
        preferredForwardBufferDuration: TimeInterval
    ) -> PreparedAudioPlaybackItem {
        // Keep the primary playback asset on AVFoundation's fast/best-effort
        // timing path. Precise timing is resolved asynchronously only when
        // the normal track metadata cannot provide a usable time range.
        let asset = AVURLAsset(
            url: source.url,
            options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: false
            ]
        )
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration =
            max(
                preferredForwardBufferDuration,
                source.preferredForwardBufferDuration
            )
        item.allowedAudioSpatializationFormats = .multichannel
        return PreparedAudioPlaybackItem(
            item: item,
            asset: asset
        )
    }

    /// Loads the metadata that is useful to MeloX after the AVPlayerItem has
    /// already been installed in its deck. The operation is cancellation-aware
    /// so rapidly changing tracks do not leave a precise-timing asset parsing
    /// in the background.
    func loadMetadata(
        for playbackItem: PreparedAudioPlaybackItem,
        autoMixEqualizerState:
            SharedAutoMixEqualizerState
    ) async throws -> AudioPlaybackItemMetadata {
        let asset = playbackItem.asset

        return try await withTaskCancellationHandler(
            operation: {
                try Task.checkCancellation()

                let audioTrack = try await asset.loadTracks(
                    withMediaType: .audio
                ).first

                guard let audioTrack else {
                    return AudioPlaybackItemMetadata(
                        timeline: AudioPlaybackMediaTimeline(),
                        audioMix: nil
                    )
                }

                try Task.checkCancellation()

                // First prefer the already-loaded playback asset. This avoids a
                // second network parser in the common case while still giving us a
                // concrete track time range whenever the container exposes it.
                var resolvedRange: CMTimeRange?
                do {
                    resolvedRange = try await audioTrack.load(.timeRange)
                } catch {
                    resolvedRange = nil
                }
                try Task.checkCancellation()

                // If the fast asset cannot provide a usable range, escalate only
                // the metadata path to a precise AVURLAsset. Playback itself never
                // waits for this asset. The precise asset is used only as a timing
                // authority; the audio mix is still built against the primary
                // item's track.
                if !isUsableTimeRange(resolvedRange) {
                    do {
                        if let preciseRange = try await
                            loadPreciseTrackTimeRange(from: asset.url),
                           isUsableTimeRange(preciseRange) {
                            resolvedRange = preciseRange
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // Keep the fallback media-zero timeline if the precise
                        // metadata path is unavailable.
                    }
                }

                try Task.checkCancellation()
                let audioMix = equalizerProcessor.makeAudioMix(
                    for: audioTrack,
                    autoMixEqualizerState: autoMixEqualizerState
                )

                return AudioPlaybackItemMetadata(
                    timeline: AudioPlaybackMediaTimeline(
                        audioTrackTimeRange: resolvedRange
                    ),
                    audioMix: audioMix
                )
            },
            onCancel: {
                asset.cancelLoading()
            }
        )
    }

    private func loadPreciseTrackTimeRange(
        from url: URL
    ) async throws -> CMTimeRange? {
        let preciseAsset = AVURLAsset(
            url: url,
            options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: true
            ]
        )

        return try await withTaskCancellationHandler(
            operation: {
                try Task.checkCancellation()
                let preciseTrack = try await preciseAsset
                    .loadTracks(withMediaType: .audio)
                    .first
                guard let preciseTrack else {
                    return nil
                }
                try Task.checkCancellation()
                return try await preciseTrack.load(.timeRange)
            },
            onCancel: {
                preciseAsset.cancelLoading()
            }
        )
    }

    private func isUsableTimeRange(
        _ range: CMTimeRange?
    ) -> Bool {
        guard let range,
              range.isValid,
              range.start.isNumeric else {
            return false
        }
        let start = range.start.seconds
        let duration = range.duration.seconds
        return start.isFinite
            && start >= 0
            && duration.isFinite
            && duration >= 0
    }

    func updateEqualizer(
        _ configuration: AudioEqualizerConfiguration
    ) {
        equalizerProcessor.update(
            configuration: configuration
        )
    }
}
