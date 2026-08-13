@preconcurrency import AVFoundation
import Foundation

/// Maps the container timeline used by AVPlayer to the song timeline used by
/// playback controls and lyrics. Some encodings start their audio track after
/// asset time zero, so passing lyric seconds directly to AVPlayer would seek
/// into a different point after changing source quality.
struct AudioPlaybackMediaTimeline {
    enum Resolution: Equatable {
        case preciseTrackTimeRange
        case mediaZeroFallback
    }

    let mediaStart: TimeInterval
    let trackDuration: TimeInterval?
    let resolution: Resolution

    init(audioTrackTimeRange: CMTimeRange? = nil) {
        if let range = audioTrackTimeRange,
           range.isValid,
           range.start.isNumeric,
           range.duration.isNumeric {
            let start = range.start.seconds
            let duration = range.duration.seconds
            if start.isFinite,
               start >= 0,
               duration.isFinite,
               duration > 0 {
                mediaStart = start
                trackDuration = duration
                resolution = .preciseTrackTimeRange
                return
            }
        }

        mediaStart = 0
        trackDuration = nil
        resolution = .mediaZeroFallback
    }

    var isFallback: Bool {
        resolution == .mediaZeroFallback
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
            preferredTimescale: 600
        )
    }

    func playbackDuration(
        forMediaDuration mediaDuration: CMTime
    ) -> TimeInterval? {
        if let trackDuration,
           trackDuration.isFinite,
           trackDuration > 0 {
            return trackDuration
        }
        let seconds = mediaDuration.seconds
        guard seconds.isFinite, seconds > 0 else {
            return nil
        }
        return max(seconds - mediaStart, 0)
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
