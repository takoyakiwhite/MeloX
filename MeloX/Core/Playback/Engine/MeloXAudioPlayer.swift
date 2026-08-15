@preconcurrency import AVFoundation
import Foundation

/// AVPlayer compatibility layer for Xcode 26.5 and FLAC precise-timing
/// background handoff.
///
/// Normal FLAC seeks always complete immediately on the current item. A second
/// muted player prepares the same URL with precise timing in the background.
/// Once that player is ready, it seeks to the current real playback position,
/// starts muted at the same rate, and only then hands the prepared item back to
/// the main player. This avoids making the first seek wait for precise timing.
final class MeloXAudioPlayer: AVPlayer {
    private final class PreciseState: @unchecked Sendable {
        let lock = NSLock()
        var generation = 0
        var url: URL?
        var preparationTask: Task<AVPlayerItem?, Never>?
        var preparedItem: AVPlayerItem?
        var preparedDuration: CMTime = .invalid

        func reset() {
            lock.lock()
            generation &+= 1
            preparationTask?.cancel()
            preparationTask = nil
            preparedItem = nil
            preparedDuration = .invalid
            url = nil
            lock.unlock()
        }
    }

    private let preciseState = PreciseState()
    private let shadowPlayer = AVPlayer()
    private var handoffTask: Task<Void, Never>?
    private static let handoffTolerance: TimeInterval = 0.020
    private static let handoffPreparationTimeout: Duration = .seconds(3)

    nonisolated override init() {
        super.init()
        shadowPlayer.volume = 0
        shadowPlayer.muted = true
    }

    nonisolated override init(url URL: URL) {
        super.init(url: URL)
        shadowPlayer.volume = 0
        shadowPlayer.muted = true
    }

    nonisolated override init(playerItem item: AVPlayerItem?) {
        super.init(playerItem: item)
        shadowPlayer.volume = 0
        shadowPlayer.muted = true
    }

    deinit {
        handoffTask?.cancel()
        preciseState.reset()
        shadowPlayer.pause()
        shadowPlayer.replaceCurrentItem(with: nil)
    }

    nonisolated func preciseStateReset() {
        handoffTask?.cancel()
        handoffTask = nil
        preciseState.reset()
        shadowPlayer.pause()
        shadowPlayer.replaceCurrentItem(with: nil)
    }

    nonisolated func preparePreciseIfNeeded(
        for item: AVPlayerItem
    ) {
        guard let asset = item.asset as? AVURLAsset,
              asset.url.pathExtension.lowercased() == "flac" else {
            preciseState.reset()
            return
        }

        let url = asset.url
        preciseState.lock.lock()
        if preciseState.url == url,
           preciseState.preparationTask != nil ||
            preciseState.preparedItem != nil {
            preciseState.lock.unlock()
            return
        }
        preciseState.generation &+= 1
        let generation = preciseState.generation
        preciseState.url = url
        preciseState.preparationTask?.cancel()
        preciseState.preparationTask = nil
        preciseState.preparedItem = nil
        preciseState.preparedDuration = .invalid
        preciseState.lock.unlock()

        let task = Task.detached(priority: .utility) {
            () -> AVPlayerItem? in
            let preciseAsset = AVURLAsset(
                url: url,
                options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
            )
            do {
                _ = try await preciseAsset.load(.duration)
                guard let track = try await preciseAsset.loadTracks(
                    withMediaType: .audio
                ).first else {
                    return nil
                }
                let preciseItem = AVPlayerItem(asset: preciseAsset)
                if let range = try? await track.load(.timeRange),
                   range.duration.isNumeric {
                    preciseItem.forwardPlaybackEndTime =
                        CMTimeAdd(range.start, range.duration)
                }
                return preciseItem
            } catch {
                return nil
            }
        }

        preciseState.lock.lock()
        guard preciseState.generation == generation else {
            preciseState.lock.unlock()
            task.cancel()
            return
        }
        preciseState.preparationTask = task
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
            self.preciseState.preparationTask = nil
            self.preciseState.preparedItem = result
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

    /// Called automatically after a FLAC seek has completed. The caller does
    /// not need to await it. When precise timing is ready, the current main
    /// player is synchronized to a muted shadow player and the prepared item is
    /// handed off at the same position/rate.
    nonisolated func schedulePreciseHandoffIfNeeded() {
        guard let item = currentItem,
              let asset = item.asset as? AVURLAsset,
              asset.url.pathExtension.lowercased() == "flac" else {
            return
        }

        handoffTask?.cancel()
        let wasPlaying = timeControlStatus == .playing || rate > 0
        guard wasPlaying else { return }
        let url = asset.url
        let targetRate = max(rate, 1)

        handoffTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let prepared = await self.waitForPreparedItem(
                url: url,
                timeout: Self.handoffPreparationTimeout
            )
            guard let prepared,
                  self.currentItem === item,
                  self.currentTime().isNumeric else {
                return
            }

            let target = self.currentTime()
            self.shadowPlayer.replaceCurrentItem(with: prepared)
            self.shadowPlayer.volume = 0
            self.shadowPlayer.muted = true
            self.shadowPlayer.rate = 0

            prepared.cancelPendingSeeks()
            self.shadowPlayer.seek(
                to: target,
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { [weak self] finished in
                guard let self, finished else { return }
                Task { @MainActor [weak self] in
                    guard let self,
                          self.currentItem === item,
                          prepared === self.shadowPlayer.currentItem else {
                        return
                    }
                    self.shadowPlayer.playImmediately(atRate: targetRate)
                    let shadowTime = self.shadowPlayer.currentTime()
                    let mainTime = self.currentTime()
                    guard shadowTime.isNumeric,
                          mainTime.isNumeric,
                          abs(shadowTime.seconds - mainTime.seconds)
                            <= Self.handoffTolerance else {
                        return
                    }

                    self.handoffTask?.cancel()
                    let preservedVolume = self.volume
                    let preservedMuted = self.isMuted
                    self.shadowPlayer.volume = preservedMuted
                        ? 0
                        : preservedVolume
                    self.shadowPlayer.muted = preservedMuted

                    self.pause()
                    self.replaceCurrentItem(with: prepared)
                    self.shadowPlayer.pause()
                    self.shadowPlayer.replaceCurrentItem(with: nil)
                    self.volume = preservedVolume
                    self.isMuted = preservedMuted
                    self.playImmediately(atRate: targetRate)
                }
            }
        }
    }

    private nonisolated func waitForPreparedItem(
        url: URL,
        timeout: Duration
    ) async -> AVPlayerItem? {
        let existing: AVPlayerItem?
        preciseState.lock.lock()
        existing = preciseState.url == url
            ? preciseState.preparedItem
            : nil
        let task = preciseState.url == url
            ? preciseState.preparationTask
            : nil
        preciseState.lock.unlock()

        if let existing {
            return existing
        }
        guard let task else {
            return nil
        }

        return await withTaskGroup(of: AVPlayerItem?.self) { group in
            group.addTask {
                await task.value
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let result = await group.next()!
            group.cancelAll()
            return result
        }
    }
}
