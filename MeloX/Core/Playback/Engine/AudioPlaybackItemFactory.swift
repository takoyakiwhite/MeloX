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
        let asset = AVURLAsset(
            url: source.url,
            options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: true
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

                guard let audioTrack = try await asset.loadTracks(
                    withMediaType: .audio
                ).first else {
                    return AudioPlaybackItemMetadata(
                        timeline: AudioPlaybackMediaTimeline(),
                        audioMix: nil
                    )
                }

                try Task.checkCancellation()
                let audioTrackTimeRange =
                    try? await audioTrack.load(.timeRange)
                try Task.checkCancellation()

                let audioMix = equalizerProcessor.makeAudioMix(
                    for: audioTrack,
                    autoMixEqualizerState: autoMixEqualizerState
                )

                return AudioPlaybackItemMetadata(
                    timeline: AudioPlaybackMediaTimeline(
                        audioTrackTimeRange: audioTrackTimeRange
                    ),
                    audioMix: audioMix
                )
            },
            onCancel: {
                // AVAsset property loads are independent of Swift task
                // cancellation. Explicitly cancel them as soon as the track
                // request becomes obsolete.
                asset.cancelLoading()
            }
        )
    }

    func updateEqualizer(
        _ configuration: AudioEqualizerConfiguration
    ) {
        equalizerProcessor.update(
            configuration: configuration
        )
    }
}
