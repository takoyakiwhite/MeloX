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

    private final class PreciseState: @unchecked Sendable {
        final class Configuration: @unchecked Sendable {
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

    nonisolated func preparePreciseIfNeeded(for item: AVPlayerItem) {
        guard let asset = item.asset as? AVURLAsset,
              asset.url.pathExtension.lowercased() == "flac" else {
            preciseState.reset()
            return
        }

        let url = asset.url
        preciseState.lock.lock()
        if preciseState.url == url,
           preciseState.preparationTask != nil || preciseState.prepared != nil {
            preciseState.lock.unlock()
            return
        }
        preciseState.generation &+= 1
        let generation = preciseState.generation
        preciseState.url = url
        preciseState.configuration = .init(
            audioMix: item.audioMix,
            bufferDuration: item.preferredForwardBufferDuration,
            spatialization: item.allowedAudioSpatializationFormats,
            pitchAlgorithm: item.audioTimePitchAlgorithm
        )
        preciseState.preparationTask?.cancel()
        preciseState.preparationTask = nil
        preciseState.prepared = nil
        preciseState.lock.unlock()

        let task = Task<PreparedPayload?, Never> { @MainActor [weak self] in
            guard let self else { return nil }
            self.preciseState.lock.lock()
            let configuration = self.preciseState.configuration
            self.preciseState.lock.unlock()
            guard let configuration else { return nil }

            let asset = AVURLAsset(
                url: url,
                options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
            )
            do {
                _ = try await asset.load(.duration)
                guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                    return nil
                }
                let timeRange = try? await track.load(.timeRange)
                let preciseItem = AVPlayerItem(asset: asset)
                preciseItem.preferredForwardBufferDuration = configuration.bufferDuration
                preciseItem.allowedAudioSpatializationFormats = configuration.spatialization
                preciseItem.audioTimePitchAlgorithm = configuration.pitchAlgorithm
                preciseItem.audioMix = configuration.audioMix
                let prepared = PreparedAudioPlaybackItem(
                    item: preciseItem,
                    timeline: AudioPlaybackMediaTimeline(
                        audioTrackTimeRange: timeRange
                    )
                )
                self.preciseState.lock.lock()
                guard self.preciseState.generation == generation,
                      self.preciseState.url == url else {
                    self.preciseState.lock.unlock()
                    return nil
                }
                self.preciseState.prepared = prepared
                self.preciseState.preparationTask = nil
                self.preciseState.lock.unlock()
                return PreparedPayload(
                    item: preciseItem,
                    timeline: prepared.timeline
                )
            } catch {
                self.preciseState.lock.lock()
                if self.preciseState.generation == generation {
                    self.preciseState.preparationTask = nil
                }
                self.preciseState.lock.unlock()
                return nil
            }
        }

        preciseState.lock.lock()
        if preciseState.generation == generation {
            preciseState.preparationTask = task
        } else {
            task.cancel()
        }
        preciseState.lock.unlock()
    }

    nonisolated func preciseTimelineForCurrentItem() -> AudioPlaybackMediaTimeline? {
        preciseState.lock.lock()
        defer { preciseState.lock.unlock() }
        guard let prepared = preciseState.prepared,
              currentItem === prepared.item else {
            return nil
        }
        return prepared.timeline
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

        // Complete the normal seek against the current item first. The existing
        // AudioPlaybackEngine uses the current-item identity to finish its seek
        // transaction and release its progress/lyric clock suppression. Precise
        // correction is deliberately scheduled only after that callback.
        super.seek(
            to: time,
            toleranceBefore: toleranceBefore,
            toleranceAfter: toleranceAfter
        ) { [weak self] finished in
            completionHandler(finished)
            guard finished, let self else { return }

            Task { @MainActor [weak self] in
                guard let self else { return }
                if let preparationTask {
                    _ = await preparationTask.value
                }
                guard !Task.isCancelled else { return }
                self.tryPreciseCorrection(
                    url: url,
                    time: time,
                    seekGeneration: seekGeneration
                )
            }
        }
    }

    nonisolated private func activatePreparedItem(
        _ prepared: PreparedAudioPlaybackItem
    ) {
        guard currentItem !== prepared.item else { return }
        if rate > 0 {
            pause()
        }
        replaceCurrentItem(with: prepared.item)
    }

    @MainActor
    private func tryPreciseCorrection(
        url: URL,
        time: CMTime,
        seekGeneration: Int
    ) {
        preciseState.lock.lock()
        let currentGeneration = preciseState.seekGeneration
        let currentURL = preciseState.url
        let prepared = preciseState.prepared
        preciseState.lock.unlock()

        guard seekGeneration == currentGeneration,
              currentURL == url,
              let prepared else {
            return
        }

        let actual = currentTime().seconds
        let target = time.seconds
        guard actual.isFinite,
              target.isFinite,
              abs(actual - target) > Self.correctionTolerance else {
            return
        }

        let wasPlaying = rate > 0
        let previousRate = max(rate, 0)
        activatePreparedItem(prepared)

        super.seek(
            to: prepared.timeline.mediaTime(
                forPlaybackPosition: max(
                    target - prepared.timeline.mediaStart,
                    0
                )
            ),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] finished in
            guard let self,
                  finished,
                  wasPlaying else {
                return
            }
            Task { @MainActor in
                guard self.preciseState.seekGeneration == seekGeneration else {
                    return
                }
                self.playImmediately(
                    atRate: previousRate > 0 ? previousRate : 1
                )
            }
        }
    }
}
