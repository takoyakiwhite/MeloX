@preconcurrency import AVFoundation
import Foundation

enum AudioPlaybackState: Equatable {
    case idle
    case loading
    case paused
    case playing
}

enum AudioPlaybackError: LocalizedError {
    case audioSession(Error)
    case itemFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .audioSession(let error):
            "无法启用音频播放：\(error.localizedDescription)"
        case .itemFailed(let error):
            if let error {
                "音源载入失败：\(error.localizedDescription)"
            } else {
                "音源载入失败，请稍后重试。"
            }
        }
    }
}

@MainActor
final class AudioPlaybackEngine {
    var onStateChanged: ((AudioPlaybackState) -> Void)?
    var onPlaybackClockChanged:
        ((AudioPlaybackClockSample) -> Void)?
    var onDurationChanged: ((TimeInterval) -> Void)?
    var onPreciseTimingReady: ((Bool) -> Void)?
    var onPlaybackEnded: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    var onAutoMixTransitionBegan:
        ((Int, AutoMixTransitionPlan) -> Void)?
    var onAutoMixTransitionProgress: ((Double) -> Void)?
    var onAutoMixTransitionCompleted: ((Int) -> Void)?
    var onAutoMixPreparationFailed: ((Int, Error) -> Void)?
    var onInterruptionBegan: (() -> Void)?
    var onInterruptionEnded: ((Bool) -> Void)?
    var onOutputDeviceDisconnected: (() -> Void)?

    private(set) var state: AudioPlaybackState = .idle

    private let itemFactory: AudioPlaybackItemFactory
    private let autoMixController:
        AutoMixDeckTransitionController
    private let observedPlayers: [AVPlayer]
    private var timeObservers: [Any?] = [nil, nil]
    private var timeControlObservers:
        [NSKeyValueObservation?] = [nil, nil]
    private var notificationObservers: [NSObjectProtocol] = []
    private var wantsPlayback = false
    private var pendingSeekTime: TimeInterval?
    private var seekGeneration = 0
    private var seekRetryAttempt = 0
    private var pendingSeekRetryTask: Task<Void, Never>?
    private var seekDebounceTask: Task<Void, Never>?
    private var pendingSeekTarget: TimeInterval?
    private var activeSeekTarget: TimeInterval?
    private var activeSeekTimelineRevision: Int?
    private var seekCorrectionAttempt = 0
    private var suppressesProgressUpdates = false
    private var didReportCurrentItemFailure = false
    private var loadGeneration = 0
    private weak var lastNotifiedPreciseTimingItem: AVPlayerItem?

    private var decks: [AudioPlaybackDeck] {
        autoMixController.decks
    }

    private var activeDeckIndex: Int {
        autoMixController.activeDeckIndex
    }

    private var activeDeck: AudioPlaybackDeck {
        autoMixController.activeDeck
    }

    var hasCurrentItem: Bool {
        activeDeck.player.currentItem != nil
    }

    var currentPlaybackTime: TimeInterval? {
        guard activeDeck.player.currentItem != nil,
              !suppressesProgressUpdates else { return nil }
        return activeDeck.currentPlaybackTime
    }

    var currentPlaybackRate: Double {
        let rate = Double(activeDeck.player.rate)
        guard rate.isFinite, rate > 0 else {
            return 0
        }

        switch activeDeck.player.timeControlStatus {
        case .playing, .waitingToPlayAtSpecifiedRate:
            return rate
        case .paused:
            return 0
        @unknown default:
            return rate
        }
    }

    var expectsPlaybackToContinue: Bool {
        wantsPlayback
    }

    var nowPlayingPlayers: [AVPlayer] {
        decks.map(\.player)
    }

    var hasPreparedAutoMix: Bool {
        autoMixController.hasPreparedTransition
    }

    init(equalizerConfiguration: AudioEqualizerConfiguration) {
        let factory = AudioPlaybackItemFactory(
            equalizerConfiguration: equalizerConfiguration
        )
        itemFactory = factory
        let controller =
            AutoMixDeckTransitionController(
                itemFactory: factory
            )
        autoMixController = controller
        observedPlayers = controller.decks.map(\.player)
        bindAutoMixController()
        installPlayerObservers()
        installAudioSessionObservers()
    }

