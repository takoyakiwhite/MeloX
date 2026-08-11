@preconcurrency import AVFoundation
import Foundation

enum AutoMixPreparationError: LocalizedError {
    case itemFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .itemFailed(let error):
            error?.localizedDescription
                ?? "下一首歌曲预载失败。"
        }
    }
}

@MainActor
final class AutoMixDeckTransitionController {
    var onTransitionBegan:
        ((Int, AutoMixTransitionPlan) -> Void)?
    var onTransitionProgress: ((Double) -> Void)?
    var onTransitionCompleted: ((Int) -> Void)?
    var onPreparationFailed:
        ((Int, Error) -> Void)?
    var onActiveDeckChanged: (() -> Void)?

    let decks = [
        AudioPlaybackDeck(),
        AudioPlaybackDeck(),
    ]
    private(set) var activeDeckIndex = 0

    private struct PreparedTransition {
        let identifier: Int
        let deckIndex: Int
        let item: AVPlayerItem
        let plan: AutoMixTransitionPlan
        var isPrerolled = false
        var isPrerolling = false
    }

    private final class ActiveTransition {
        let identifier: Int
        let outgoingDeckIndex: Int
        let incomingDeckIndex: Int
        let plan: AutoMixTransitionPlan
        let outgoingStartPosition:
            TimeInterval
        let incomingStartPosition:
            TimeInterval
        var lastProgress = 0.0
        var lastPublishedProgress = 0.0

        init(
            identifier: Int,
            outgoingDeckIndex: Int,
            incomingDeckIndex: Int,
            plan: AutoMixTransitionPlan,
            outgoingStartPosition:
                TimeInterval,
            incomingStartPosition:
                TimeInterval
        ) {
            self.identifier = identifier
            self.outgoingDeckIndex =
                outgoingDeckIndex
            self.incomingDeckIndex =
                incomingDeckIndex
            self.plan = plan
            self.outgoingStartPosition =
                outgoingStartPosition
            self.incomingStartPosition =
                incomingStartPosition
        }
    }

    private let itemFactory:
        AudioPlaybackItemFactory
    private var preparationGeneration = 0
    private var baseVolume: Float = 1
    private var deckGains: [Float] = [1, 0]
    private var preparedTransition:
        PreparedTransition?
    private var activeTransition:
        ActiveTransition?
    private var envelopeTask:
        Task<Void, Never>?
    private var prerollRetryTask:
        Task<Void, Never>?
    private var wantsPlayback = false

    private static let autoMixForwardBufferDuration: TimeInterval = 120
    private static let minimumTransitionBuffer: TimeInterval = 6
    private static let rateUpdateThreshold: Float = 0.002

    var activeDeck: AudioPlaybackDeck {
        decks[activeDeckIndex]
    }

    var hasPreparedTransition: Bool {
        preparedTransition != nil
            || activeTransition != nil
    }

    private var standbyDeckIndex: Int {
        activeDeckIndex == 0 ? 1 : 0
    }

    init(itemFactory: AudioPlaybackItemFactory) {
        self.itemFactory = itemFactory
        applyOutputVolumes()
    }

    deinit {
        envelopeTask?.cancel()
        prerollRetryTask?.cancel()
    }

    func prepare(
        _ source: PlaybackSource,
        identifier: Int,
        plan: AutoMixTransitionPlan
    ) async {
        guard plan.duration > 0 else { return }
        preparationGeneration += 1
        let generation = preparationGeneration
        clearStandbyDeck()

        let deckIndex = standbyDeckIndex
        let playbackItem = await itemFactory.makeItem(
            for: source,
            preferredForwardBufferDuration:
                max(
                    Self.autoMixForwardBufferDuration,
                    plan.duration + Self.minimumTransitionBuffer
                ),
            autoMixEqualizerState:
                decks[deckIndex]
                    .autoMixEqualizerState
        )
        let item = playbackItem.item
        item.audioTimePitchAlgorithm = .spectral
        guard generation == preparationGeneration,
              !Task.isCancelled,
              activeTransition == nil else {
            return
        }

        let deck = decks[deckIndex]
        deck.replaceCurrentItem(
            with: playbackItem,
            identifier: identifier
        )
        deckGains[deckIndex] = 0
        applyOutputVolumes()
        await seek(
            deck.player,
            to: deck.mediaTime(
                forPlaybackPosition:
                    plan.incomingStartTime
            )
        )
        guard generation == preparationGeneration,
              deck.player.currentItem === item else {
            return
        }
        preparedTransition =
            PreparedTransition(
                identifier: identifier,
                deckIndex: deckIndex,
                item: item,
                plan: plan
            )
        switch item.status {
        case .readyToPlay
            where deck.player.status
                == .readyToPlay:
            requestPreroll(
                for: deckIndex,
                generation: generation
            )
        case .failed:
            failPreparedTransition(
                on: deckIndex,
                error: item.error
            )
        case .unknown, .readyToPlay:
            break
        @unknown default:
            failPreparedTransition(
                on: deckIndex,
                error: item.error
            )
        }
    }

