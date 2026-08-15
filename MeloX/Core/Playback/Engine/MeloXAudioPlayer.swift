@preconcurrency import AVFoundation

/// Keeps fast FLAC startup while preparing a precise-timing asset in the
/// background. The precise item is activated only when a FLAC seek occurs.
/// No fixed post-seek delay and no precise timing option are applied to the
/// initial playback item.
final class MeloXAudioPlayer: AVPlayer {
    private final class PreciseState: @unchecked Sendable {
        let lock = NSLock()
        var generation = 0
        var seekGeneration = 0
        var currentURL: URL?
        var preparationTask: Task<AVPlayerItem?, Never>?
        var preparedItem: AVPlayerItem?
        var audioMix: AVAudioMix?
        var preferredForwardBufferDuration: TimeInterval = 0
        var spatializationFormats: AVAudioSpatializationFormats = []
        var audioTimePitchAlgorithm: AVAudioTimePitchAlgorithm = .timeDomain

        func reset(for url: URL?) {
            lock.lock()
            generation += 1
            seekGeneration += 1
            currentURL = url
            preparationTask?.cancel()
            preparationTask = nil
            preparedItem = nil
            audioMix = nil
            lock.unlock()
        }

        func beginSeek(for url: URL) -> Int {
            lock.lock()
            seekGeneration += 1
            let value = seekGeneration
            currentURL = url
            lock.unlock()
            return value
        }

        func isCurrentSeek(_ value: Int, url: URL) -> Bool {
            lock.lock()
            let result = seekGeneration == value && currentURL == url
            lock.unlock()
            return result
        }

        func storePreparedIfCurrent(
            _ item: AVPlayerItem?,
            generation: Int,
            url: URL
        ) {
            lock.lock()
            guard self.generation == generation,
                  currentURL == url else {
                lock.unlock()
                return
            }
            preparedItem = item
            lock.unlock()
        }
    }

    private let preciseState = PreciseState()
    private var currentItemObservation: NSKeyValueObservation?

    nonisolated override init() {
        super.init()
        installCurrentItemObservation()
    }

    nonisolated override init(url URL: URL) {
        super.init(url: URL)
        installCurrentItemObservation()
    }

    nonisolated override init(playerItem item: AVPlayerItem?) {
        super.init(playerItem: item)
        installCurrentItemObservation()
    }

    deinit {
        currentItemObservation?.invalidate()
        preciseState.reset(for: nil)
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
        let seekGeneration = preciseState.beginSeek(for: url)
        let task = preciseTask(for: currentItem, url: url)

        Task {
            let preciseItem = await task.value
            guard preciseState.isCurrentSeek(seekGeneration, url: url) else {
                return
            }

            guard let preciseItem else {
                superSeek(
                    to: time,
                    toleranceBefore: toleranceBefore,
                    toleranceAfter: toleranceAfter,
                    completionHandler: completionHandler
                )
                return
            }

            preciseState.storePreparedIfCurrent(
                preciseItem,
                generation: currentGeneration(for: url),
                url: url
            )
            activatePreciseItem(preciseItem)
            waitForReadyAndSeek(
                preciseItem,
                to: time,
                toleranceBefore: toleranceBefore,
                toleranceAfter: toleranceAfter,
                completionHandler: completionHandler
            )
        }
    }

    private nonisolated func currentGeneration(for url: URL) -> Int {
        preciseState.lock.lock()
        defer { preciseState.lock.unlock() }
        guard preciseState.currentURL == url else { return -1 }
        return preciseState.generation
    }

    private nonisolated func installCurrentItemObservation() {
        currentItemObservation = observe(
            \.currentItem,
            options: [.initial, .new]
        ) { [weak self] _, change in
            guard let self,
                  let item = change.newValue ?? self.currentItem else {
                return
            }
            self.beginPrecisePreparation(for: item)
        }
    }

