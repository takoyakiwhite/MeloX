import AVFoundation

/// Gives FLAC decoder/output paths a short settle window after seek. The
/// requested media position is never changed; the existing playback engine
/// samples AVPlayer.currentTime after this callback and re-anchors its clock.
final class MeloXAudioPlayer: AVPlayer {
    private static let flacSeekSettleDelay: TimeInterval = 0.08

    nonisolated override init() {
        super.init()
    }

    nonisolated override init(url URL: URL) {
        super.init(url: URL)
    }

    nonisolated override init(playerItem item: AVPlayerItem?) {
        super.init(playerItem: item)
    }

    nonisolated override func seek(
        to time: CMTime,
        toleranceBefore: CMTime,
        toleranceAfter: CMTime,
        completionHandler: @escaping @Sendable (Bool) -> Void
    ) {
        guard isCurrentItemFLAC else {
            super.seek(
                to: time,
                toleranceBefore: toleranceBefore,
                toleranceAfter: toleranceAfter,
                completionHandler: completionHandler
            )
            return
        }

        super.seek(
            to: time,
            toleranceBefore: toleranceBefore,
            toleranceAfter: toleranceAfter
        ) { [weak self] finished in
            guard finished else {
                completionHandler(false)
                return
            }

            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.flacSeekSettleDelay
            ) {
                guard self?.currentItem != nil else {
                    completionHandler(false)
                    return
                }
                completionHandler(true)
            }
        }
    }

    private nonisolated var isCurrentItemFLAC: Bool {
        guard let asset = currentItem?.asset as? AVURLAsset else {
            return false
        }
        return asset.url.pathExtension.lowercased() == "flac"
    }
}
