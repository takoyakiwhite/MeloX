@preconcurrency import AVFoundation
import Foundation

/// AVPlayer compatibility layer for Xcode 26.5 and FLAC precise-timing
/// background handoff.
///
/// Normal FLAC playback and seeks use the fast, non-precise asset. A muted
/// shadow player prepares the same URL with precise timing in the background.
/// Once precise timing is ready, the shadow player is aligned to the current
/// playback position and a handoff is attempted automatically, even when the
/// user has never sought.
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

    private final class PreparedPayload: @unchecked Sendable {
        let item: AVPlayerItem
        let timeline: AudioPlaybackMediaTimeline

        init(item: AVPlayerItem, timeline: AudioPlaybackMediaTimeline) {
            self.item = item
            self.timeline = timeline
        }
    }

    private final class PreciseState: @unchecked Sendable {
        let lock = NSLock()
        var generation = 0
        var url: URL?
        var configuration: Configuration?
        var preparationTask: Task<PreparedPayload?, Never>?
        var prepared: PreparedPayload?

        func reset() {
            lock.lock()
            generation &+= 1
            preparationTask?.cancel()
            preparationTask = nil
            prepared = nil
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

    nonisolated func preciseTimeline(
        for item: AVPlayerItem
    ) -> AudioPlaybackMediaTimeline? {
        preciseState.lock.lock()
        defer { preciseState.lock.unlock() }
        guard let prepared = preciseState.prepared,
              prepared.item === item else {
            return nil
        }
        return prepared.timeline
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
        if preciseState.url == url {
            let alreadyPrepared = preciseState.prepared != nil
            let alreadyPreparing = preciseState.preparationTask != nil
            preciseState.lock.unlock()
            if alreadyPrepared || alreadyPreparing {
                if alreadyPrepared {
                    schedulePreciseHandoffIfNeeded()
                }
                return
            }
        } else {
            preciseState.generation &+= 1
            preciseState.url = url
            preciseState.configuration = configuration
            preciseState.preparationTask?.cancel()
            preciseState.preparationTask = nil
            preciseState.prepared = nil
            preciseState.lock.unlock()
        }

        preciseState.lock.lock()
        let generation = preciseState.generation
        preciseState.configuration = configuration
        preciseState.lock.unlock()

        let task = Task.detached(priority: .utility) {
            () -> PreparedPayload? in
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
                let timeRange = try? await track.load(.timeRange)
                let preciseItem = AVPlayerItem(asset: preciseAsset)
                preciseItem.preferredForwardBufferDuration =
                    configuration.bufferDuration
                preciseItem.allowedAudioSpatializationFormats =
                    configuration.spatialization
                preciseItem.audioTimePitchAlgorithm =
                    configuration.pitchAlgorithm
                preciseItem.audioMix = configuration.audioMix
                return PreparedPayload(
                    item: preciseItem,
                    timeline: AudioPlaybackMediaTimeline(
                        audioTrackTimeRange: timeRange
                    )
                )
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
            self.preciseState.prepared = result
            self.preciseState.lock.unlock()
            guard result != nil else { return }
            self.schedulePreciseHandoffIfNeeded()
        }
    }

    nonisolated override func play() {
        super.play()
        schedulePreciseHandoffIfNeeded()
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

    /// Automatically calibrates FLAC timing after precise preparation. It is
    /// also called after a seek and when normal playback starts, but the first
    /// seek never waits for precise timing.
    nonisolated func schedulePreciseHandoffIfNeeded() {
        guard let item = currentItem,
              let asset = item.asset as? AVURLAsset,
              asset.url.pathExtension.lowercased() == "flac" else {
            return
        }

        preciseState.lock.lock()
        let prepared = preciseState.prepared
        preciseState.lock.unlock()
        if let prepared, prepared.item === item {
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
            guard let payload = await self.waitForPreparedPayload(
                url: url,
                timeout: Self.handoffPreparationTimeout
            ) else {
                return
            }

            let prepared = payload.item
            guard self.currentItem === item,
                  self.timeControlStatus == .playing || self.rate > 0,
                  self.currentTime().isNumeric else {
                return
            }

            let target = self.currentTime()
            let targetPlaybackPosition = max(target.seconds, 0)
            self.shadowPlayer.pause()
            self.shadowPlayer.replaceCurrentItem(with: prepared)
            self.shadowPlayer.volume = 0
            self.shadowPlayer.muted = true
            self.shadowPlayer.seek(
                to: payload.timeline.mediaTime(
                    forPlaybackPosition: targetPlaybackPosition
                ),
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
                    let shadowPlaybackTime =
                        payload.timeline.playbackPosition(
                            forMediaTime: self.shadowPlayer.currentTime()
                        ) ?? .nan

                    guard mainTime.isFinite,
                          shadowPlaybackTime.isFinite,
                          abs(mainTime - target.seconds) <=
                            Self.handoffTolerance,
                          abs(shadowPlaybackTime - targetPlaybackPosition) <=
                            Self.handoffTolerance else {
                        self.shadowPlayer.pause()
                        self.shadowPlayer.replaceCurrentItem(with: nil)
                        return
                    }

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

    private nonisolated func waitForPreparedPayload(
        url: URL,
        timeout: Duration
    ) async -> PreparedPayload? {
        preciseState.lock.lock()
        let existing = preciseState.url == url
            ? preciseState.prepared
            : nil
        let task = preciseState.url == url
            ? preciseState.preparationTask
            : nil
        preciseState.lock.unlock()

        if let existing {
            return existing
        }
        guard let task else { return nil }

        return await withTaskGroup(of: PreparedPayload?.self) { group in
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
