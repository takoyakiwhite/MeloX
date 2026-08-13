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
    private var prerollTask:
        Task<Void, Never>?
    private var wantsPlayback = false

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
        prerollTask?.cancel()
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
        let playbackItem = itemFactory.makeItem(
            for: source,
            preferredForwardBufferDuration:
                max(plan.duration + 8, 12)
        )
        let item = playbackItem.item
        item.audioTimePitchAlgorithm = .spectral
        guard generation == preparationGeneration,
              !Task.isCancelled,
              activeTransition == nil else {
            return
        }

        let deck = decks[deckIndex]
        deck.onMetadataReady = nil
        let equalizerState =
            decks[deckIndex].autoMixEqualizerState
        deck.onMetadataReady = { [weak self, weak deck, weak item] readyItem in
            guard let self, let deck, let item,
                  readyItem === item,
                  generation == self.preparationGeneration,
                  deck.player.currentItem === item,
                  self.preparedTransition?.deckIndex == deckIndex,
                  self.preparedTransition?.item === item else {
                return
            }
            Task { @MainActor [weak self, weak deck, weak item] in
                guard let self, let deck, let item,
                      generation == self.preparationGeneration,
                      deck.player.currentItem === item,
                      self.preparedTransition?.deckIndex == deckIndex,
                      self.preparedTransition?.item === item else {
                    return
                }
                await self.seek(
                    deck.player,
                    to: deck.mediaTime(
                        forPlaybackPosition:
                            self.preparedTransition?.plan.incomingStartTime ?? 0
                    )
                )
                self.startPrerollIfReady(
                    deckIndex: deckIndex,
                    item: item,
                    generation: generation
                )
            }
        }
        deck.replaceCurrentItem(
            with: playbackItem,
            identifier: identifier,
            metadataLoader: { [itemFactory, playbackItem, equalizerState] in
                try await itemFactory.loadMetadata(
                    for: playbackItem,
                    autoMixEqualizerState: equalizerState
                )
            }
        )
        deckGains[deckIndex] = 0
        applyOutputVolumes()
        guard generation == preparationGeneration,
              deck.player.currentItem === item else {
            return
        }
        preparedTransition =
            PreparedTransition(
                identifier: identifier,
                deckIndex: deckIndex,
                item: item,
                plan: plan,
                isPrerolled: false
            )
        switch item.status {
        case .readyToPlay:
            startPrerollIfReady(
                deckIndex: deckIndex,
                item: item,
                generation: generation
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

    func cancel(wantsPlayback: Bool) {
        self.wantsPlayback = wantsPlayback
        preparationGeneration += 1
        envelopeTask?.cancel()
        envelopeTask = nil
        prerollTask?.cancel()
        prerollTask = nil

        if let activeTransition {
            decks[
                activeTransition
                    .incomingDeckIndex
            ].player.automaticallyWaitsToMinimizeStalling = true
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
            deck.player.automaticallyWaitsToMinimizeStalling = true
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

    @discardableResult
    func resumeIncomingIfNeeded() -> Bool {
        wantsPlayback = true
        guard let activeTransition else {
            return false
        }
        let progress = currentProgress(
            for: activeTransition
        )
        if progress >= 1 {
            finish(
                activeTransition,
                wantsPlayback: true
            )
            return false
        }
        let incomingPlayer =
            decks[activeTransition.incomingDeckIndex].player
        let outgoingPlayer =
            decks[activeTransition.outgoingDeckIndex].player
        incomingPlayer.playImmediately(
            atRate:
                incomingRate(
                    for: activeTransition,
                    progress: progress
                )
        )
        outgoingPlayer.rate =
            outgoingRate(
                for: activeTransition,
                progress: progress
            )
        return true
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
            startPrerollIfReady(
                deckIndex: deckIndex,
                item: item,
                generation: preparationGeneration
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
                activeDeck.currentPlaybackTime,
              seconds
                >= preparedTransition
                    .plan
                    .outgoingStartTime else {
            return
        }

        let outgoingDuration =
            activeDeck.playbackDuration
                ?? preparedTransition.plan.outgoingStartTime
                + preparedTransition.plan.duration
        let remainingDuration = max(
            outgoingDuration - seconds,
            0
        )

        // The transition may have been prepared ahead of time, but the
        // actual start can be delayed by buffering, a pause, an interruption,
        // or other main-actor work. Never start a transition whose planned
        // duration no longer fits inside the remaining outgoing content.
        guard remainingDuration >= 1 else {
            return
        }

        let effectiveDuration = min(
            preparedTransition.plan.duration,
            remainingDuration
        )
        let effectivePlan:
            AutoMixTransitionPlan
        if effectiveDuration <
            preparedTransition.plan.duration {
            effectivePlan = AutoMixTransitionPlan(
                kind: preparedTransition.plan.kind,
                outgoingStartTime:
                    preparedTransition.plan.outgoingStartTime,
                duration: effectiveDuration,
                incomingStartTime:
                    preparedTransition.plan.incomingStartTime,
                outgoingEndPlaybackRate:
                    preparedTransition.plan.outgoingEndPlaybackRate,
                incomingStartPlaybackRate:
                    preparedTransition.plan.incomingStartPlaybackRate,
                fadeCurve: preparedTransition.plan.fadeCurve,
                confidence: preparedTransition.plan.confidence
            )
        } else {
            effectivePlan = preparedTransition.plan
        }

        let startPlan =
            effectivePlan == preparedTransition.plan
            ? preparedTransition
            : PreparedTransition(
                identifier: preparedTransition.identifier,
                deckIndex: preparedTransition.deckIndex,
                item: preparedTransition.item,
                plan: effectivePlan,
                isPrerolled:
                    preparedTransition.isPrerolled
            )
        start(startPlan)
    }

    private func startPrerollIfReady(
        deckIndex: Int,
        item: AVPlayerItem,
        generation: Int
    ) {
        guard deckIndex != activeDeckIndex,
              preparedTransition?.deckIndex == deckIndex,
              preparedTransition?.item === item,
              item.status == .readyToPlay,
              decks[deckIndex].player.status == .readyToPlay,
              decks[deckIndex].isMetadataReady else {
            return
        }
        prerollTask?.cancel()
        prerollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let rate = self.normalizedRate(
                self.preparedTransition?.plan.incomingStartPlaybackRate ?? 1
            )
            var attempt = 0
            while !Task.isCancelled {
                let success = await self.preroll(
                    self.decks[deckIndex].player,
                    atRate: rate
                )
                guard generation == self.preparationGeneration,
                      self.activeTransition == nil,
                      self.decks[deckIndex].player.currentItem === item,
                      self.preparedTransition?.deckIndex == deckIndex,
                      self.preparedTransition?.item === item else {
                    return
                }

                if success {
                    self.preparedTransition?.isPrerolled = true
                    self.startIfNeeded(
                        wantsPlayback: self.wantsPlayback
                    )
                    return
                }

                attempt += 1
                guard attempt < 6 else {
                    self.failPreparedTransition(
                        on: deckIndex,
                        error: nil
                    )
                    return
                }

                do {
                    try await Task.sleep(
                        for: .milliseconds(
                            min(250 * attempt, 1_000)
                        )
                    )
                } catch {
                    return
                }
            }
        }
    }

    private func preroll(
        _ player: AVPlayer,
        atRate rate: Float
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            player.preroll(atRate: rate) { finished in
                continuation.resume(returning: finished)
            }
        }
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
        guard wantsPlayback else {
            return true
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
        let outgoingPosition =
            activeDeck.currentPlaybackTime
        let incomingPosition =
            decks[prepared.deckIndex]
                .currentPlaybackTime
        let transition = ActiveTransition(
            identifier: prepared.identifier,
            outgoingDeckIndex:
                activeDeckIndex,
            incomingDeckIndex:
                prepared.deckIndex,
            plan: prepared.plan,
            outgoingStartPosition:
                outgoingPosition
                    ?? prepared.plan
                        .outgoingStartTime,
            incomingStartPosition:
                incomingPosition
                    ?? prepared.plan
                        .incomingStartTime
        )
        preparedTransition = nil
        activeTransition = transition
        decks[transition.incomingDeckIndex]
            .player
            .automaticallyWaitsToMinimizeStalling = false
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
        let incomingPlayer =
            decks[transition.incomingDeckIndex].player
        incomingPlayer.playImmediately(
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
                    outgoingPlayer.rate =
                        self.outgoingRate(
                            for: current,
                            progress: progress
                        )
                    incomingPlayer.rate =
                        self.incomingRate(
                            for: current,
                            progress: progress
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
            transition.incomingDeckIndex
        ].player.automaticallyWaitsToMinimizeStalling = true
        decks[
            transition.outgoingDeckIndex
        ].player.automaticallyWaitsToMinimizeStalling = true
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
        decks[deckIndex].onMetadataReady = nil
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
        decks[index].onMetadataReady = nil
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
