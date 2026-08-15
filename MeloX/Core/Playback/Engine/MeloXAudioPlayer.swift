@preconcurrency import AVFoundation
import Foundation

/// Keeps the fast normal AVURLAsset for initial playback, while preparing a
/// precise-timing FLAC asset in the background. The precise item is only used
/// when a FLAC seek needs it; normal playback never waits for precise timing.
final class MeloXAudioPlayer: AVPlayer {
    private final class PreciseState: @unchecked Sendable {
        let lock = NSLock()
        var generation = 0
        var seekGeneration = 0
        var url: URL?
        var preparationTask: Task<PreparedAudioPlaybackItem?, Never>?
        var prepared: PreparedAudioPlaybackItem?

        func reset() {
            lock.lock()
            generation &+= 1
            seekGeneration &+= 1
            preparationTask?.cancel()
            preparationTask = nil
            prepared = nil
            url = nil
            lock.unlock()
        }
    }

    private let preciseState = PreciseState()
    private static let correctionTolerance: TimeInterval = 0.025
    private static let correctionTimeout: Duration = .milliseconds(300)

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

    /// Starts preparing a precise FLAC item without delaying normal playback.
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
        preciseState.preparationTask?.cancel()
        preciseState.preparationTask = nil
        preciseState.prepared = nil
        preciseState.lock.unlock()

        let audioMix = item.audioMix
        let bufferDuration = item.preferredForwardBufferDuration
        let spatialization = item.allowedAudioSpatializationFormats
        let pitchAlgorithm = item.audioTimePitchAlgorithm

        let task = Task<PreparedAudioPlaybackItem?, Never> { @MainActor [weak self] in
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
                preciseItem.preferredForwardBufferDuration = bufferDuration
                preciseItem.allowedAudioSpatializationFormats = spatialization
                preciseItem.audioTimePitchAlgorithm = pitchAlgorithm
                preciseItem.audioMix = audioMix
                let prepared = PreparedAudioPlaybackItem(
                    item: preciseItem,
                    timeline: AudioPlaybackMediaTimeline(
                        audioTrackTimeRange: timeRange
                    )
                )
                guard let self else { return nil }
                self.preciseState.lock.lock()
                guard self.preciseState.generation == generation,
                      self.preciseState.url == url else {
                    self.preciseState.lock.unlock()
                    return nil
                }
                self.preciseState.prepared = prepared
                self.preciseState.preparationTask = nil
                self.preciseState.lock.unlock()
                return prepared
            } catch {
                self?.preciseState.lock.lock()
                if self?.preciseState.generation == generation {
                    self?.preciseState.preparationTask = nil
                }
                self?.preciseState.lock.unlock()
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
        let prepared = preciseState.prepared
        let preparationTask = preciseState.preparationTask
        preciseState.lock.unlock()

        if let prepared {
            activatePreparedItem(prepared)
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
            toleranceAfter: toleranceAfter,
            completionHandler: completionHandler
        )

        guard let preparationTask else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: Self.correctionTimeout)
            } catch {
                return
            }
            self.tryPreciseCorrection(
                url: url,
                time: time,
                seekGeneration: seekGeneration,
                preparationTask: preparationTask
            )
        }
    }

    @MainActor
    private func activatePreparedItem(
        _ prepared: PreparedAudioPlaybackItem
    ) {
        guard currentItem !== prepared.item else { return }
        let rate = playerRateForReplacement()
        if rate > 0 { pause() }
        replaceCurrentItem(with: prepared.item)
        if rate > 0 {
            playImmediately(atRate: rate)
        }
    }

    @MainActor
    private func tryPreciseCorrection(
        url: URL,
        time: CMTime,
        seekGeneration: Int,
        preparationTask: Task<PreparedAudioPlaybackItem?, Never>
    ) {
        preciseState.lock.lock()
        let currentGeneration = preciseState.seekGeneration
        let currentURL = preciseState.url
        let prepared = preciseState.prepared
        preciseState.lock.unlock()

        guard seekGeneration == currentGeneration,
              currentURL == url else {
            return
        }

        if prepared == nil {
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await preparationTask.value
                guard !Task.isCancelled else { return }
                self.tryPreciseCorrection(
                    url: url,
                    time: time,
                    seekGeneration: seekGeneration,
                    preparationTask: preparationTask
                )
            }
            return
        }

        guard let prepared else { return }
        let actual = currentTime().seconds
        let target = time.seconds
        guard actual.isFinite,
              target.isFinite,
              abs(actual - target) > Self.correctionTolerance else {
            return
        }

        activatePreparedItem(prepared)
        super.seek(
            to: time,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.preciseState.lock.lock()
                let stillCurrent =
                    self.preciseState.seekGeneration == seekGeneration
                    && self.preciseState.url == url
                self.preciseState.lock.unlock()
                guard stillCurrent else { return }
            }
        }
    }

    @MainActor
    private func playerRateForReplacement() -> Float {
        max(rate, 0)
    }
}
