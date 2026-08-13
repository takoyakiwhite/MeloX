@preconcurrency import AVFoundation
import Foundation

/// Maps the container timeline used by AVPlayer to the song timeline used by
/// playback controls and lyrics. Some encodings start their audio track after
/// asset time zero, so passing lyric seconds directly to AVPlayer would seek
/// into a different point after changing source quality.
struct AudioPlaybackMediaTimeline {
    let mediaStart: TimeInterval
    let trackDuration: TimeInterval

    init() {
        mediaStart = 0
        trackDuration = 0
    }

    init(audioTrackTimeRange: CMTimeRange) {
        precondition(
            audioTrackTimeRange.isValid,
            "AudioPlaybackMediaTimeline requires a valid time range"
        )
        precondition(
            audioTrackTimeRange.start.isNumeric,
            "AudioPlaybackMediaTimeline requires a numeric start"
        )
        precondition(
            audioTrackTimeRange.duration.isNumeric,
            "AudioPlaybackMediaTimeline requires a numeric duration"
        )
        mediaStart = max(audioTrackTimeRange.start.seconds, 0)
        trackDuration = max(audioTrackTimeRange.duration.seconds, 0)
    }

    func playbackPosition(
        forMediaTime mediaTime: CMTime
    ) -> TimeInterval? {
        let seconds = mediaTime.seconds
        guard seconds.isFinite else { return nil }
        return max(seconds - mediaStart, 0)
    }

    func mediaTime(
        forPlaybackPosition position: TimeInterval
    ) -> CMTime {
        let normalizedPosition = position.isFinite
            ? max(position, 0)
            : 0
        return CMTime(
            seconds: normalizedPosition + mediaStart,
            preferredTimescale: 1_000_000
        )
    }

    func playbackDuration(
        forMediaDuration _: CMTime
    ) -> TimeInterval? {
        guard trackDuration.isFinite, trackDuration > 0 else {
            return nil
        }
        return trackDuration
    }
}

struct PreparedAudioPlaybackItem {
    let item: AVPlayerItem
    let asset: AVURLAsset
}

struct AudioPlaybackItemMetadata {
    let timeline: AudioPlaybackMediaTimeline
    let audioMix: AVAudioMix?
}