    private nonisolated func beginPrecisePreparation(
        for item: AVPlayerItem
    ) {
        guard let asset = item.asset as? AVURLAsset,
              asset.url.pathExtension.lowercased() == "flac" else {
            preciseState.reset(for: nil)
            return
        }

        let url = asset.url
        preciseState.lock.lock()
        if preciseState.currentURL == url,
           preciseState.preparationTask != nil {
            preciseState.lock.unlock()
            return
        }
        preciseState.generation += 1
        let generation = preciseState.generation
        preciseState.currentURL = url
        preciseState.preparationTask?.cancel()
        preciseState.preparationTask = nil
        preciseState.preparedItem = nil
        preciseState.audioMix = item.audioMix
        preciseState.preferredForwardBufferDuration =
            item.preferredForwardBufferDuration
        preciseState.spatializationFormats =
            item.allowedAudioSpatializationFormats
        preciseState.audioTimePitchAlgorithm =
            item.audioTimePitchAlgorithm
        preciseState.lock.unlock()

        let task = Task<AVPlayerItem?, Never> { [preciseState] in
            let preciseAsset = AVURLAsset(
                url: url,
                options: [
                    AVURLAssetPreferPreciseDurationAndTimingKey: true
                ]
            )

            do {
                _ = try await preciseAsset.load(.duration)
                if let track = try await preciseAsset
                    .loadTracks(withMediaType: .audio).first {
                    _ = try? await track.load(.timeRange)
                }
            } catch {
                preciseState.storePreparedIfCurrent(
                    nil,
                    generation: generation,
                    url: url
                )
                return nil
            }

            if Task.isCancelled {
                return nil
            }

            preciseState.lock.lock()
            let mix = preciseState.audioMix
            let buffer = preciseState.preferredForwardBufferDuration
            let spatialization = preciseState.spatializationFormats
            let pitchAlgorithm = preciseState.audioTimePitchAlgorithm
            preciseState.lock.unlock()

            let preciseItem = AVPlayerItem(asset: preciseAsset)
            preciseItem.preferredForwardBufferDuration = buffer
            preciseItem.allowedAudioSpatializationFormats = spatialization
            preciseItem.audioTimePitchAlgorithm = pitchAlgorithm
            preciseItem.audioMix = mix
            preciseState.storePreparedIfCurrent(
                preciseItem,
                generation: generation,
                url: url
            )
            return preciseItem
        }

        preciseState.lock.lock()
        guard preciseState.generation == generation else {
            preciseState.lock.unlock()
            task.cancel()
            return
        }
        preciseState.preparationTask = task
        preciseState.lock.unlock()
    }

    private nonisolated func preciseTask(
        for item: AVPlayerItem?,
        url: URL
    ) -> Task<AVPlayerItem?, Never> {
        if let item {
            beginPrecisePreparation(for: item)
        }

        preciseState.lock.lock()
        if let task = preciseState.preparationTask,
           preciseState.currentURL == url {
            preciseState.lock.unlock()
            return task
        }
        preciseState.lock.unlock()

        return Task { nil }
    }

    private nonisolated func activatePreciseItem(
        _ item: AVPlayerItem
    ) {
        guard currentItem !== item else { return }
        super.replaceCurrentItem(with: item)
    }

    private nonisolated func waitForReadyAndSeek(
        _ item: AVPlayerItem,
        to time: CMTime,
        toleranceBefore: CMTime,
        toleranceAfter: CMTime,
        completionHandler: @escaping @Sendable (Bool) -> Void
    ) {
        if item.status == .readyToPlay {
            superSeek(
                to: time,
                toleranceBefore: toleranceBefore,
                toleranceAfter: toleranceAfter,
                completionHandler: completionHandler
            )
            return
        }

        if item.status == .failed {
            completionHandler(false)
            return
        }

        var observation: NSKeyValueObservation?
        observation = item.observe(
            \.status,
            options: [.initial, .new]
        ) { [weak self] item, _ in
            guard item.status == .readyToPlay || item.status == .failed else {
                return
            }
            observation?.invalidate()
            observation = nil
            guard let self else {
                completionHandler(false)
                return
            }
            if item.status == .readyToPlay {
                self.superSeek(
                    to: time,
                    toleranceBefore: toleranceBefore,
                    toleranceAfter: toleranceAfter,
                    completionHandler: completionHandler
                )
            } else {
                completionHandler(false)
            }
        }
    }

    private nonisolated func superSeek(
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
