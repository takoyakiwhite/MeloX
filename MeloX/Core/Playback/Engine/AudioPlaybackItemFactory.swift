@preconcurrency import AVFoundation


enum AudioPlaybackMetadataError: LocalizedError {
    case missingAudioTrack
    case invalidAudioTimeRange

    var errorDescription: String? {
        switch self {
        case .missingAudioTrack:
            return "音频轨道不可用。"
        case .invalidAudioTimeRange:
            return "无法取得精确音频时间轴。"
        }
    }
}

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
                    throw AudioPlaybackMetadataError.missingAudioTrack
                }
                try Task.checkCancellation()
                let range = try await audioTrack.load(.timeRange)
                try Task.checkCancellation()
                guard Self.isUsableTimeRange(range) else {
                    throw AudioPlaybackMetadataError.invalidAudioTimeRange
                }
                let audioMix = equalizerProcessor.makeAudioMix(
                    for: audioTrack,
                    autoMixEqualizerState: autoMixEqualizerState
                )
                return AudioPlaybackItemMetadata(
                    timeline: AudioPlaybackMediaTimeline(
                        audioTrackTimeRange: range
                    ),
                    audioMix: audioMix
                )
            },
            onCancel: {
                asset.cancelLoading()
            }
        )
    }

    private static func isUsableTimeRange(
        _ range: CMTimeRange
    ) -> Bool {
        guard range.isValid,
              range.start.isNumeric,
              range.duration.isNumeric else {
            return false
        }
        let start = range.start.seconds
        let duration = range.duration.seconds
        return start.isFinite
            && start >= 0
            && duration.isFinite
            && duration > 0
    }

    func updateEqualizer(
        _ configuration: AudioEqualizerConfiguration
    ) {
        equalizerProcessor.update(
            configuration: configuration
        )
    }
}
