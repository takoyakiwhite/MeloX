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
    private var suppressesProgressUpdates = false
    private var didReportCurrentItemFailure = false
    private var loadGeneration = 0
    private var currentSource: PlaybackSource?
    private var playbackRecoveryTask: Task<Void, Never>?
    private var playbackRecoveryGeneration = 0
    private var playbackRecoveryAttempt = 0
    private var isReloadingForPlaybackRecovery = false

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

    var expectsPlaybackToContinue: Bool {
        wantsPlayback
    }

    var nowPlayingPlayers: [AVPlayer] {
        decks.map(\.player)
    }

    var hasPreparedAutoMix: Bool {
        autoMixController.hasPreparedTransition
    }

    var audioSpectrumSnapshot: PlaybackAudioSpectrumSnapshot {
        itemFactory.spectrumSnapshot()
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
        playbackRecoveryTask?.cancel()
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
        cancelPlaybackRecovery()
        seekRetryAttempt = 0
        wantsPlayback = autoplay
        currentSource = source
        pendingSeekTime = startAt > 0 ? startAt : nil
        // Any non-zero starting position (resume, explicit start, or a
        // restored position after relaunch) must be resolved against the
        // precise media timeline. Starting from zero needs no seek.
        seekGeneration += 1
        suppressesProgressUpdates = true
        didReportCurrentItemFailure = false
        transition(to: .loading)

        do {
            let playbackItem = try await itemFactory.makeItem(
                for: source,
                preferredForwardBufferDuration: 8,
                autoMixEqualizerState: activeDeck.autoMixEqualizerState
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
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            fail(with: error)
        }
    }

    func unload() {
        loadGeneration += 1
        pendingSeekRetryTask?.cancel()
        cancelPlaybackRecovery()
        pendingSeekRetryTask = nil
        wantsPlayback = false
        pendingSeekTime = nil
        seekGeneration += 1
        seekRetryAttempt = 0
        suppressesProgressUpdates = false
        didReportCurrentItemFailure = false
        currentSource = nil
        autoMixController.reset()
        transition(to: .idle)
    }

    func play() {
        wantsPlayback = true
        cancelPlaybackRecovery()
        guard let item = activeDeck.player.currentItem else {
            schedulePlaybackRecovery(reason: .missingItem)
            return
        }
        guard item.status == .readyToPlay else {
            if item.status == .failed {
                schedulePlaybackRecovery(reason: .failedItem)
            } else {
                transition(to: .loading)
                schedulePlaybackRecovery(reason: .waiting)
            }
            return
        }

        do {
            try activateAudioSession()

            if pendingSeekTime != nil {
                retryPendingSeek(for: item)
                return
            }

            suppressesProgressUpdates = false
            updateStateFromPlayer()
            let resumedAutoMix =
                autoMixController.resumeIncomingIfNeeded()
            if !resumedAutoMix {
                activeDeck.player.play()
            }
        } catch {
            wantsPlayback = false
            onFailure?(AudioPlaybackError.audioSession(error))
        }
    }

    func pause() {
        wantsPlayback = false
        cancelPlaybackRecovery()
        autoMixController.pauseAll()
        updateStateFromPlayer()
    }

    func seek(to seconds: TimeInterval) {
        performSeek(to: seconds)
    }

    func seekToLyric(at seconds: TimeInterval) {
        performSeek(to: seconds)
    }

    private func performSeek(
        to seconds: TimeInterval
    ) {
        cancelPlaybackRecovery()
        let position = max(0, seconds)
        pendingSeekRetryTask?.cancel()
        pendingSeekRetryTask = nil
        seekRetryAttempt = 0
        seekGeneration += 1
        guard let item = activeDeck.player.currentItem else {
            pendingSeekTime = position
            suppressesProgressUpdates = true
            return
        }
        cancelAutoMix()
        guard item.status == .readyToPlay else {
            pendingSeekTime = position
            suppressesProgressUpdates = true
            return
        }

        pendingSeekTime = nil
        applySeek(
            to: position,
            for: item
        )
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
            if wantsPlayback {
                schedulePlaybackRecovery(reason: .failedItem)
            } else {
                fail(with: item.error)
            }
        @unknown default:
            if wantsPlayback {
                schedulePlaybackRecovery(reason: .failedItem)
            } else {
                fail(with: item.error)
            }
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
            if wantsPlayback {
                schedulePlaybackRecovery(reason: .failedItem)
                transition(to: .loading)
            } else {
                fail(with: item.error)
            }
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
        cancelPlaybackRecovery()
        pendingSeekRetryTask?.cancel()
        pendingSeekRetryTask = nil
        pendingSeekTime = nil
        seekGeneration += 1
        let generation = seekGeneration
        let seekingDeck = activeDeck
        let seekingPlayer = activeDeck.player
        suppressesProgressUpdates = true
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
                    self.pendingSeekTime = position
                    self.seekRetryAttempt += 1
                    self.schedulePendingSeekRetry(for: item)
                    return
                }
                self.seekRetryAttempt = 0
                self.suppressesProgressUpdates = false
                self.publishPlaybackClockSample(
                    origin: .seekCompleted
                )
                self.resumePlaybackIfNeeded()
            }
        }
    }

    private func retryPendingSeek(
        for item: AVPlayerItem
    ) {
        guard let requestedPosition = pendingSeekTime,
              activeDeck.player.currentItem === item,
              item.status == .readyToPlay else {
            return
        }
        let position = clampedPreciseSeekPosition(
            requestedPosition,
            for: item
        )
        applySeek(to: position, for: item)
    }

    private func clampedPreciseSeekPosition(
        _ position: TimeInterval,
        for item: AVPlayerItem
    ) -> TimeInterval {
        let normalized = position.isFinite ? max(position, 0) : 0
        guard activeDeck.player.currentItem === item,
              let duration = activeDeck.playbackDuration,
              duration.isFinite,
              duration > 0 else {
            return normalized
        }
        return min(normalized, max(duration - 0.001, 0))
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

    private enum PlaybackRecoveryReason {
        case missingItem
        case paused
        case waiting
        case failedItem
    }

    private func schedulePlaybackRecovery(
        reason: PlaybackRecoveryReason
    ) {
        guard wantsPlayback,
              !suppressesRecoveryForCurrentState,
              let item = activeDeck.player.currentItem else {
            if reason == .missingItem {
                schedulePlaybackReload()
            }
            return
        }

        let duration = activeDeck.playbackDuration ?? 0
        let position = activeDeck.currentPlaybackTime ?? 0
        if duration > 0, position >= duration - 0.25 {
            return
        }

        playbackRecoveryTask?.cancel()
        playbackRecoveryGeneration += 1
        let generation = playbackRecoveryGeneration
        let delay: Duration = switch reason {
        case .paused:
            .milliseconds(250)
        case .waiting:
            .milliseconds(750)
        case .failedItem, .missingItem:
            .milliseconds(0)
        }

        playbackRecoveryTask = Task { @MainActor [weak self, weak item] in
            do {
                if delay > .zero {
                    try await Task.sleep(for: delay)
                }
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  generation == self.playbackRecoveryGeneration,
                  self.wantsPlayback else {
                return
            }
            if reason == .missingItem {
                await self.reloadCurrentItemForPlaybackRecovery(
                    generation: generation
                )
                return
            }
            guard let item,
                  self.activeDeck.player.currentItem === item else {
                return
            }
            if item.status == .failed {
                await self.reloadCurrentItemForPlaybackRecovery(
                    generation: generation
                )
                return
            }

            do {
                try self.activateAudioSession()
                self.activeDeck.player.play()
            } catch {
                await self.reloadCurrentItemForPlaybackRecovery(
                    generation: generation
                )
                return
            }

            do {
                try await Task.sleep(for: .milliseconds(700))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  generation == self.playbackRecoveryGeneration,
                  self.wantsPlayback,
                  self.activeDeck.player.currentItem === item else {
                return
            }
            if self.activeDeck.player.timeControlStatus == .playing {
                self.playbackRecoveryAttempt = 0
                self.playbackRecoveryTask = nil
                self.suppressesProgressUpdates = false
                self.publishPlaybackClockSample(origin: .stateChanged)
                return
            }
            self.playbackRecoveryAttempt += 1
            if self.playbackRecoveryAttempt < 3 {
                self.schedulePlaybackRecovery(reason: .waiting)
            } else {
                await self.reloadCurrentItemForPlaybackRecovery(
                    generation: generation
                )
            }
        }
    }

    private var suppressesRecoveryForCurrentState: Bool {
        suppressesProgressUpdates || pendingSeekTime != nil
    }

    private func schedulePlaybackReload() {
        playbackRecoveryGeneration += 1
        let generation = playbackRecoveryGeneration
        playbackRecoveryTask?.cancel()
        playbackRecoveryTask = Task { @MainActor [weak self] in
            guard let self,
                  generation == self.playbackRecoveryGeneration,
                  self.wantsPlayback else { return }
            await self.reloadCurrentItemForPlaybackRecovery(
                generation: generation
            )
        }
    }

    private func cancelPlaybackRecovery() {
        playbackRecoveryGeneration += 1
        playbackRecoveryTask?.cancel()
        playbackRecoveryTask = nil
    }

    private func reloadCurrentItemForPlaybackRecovery(
        generation: Int
    ) async {
        guard generation == playbackRecoveryGeneration,
              wantsPlayback,
              let source = currentSource,
              !isReloadingForPlaybackRecovery else {
            return
        }
        isReloadingForPlaybackRecovery = true
        playbackRecoveryTask = nil
        cancelAutoMix()
        let loadGenerationAtStart = loadGeneration
        let resumePosition = max(
            activeDeck.currentPlaybackTime ?? pendingSeekTime ?? 0,
            0
        )
        pendingSeekRetryTask?.cancel()
        pendingSeekRetryTask = nil
        pendingSeekTime = resumePosition > 0 ? resumePosition : nil
        suppressesProgressUpdates = true
        transition(to: .loading)

        do {
            let playbackItem = try await itemFactory.makeItem(
                for: source,
                preferredForwardBufferDuration: 8,
                autoMixEqualizerState: activeDeck.autoMixEqualizerState
            )
            guard generation == playbackRecoveryGeneration,
                  loadGeneration == loadGenerationAtStart,
                  wantsPlayback,
                  !Task.isCancelled else {
                isReloadingForPlaybackRecovery = false
                return
            }
            activeDeck.replaceCurrentItem(
                with: playbackItem,
                identifier: nil
            )
            didReportCurrentItemFailure = false
            playbackRecoveryAttempt = 0
            isReloadingForPlaybackRecovery = false
        } catch is CancellationError {
            isReloadingForPlaybackRecovery = false
        } catch {
            isReloadingForPlaybackRecovery = false
            wantsPlayback = false
            fail(with: error)
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
