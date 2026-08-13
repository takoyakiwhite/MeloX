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
    private var pendingSeekRequiresPrecise = false
    private var preciseSeekFallbackTask: Task<Void, Never>?
    private var seekGeneration = 0
    private var seekRetryAttempt = 0
    private var pendingSeekRetryTask: Task<Void, Never>?
    private var suppressesProgressUpdates = false
    private var didReportCurrentItemFailure = false
    private var loadGeneration = 0

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
        preciseSeekFallbackTask?.cancel()
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
        preciseSeekFallbackTask?.cancel()
        preciseSeekFallbackTask = nil
        seekRetryAttempt = 0
        wantsPlayback = autoplay
        pendingSeekTime = startAt > 0 ? startAt : nil
        pendingSeekRequiresPrecise = false
        seekGeneration += 1
        suppressesProgressUpdates = true
        didReportCurrentItemFailure = false
        transition(to: .loading)

        let playbackItem = itemFactory.makeItem(
            for: source,
            preferredForwardBufferDuration: 8
        )
        guard generation == loadGeneration,
              !Task.isCancelled else {
            return
        }
        let equalizerState = activeDeck.autoMixEqualizerState
        activeDeck.replaceCurrentItem(
            with: playbackItem,
            identifier: nil,
            metadataLoader: { [itemFactory, playbackItem, equalizerState] in
                try await itemFactory.loadMetadata(
                    for: playbackItem,
                    autoMixEqualizerState: equalizerState
                )
            }
        )
        if autoplay {
            play()
        }
    }

    func unload() {
        loadGeneration += 1
        pendingSeekRetryTask?.cancel()
        pendingSeekRetryTask = nil
        preciseSeekFallbackTask?.cancel()
        preciseSeekFallbackTask = nil
        wantsPlayback = false
        pendingSeekTime = nil
        pendingSeekRequiresPrecise = false
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
        guard item.status == .readyToPlay else {
            transition(to: .loading)
            return
        }

        do {
            try activateAudioSession()

            // Ordinary playback never waits for precise timing. If the caller
            // requested a starting position before precise metadata is ready,
            // perform a best-effort seek against the fallback media-zero
            // timeline and let a later precise timeline upgrade only re-anchor
            // the clock. Explicitly precise workflows (AutoMix) are handled by
            // their own controller and still wait for a precise timeline.
            if pendingSeekTime != nil {
                if activeDeck.isPreciseMetadataReady {
                    retryPendingSeek(for: item)
                } else if !pendingSeekRequiresPrecise, let position = pendingSeekTime {
                    pendingSeekTime = nil
                    applySeek(to: position, for: item)
                }
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
        autoMixController.pauseAll()
        updateStateFromPlayer()
    }

    func seek(to seconds: TimeInterval) {
        seek(to: seconds, requiresPreciseTimeline: false)
    }

    func seekToLyric(at seconds: TimeInterval) {
        seek(to: seconds, requiresPreciseTimeline: true)
    }

    private func seek(
        to seconds: TimeInterval,
        requiresPreciseTimeline: Bool
    ) {
        let position = max(0, seconds)
        pendingSeekRetryTask?.cancel()
        pendingSeekRetryTask = nil
        preciseSeekFallbackTask?.cancel()
        preciseSeekFallbackTask = nil
        seekRetryAttempt = 0
        seekGeneration += 1
        pendingSeekRequiresPrecise = requiresPreciseTimeline
        guard let item = activeDeck.player.currentItem else {
            pendingSeekTime = position
            suppressesProgressUpdates = true
            if requiresPreciseTimeline { schedulePreciseSeekFallback(at: position, generation: seekGeneration) }
            return
        }
        cancelAutoMix()
        guard item.status == .readyToPlay else {
            pendingSeekTime = position
            suppressesProgressUpdates = true
            if requiresPreciseTimeline { schedulePreciseSeekFallback(at: position, generation: seekGeneration) }
            return
        }

        if requiresPreciseTimeline && !activeDeck.isPreciseMetadataReady {
            pendingSeekTime = position
            suppressesProgressUpdates = true
            schedulePreciseSeekFallback(at: position, generation: seekGeneration)
            transition(to: .loading)
            return
        }

        pendingSeekTime = nil
        pendingSeekRequiresPrecise = false
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

            deck.onPreciseMetadataReady = {
                [weak self, weak deck] item in
                guard let self, let deck else { return }
                self.handlePreciseMetadataReady(
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

    private func handlePreciseMetadataReady(
        _ item: AVPlayerItem,
        on deck: AudioPlaybackDeck,
        at deckIndex: Int
    ) {
        guard deckIndex == activeDeckIndex,
              deck.player.currentItem === item else { return }

        // The audio clock is authoritative. Once the precise media offset is
        // known, re-anchor the public clock from the player's current media
        // time rather than blindly seeking again. This avoids a visible jump
        // when precise metadata arrives after a best-effort seek.
        if pendingSeekTime != nil, pendingSeekRequiresPrecise {
            preciseSeekFallbackTask?.cancel()
            preciseSeekFallbackTask = nil
            retryPendingSeek(for: item)
            return
        }
        if !suppressesProgressUpdates {
            publishDurationIfAvailable()
            publishPlaybackClockSample(origin: .stateChanged)
        }
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
                resumePlaybackIfNeeded()
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
        pendingSeekTime = nil
        pendingSeekRequiresPrecise = false
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
        guard let position = pendingSeekTime,
              activeDeck.player.currentItem === item,
              item.status == .readyToPlay else {
            return
        }
        if pendingSeekRequiresPrecise && !activeDeck.isPreciseMetadataReady {
            return
        }
        pendingSeekRequiresPrecise = false
        preciseSeekFallbackTask?.cancel()
        preciseSeekFallbackTask = nil
        applySeek(to: position, for: item)
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

    private func schedulePreciseSeekFallback(
        at position: TimeInterval,
        generation: Int
    ) {
        preciseSeekFallbackTask?.cancel()
        preciseSeekFallbackTask = Task { @MainActor [weak self] in
            do {
                // Give the precise metadata path its normal bounded retry window.
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard let self,
                  generation == self.seekGeneration,
                  self.pendingSeekTime == position,
                  self.pendingSeekRequiresPrecise,
                  let item = self.activeDeck.player.currentItem,
                  item.status == .readyToPlay else {
                return
            }
            self.pendingSeekRequiresPrecise = false
            self.pendingSeekTime = nil
            self.suppressesProgressUpdates = true
            self.applySeek(to: position, for: item)
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