    func cancel(wantsPlayback: Bool) {
        self.wantsPlayback = wantsPlayback
        preparationGeneration += 1
        envelopeTask?.cancel()
        envelopeTask = nil
        prerollRetryTask?.cancel()
        prerollRetryTask = nil

        if let activeTransition {
            decks[
                activeTransition
                    .incomingDeckIndex
            ].clear()
            activeDeckIndex =
                activeTransition
                    .outgoingDeckIndex
        } else if let preparedTransition {
            decks[
                preparedTransition.deckIndex
            ].clear()
        } else {
            clearStandbyDeck()
        }

        preparedTransition = nil
        activeTransition = nil
        resetAutoMixEqualizers()
        deckGains = activeDeckIndex == 0
            ? [1, 0]
            : [0, 1]
        activeDeck.player.rate =
            wantsPlayback ? 1 : 0
        applyOutputVolumes()
        onTransitionProgress?(0)
    }

    func reset() {
        cancel(wantsPlayback: false)
        for deck in decks {
            deck.clear()
        }
        activeDeckIndex = 0
        deckGains = [1, 0]
        applyOutputVolumes()
    }

    func setVolume(_ volume: Double) {
        baseVolume = Float(
            min(max(volume, 0), 1)
        )
        applyOutputVolumes()
    }

    func pauseAll() {
        wantsPlayback = false
        for deck in decks {
            deck.player.pause()
        }
    }

    func resumeIncomingIfNeeded() {
        wantsPlayback = true
        guard let activeTransition else {
            return
        }
        let progress = currentProgress(
            for: activeTransition
        )
        decks[
            activeTransition.outgoingDeckIndex
        ].player.rate = outgoingRate(
            for: activeTransition,
            progress: progress
        )
        decks[
            activeTransition.incomingDeckIndex
        ].player.playImmediately(
            atRate:
                incomingRate(
                    for: activeTransition,
                    progress: progress
                )
        )
    }

    func handleStandbyStatus(
        _ item: AVPlayerItem,
        deckIndex: Int,
        wantsPlayback: Bool
    ) {
        guard deckIndex != activeDeckIndex else {
            return
        }
        switch item.status {
        case .readyToPlay:
            if let preparedTransition,
               preparedTransition.deckIndex == deckIndex,
               !preparedTransition.isPrerolled,
               !preparedTransition.isPrerolling {
                requestPreroll(
                    for: deckIndex,
                    generation: preparationGeneration
                )
            }
            startIfNeeded(
                wantsPlayback: wantsPlayback
            )
        case .failed:
            failPreparedTransition(
                on: deckIndex,
                error: item.error
            )
        case .unknown:
            break
        @unknown default:
            failPreparedTransition(
                on: deckIndex,
                error: item.error
            )
        }
    }

    func startIfNeeded(
        wantsPlayback: Bool
    ) {
        self.wantsPlayback = wantsPlayback
        guard activeTransition == nil,
              let preparedTransition,
              wantsPlayback,
              preparedTransition.item.status
                == .readyToPlay,
              preparedTransition.isPrerolled,
              decks[
                preparedTransition.deckIndex
              ].player.status
                == .readyToPlay else {
            return
        }
        guard let seconds =
                activeDeck.currentPlaybackTime else {
            return
        }
        guard seconds
                >= preparedTransition
                    .plan
                    .outgoingStartTime else {
            return
        }
        guard seconds
                < preparedTransition
                    .plan
                    .outgoingStartTime
                    + preparedTransition.plan.duration else {
            return
        }
        guard hasSufficientBuffer(
            for: preparedTransition,
            at: preparedTransition.plan.incomingStartTime
        ) else {
            return
        }
        start(preparedTransition)
    }