    deinit {
        pendingSeekRetryTask?.cancel()
        seekDebounceTask?.cancel()
        for (player, observer) in zip(
            observedPlayers,
            timeObservers
        ) {
            if let observer {
                player.removeTimeObserver(observer)
            }
        }
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func load(
        _ source: PlaybackSource,
        startAt: TimeInterval = 0,
        autoplay: Bool
    ) async {
        loadGeneration += 1
        let generation = loadGeneration
        cancelAutoMix()
        pendingSeekRetryTask?.cancel()
        pendingSeekRetryTask = nil
        seekDebounceTask?.cancel()
        seekDebounceTask = nil
        seekRetryAttempt = 0
        pendingSeekTarget = nil
        activeSeekTarget = nil
        activeSeekTimelineRevision = nil
        seekCorrectionAttempt = 0
        wantsPlayback = autoplay
        pendingSeekTime = max(0, startAt)
        seekGeneration += 1
        suppressesProgressUpdates = true
        didReportCurrentItemFailure = false
        lastNotifiedPreciseTimingItem = nil
        transition(to: .loading)

        let playbackItem = await itemFactory.makeItem(
            for: source,
            preferredForwardBufferDuration: 8,
            autoMixEqualizerState:
                activeDeck
                    .autoMixEqualizerState
        )
        guard generation == loadGeneration,
              !Task.isCancelled else {
            return
        }
        activeDeck.replaceCurrentItem(
            with: playbackItem,
            identifier: nil
        )
        if autoplay {
            play()
        }
    }

    func unload() {
        loadGeneration += 1
        pendingSeekRetryTask?.cancel()
        pendingSeekRetryTask = nil
        seekDebounceTask?.cancel()
        seekDebounceTask = nil
        pendingSeekTarget = nil
        activeSeekTarget = nil
        activeSeekTimelineRevision = nil
        seekCorrectionAttempt = 0
        wantsPlayback = false
        pendingSeekTime = nil
        seekGeneration += 1
        seekRetryAttempt = 0
        suppressesProgressUpdates = false
        didReportCurrentItemFailure = false
        autoMixController.reset()
        transition(to: .idle)
    }

    func play() {
        wantsPlayback = true
        guard let item = activeDeck.player.currentItem else {
            return
        }
        guard item.status == .readyToPlay,
              !suppressesProgressUpdates else {
            transition(to: .loading)
            return
        }
        do {
            try activateAudioSession()
            let resumedAutoMix =
                autoMixController.resumeIncomingIfNeeded()
            if !resumedAutoMix {
                activeDeck.player.play()
            }
            updateStateFromPlayer()
        } catch {
            wantsPlayback = false
            onFailure?(AudioPlaybackError.audioSession(error))
        }
    }

    func pause() {
        wantsPlayback = false
        autoMixController.pauseAll()
        updateStateFromPlayer()
    }

    func seek(to seconds: TimeInterval) {
        let position = max(0, seconds)
        pendingSeekRetryTask?.cancel()
        pendingSeekRetryTask = nil
        seekRetryAttempt = 0
        seekCorrectionAttempt = 0
        cancelAutoMix()

        seekGeneration &+= 1
        suppressesProgressUpdates = true
        activeSeekTarget = nil
        activeSeekTimelineRevision = nil
        pendingSeekTarget = position

        guard let item = activeDeck.player.currentItem else {
            pendingSeekTime = position
            scheduleDebouncedSeekIfPossible()
            return
        }

        guard item.status == .readyToPlay else {
            pendingSeekTime = position
            scheduleDebouncedSeekIfPossible()
            return
        }

        pendingSeekTime = nil
        item.cancelPendingSeeks()
        scheduleDebouncedSeekIfPossible()
    }

    func setVolume(_ volume: Double) {
        autoMixController.setVolume(volume)
    }

    func setEqualizerConfiguration(
        _ configuration: AudioEqualizerConfiguration
    ) {
        itemFactory.updateEqualizer(configuration)
    }

    func prepareAutoMix(
        _ source: PlaybackSource,
        identifier: Int,
        plan: AutoMixTransitionPlan
    ) async {
        await autoMixController.prepare(
            source,
            identifier: identifier,
            plan: plan
        )
        autoMixController.startIfNeeded(
            wantsPlayback: wantsPlayback
        )
    }

    func cancelAutoMix() {
        autoMixController.cancel(
            wantsPlayback: wantsPlayback
        )
    }

    private func bindAutoMixController() {
        autoMixController.onTransitionBegan = {
            [weak self] identifier, plan in
            self?.onAutoMixTransitionBegan?(
                identifier,
                plan
            )
        }
        autoMixController.onTransitionProgress = {
            [weak self] progress in
            self?.onAutoMixTransitionProgress?(progress)
        }
        autoMixController.onTransitionCompleted = {
            [weak self] identifier in
            guard let self else { return }
            self.onAutoMixTransitionCompleted?(identifier)
            self.publishDurationIfAvailable()
            self.notifyPreciseTimingIfReady()
            self.updateStateFromPlayer(
                clockOrigin: .activeItemChanged
            )
        }
        autoMixController.onPreparationFailed = {
            [weak self] identifier, error in
            self?.onAutoMixPreparationFailed?(
                identifier,
                error
            )
        }
    }

    private func installPlayerObservers() {
        for index in decks.indices {
            let deck = decks[index]
            deck.onItemStatusChanged = {
                [weak self, weak deck] item in
                guard let self, let deck else { return }
                self.handleItemStatusChange(
                    item,
                    on: deck,
                    at: index
                )
            }
            deck.onSeekableTimeRangesChanged = {
                [weak self, weak deck] item in
                guard let self, let deck else { return }
                self.handleSeekableTimeRangesChange(
                    item,
                    on: deck,
                    at: index
                )
            }
            deck.onPreciseTimingReady = {
                [weak self, weak deck] in
                guard let self, let deck,
                      index == self.activeDeckIndex,
                      let item = deck.player.currentItem else {
                    return
                }
                self.notifyPreciseTimingIfNeeded(for: item)
            }

            timeObservers[index] =
                deck.player.addPeriodicTimeObserver(
                    forInterval: CMTime(
                        seconds: 0.1,
                        preferredTimescale: 600
                    ),
                    queue: .main
                ) { [weak self] time in
                    MainActor.assumeIsolated {
                        self?.handlePeriodicTime(
                            time,
                            deckIndex: index
                        )
                    }
                }

            timeControlObservers[index] =
                deck.player.observe(
                    \.timeControlStatus,
                    options: [.initial, .new]
                ) { [weak self] _, _ in
                    guard let self else { return }
                    Task { @MainActor [self] in
                        guard index
                                == self.activeDeckIndex else {
                            return
                        }
                        self.updateStateFromPlayer()
                    }
                }
        }

        let center = NotificationCenter.default
        notificationObservers.append(
            center.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.handleItemEnded(
                        notification.object
                    )
                }
            }
        )
        notificationObservers.append(
            center.addObserver(
                forName:
                    .AVPlayerItemFailedToPlayToEndTime,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    let error = notification.userInfo?[
                        AVPlayerItemFailedToPlayToEndTimeErrorKey
                    ] as? Error
                    self?.handleItemFailedToEnd(
                        notification.object,
                        error: error
                    )
                }
            }
        )
    }

    private func notifyPreciseTimingIfReady() {
        guard activeDeck.isPreciseTimingReady,
              let item = activeDeck.player.currentItem else {
            return
        }
        notifyPreciseTimingIfNeeded(for: item)
    }

    private func notifyPreciseTimingIfNeeded(
        for item: AVPlayerItem
    ) {
        guard activeDeck.player.currentItem === item,
              !suppressesProgressUpdates,
              pendingSeekTime == nil,
              lastNotifiedPreciseTimingItem !== item else {
            return
        }
        lastNotifiedPreciseTimingItem = item
        publishPlaybackClockSample(
            origin: .stateChanged
        )
        publishDurationIfAvailable()
        onPreciseTimingReady?(true)
    }

    private func handleSeekableTimeRangesChange(
        _ item: AVPlayerItem,
        on deck: AudioPlaybackDeck,
        at deckIndex: Int
    ) {
        guard deckIndex == activeDeckIndex,
              deck.player.currentItem === item,
              item.status == .readyToPlay,
              pendingSeekTime != nil else {
            return
        }
        retryPendingSeek(for: item)
    }

    private func handlePeriodicTime(
        _: CMTime,
        deckIndex: Int
    ) {
        guard deckIndex == activeDeckIndex,
              activeDeck.player.currentItem != nil else { return }
        publishPlaybackClockSample(origin: .periodic)
        publishDurationIfAvailable()
        autoMixController.startIfNeeded(
            wantsPlayback: wantsPlayback
        )
    }

    private func handleItemStatusChange(
        _ item: AVPlayerItem,
        on deck: AudioPlaybackDeck,
        at deckIndex: Int
    ) {
        guard deck.player.currentItem === item else { return }
        if deckIndex != activeDeckIndex {
            autoMixController.handleStandbyStatus(
                item,
                deckIndex: deckIndex,
                wantsPlayback: wantsPlayback
            )
            return
        }

        switch item.status {
        case .unknown:
            transition(to: .loading)
        case .readyToPlay:
            publishDurationIfAvailable()
            if pendingSeekTime != nil {
                retryPendingSeek(for: item)
                return
            }
            suppressesProgressUpdates = false
            resumePlaybackIfNeeded()
        case .failed:
            fail(with: item.error)
        @unknown default:
            fail(with: item.error)
        }
    }

    private func handleItemEnded(_ object: Any?) {
        guard let item = object as? AVPlayerItem else {
            return
        }
        if autoMixController.finishIfOutgoingEnded(
            item,
            wantsPlayback: wantsPlayback
        ) {
            return
        }
        guard activeDeck.player.currentItem === item else {
            return
        }
        onPlaybackEnded?()
    }

    private func handleItemFailedToEnd(
        _ object: Any?,
        error: Error?
    ) {
        guard let item = object as? AVPlayerItem else {
            return
        }
        if autoMixController.failPreparedIfMatching(
            item,
            error: error
        ) {
            return
        }
        guard activeDeck.player.currentItem === item else {
            return
        }
        fail(with: error)
    }

    private func updateStateFromPlayer(
        clockOrigin: AudioPlaybackClockSample.Origin = .stateChanged
    ) {
        guard let item = activeDeck.player.currentItem else {
            transition(to: .idle)
            return
        }
        if item.status == .failed {
            fail(with: item.error)
            return
        }
        if suppressesProgressUpdates {
            transition(to: .loading)
            return
        }
        switch activeDeck.player.timeControlStatus {
        case .paused:
            transition(
                to:
                    item.status == .unknown
                        ? .loading
                        : .paused
            )
        case .waitingToPlayAtSpecifiedRate:
            transition(to: .loading)
        case .playing:
            transition(to: .playing)
        @unknown default:
            transition(to: .paused)
        }
        publishPlaybackClockSample(origin: clockOrigin)
    }

    private func publishDurationIfAvailable() {
        guard let seconds = activeDeck.playbackDuration,
              seconds > 0 else {
            return
        }
        onDurationChanged?(seconds)
    }

    private func publishPlaybackClockSample(
        origin: AudioPlaybackClockSample.Origin
    ) {
        guard !suppressesProgressUpdates,
              activeDeck.player.currentItem != nil else {
            return
        }
        let player = activeDeck.player
        guard let seconds = activeDeck.currentPlaybackTime else {
            return
        }
        let rate = switch player.timeControlStatus {
        case .playing:
            max(Double(player.rate), 0.0)
        case .paused, .waitingToPlayAtSpecifiedRate:
            0.0
        @unknown default:
            0.0
        }
        onPlaybackClockChanged?(
            AudioPlaybackClockSample(
                position: max(seconds, 0),
                rate: rate,
                sampledAt: Date(),
                origin: origin
            )
        )
    }

    private func applySeek(
        to position: TimeInterval,
        for item: AVPlayerItem
    ) {
        pendingSeekRetryTask?.cancel()
        pendingSeekRetryTask = nil
        seekDebounceTask?.cancel()
        seekDebounceTask = nil
        pendingSeekTime = nil
        pendingSeekTarget = nil

        seekGeneration &+= 1
        let generation = seekGeneration
        let seekingDeck = activeDeck
        let seekingPlayer = seekingDeck.player
        let timelineRevision = seekingDeck.mediaTimelineRevision

        suppressesProgressUpdates = true
        activeSeekTarget = position
        activeSeekTimelineRevision = timelineRevision
        item.cancelPendingSeeks()

        seekingPlayer.seek(
            to: seekingDeck.mediaTime(
                forPlaybackPosition: position
            ),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] finished in
            guard let self else { return }
            Task { @MainActor [self] in
                guard generation == self.seekGeneration,
                      self.activeDeck.player === seekingPlayer,
                      seekingPlayer.currentItem === item else {
                    return
                }

                guard finished else {
                    self.activeSeekTarget = position
                    self.pendingSeekTime = position
                    self.seekRetryAttempt += 1
                    self.schedulePendingSeekRetry(for: item)
                    return
                }

                guard let target = self.activeSeekTarget else {
                    self.finishSeekPlayback(for: item)
                    return
                }

                let timelineChanged =
                    self.activeSeekTimelineRevision
                        != seekingDeck.mediaTimelineRevision

                let actual = seekingDeck.currentPlaybackTime
                let error = actual.map { abs($0 - target) } ?? .infinity

                if self.seekCorrectionAttempt < 2,
                   timelineChanged || error > 0.05 {
                    self.seekCorrectionAttempt += 1
                    self.applySeek(to: target, for: item)
                    return
                }

                self.finishSeekPlayback(for: item)
            }
        }
    }

    private func scheduleDebouncedSeekIfPossible() {
        guard pendingSeekTarget != nil else { return }

        seekDebounceTask?.cancel()
        seekDebounceTask = Task {
            @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(80))
            } catch {
                return
            }

            guard let self,
                  !Task.isCancelled,
                  let target = self.pendingSeekTarget,
                  let item = self.activeDeck.player.currentItem else {
                return
            }

            guard item.status == .readyToPlay else {
                self.pendingSeekTime = target
                return
            }

            self.pendingSeekTime = nil
            self.applySeek(to: target, for: item)
        }
    }

    private func finishSeekPlayback(for item: AVPlayerItem) {
        guard activeDeck.player.currentItem === item else { return }
        pendingSeekRetryTask?.cancel()
        pendingSeekRetryTask = nil
        seekDebounceTask?.cancel()
        seekDebounceTask = nil
        pendingSeekTime = nil
        pendingSeekTarget = nil
        activeSeekTarget = nil
        activeSeekTimelineRevision = nil
        seekRetryAttempt = 0
        seekCorrectionAttempt = 0
        suppressesProgressUpdates = false
        publishPlaybackClockSample(origin: .seekCompleted)
        notifyPreciseTimingIfReady()
        resumePlaybackIfNeeded()
    }

    private func retryPendingSeek(
        for item: AVPlayerItem
    ) {
        guard let position = pendingSeekTime,
              activeDeck.player.currentItem === item,
              item.status == .readyToPlay else {
            return
        }
        pendingSeekTarget = position
        pendingSeekTime = nil
        scheduleDebouncedSeekIfPossible()
    }

    private func schedulePendingSeekRetry(
        for item: AVPlayerItem
    ) {
        pendingSeekRetryTask?.cancel()
        let retryAttempt = min(seekRetryAttempt, 4)
        let delayMilliseconds = min(
            50 * (1 << retryAttempt),
            500
        )
        pendingSeekRetryTask = Task {
            @MainActor [weak self, weak item] in
            do {
                try await Task.sleep(
                    for: .milliseconds(delayMilliseconds)
                )
            } catch {
                return
            }
            guard let self, let item,
                  !Task.isCancelled else { return }
            self.retryPendingSeek(for: item)
        }
    }

    private func resumePlaybackIfNeeded() {
        if wantsPlayback {
            play()
        } else {
            updateStateFromPlayer()
        }
    }

    private func fail(with error: Error?) {
        guard !didReportCurrentItemFailure else { return }
        didReportCurrentItemFailure = true
        wantsPlayback = false
        autoMixController.pauseAll()
        publishPlaybackClockSample(origin: .stateChanged)
        transition(to: .paused)
        onFailure?(AudioPlaybackError.itemFailed(error))
    }

    private func transition(
        to newState: AudioPlaybackState
    ) {
        guard state != newState else { return }
        state = newState
        onStateChanged?(newState)
    }

    private func activateAudioSession() throws {
        try AudioPlaybackSessionConfigurator.activate()
    }

    private func installAudioSessionObservers() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        notificationObservers.append(
            center.addObserver(
                forName:
                    AVAudioSession.interruptionNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.handleInterruption(notification)
                }
            }
        )
        notificationObservers.append(
            center.addObserver(
                forName:
                    AVAudioSession.routeChangeNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.handleRouteChange(notification)
                }
            }
        )
    }

    private func handleInterruption(
        _ notification: Notification
    ) {
        guard let rawType = notification.userInfo?[
            AVAudioSessionInterruptionTypeKey
        ] as? UInt,
              let type =
                AVAudioSession.InterruptionType(
                    rawValue: rawType
                ) else {
            return
        }
        switch type {
        case .began:
            onInterruptionBegan?()
        case .ended:
            let rawOptions = notification.userInfo?[
                AVAudioSessionInterruptionOptionKey
            ] as? UInt ?? 0
            let shouldResume =
                AVAudioSession.InterruptionOptions(
                    rawValue: rawOptions
                ).contains(.shouldResume)
            onInterruptionEnded?(shouldResume)
        @unknown default:
            break
        }
    }

    private func handleRouteChange(
        _ notification: Notification
    ) {
        guard let rawReason = notification.userInfo?[
            AVAudioSessionRouteChangeReasonKey
        ] as? UInt,
              AVAudioSession.RouteChangeReason(
                rawValue: rawReason
              ) == .oldDeviceUnavailable else {
            return
        }
        pause()
        onOutputDeviceDisconnected?()
    }
}
