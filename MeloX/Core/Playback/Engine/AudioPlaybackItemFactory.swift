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

    func makeItem(
        for source: PlaybackSource,
        preferredForwardBufferDuration: TimeInterval,
        autoMixEqualizerState:
            SharedAutoMixEqualizerState
    ) async -> PreparedAudioPlaybackItem {
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
        var audioTrackTimeRange: CMTimeRange?
        do {
            if let audioTrack = try await asset.loadTracks(
                withMediaType: .audio
            ).first {
                audioTrackTimeRange = try? await audioTrack.load(
                    .timeRange
                )
                item.audioMix =
                    equalizerProcessor.makeAudioMix(
                        for: audioTrack,
                        autoMixEqualizerState:
                            autoMixEqualizerState
                    )
            }
        } catch {
            // AVPlayerItem reports an actionable error if playback fails.
        }
        return PreparedAudioPlaybackItem(
            item: item,
            timeline: AudioPlaybackMediaTimeline(
                audioTrackTimeRange: audioTrackTimeRange
            ),
            preciseTimingURL: source.url
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