    func finishIfOutgoingEnded(
        _ item: AVPlayerItem,
        wantsPlayback: Bool
    ) -> Bool {
        self.wantsPlayback = wantsPlayback
        guard let activeTransition,
              decks[
                activeTransition.outgoingDeckIndex
              ].player.currentItem === item else {
            return false
        }
        finish(
            activeTransition,
            wantsPlayback: wantsPlayback
        )
        return true
    }

    func failPreparedIfMatching(
        _ item: AVPlayerItem,
        error: Error?
    ) -> Bool {
        guard let preparedTransition,
              decks[
                preparedTransition.deckIndex
              ].player.currentItem === item else {
            return false
        }
        failPreparedTransition(
            on: preparedTransition.deckIndex,
            error: error
        )
        return true
    }

    private func start(
        _ prepared: PreparedTransition
    ) {
        guard prepared.deckIndex
                == standbyDeckIndex,
              decks[prepared.deckIndex]
                .player.currentItem
                === prepared.item else {
            return
        }
        let transition = ActiveTransition(
            identifier: prepared.identifier,
            outgoingDeckIndex:
                activeDeckIndex,
            incomingDeckIndex:
                prepared.deckIndex,
            plan: prepared.plan,
            outgoingStartPosition:
                prepared.plan.outgoingStartTime,
            incomingStartPosition:
                prepared.plan.incomingStartTime
        )
        preparedTransition = nil
        activeTransition = transition
        deckGains[
            transition.outgoingDeckIndex
        ] = 1
        deckGains[
            transition.incomingDeckIndex
        ] = 0
        applyAutoMixEqualizer(
            progress: 0,
            transition: transition
        )
        applyOutputVolumes()
        decks[transition.incomingDeckIndex]
            .player.playImmediately(
                atRate:
                    incomingRate(
                        for: transition,
                        progress: 0
                    )
            )
        onTransitionBegan?(
            transition.identifier,
            transition.plan
        )
        runEnvelope(transition)
    }

    private func runEnvelope(
        _ transition: ActiveTransition
    ) {
        envelopeTask?.cancel()
        envelopeTask = Task {
            @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled,
                  let current =
                    self.activeTransition,
                  current.identifier
                    == transition.identifier {
                let progress =
                    self.currentProgress(
                        for: current
                    )
                let gains =
                    AutoMixFadeEnvelope.gains(
                        at: progress,
                        curve:
                            current.plan.fadeCurve
                    )
                self.deckGains[
                    current.outgoingDeckIndex
                ] = gains.outgoing
                self.deckGains[
                    current.incomingDeckIndex
                ] = gains.incoming
                self.applyAutoMixEqualizer(
                    progress: progress,
                    transition: current
                )
                self.applyOutputVolumes()

                let outgoingPlayer =
                    self.decks[
                        current.outgoingDeckIndex
                    ].player
                let incomingPlayer =
                    self.decks[
                        current.incomingDeckIndex
                    ].player
                if self.wantsPlayback {
                    self.setRateIfNeeded(
                        outgoingPlayer,
                        to: self.outgoingRate(
                            for: current,
                            progress: progress
                        )
                    )
                    self.setRateIfNeeded(
                        incomingPlayer,
                        to: self.incomingRate(
                            for: current,
                            progress: progress
                        )
                    )
                } else {
                    if outgoingPlayer.rate != 0 {
                        outgoingPlayer.pause()
                    }
                    if incomingPlayer.rate != 0 {
                        incomingPlayer.pause()
                    }
                }
                self.publishProgressIfNeeded(
                    progress,
                    transition: current
                )
                if progress >= 1 {
                    self.finish(
                        current,
                        wantsPlayback:
                            self.wantsPlayback
                    )
                    return
                }
                try? await Task.sleep(
                    for: .milliseconds(20)
                )
            }
        }
    }

