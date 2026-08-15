@preconcurrency import AVFoundation
import Foundation

/// AVPlayer compatibility layer for Xcode 26.5 and FLAC precise-timing
/// background handoff.
///
/// Normal FLAC seeks complete immediately on the current item. A second muted
/// player prepares the same URL with precise timing in the background. Once it
/// is ready, it seeks to the current real playback position, starts muted at
/// the same rate, verifies alignment, and only then hands the prepared item
/// back to the main player.
final class MeloXAudioPlayer: AVPlayer {
    private final class Configuration: @unchecked Sendable {
        let audioMix: AVAudioMix?
        let bufferDuration: TimeInterval
        let spatialization: AVAudioSpatializationFormats
        let pitchAlgorithm: AVAudioTimePitchAlgorithm

        init(item: AVPlayerItem) {
            audioMix = item.audioMix
            bufferDuration = item.preferredForwardBufferDuration
            spatialization = item.allowedAudioSpatializationFormats
            pitchAlgorithm = item.audioTimePitchAlgorithm
        }
    }

    private final class PreciseState: @unchecked Sendable {
        let lock = NSLock()
        var generation = 0
        var url: URL?
        var configuration: Configuration?
        var preparationTask: Task<AVPlayerItem?, Never>?
        var preparedItem: AVPlayerItem?

        func reset() {
            lock.lock()
            generation &+= 1
            preparationTask?.cancel()
            preparationTask = nil
            preparedItem = nil
            configuration = nil
            url = nil
            lock.unlock()
        }
    }

    private let preciseState = PreciseState()
    private let shadowPlayer = AVPlayer()
    private var handoffTask: Task<Void, Never>?

    private static let handoffTolerance: TimeInterval = 0.020
    private static let handoffPreparationTimeout: Duration = .seconds(3)
    private static let shadowSettleDelay: Duration = .milliseconds(30)

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
        let configuration = Configuration(item: item)

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
        preciseState.configuration = configuration
        preciseState.preparationTask?.cancel()
        preciseState.preparationTask = nil
        preciseState.preparedItem = nil
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
                preciseItem.preferredForwardBufferDuration =
                    configuration.bufferDuration
                preciseItem.allowedAudioSpatializationFormats =
                    configuration.spatialization
                preciseItem.audioTimePitchAlgorithm =
                    configuration.pitchAlgorithm
                preciseItem.audioMix = configuration.audioMix
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
        guard let asset = currentItem?.asset as? AVURLAsset,
              asset.url.pathExtension.lowercased() == "flac" else {
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
            completionHandler(finished)
            guard finished else { return }
            self?.schedulePreciseHandoffIfNeeded()
        }
    }

    /// Automatically attempts a seamless handoff after a normal FLAC seek.
    /// No caller waits for precise timing. The main player keeps playing while
    /// a muted shadow player prepares and aligns the precise item.
    nonisolated func schedulePreciseHandoffIfNeeded() {
        guard let item = currentItem,
              let asset = item.asset as? AVURLAsset,
              asset.url.pathExtension.lowercased() == "flac" else {
            return
        }

        handoffTask?.cancel()
        guard timeControlStatus == .playing || rate > 0 else { return }

        let url = asset.url
        let targetRate = max(rate, 1)
        let wasMuted = isMuted
        let currentVolume = volume

        handoffTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let prepared = await self.waitForPreparedItem(
                url: url,
                timeout: Self.handoffPreparationTimeout
            ) else {
                return
            }
            guard self.currentItem === item,
                  self.timeControlStatus == .playing || self.rate > 0,
                  self.currentTime().isNumeric else {
                return
            }

            let target = self.currentTime()
            self.shadowPlayer.pause()
            self.shadowPlayer.replaceCurrentItem(with: prepared)
            self.shadowPlayer.volume = 0
            self.shadowPlayer.muted = true
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
                    try? await Task.sleep(for: Self.shadowSettleDelay)

                    guard self.currentItem === item,
                          prepared === self.shadowPlayer.currentItem else {
                        return
                    }

                    let mainTime = self.currentTime().seconds
                    let shadowTime = self.shadowPlayer.currentTime().seconds
                    guard mainTime.isFinite,
                          shadowTime.isFinite,
                          abs(mainTime - shadowTime)
                            <= Self.handoffTolerance else {
                        self.shadowPlayer.pause()
                        self.shadowPlayer.replaceCurrentItem(with: nil)
                        return
                    }

                    // The shadow stream is already decoding at the target
                    // position. Switch the item only after both timelines are
                    // aligned, then immediately resume the same rate.
                    self.pause()
                    self.replaceCurrentItem(with: prepared)
                    self.shadowPlayer.pause()
                    self.shadowPlayer.replaceCurrentItem(with: nil)
                    self.volume = currentVolume
                    self.isMuted = wasMuted
                    self.playImmediately(atRate: targetRate)
                }
            }
        }
    }

    private nonisolated func waitForPreparedItem(
        url: URL,
        timeout: Duration
    ) async -> AVPlayerItem? {
        preciseState.lock.lock()
        let existing = preciseState.url == url
            ? preciseState.preparedItem
            : nil
        let task = preciseState.url == url
            ? preciseState.preparationTask
            : nil
        preciseState.lock.unlock()

        if let existing {
            return existing
        }
        guard let task else { return nil }

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
