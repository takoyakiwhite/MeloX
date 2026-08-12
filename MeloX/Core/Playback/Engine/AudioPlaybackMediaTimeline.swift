@preconcurrency import AVFoundation
import Foundation

/// Maps the container timeline used by AVPlayer to the song timeline used by
/// playback controls and lyrics. Some encodings start their audio track after
/// asset time zero, so passing lyric seconds directly to AVPlayer would seek
/// into a different point after changing source quality.
struct AudioPlaybackMediaTimeline {
    let mediaStart: TimeInterval
    let knownPlaybackDuration: TimeInterval?

    init(
        audioTrackTimeRange: CMTimeRange? = nil,
        knownPlaybackDuration: TimeInterval? = nil
    ) {
        let start = audioTrackTimeRange?.start.seconds ?? 0
        mediaStart = start.isFinite ? max(start, 0) : 0
        if let knownPlaybackDuration,
           knownPlaybackDuration.isFinite,
           knownPlaybackDuration > 0 {
            self.knownPlaybackDuration = knownPlaybackDuration
        } else {
            self.knownPlaybackDuration = nil
        }
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
        if let knownPlaybackDuration {
            return knownPlaybackDuration
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
    let timeline: AudioPlaybackMediaTimeline
    let preciseTimingURL: URL?
}