    private func requestPreroll(
        for deckIndex: Int,
        generation: Int
    ) {
        guard var preparedTransition,
              preparedTransition.deckIndex == deckIndex,
              preparedTransition.item.status == .readyToPlay,
              decks[deckIndex].player.status == .readyToPlay,
              !preparedTransition.isPrerolled,
              !preparedTransition.isPrerolling else {
            return
        }

        preparedTransition.isPrerolling = true
        self.preparedTransition = preparedTransition
        let item = preparedTransition.item
        let rate = normalizedRate(
            preparedTransition.plan.incomingStartPlaybackRate
        )
        decks[deckIndex].player.preroll(atRate: rate) {
            [weak self, weak item] finished in
            Task { @MainActor [weak self, weak item] in
                guard let self,
                      let item,
                      generation == self.preparationGeneration,
                      var current = self.preparedTransition,
                      current.deckIndex == deckIndex,
                      current.item === item,
                      self.decks[deckIndex].player.currentItem === item else {
                    return
                }
                current.isPrerolling = false
                current.isPrerolled = finished
                self.preparedTransition = current
                if finished {
                    self.startIfNeeded(
                        wantsPlayback: self.wantsPlayback
                    )
                } else {
                    self.schedulePrerollRetry(
                        generation: generation
                    )
                }
            }
        }
    }

    private func schedulePrerollRetry(
        generation: Int
    ) {
        prerollRetryTask?.cancel()
        prerollRetryTask = Task {
            try? await Task.sleep(
                for: .milliseconds(250)
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self,
                      generation == self.preparationGeneration,
                      let preparedTransition = self.preparedTransition,
                      !preparedTransition.isPrerolled else {
                    return
                }
                self.requestPreroll(
                    for: preparedTransition.deckIndex,
                    generation: generation
                )
            }
        }
    }

    private func hasSufficientBuffer(
        for prepared: PreparedTransition,
        at playbackPosition: TimeInterval
    ) -> Bool {
        let item = prepared.item
        if let asset = item.asset as? AVURLAsset,
           asset.url.isFileURL {
            return true
        }
        let required = min(
            max(Self.minimumTransitionBuffer, prepared.plan.duration + 2),
            12
        )
        return bufferedDuration(
            of: item,
            from: playbackPosition
        ) >= required
            || item.isPlaybackBufferFull
    }

