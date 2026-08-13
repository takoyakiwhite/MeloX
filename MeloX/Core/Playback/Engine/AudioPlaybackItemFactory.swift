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

    /// Creates a player item together with its precise media timeline and audio mix.
    /// Precise timing is resolved before the item is handed to a deck so there is
    /// only one timeline path and no background metadata/fallback state machine.
    func makeItem(
        for source: PlaybackSource,
        preferredForwardBufferDuration: TimeInterval,
        autoMixEqualizerState: SharedAutoMixEqualizerState
    ) async throws -> PreparedAudioPlaybackItem {
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
                return PreparedAudioPlaybackItem(
                    item: item,
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
