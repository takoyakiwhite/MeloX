@preconcurrency import AVFoundation
import Foundation

/// AVPlayer compatibility wrapper for the playback engine.
///
/// FLAC precise-timing preparation is intentionally kept out of the seek path.
/// Replacing the current AVPlayerItem from inside AVPlayer.seek() breaks the
/// playback engine's item identity/state machine (notably lyric-tap seeking).
final class MeloXAudioPlayer: AVPlayer {
    nonisolated override init() {
        super.init()
    }

    nonisolated override init(url URL: URL) {
        super.init(url: URL)
    }

    nonisolated override init(playerItem item: AVPlayerItem?) {
        super.init(playerItem: item)
    }

    /// Keep AVPlayer's seek semantics intact. Never replace currentItem from
    /// this override because AudioPlaybackEngine validates item identity in
    /// its seek completion callback.
    nonisolated override func seek(
        to time: CMTime,
        toleranceBefore: CMTime,
        toleranceAfter: CMTime,
        completionHandler: @escaping @Sendable (Bool) -> Void
    ) {
        super.seek(
            to: time,
            toleranceBefore: toleranceBefore,
            toleranceAfter: toleranceAfter,
            completionHandler: completionHandler
        )
    }
}
