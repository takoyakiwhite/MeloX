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
        var preciseTimingTask:
            Task<AudioPlaybackMediaTimeline?, Never>?
        do {
            if let audioTrack = try await asset.loadTracks(
                withMediaType: .audio
            ).first {
                item.audioMix =
                    equalizerProcessor.makeAudioMix(
                        for: audioTrack,
                        autoMixEqualizerState:
                            autoMixEqualizerState
                    )

                preciseTimingTask = Task {
                    let preciseAsset = AVURLAsset(
                        url: source.url,
                        options: [
                            AVURLAssetPreferPreciseDurationAndTimingKey: true
                        ]
                    )
                    do {
                        guard let preciseTrack = try await preciseAsset
                            .loadTracks(withMediaType: .audio)
                            .first else {
                            return nil
                        }
                        let timeRange = try await preciseTrack.load(
                            .timeRange
                        )
                        return AudioPlaybackMediaTimeline(
                            audioTrackTimeRange: timeRange
                        )
                    } catch is CancellationError {
                        return nil
                    } catch {
                        return nil
                    }
                }
            }
        } catch {
            // AVPlayerItem reports an actionable error if playback fails.
        }
        return PreparedAudioPlaybackItem(
            item: item,
            timeline: AudioPlaybackMediaTimeline(),
            preciseTimingTask: preciseTimingTask
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
