@preconcurrency import AVFoundation
import Foundation

/// AVPlayer compatibility layer for Xcode 26.5.
///
/// FLAC playback remains on the fast AVPlayer item. In the background a
/// precise-timing AVURLAsset is loaded and only its timing metadata is exposed
/// to the playback deck. The playing item is never replaced.
final class MeloXAudioPlayer: AVPlayer {
    struct PreciseTimingSnapshot: @unchecked Sendable {
        let timeline: AudioPlaybackMediaTimeline
        let duration: TimeInterval?
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var generation = 0
        var url: URL?
        var task: Task<PreciseTimingSnapshot?, Never>?
        var snapshot: PreciseTimingSnapshot?

        func reset() {
            lock.lock()
            generation &+= 1
            task?.cancel()
            task = nil
            snapshot = nil
            url = nil
            lock.unlock()
        }
    }

    private let preciseState = State()

    nonisolated override init() {
        super.init()
    }

    nonisolated override init(url URL: URL) {
        super.init(url: URL)
    }

    nonisolated override init(playerItem item: AVPlayerItem?) {
        super.init(playerItem: item)
    }

    deinit {
        preciseState.reset()
    }

    nonisolated func preciseStateReset() {
        preciseState.reset()
    }

    nonisolated func preciseTimingSnapshot(
        for item: AVPlayerItem
    ) -> PreciseTimingSnapshot? {
        preciseState.lock.lock()
        defer { preciseState.lock.unlock() }
        guard let asset = item.asset as? AVURLAsset,
              asset.url.pathExtension.lowercased() == "flac",
              preciseState.url == asset.url,
              let snapshot = preciseState.snapshot else {
            return nil
        }
        return snapshot
    }

    nonisolated func preparePreciseTimingIfNeeded(
        for item: AVPlayerItem
    ) {
        guard let asset = item.asset as? AVURLAsset,
              asset.url.pathExtension.lowercased() == "flac" else {
            preciseState.reset()
            return
        }

        let url = asset.url
        preciseState.lock.lock()
        if preciseState.url == url {
            let preparing = preciseState.task != nil
            let prepared = preciseState.snapshot != nil
            preciseState.lock.unlock()
            if preparing || prepared {
                return
            }
        } else {
            preciseState.generation &+= 1
            preciseState.task?.cancel()
            preciseState.task = nil
            preciseState.snapshot = nil
            preciseState.url = url
            preciseState.lock.unlock()
        }

        preciseState.lock.lock()
        let generation = preciseState.generation
        preciseState.lock.unlock()

        let task = Task.detached(priority: .utility) {
            () -> PreciseTimingSnapshot? in
            let preciseAsset = AVURLAsset(
                url: url,
                options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
            )
            do {
                let duration = try await preciseAsset.load(.duration)
                let track = try await preciseAsset.loadTracks(
                    withMediaType: .audio
                ).first
                let timeRange = try await track?.load(.timeRange)
                let timeline = AudioPlaybackMediaTimeline(
                    audioTrackTimeRange: timeRange
                )
                let seconds = duration.seconds
                return PreciseTimingSnapshot(
                    timeline: timeline,
                    duration: seconds.isFinite
                        ? max(seconds - timeline.mediaStart, 0)
                        : nil
                )
            } catch {
                return nil
            }
        }

        preciseState.lock.lock()
        guard preciseState.generation == generation,
              preciseState.url == url else {
            preciseState.lock.unlock()
            task.cancel()
            return
        }
        preciseState.task = task
        preciseState.lock.unlock()

        Task { @MainActor [weak self] in
            let result = await task.value
            guard let self else { return }
            self.preciseState.lock.lock()
            guard self.preciseState.generation == generation,
                  self.preciseState.url == url else {
                self.preciseState.lock.unlock()
                return
            }
            self.preciseState.task = nil
            self.preciseState.snapshot = result
            self.preciseState.lock.unlock()
        }
    }

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
