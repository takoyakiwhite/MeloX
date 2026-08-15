@preconcurrency import AVFoundation
import Foundation

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
        init(audioMix: AVAudioMix?, bufferDuration: TimeInterval, spatialization: AVAudioSpatializationFormats, pitchAlgorithm: AVAudioTimePitchAlgorithm) {
            self.audioMix = audioMix
            self.bufferDuration = bufferDuration
            self.spatialization = spatialization
            self.pitchAlgorithm = pitchAlgorithm
        }
    }

    private final class State: @unchecked Sendable {
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

    private let state = State()
    private static let preciseWait: Duration = .milliseconds(250)

    nonisolated override init() { super.init() }
    nonisolated override init(url URL: URL) { super.init(url: URL) }
    nonisolated override init(playerItem item: AVPlayerItem?) { super.init(playerItem: item) }
    deinit { state.reset() }

    nonisolated func preciseStateReset() { state.reset() }

    nonisolated func preciseTimeline(for item: AVPlayerItem) -> AudioPlaybackMediaTimeline? {
        state.lock.lock()
        defer { state.lock.unlock() }
        guard let prepared = state.prepared, prepared.item === item else { return nil }
        return prepared.timeline
    }

    nonisolated func preparePreciseIfNeeded(for item: AVPlayerItem) {
        guard let asset = item.asset as? AVURLAsset,
              asset.url.pathExtension.lowercased() == "flac" else {
            state.reset()
            return
        }
        let url = asset.url
        state.lock.lock()
        if state.url == url && (state.preparationTask != nil || state.prepared != nil) {
            state.lock.unlock()
            return
        }
        state.generation &+= 1
        let generation = state.generation
        state.url = url
        state.configuration = Configuration(
            audioMix: item.audioMix,
            bufferDuration: item.preferredForwardBufferDuration,
            spatialization: item.allowedAudioSpatializationFormats,
            pitchAlgorithm: item.audioTimePitchAlgorithm
        )
        state.preparationTask?.cancel()
        state.preparationTask = nil
        state.prepared = nil
        let configuration = state.configuration
        state.lock.unlock()
        guard let configuration else { return }

        let task = Task.detached(priority: .utility) { () -> PreparedPayload? in
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            do {
                _ = try await asset.load(.duration)
                guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
                let timeRange = try? await track.load(.timeRange)
                let preciseItem = AVPlayerItem(asset: asset)
                preciseItem.preferredForwardBufferDuration = configuration.bufferDuration
                preciseItem.allowedAudioSpatializationFormats = configuration.spatialization
                preciseItem.audioTimePitchAlgorithm = configuration.pitchAlgorithm
                preciseItem.audioMix = configuration.audioMix
                return PreparedPayload(item: preciseItem, timeline: AudioPlaybackMediaTimeline(audioTrackTimeRange: timeRange))
            } catch { return nil }
        }

        state.lock.lock()
        guard state.generation == generation else {
            state.lock.unlock()
            task.cancel()
            return
        }
        state.preparationTask = task
        state.lock.unlock()

        Task { @MainActor [weak self] in
            let result = await task.value
            guard let self else { return }
            self.state.lock.lock()
            guard self.state.generation == generation, self.state.url == url else {
                self.state.lock.unlock()
                return
            }
            self.state.preparationTask = nil
            self.state.prepared = result.map { PreparedAudioPlaybackItem(item: $0.item, timeline: $0.timeline) }
            self.state.lock.unlock()
        }
    }

    nonisolated override func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime, completionHandler: @escaping @Sendable (Bool) -> Void) {
        guard let asset = currentItem?.asset as? AVURLAsset,
              asset.url.pathExtension.lowercased() == "flac" else {
            super.seek(to: time, toleranceBefore: toleranceBefore, toleranceAfter: toleranceAfter, completionHandler: completionHandler)
            return
        }

        state.lock.lock()
        state.seekGeneration &+= 1
        let generation = state.seekGeneration
        let prepared = state.prepared
        let preparationTask = state.preparationTask
        state.lock.unlock()

        Task { @MainActor [weak self] in
            guard let self else { completionHandler(false); return }
            let precise = prepared ?? await Self.waitForPrepared(preparationTask, timeout: Self.preciseWait)
            guard self.isCurrentSeekGeneration(generation) else { completionHandler(false); return }
            if let precise {
                self.replaceCurrentItem(with: precise.item)
                super.seek(to: precise.timeline.mediaTime(forPlaybackPosition: max(time.seconds, 0)), toleranceBefore: toleranceBefore, toleranceAfter: toleranceAfter, completionHandler: completionHandler)
            } else {
                super.seek(to: time, toleranceBefore: toleranceBefore, toleranceAfter: toleranceAfter, completionHandler: completionHandler)
            }
        }
    }

    nonisolated private func isCurrentSeekGeneration(_ generation: Int) -> Bool {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.seekGeneration == generation
    }

    private static func waitForPrepared(_ task: Task<PreparedPayload?, Never>?, timeout: Duration) async -> PreparedAudioPlaybackItem? {
        guard let task else { return nil }
        return await withTaskGroup(of: PreparedAudioPlaybackItem?.self) { group in
            group.addTask {
                guard let payload = await task.value else { return nil }
                return PreparedAudioPlaybackItem(item: payload.item, timeline: payload.timeline)
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
