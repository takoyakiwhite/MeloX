@preconcurrency import AVFoundation
import Foundation

/// AVPlayer compatibility layer for Xcode 26.5 plus background precise-timing
/// preparation for FLAC. The normal seek completion is allowed to finish the
/// playback engine's own seek transaction before any precise-item handoff.
final class MeloXAudioPlayer: AVPlayer {
    private final class PreparedPayload: @unchecked Sendable {
        let item: AVPlayerItem
        let timeline: AudioPlaybackMediaTimeline

        init(item: AVPlayerItem, timeline: AudioPlaybackMediaTimeline) {
            self.item = item
            self.timeline = timeline
        }
    }

    private final class Configuration: @unchecked Sendable {
        let audioMix: AVAudioMix?
        let bufferDuration: TimeInterval
        let spatialization: AVAudioSpatializationFormats
        let pitchAlgorithm: AVAudioTimePitchAlgorithm

        init(
            audioMix: AVAudioMix?,
            bufferDuration: TimeInterval,
            spatialization: AVAudioSpatializationFormats,
            pitchAlgorithm: AVAudioTimePitchAlgorithm
        ) {
            self.audioMix = audioMix
            self.bufferDuration = bufferDuration
            self.spatialization = spatialization
            self.pitchAlgorithm = pitchAlgorithm
        }
    }

    private final class PreciseState: @unchecked Sendable {
        let lock = NSLock()
        var generation = 0
        var seekGeneration = 0
        var url: URL?
        var configuration: Configuration?
        var preparationTask: Task<PreparedPayload?, Never>?
        var prepared: PreparedAudioPlaybackItem?

        func reset() {
            lock.lock()
            generation &+= 1
            seekGeneration &+= 1
            preparationTask?.cancel()
            preparationTask = nil
            prepared = nil
            configuration = nil
            url = nil
            lock.unlock()
        }
    }

    private let preciseState = PreciseState()
    private static let correctionTolerance: TimeInterval = 0.025
    private static let correctionWait: Duration = .milliseconds(300)

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
        preciseState.lock.lock()
        if preciseState.url == url,
           preciseState.preparationTask != nil ||
            preciseState.prepared != nil {
            preciseState.lock.unlock()
            return
        }

        preciseState.generation &+= 1
        let generation = preciseState.generation
        preciseState.url = url
        preciseState.configuration = Configuration(
            audioMix: item.audioMix,
            bufferDuration: item.preferredForwardBufferDuration,
            spatialization: item.allowedAudioSpatializationFormats,
            pitchAlgorithm: item.audioTimePitchAlgorithm
        )
        preciseState.preparationTask?.cancel()
        preciseState.preparationTask = nil
        preciseState.prepared = nil
        let configuration = preciseState.configuration
        preciseState.lock.unlock()

        guard let configuration else { return }

        let task = Task.detached(priority: .utility) {
            () -> PreparedPayload? in
            let asset = AVURLAsset(
                url: url,
                options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
            )
            do {
                _ = try await asset.load(.duration)
                guard let track = try await asset.loadTracks(
                    withMediaType: .audio
                ).first else {
                    return nil
                }
                let timeRange = try? await track.load(.timeRange)
                let preciseItem = AVPlayerItem(asset: asset)
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
            self.preciseState.prepared = result.map {
                PreparedAudioPlaybackItem(
                    item: $0.item,
                    timeline: $0.timeline
                )
            }
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

        let url = asset.url
        preciseState.lock.lock()
        preciseState.seekGeneration &+= 1
        let seekGeneration = preciseState.seekGeneration
        let preparationTask = preciseState.preparationTask
        preciseState.lock.unlock()

        super.seek(
            to: time,
            toleranceBefore: toleranceBefore,
            toleranceAfter: toleranceAfter
        ) { [weak self] finished in
            completionHandler(finished)
            guard finished else { return }

            Task { @MainActor [weak self] in
                guard let self else { return }
                await Task.yield()
                self.schedulePreciseCorrection(
                    url: url,
                    target: time,
                    seekGeneration: seekGeneration,
                    preparationTask: preparationTask
                )
            }
        }
    }

    @MainActor
    private func schedulePreciseCorrection(
        url: URL,
        target: CMTime,
        seekGeneration: Int,
        preparationTask: Task<PreparedPayload?, Never>?
    ) {
        if let preparationTask {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result = await Self.awaitWithin(
                    preparationTask,
                    timeout: Self.correctionWait
                )
                guard result != nil else { return }
                self.performPreciseCorrectionIfNeeded(
                    url: url,
                    target: target,
                    seekGeneration: seekGeneration
                )
            }
        } else {
            performPreciseCorrectionIfNeeded(
                url: url,
                target: target,
                seekGeneration: seekGeneration
            )
        }
    }

    private static func awaitWithin(
        _ task: Task<PreparedPayload?, Never>,
        timeout: Duration
    ) async -> PreparedPayload?? {
        await withTaskGroup(of: PreparedPayload??.self) { group in
            group.addTask {
                .some(await task.value)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
    }

    @MainActor
    private func performPreciseCorrectionIfNeeded(
        url: URL,
        target: CMTime,
        seekGeneration: Int
    ) {
        preciseState.lock.lock()
        let currentGeneration = preciseState.seekGeneration
        let currentURL = preciseState.url
        let prepared = preciseState.prepared
        preciseState.lock.unlock()

        guard currentGeneration == seekGeneration,
              currentURL == url,
              let prepared else {
            return
        }

        guard let currentItem,
              let currentAsset = currentItem.asset as? AVURLAsset,
              currentAsset.url == url else {
            return
        }

        let actual = currentTime().seconds
        let requested = target.seconds
        guard actual.isFinite,
              requested.isFinite,
              abs(actual - requested) > Self.correctionTolerance else {
            return
        }

        let wasPlaying = timeControlStatus == .playing || rate > 0
        let previousRate = rate > 0 ? rate : 1

        pause()
        replaceCurrentItem(with: prepared.item)
        prepared.item.cancelPendingSeeks()
        seek(
            to: prepared.timeline.mediaTime(
                forPlaybackPosition: requested
            ),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] finished in
            guard let self, finished, wasPlaying else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.playImmediately(atRate: previousRate)
            }
        }
    }
}
