import AVFoundation

/// Adds a FLAC-specific seek validation layer without changing AVURLAsset
/// loading options or adding a fixed post-seek delay. AVPlayer's exact seek
/// completion is accepted only when the reported media time is close to the
/// requested media time. If it is not, the existing playback engine retry
/// path is allowed to issue another seek.
final class MeloXAudioPlayer: AVPlayer {
    private static let flacSeekAcceptanceTolerance: TimeInterval = 0.025

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
            guard finished, let self else {
                completionHandler(false)
                return
            }

            let current = self.currentTime().seconds
            let target = time.seconds
            guard current.isFinite,
                  target.isFinite,
                  abs(current - target)
                    <= Self.flacSeekAcceptanceTolerance else {
                completionHandler(false)
                return
            }

            completionHandler(true)
        }
    }

    private nonisolated var isCurrentItemFLAC: Bool {
        guard let asset = currentItem?.asset as? AVURLAsset else {
            return false
        }
        return asset.url.pathExtension.lowercased() == "flac"
    }
}