    private func bufferedDuration(
        of item: AVPlayerItem,
        from playbackPosition: TimeInterval
    ) -> TimeInterval {
        guard playbackPosition.isFinite else { return 0 }
        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            let start = range.start.seconds
            let end = range.end.seconds
            guard start.isFinite, end.isFinite, end > start else {
                continue
            }
            if playbackPosition >= start - 0.05,
               playbackPosition <= end + 0.05 {
                return max(end - playbackPosition, 0)
            }
        }
        return 0
    }

    private func setRateIfNeeded(
        _ player: AVPlayer,
        to rate: Float
    ) {
        guard abs(player.rate - rate) >= Self.rateUpdateThreshold else {
            return
        }
        player.rate = rate
    }

    private func currentProgress(
        for transition: ActiveTransition
    ) -> Double {
        guard let outgoingPosition = decks[
                  transition.outgoingDeckIndex
              ].currentPlaybackTime,
              let incomingPosition = decks[
                  transition.incomingDeckIndex
              ].currentPlaybackTime else {
            return transition.lastProgress
        }

        let outgoingProgress =
            AutoMixTempoEnvelope.progress(
                forContentDuration:
                    max(
                        outgoingPosition
                            - transition
                                .outgoingStartPosition,
                        0
                    ),
                wallClockDuration:
                    transition.plan.duration,
                startRate: 1,
                endRate:
                    transition.plan
                        .outgoingEndPlaybackRate
            )
        let incomingProgress =
            AutoMixTempoEnvelope.progress(
                forContentDuration:
                    max(
                        incomingPosition
                            - transition
                                .incomingStartPosition,
                        0
                    ),
                wallClockDuration:
                    transition.plan.duration,
                startRate:
                    transition.plan
                        .incomingStartPlaybackRate,
                endRate: 1
            )
        transition.lastProgress = max(
            transition.lastProgress,
            min(
                max(
                    min(
                        outgoingProgress,
                        incomingProgress
                    ),
                    0
                ),
                1
            )
        )
        return transition.lastProgress
    }

    private func outgoingRate(
        for transition: ActiveTransition,
        progress: Double
    ) -> Float {
        AutoMixTempoEnvelope.playbackRate(
            at: progress,
            startRate: 1,
            endRate:
                transition.plan
                    .outgoingEndPlaybackRate
        )
    }

    private func incomingRate(
        for transition: ActiveTransition,
        progress: Double
    ) -> Float {
        AutoMixTempoEnvelope.playbackRate(
            at: progress,
            startRate:
                transition.plan
                    .incomingStartPlaybackRate,
            endRate: 1
        )
    }

    private func finish(
        _ transition: ActiveTransition,
        wantsPlayback: Bool
    ) {
        guard activeTransition?.identifier
                == transition.identifier else {
            return
        }
        envelopeTask?.cancel()
        envelopeTask = nil

        decks[
            transition.outgoingDeckIndex
        ].clear()
        activeDeckIndex =
            transition.incomingDeckIndex
        resetAutoMixEqualizers()
        activeDeck.player.rate =
            wantsPlayback ? 1 : 0
        deckGains = activeDeckIndex == 0
            ? [1, 0]
            : [0, 1]
        activeTransition = nil
        applyOutputVolumes()
        onActiveDeckChanged?()
        onTransitionProgress?(1)
        onTransitionCompleted?(
            transition.identifier
        )
    }

    private func failPreparedTransition(
        on deckIndex: Int,
        error: Error?
    ) {
        guard let preparedTransition,
              preparedTransition.deckIndex
                == deckIndex else {
            return
        }
        let identifier =
            preparedTransition.identifier
        decks[deckIndex].clear()
        self.preparedTransition = nil
        deckGains[deckIndex] = 0
        applyOutputVolumes()
        onPreparationFailed?(
            identifier,
            AutoMixPreparationError
                .itemFailed(error)
        )
    }

    private func clearStandbyDeck() {
        guard activeTransition == nil else {
            return
        }
        let index = standbyDeckIndex
        decks[index].clear()
        deckGains[index] = 0
        preparedTransition = nil
    }

    private func applyOutputVolumes() {
        for index in decks.indices {
            decks[index].player.volume =
                baseVolume * deckGains[index]
        }
    }

    private func applyAutoMixEqualizer(
        progress: Double,
        transition: ActiveTransition
    ) {
        let adjustments =
            AutoMixEqualizerEnvelope
                .adjustments(at: progress)
        decks[
            transition.outgoingDeckIndex
        ].autoMixEqualizerState.update(
            lowGain:
                adjustments.outgoing.low,
            midGain:
                adjustments.outgoing.mid,
            highGain:
                adjustments.outgoing.high
        )
        decks[
            transition.incomingDeckIndex
        ].autoMixEqualizerState.update(
            lowGain:
                adjustments.incoming.low,
            midGain:
                adjustments.incoming.mid,
            highGain:
                adjustments.incoming.high
        )
    }

    private func resetAutoMixEqualizers() {
        for deck in decks {
            deck.autoMixEqualizerState.reset()
        }
    }

    private func publishProgressIfNeeded(
        _ progress: Double,
        transition: ActiveTransition
    ) {
        let minimumStep = max(
            0.004,
            0.08
                / max(
                    transition.plan.duration,
                    0.1
                )
        )
        guard progress >= 1
                || progress
                    - transition
                        .lastPublishedProgress
                    >= minimumStep else {
            return
        }
        transition.lastPublishedProgress =
            progress
        onTransitionProgress?(progress)
    }

    private func normalizedRate(
        _ rate: Double
    ) -> Float {
        Float(min(max(rate, 0.5), 2))
    }

    private func seek(
        _ player: AVPlayer,
        to time: CMTime
    ) async {
        await withCheckedContinuation {
            continuation in
            player.seek(
                to: time,
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { _ in
                continuation.resume()
            }
        }
    }

}
