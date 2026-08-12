import SwiftUI

struct AppleMusicLyricsView: View {
    private static let bottomPreloadLineCount = 2
    private static let futureCascadeSafetyLineCount = 6
    private static let annotationSpacing =
        LyricAnnotationMetrics.verticalSpacing
    private static let cascadeSettlementGraceDuration: TimeInterval =
        1.0 / 60.0
    private static let interludeExpansionDuration: TimeInterval = 0.5
    private static let focusColorTransitionDuration: TimeInterval = 0.12
    nonisolated private static let expandedBottomDistanceScale: CGFloat = 0.68

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(PlayerStore.self) private var player
    @Environment(AppSettings.self) private var settings

    let lyrics: [LyricLine]
    let errorMessage: String?
    let highlightedLyricID: LyricLine.ID?
    let isActive: Bool
    let isInterfaceHidden: Bool
    let bottomOverlayHeight: CGFloat
    let onInterfaceInteraction: (() -> Void)?
    let onInterfaceVisibilityChange: ((Bool) -> Void)?
    let onInitialFocusPrepared: (() -> Void)?
    private let lyricIndexByID: [LyricLine.ID: Int]
    private let hasSyllableSyncedLyrics: Bool
    private let hasTranslations: Bool
    private let hasRomanizations: Bool
    private let interludes: [LyricInterlude]
    private let interludeByID: [LyricInterlude.ID: LyricInterlude]
    private let displayItems: [AppleMusicLyricsDisplayItem]

    @State private var scrollPositionID: LyricLine.ID?
    @State private var isBrowsingLyrics = false
    @State private var browsingGeneration = 0
    @State private var playbackFocusRequestGeneration = 0
    @State private var isPreparingInitialFocus = true
    @State private var visualHighlightedLyricID: LyricLine.ID?
    @State private var lyricFocusColorTransition:
        LyricFocusColorTransition?
    @State private var visualCascadeFocusLyricID: LyricLine.ID?
    @State private var lyricFrameByID: [LyricLine.ID: CGRect] = [:]
    @State private var lyricLayoutHeightByID: [LyricLine.ID: CGFloat] = [:]
    @State private var lyricAnnotationHeightByID: [
        LyricLine.ID: CGFloat
    ] = [:]
    @State private var lyricMovementOffsetByID: [LyricLine.ID: CGFloat] = [:]
    @State private var lyricMovementTransition: LyricMovementTransition?
    @State private var retainedTopCascadeLyrics: [RetainedCascadeLyric] = []
    @State private var playbackFocus: AppleMusicLyricsPlaybackFocus?
    @State private var positionedInterludeID: LyricInterlude.ID?
    @State private var isManuallyScrolling = false
    @State private var interfaceVisibilityTracker =
        LyricsScrollInterfaceVisibilityTracker()
    @State private var hiddenInterfaceProgress: CGFloat
    @State private var lyricSharePresentation: LyricSharePresentation?
    @State private var seekFeedback: LyricSeekFeedback?

    init(
        lyrics: [LyricLine],
        errorMessage: String?,
        highlightedLyricID: LyricLine.ID?,
        isActive: Bool = true,
        isInterfaceHidden: Bool = false,
        bottomOverlayHeight: CGFloat = 0,
        onInterfaceInteraction: (() -> Void)? = nil,
        onInterfaceVisibilityChange: ((Bool) -> Void)? = nil,
        onInitialFocusPrepared: (() -> Void)? = nil
    ) {
        self.lyrics = lyrics
        self.errorMessage = errorMessage
        self.highlightedLyricID = highlightedLyricID
        self.isActive = isActive
        self.isInterfaceHidden = isInterfaceHidden
        self.bottomOverlayHeight = bottomOverlayHeight
        self.onInterfaceInteraction = onInterfaceInteraction
        self.onInterfaceVisibilityChange = onInterfaceVisibilityChange
        self.onInitialFocusPrepared = onInitialFocusPrepared
        lyricIndexByID = Dictionary(
            uniqueKeysWithValues: lyrics.enumerated().map { index, line in
                (line.id, index)
            }
        )
        hasSyllableSyncedLyrics = lyrics.contains {
            $0.isSyllableSynced
        }
        hasTranslations = lyrics.contains { $0.hasTranslation }
        hasRomanizations = lyrics.contains { $0.hasRomanization }
        let interludes = LyricInterludeTimeline.interludes(in: lyrics)
        self.interludes = interludes
        interludeByID = Dictionary(
            uniqueKeysWithValues: interludes.map { ($0.id, $0) }
        )
        let interludeByDisplayLyricID = interludes.reduce(into: [:]) {
            interludeByLyricID,
            interlude in
            interludeByLyricID[interlude.displayBeforeLyricID] = interlude
        }
        displayItems = lyrics.flatMap {
            line -> [AppleMusicLyricsDisplayItem] in
            if let interlude = interludeByDisplayLyricID[line.id] {
                return [.interlude(interlude), .lyric(line)]
            }
            return [.lyric(line)]
        }
        _scrollPositionID = State(initialValue: highlightedLyricID)
        _visualHighlightedLyricID = State(initialValue: highlightedLyricID)
        _visualCascadeFocusLyricID = State(initialValue: highlightedLyricID)
        _playbackFocus = State(
            initialValue: highlightedLyricID.map {
                AppleMusicLyricsPlaybackFocus.lyric($0)
            }
        )
        _hiddenInterfaceProgress = State(
            initialValue: isInterfaceHidden ? 1 : 0
        )
    }

    var body: some View {
        lyricsContent
            .background {
                AppleMusicLyricsFocusCoordinator(
                    lyrics: lyrics,
                    interludes: interludes,
                    playbackFocus: $playbackFocus
                )
            }
            .onChange(of: isInterfaceHidden) { _, isHidden in
                guard isActive else { return }
                withAnimation(
                    NowPlayingInterfaceTransition.interfaceAnimation(
                        isVisible: !isHidden,
                        reducesMotion: accessibilityReduceMotion
                    )
                ) {
                    hiddenInterfaceProgress = isHidden ? 1 : 0
                }
            }
            .onChange(of: isActive) { _, isActive in
                guard isActive else { return }
                synchronizeInterfaceVisibility()
            }
            .sheet(item: $lyricSharePresentation) { presentation in
                SystemShareSheet(
                    activityItems: [
                        lyricShareText(for: presentation),
                    ]
                )
            }
    }

    private func synchronizeInterfaceVisibility() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            hiddenInterfaceProgress = isInterfaceHidden ? 1 : 0
        }
    }

    @ViewBuilder
    private var lyricsContent: some View {
        if lyrics.isEmpty {
            if let errorMessage {
                ContentUnavailableView(
                    "暂无歌词",
                    systemImage: "quote.bubble",
                    description: Text(errorMessage)
                )
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
                .onTapGesture {
                    onInterfaceInteraction?()
                }
            } else {
                ProgressView("正在载入歌词")
                    .tint(.white)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(.rect)
                    .onTapGesture {
                        onInterfaceInteraction?()
                    }
            }
        } else {
            let blurFocusLyricID =
                visualCascadeFocusLyricID
                ?? highlightedLyricID
            let focusNeighborIDs = lyricNeighborIDs(around: blurFocusLyricID)
            let focusEffectAnimation = lyricFocusEffectAnimation(
                for: visualHighlightedLyricID
            )
            let visualScaleFocusLyricID =
                seekFeedback?.previousFocusLyricID
                ?? visualCascadeFocusLyricID
            let usesPseudoTiming = settings.lyricsPseudoWordByWord
                && !hasSyllableSyncedLyrics
            let showsTranslations = settings.lyricsTranslationEnabled
                && hasTranslations
            let showsRomanizations =
                settings.lyricsRomanizationEnabled
                && hasRomanizations
            let showsAnnotations =
                showsRomanizations || showsTranslations
            let retainedTopCascadeLyricIDs = Set(
                retainedTopCascadeLyrics.map(\.id)
            )
            let reservesAnnotationSpace = showsAnnotations
            let lineSpacing = CGFloat(settings.lyricsLineSpacing)
            let activeInterlude = playbackInterlude
            // Once an interlude has expanded, keep its spacing after playback
            // moves on. Collapsing it would shift lyrics on either side.
            let layoutInterludeID =
                activeInterlude?.id
                ?? positionedInterludeID
            let layoutDisplayItems = visibleDisplayItems(
                interludeID: layoutInterludeID
            )
            let romanizationFontSize = max(
                CGFloat(
                    settings.lyricsFontSize
                        * settings.lyricsRomanizationFontScale
                ),
                13
            )
            let romanizationHeight = showsRomanizations
                ? romanizationFontSize * 1.2
                : 0
            let translationHeight = showsTranslations
                ? CGFloat(
                    settings.lyricsFontSize
                        * settings.lyricsTranslationFontScale
                        * 1.2
                )
                : 0
            let annotationHeight =
                romanizationHeight
                + translationHeight
                + (
                    showsRomanizations
                        ? Self.annotationSpacing
                        : 0
                )
                + (
                    showsTranslations
                        ? Self.annotationSpacing
                        : 0
                )
            let lyricStride = max(
                CGFloat(settings.lyricsFontSize) * 1.2
                    + annotationHeight
                    + lineSpacing,
                1
            )
            let blurIntensity = CGFloat(settings.lyricsBlurIntensity)
            let usesUniformBrowsingDimming =
                isBrowsingLyrics
                    && settings
                        .lyricsUsesUniformDimmingWhileBrowsing
            let activeBlurIntensity = usesUniformBrowsingDimming
                ? 0
                : blurIntensity
            let distanceBlurScale = CGFloat(settings.lyricsDistanceBlurScale)
            let hiddenInterfaceBlurScale = CGFloat(
                settings.lyricsHiddenInterfaceBlurScale
            )
            let activeHiddenInterfaceProgress = min(
                max(hiddenInterfaceProgress, 0),
                1
            )
            let dimAmount = settings.lyricsDimAmount
            let distanceDimAmount = usesUniformBrowsingDimming
                ? 0
                : dimAmount
            let currentLineScale = lyricsCurrentLineScale
            let glowOverflow = Self.lyricGlowOverflow(
                isEnabled: settings.lyricsGlowEnabled
                    && (
                        (settings.lyricsWordByWord && hasSyllableSyncedLyrics)
                            || usesPseudoTiming
                    ),
                fontSize: settings.lyricsFontSize,
                intensity: settings.lyricsGlowIntensity
            )
            let horizontalVisualOverflow = max(
                glowOverflow,
                SynchronizedLyricText
                    .interactionBackgroundVisualOverflow
            )

            GeometryReader { proxy in
                let focusPosition = lyricsFocusPosition(
                    for: proxy.size.height
                )
                let focusAnchorY = proxy.size.height * focusPosition
                let visibleViewportHeight = visibleLyricsViewportHeight(
                    for: proxy.size.height
                )
                let maskLocations = lyricsMaskLocations(
                    for: proxy.size.height
                )
                let lyricLayoutWidth = max(proxy.size.width, 1)
                let bottomContentPadding = max(
                    proxy.size.height * (1 - focusPosition),
                    40
                )

                ScrollView {
                    LazyVStack(
                        alignment: .leading,
                        spacing: lineSpacing
                    ) {
                        ForEach(layoutDisplayItems) { item in
                            if case let .interlude(interlude) = item {
                                AppleMusicLyricInterludeView(
                                    interlude: interlude,
                                    advanceTime:
                                        effectiveLyricsAdvanceTime,
                                    fontSize: CGFloat(
                                        settings.lyricsFontSize
                                    ),
                                    onInterfaceInteraction:
                                        onInterfaceInteraction
                                )
                                .id(interlude.id)
                            }

                            if case let .lyric(line) = item {
                            let isPlaybackLine = line.id == visualHighlightedLyricID
                            let isCascadeFocusLine = line.id == visualCascadeFocusLyricID
                            let isVisualScaleFocusLine =
                                line.id == visualScaleFocusLyricID
                            let isActualPlaybackLine = line.id == highlightedLyricID
                            let isPrecedingFocusLine = line.id == focusNeighborIDs.preceding
                            let isFollowingFocusLine = line.id == focusNeighborIDs.following
                            let isRetainedTopCascadeLine =
                                retainedTopCascadeLyricIDs.contains(line.id)
                            let movementPhase = lyricMovementPhase(
                                for: line.id
                            )
                            let focusBlurRadius = Self.lyricFocusBlurRadius(
                                intensity: activeBlurIntensity,
                                isPrecedingFocusLine: isPrecedingFocusLine,
                                isFollowingFocusLine: isFollowingFocusLine
                            )
                            let focusScaleAnimation = lyricFocusScaleAnimation(
                                isFocused: isVisualScaleFocusLine
                            )

                            LifecycleAwareLyricMovement(
                                phase: movementPhase
                            ) { movementOffset in
                                LifecycleAwareLyricFocusColor(
                                    lyricID: line.id,
                                    focusedLyricID:
                                        visualHighlightedLyricID,
                                    transition:
                                        lyricFocusColorTransition
                                ) { focusColorProgress in
                                    LyricPressInteraction(
                                        isSelected:
                                            seekFeedback?.lyricID == line.id
                                            || lyricSharePresentation?.lyric.id
                                                == line.id,
                                        onTap: {
                                            if !isInterfaceHidden {
                                                onInterfaceInteraction?()
                                            }
                                            seek(to: line)
                                        },
                                        onLongPress: {
                                            presentShare(for: line)
                                        }
                                    ) { interactionBackgroundProgress in
                                        SynchronizedLyricText(
                                            line: line,
                                            isPlaybackLine: isPlaybackLine,
                                            playbackFocusProgress:
                                                focusColorProgress,
                                            usesPseudoTiming: usesPseudoTiming,
                                            fontSize: CGFloat(
                                                settings.lyricsFontSize
                                            ),
                                            romanizationFontSize:
                                                romanizationFontSize,
                                            fontWeight:
                                                settings.lyricsFontWeight,
                                            showsTranslation:
                                                showsLyricTranslation(
                                                    isFocusedLine:
                                                        isCascadeFocusLine
                                                ),
                                            showsRomanization:
                                                showsLyricRomanization(
                                                    isFocusedLine:
                                                        isCascadeFocusLine
                                                ),
                                            includesRomanization: true,
                                            reservesAnnotationSpace:
                                                reservesAnnotationSpace,
                                            onAnnotationHeightChange: { height in
                                                recordAnnotationHeight(
                                                    height,
                                                    for: line.id
                                                )
                                            },
                                            annotationLayoutAnimation:
                                                lyricAnnotationLayoutAnimation(),
                                            annotationVisibilityAnimation:
                                                lyricAnnotationVisibilityAnimation(
                                                    focusScaleAnimation:
                                                        focusScaleAnimation
                                                ),
                                            interactionBackgroundOpacity:
                                                0.12
                                                    * interactionBackgroundProgress,
                                            visualScale:
                                                isVisualScaleFocusLine
                                                    ? currentLineScale
                                                    : 1,
                                            visualScaleAnimation:
                                                focusScaleAnimation,
                                            promotedLayoutScale:
                                                currentLineScale,
                                            layoutWidth: lyricLayoutWidth
                                        )
                                    }
                                    .opacity(
                                        isRetainedTopCascadeLine
                                            ? 0
                                            : Self.lyricEmphasis(
                                                focusProgress:
                                                    focusColorProgress,
                                                isBrowsingFocus: false,
                                                dimAmount: dimAmount
                                            )
                                    )
                                    .contentShape(.rect)
                                    .visualEffect { content, geometry in
                                        let frame = geometry.frame(
                                            in: .scrollView(axis: .vertical)
                                        )
                                        let visualMidY =
                                            frame.midY + movementOffset
                                        let distance =
                                            Self.lyricVisualDistance(
                                                visualMidY: visualMidY,
                                                focusAnchorY: focusAnchorY,
                                                expandedBottomProgress:
                                                    activeHiddenInterfaceProgress
                                            )
                                        let activeDistanceBlurScale =
                                            distanceBlurScale
                                            + (
                                                hiddenInterfaceBlurScale
                                                    - distanceBlurScale
                                            ) * activeHiddenInterfaceProgress
                                        let bottomRevealOpacity =
                                            Self.lyricBottomRevealOpacity(
                                                frame: frame,
                                                movementOffset: movementOffset,
                                                viewportHeight:
                                                    proxy.size.height
                                            )
                                        return content
                                            .blur(
                                                radius:
                                                    Self.lyricDistanceBlurRadius(
                                                        forPixelDistance:
                                                            distance,
                                                        lyricStride:
                                                            lyricStride,
                                                        intensity:
                                                            activeBlurIntensity
                                                                * activeDistanceBlurScale,
                                                        focusProgress:
                                                            focusColorProgress
                                                    )
                                            )
                                            .opacity(
                                                Self.lyricOpacity(
                                                    forPixelDistance: distance,
                                                    lyricStride: lyricStride,
                                                    dimAmount:
                                                        distanceDimAmount,
                                                    focusProgress:
                                                        focusColorProgress
                                                ) * bottomRevealOpacity
                                            )
                                            .offset(y: movementOffset)
                                    }
                                    .blur(radius: focusBlurRadius)
                                    .animation(
                                        focusEffectAnimation,
                                        value: focusBlurRadius
                                    )
                                }
                            }
                                .onGeometryChange(
                                    for: LyricGeometryMeasurement.self
                                ) { geometry in
                                    LyricGeometryMeasurement(
                                        frame: geometry.frame(
                                            in: .scrollView(axis: .vertical)
                                        ),
                                        layoutHeight: geometry.size.height
                                    )
                                } action: { measurement in
                                    recordLyricGeometry(
                                        measurement,
                                        for: line.id
                                    )
                                }
                                .id(line.id)
                                .onDisappear {
                                    lyricFrameByID.removeValue(forKey: line.id)
                                    lyricLayoutHeightByID.removeValue(
                                        forKey: line.id
                                    )
                                    lyricAnnotationHeightByID.removeValue(
                                        forKey: line.id
                                    )
                                }
                                .accessibilityLabel(
                                    line.accessibilityText(
                                        includingTranslation:
                                            settings.lyricsTranslationEnabled
                                                && showsLyricTranslation(
                                                    isFocusedLine:
                                                        isActualPlaybackLine
                                                ),
                                        includingRomanization:
                                            settings.lyricsRomanizationEnabled
                                                && showsLyricRomanization(
                                                    isFocusedLine:
                                                        isActualPlaybackLine
                                                )
                                    )
                                )
                                .accessibilityValue(
                                    lyricAccessibilityValue(
                                        isPlaybackLine: isActualPlaybackLine,
                                        isBrowsingFocus: false
                                    )
                                )
                                .accessibilityHint(
                                    lyricInteractionAccessibilityHint
                                )
                                .accessibilityAddTraits(settings.lyricsTapToSeek ? .isButton : [])
                                .accessibilityAction {
                                    seek(to: line)
                                }
                            }
                        }
                    }
                    .animation(
                        accessibilityReduceMotion
                            ? nil
                            : .smooth(
                                duration: Self.interludeExpansionDuration
                            ),
                        value: layoutInterludeID
                    )
                    .scrollTargetLayout()
                    .padding(.top, max(proxy.size.height * focusPosition, 40))
                    .padding(.bottom, bottomContentPadding)
                    .overlay(alignment: .bottom) {
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: bottomContentPadding)
                            .contentShape(.rect)
                            .onTapGesture {
                                onInterfaceInteraction?()
                            }
                            .accessibilityHidden(true)
                    }
                    .overlay(alignment: .top) {
                        hiddenControlsTapTarget(
                            viewportHeight: proxy.size.height
                        )
                    }
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                .scrollPosition(
                    id: $scrollPositionID,
                    anchor: UnitPoint(x: 0.5, y: focusPosition)
                )
                .transaction { transaction in
                    if isPreparingInitialFocus {
                        transaction.animation = nil
                    }
                }
                .overlay(alignment: .topLeading) {
                    retainedTopCascadeLyricsOverlay(
                        viewportSize: proxy.size,
                        lyricLayoutWidth: lyricLayoutWidth,
                        focusPosition: focusPosition,
                        lyricStride: lyricStride,
                        blurIntensity: activeBlurIntensity,
                        distanceBlurScale: distanceBlurScale,
                        hiddenInterfaceBlurScale: hiddenInterfaceBlurScale,
                        dimAmount: dimAmount,
                        distanceDimAmount: distanceDimAmount,
                        currentLineScale: currentLineScale,
                        usesPseudoTiming: usesPseudoTiming,
                        focusEffectAnimation: focusEffectAnimation
                    )
                }
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: maskLocations.topOpaque),
                            .init(color: .black, location: maskLocations.bottomOpaque),
                            .init(color: .clear, location: maskLocations.bottomClear),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(
                        width:
                            proxy.size.width
                            + horizontalVisualOverflow * 2
                    )
                }
                .onScrollGeometryChange(
                    for: CGFloat.self,
                    of: { geometry in
                        let normalizedOffset =
                            geometry.contentOffset.y
                            + geometry.contentInsets.top
                        let maximumOffset = max(
                            geometry.contentSize.height
                                + geometry.contentInsets.top
                                + geometry.contentInsets.bottom
                                - geometry.containerSize.height,
                            0
                        )
                        return min(
                            max(normalizedOffset, 0),
                            maximumOffset
                        )
                    }
                ) { oldOffset, newOffset in
                    handleManualScrollOffsetChange(
                        from: oldOffset,
                        to: newOffset
                    )
                }
                .onScrollPhaseChange { _, newPhase in
                    switch newPhase {
                    case .tracking, .interacting:
                        if let seekFeedback {
                            completeSeekFeedback(seekFeedback)
                        }
                        if !isManuallyScrolling {
                            isManuallyScrolling = true
                            interfaceVisibilityTracker.begin(
                                isInterfaceVisible: !isInterfaceHidden
                            )
                        }
                        browsingGeneration += 1
                        resetMovementOffsets()
                        isBrowsingLyrics = true
                    case .idle:
                        isManuallyScrolling = false
                        interfaceVisibilityTracker.end()
                        schedulePlaybackFollowing()
                    case .decelerating, .animating:
                        break
                    }
                }
                .onChange(of: highlightedLyricID) { _, newValue in
                    guard newValue == nil else { return }
                    startFocusColorTransition(to: nil)
                    visualCascadeFocusLyricID = nil
                    lyricMovementOffsetByID.removeAll()
                    lyricMovementTransition = nil
                    retainedTopCascadeLyrics.removeAll()
                    if playbackInterlude == nil {
                        positionedInterludeID = nil
                    }
                }
                .onChange(of: settings.lyricsTranslationDisplayMode) {
                    _, _ in
                    resetMovementOffsets()
                }
                .onChange(of: settings.lyricsRomanizationDisplayMode) {
                    _, _ in
                    resetMovementOffsets()
                }
                .onChange(of: settings.lyricsTranslationEnabled) { _, _ in
                    resetMovementOffsets()
                }
                .onChange(of: settings.lyricsRomanizationEnabled) { _, _ in
                    resetMovementOffsets()
                }
                .onChange(of: settings.lyricsTranslationFontScale) {
                    _, _ in
                    resetMovementOffsets()
                }
                .onChange(of: settings.lyricsRomanizationFontScale) {
                    _, _ in
                    resetMovementOffsets()
                }
                .onChange(of: settings.lyricsFontSize) { _, _ in
                    resetMovementOffsets()
                }
                .onChange(of: settings.lyricsCurrentLineScale) { _, _ in
                    resetMovementOffsets()
                }
                .onChange(of: player.seekRevision) { _, newRevision in
                    guard seekFeedback?.playerSeekRevision
                            != newRevision else {
                        return
                    }
                    requestPlaybackFocus()
                }
                .onChange(of: player.isPlaying) { wasPlaying, isPlaying in
                    guard !wasPlaying, isPlaying else { return }
                    requestPlaybackFocus()
                }
                .onAppear {
                    synchronizeFocusWithPlayback()
                }
                .task(id: focusMovementTrigger) {
                    let preparesInitialFocus =
                        isPreparingInitialFocus
                    await cascadeMoveFocus(
                        to: requestedFocusLyricID,
                        viewportHeight: proxy.size.height,
                        visibleViewportHeight: visibleViewportHeight,
                        preloadLineCount: Self.bottomPreloadLineCount
                    )
                    guard !Task.isCancelled else { return }
                    isPreparingInitialFocus = false
                    if preparesInitialFocus {
                        onInitialFocusPrepared?()
                    }
                }
                .task(id: seekFeedback) {
                    await holdSeekFeedbackUntilFocusCompletes(
                        viewportHeight: proxy.size.height
                    )
                }
                .task(id: lyricFocusColorTransition?.id) {
                    guard let transition =
                        lyricFocusColorTransition else {
                        return
                    }
                    await finishFocusColorTransition(transition)
                }
                .onDisappear {
                    browsingGeneration += 1
                    isManuallyScrolling = false
                    interfaceVisibilityTracker.end()
                    seekFeedback = nil
                    lyricFrameByID.removeAll()
                    lyricLayoutHeightByID.removeAll()
                    lyricAnnotationHeightByID.removeAll()
                    lyricMovementOffsetByID.removeAll()
                    lyricMovementTransition = nil
                    lyricFocusColorTransition = nil
                    retainedTopCascadeLyrics.removeAll()
                    positionedInterludeID = nil
                }
            }
        }
    }

    @ViewBuilder
    private func hiddenControlsTapTarget(
        viewportHeight: CGFloat
    ) -> some View {
        let tapHeight = min(
            max(bottomOverlayHeight, 0),
            max(viewportHeight, 0)
        )

        if isInterfaceHidden, tapHeight > 0 {
            GeometryReader { geometry in
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: tapHeight)
                    .contentShape(.rect)
                    .offset(
                        y:
                            -geometry.frame(
                                in: .scrollView(axis: .vertical)
                            ).minY
                            + max(viewportHeight - tapHeight, 0)
                    )
                    .onTapGesture {
                        onInterfaceInteraction?()
                    }
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private func retainedTopCascadeLyricsOverlay(
        viewportSize: CGSize,
        lyricLayoutWidth: CGFloat,
        focusPosition: CGFloat,
        lyricStride: CGFloat,
        blurIntensity: CGFloat,
        distanceBlurScale: CGFloat,
        hiddenInterfaceBlurScale: CGFloat,
        dimAmount: Double,
        distanceDimAmount: Double,
        currentLineScale: CGFloat,
        usesPseudoTiming: Bool,
        focusEffectAnimation: Animation?
    ) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(retainedTopCascadeLyrics) { retainedLyric in
                if let lineIndex = lyricIndexByID[retainedLyric.id],
                   lyrics.indices.contains(lineIndex) {
                    let line = lyrics[lineIndex]
                    let isPlaybackLine = line.id == visualHighlightedLyricID
                    let isCascadeFocusLine = line.id == visualCascadeFocusLyricID
                    let visualScaleFocusLyricID =
                        seekFeedback?.previousFocusLyricID
                        ?? visualCascadeFocusLyricID
                    let isVisualScaleFocusLine =
                        line.id == visualScaleFocusLyricID
                    let blurFocusLyricID =
                        visualCascadeFocusLyricID
                        ?? highlightedLyricID
                    let focusNeighborIDs = lyricNeighborIDs(around: blurFocusLyricID)
                    let movementPhase = lyricMovementPhase(for: line.id)
                    let focusBlurRadius = Self.lyricFocusBlurRadius(
                        intensity: blurIntensity,
                        isPrecedingFocusLine: line.id == focusNeighborIDs.preceding,
                        isFollowingFocusLine: line.id == focusNeighborIDs.following
                    )
                    let focusScaleAnimation = lyricFocusScaleAnimation(
                        isFocused: isVisualScaleFocusLine
                    )

                    LifecycleAwareLyricMovement(
                        phase: movementPhase
                    ) { movementOffset in
                        let visualOffset =
                            movementOffset
                            - retainedLyric.movementDistance
                        let visualMidY =
                            retainedLyric.frame.midY + visualOffset
                        let focusAnchorY =
                            viewportSize.height * focusPosition
                        let distance = Self.lyricVisualDistance(
                            visualMidY: visualMidY,
                            focusAnchorY: focusAnchorY,
                            expandedBottomProgress:
                                hiddenInterfaceProgress
                        )
                        let activeDistanceBlurScale =
                            distanceBlurScale
                            + (
                                hiddenInterfaceBlurScale
                                    - distanceBlurScale
                            ) * hiddenInterfaceProgress

                        LifecycleAwareLyricFocusColor(
                            lyricID: line.id,
                            focusedLyricID:
                                visualHighlightedLyricID,
                            transition: lyricFocusColorTransition
                        ) { focusColorProgress in
                            SynchronizedLyricText(
                                line: line,
                                isPlaybackLine: isPlaybackLine,
                                playbackFocusProgress:
                                    focusColorProgress,
                                usesPseudoTiming: usesPseudoTiming,
                                fontSize: CGFloat(
                                    settings.lyricsFontSize
                                ),
                                romanizationFontSize:
                                    lyricRomanizationFontSize,
                                fontWeight: settings.lyricsFontWeight,
                                showsTranslation:
                                    showsLyricTranslation(
                                        isFocusedLine:
                                            isCascadeFocusLine
                                    ),
                                showsRomanization:
                                    showsLyricRomanization(
                                        isFocusedLine:
                                            isCascadeFocusLine
                                    ),
                                includesRomanization: true,
                                reservesAnnotationSpace:
                                    (
                                        settings
                                            .lyricsRomanizationEnabled
                                            && hasRomanizations
                                    ) || (
                                        settings
                                            .lyricsTranslationEnabled
                                            && hasTranslations
                                    ),
                                annotationLayoutAnimation:
                                    lyricAnnotationLayoutAnimation(),
                                annotationVisibilityAnimation:
                                    lyricAnnotationVisibilityAnimation(
                                        focusScaleAnimation:
                                            focusScaleAnimation
                                    ),
                                visualScale:
                                    isVisualScaleFocusLine
                                        ? currentLineScale
                                        : 1,
                                visualScaleAnimation:
                                    focusScaleAnimation,
                                promotedLayoutScale:
                                    currentLineScale,
                                layoutWidth: lyricLayoutWidth
                            )
                            .opacity(
                                Self.lyricEmphasis(
                                    focusProgress:
                                        focusColorProgress,
                                    isBrowsingFocus: false,
                                    dimAmount: dimAmount
                                )
                            )
                            .blur(
                                radius:
                                    Self.lyricDistanceBlurRadius(
                                        forPixelDistance: distance,
                                        lyricStride: lyricStride,
                                        intensity:
                                            blurIntensity
                                                * activeDistanceBlurScale,
                                        focusProgress:
                                            focusColorProgress
                                    )
                            )
                            .opacity(
                                Self.lyricOpacity(
                                    forPixelDistance: distance,
                                    lyricStride: lyricStride,
                                    dimAmount:
                                        distanceDimAmount,
                                    focusProgress:
                                        focusColorProgress
                                )
                            )
                            .blur(radius: focusBlurRadius)
                            .animation(
                                focusEffectAnimation,
                                value: focusBlurRadius
                            )
                            .frame(
                                width: viewportSize.width,
                                alignment: .leading
                            )
                            .offset(
                                y:
                                    retainedLyric.frame.minY
                                    + visualOffset
                            )
                        }
                    }
                    // A retained line can survive into the next cascade with
                    // the same lyric ID. Reset only its movement state when
                    // the transition changes so it cannot replay the prior
                    // transition's final offset for one frame.
                    .id(lyricMovementTransition?.id)
                }
            }
        }
        .frame(
            width: viewportSize.width,
            height: viewportSize.height,
            alignment: .topLeading
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var preferredLyricsFocusPosition: CGFloat {
        CGFloat(
            min(
                max(
                    settings.lyricsFocusPosition,
                    AppSettings.lyricsFocusPositionRange.lowerBound
                ),
                AppSettings.lyricsFocusPositionRange.upperBound
            )
        )
    }

    private var playbackInterlude: LyricInterlude? {
        guard settings.lyricsInterludeCountdownEnabled,
              let interludeID = playbackFocus?.interludeID else {
            return nil
        }
        return interludeByID[interludeID]
    }

    private var focusedInterlude: LyricInterlude? {
        guard seekFeedback == nil else { return nil }
        return playbackInterlude
    }

    private func visibleDisplayItems(
        interludeID: LyricInterlude.ID?
    ) -> [AppleMusicLyricsDisplayItem] {
        displayItems.filter { item in
            guard case let .interlude(interlude) = item else {
                return true
            }
            return interlude.id == interludeID
        }
    }

    private func lyricsFocusPosition(for viewportHeight: CGFloat) -> CGFloat {
        guard viewportHeight > 0 else { return preferredLyricsFocusPosition }
        return preferredLyricsFocusPosition
            * referenceLyricsViewportHeight(for: viewportHeight)
            / viewportHeight
    }

    private func referenceLyricsViewportHeight(
        for viewportHeight: CGFloat
    ) -> CGFloat {
        let overlayHeight = min(
            max(bottomOverlayHeight, 0),
            max(viewportHeight - 1, 0)
        )
        return max(viewportHeight - overlayHeight, 1)
    }

    private func visibleLyricsViewportHeight(
        for viewportHeight: CGFloat
    ) -> CGFloat {
        isInterfaceHidden
            ? viewportHeight
            : referenceLyricsViewportHeight(for: viewportHeight)
    }

    private func lyricsMaskLocations(
        for viewportHeight: CGFloat
    ) -> (
        topOpaque: CGFloat,
        bottomOpaque: CGFloat,
        bottomClear: CGFloat
    ) {
        guard viewportHeight > 0 else { return (0.08, 0.84, 1) }
        let referenceRatio = referenceLyricsViewportHeight(for: viewportHeight)
            / viewportHeight
        let progress = min(max(hiddenInterfaceProgress, 0), 1)
        let collapseStart: CGFloat = 0.68
        let normalizedCollapse = min(
            max(
                (progress - collapseStart)
                    / (1 - collapseStart),
                0
            ),
            1
        )
        let collapseProgress =
            normalizedCollapse
            * normalizedCollapse
            * (3 - 2 * normalizedCollapse)
        let bottomClear =
            referenceRatio
            + (1 - referenceRatio) * collapseProgress
        let shownFadeHeight = 0.16 * referenceRatio
        let hiddenFadeHeight: CGFloat = 0.08
        let fadeHeight =
            shownFadeHeight
            + (hiddenFadeHeight - shownFadeHeight)
                * collapseProgress
        return (
            topOpaque: 0.08 * referenceRatio,
            bottomOpaque: bottomClear - fadeHeight,
            bottomClear: bottomClear
        )
    }

    private var lyricsCurrentLineScale: CGFloat {
        CGFloat(
            min(
                max(
                    settings.lyricsCurrentLineScale,
                    AppSettings.lyricsCurrentLineScaleRange.lowerBound
                ),
                AppSettings.lyricsCurrentLineScaleRange.upperBound
            )
        )
    }

    private func lyricFocusScaleAnimation(
        isFocused: Bool
    ) -> Animation? {
        guard !accessibilityReduceMotion else { return nil }

        let duration = lyricFocusScaleDuration()
        guard isFocused, settings.lyricsFocusScaleBounceEnabled else {
            return .smooth(duration: duration)
        }

        let bounce = min(
            max(
                settings.lyricsFocusScaleBounce,
                AppSettings.lyricsFocusScaleBounceRange.lowerBound
            ),
            AppSettings.lyricsFocusScaleBounceRange.upperBound
        )
        return lyricSpringAnimation(
            duration: duration,
            bounce: bounce
        )
    }

    private func showsLyricTranslation(
        isFocusedLine: Bool
    ) -> Bool {
        switch settings.lyricsTranslationDisplayMode {
        case .focusedLine:
            isFocusedLine
        case .allLines:
            true
        }
    }

    private func showsLyricRomanization(
        isFocusedLine: Bool
    ) -> Bool {
        switch settings.lyricsRomanizationDisplayMode {
        case .focusedLine:
            isFocusedLine
        case .allLines:
            true
        }
    }

    private var lyricRomanizationFontSize: CGFloat {
        max(
            CGFloat(
                settings.lyricsFontSize
                    * settings.lyricsRomanizationFontScale
            ),
            13
        )
    }

    private func recordLyricGeometry(
        _ measurement: LyricGeometryMeasurement,
        for id: LyricLine.ID
    ) {
        let frame = measurement.frame
        let layoutHeight = measurement.layoutHeight
        guard Self.isValidLyricFrame(frame),
              layoutHeight.isFinite,
              layoutHeight > 0 else {
            if lyricFrameByID[id] != nil {
                lyricFrameByID.removeValue(forKey: id)
            }
            if lyricLayoutHeightByID[id] != nil {
                lyricLayoutHeightByID.removeValue(forKey: id)
            }
            return
        }

        let previousFrame = lyricFrameByID[id]
        let previousLayoutHeight = lyricLayoutHeightByID[id]
        let frameChanged = previousFrame == nil
            || !Self.isApproximatelyEqual(
                previousFrame ?? .zero,
                frame
            )
        let layoutHeightChanged = previousLayoutHeight == nil
            || abs((previousLayoutHeight ?? 0) - layoutHeight) > 0.5
        guard frameChanged || layoutHeightChanged else {
            return
        }

        lyricFrameByID[id] = frame
        lyricLayoutHeightByID[id] = layoutHeight
        guard id == visualCascadeFocusLyricID,
              lyricMovementTransition == nil,
              layoutHeightChanged else {
            return
        }
        synchronizeStationaryFollowingOffsets()
    }

    private func recordAnnotationHeight(
        _ height: CGFloat,
        for id: LyricLine.ID
    ) {
        guard height.isFinite, height > 0 else { return }
        let normalizedHeight = max(height, 0)
        let previousHeight = lyricAnnotationHeightByID[id]
        guard previousHeight == nil
                || abs((previousHeight ?? 0) - normalizedHeight) > 0.5 else {
            return
        }

        lyricAnnotationHeightByID[id] = normalizedHeight
        guard id == visualCascadeFocusLyricID,
              lyricMovementTransition == nil else {
            return
        }
        synchronizeStationaryFollowingOffsets()
    }

    private static func isApproximatelyEqual(
        _ lhs: CGRect,
        _ rhs: CGRect
    ) -> Bool {
        let tolerance: CGFloat = 0.5
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private func synchronizeStationaryFollowingOffsets() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            lyricMovementOffsetByID = focusedLineFollowingOffsets(
                for:
                    visualCascadeFocusLyricID
                    ?? playbackFocus?.lyricID
                    ?? highlightedLyricID
            )
        }
    }

    private func focusedLineFollowingOffsets(
        for focusedLyricID: LyricLine.ID?
    ) -> [LyricLine.ID: CGFloat] {
        guard let focusedLyricID,
              let focusedIndex = lyricIndexByID[focusedLyricID],
              focusedIndex + 1 < lyrics.endIndex else {
            return [:]
        }

        let scale = lyricsCurrentLineScale
        let fallbackPrimaryHeight = CGFloat(settings.lyricsFontSize) * 1.2
        var focusedLayoutHeight = lyricLayoutHeightByID[focusedLyricID]
            ?? fallbackPrimaryHeight
        let focusedLine = lyrics[focusedIndex]
        let hasFocusedRomanization =
            settings.lyricsRomanizationEnabled
            && focusedLine.hasRomanization
        let hasFocusedTranslation =
            settings.lyricsTranslationEnabled
            && focusedLine.hasTranslation
        let expandsFocusedRomanization =
            hasFocusedRomanization
            && settings.lyricsRomanizationDisplayMode == .focusedLine
        let expandsFocusedTranslation =
            hasFocusedTranslation
            && settings.lyricsTranslationDisplayMode == .focusedLine
        if expandsFocusedRomanization || expandsFocusedTranslation,
           focusedLyricID != visualCascadeFocusLyricID {
            let fallbackRomanizationHeight = expandsFocusedRomanization
                ? max(
                    CGFloat(
                        settings.lyricsFontSize
                            * settings.lyricsRomanizationFontScale
                    ),
                    13
                ) * 1.2
                : 0
            let fallbackTranslationHeight = expandsFocusedTranslation
                ? max(
                    CGFloat(
                        settings.lyricsFontSize
                            * settings.lyricsTranslationFontScale
                    ),
                    13
                ) * 1.2
                : 0
            focusedLayoutHeight +=
                fallbackRomanizationHeight
                + (
                    expandsFocusedRomanization
                        ? Self.annotationSpacing
                        : 0
                )
                + (
                    expandsFocusedTranslation
                        ? (
                            lyricAnnotationHeightByID[focusedLyricID]
                                ?? fallbackTranslationHeight
                        ) + Self.annotationSpacing
                        : 0
                )
        }
        let scaleOverflow = max(
            focusedLayoutHeight * (scale - 1),
            0
        )

        let followingOffset = scaleOverflow
        guard followingOffset > 0.5 else { return [:] }
        return Dictionary(
            uniqueKeysWithValues:
                lyrics[(focusedIndex + 1)...].map { line in
                    (line.id, followingOffset)
                }
        )
    }

    private func lyricAnnotationVisibilityAnimation(
        focusScaleAnimation: Animation?
    ) -> Animation? {
        guard !accessibilityReduceMotion else { return nil }
        if usesFocusedLineAnnotationMode {
            return focusScaleAnimation
        }
        let duration = min(
            max(settings.lyricsFocusCascadeDuration * 0.7, 0.16),
            0.32
        )
        return .smooth(duration: duration)
    }

    private func lyricAnnotationLayoutAnimation() -> Animation? {
        guard !accessibilityReduceMotion else { return nil }
        let duration: TimeInterval
        if usesFocusedLineAnnotationMode {
            duration = lyricFocusScaleDuration()
        } else {
            duration = min(
                max(settings.lyricsFocusCascadeDuration * 0.7, 0.16),
                0.32
            )
        }
        return .smooth(duration: duration)
    }

    private var usesFocusedLineAnnotationMode: Bool {
        (
            settings.lyricsRomanizationEnabled
                && settings.lyricsRomanizationDisplayMode
                    == .focusedLine
        ) || (
            settings.lyricsTranslationEnabled
                && settings.lyricsTranslationDisplayMode
                    == .focusedLine
        )
    }

    private func lyricFocusScaleDuration() -> TimeInterval {
        if settings.lyricsFocusScaleBounceEnabled {
            return min(
                max(
                    settings.lyricsFocusScaleBounceDuration,
                    AppSettings.lyricsFocusScaleBounceDurationRange.lowerBound
                ),
                AppSettings.lyricsFocusScaleBounceDurationRange.upperBound
            )
        }
        return min(
            max(
                LyricPlaybackTimeline.focusAnimationDuration(
                    for: highlightedLyricID,
                    in: lyrics
                ),
                0.28
            ),
            0.42
        )
    }

    private func lyricSpringAnimation(
        duration: TimeInterval,
        bounce: Double
    ) -> Animation {
        .spring(
            duration: duration,
            bounce: bounce,
            blendDuration: min(max(duration * 0.22, 0.06), 0.14)
        )
    }

    private var focusMovementTrigger: LyricFocusMovementTrigger {
        LyricFocusMovementTrigger(
            highlightedLyricID: requestedFocusLyricID,
            interludeID: focusedInterlude?.id,
            isBrowsingLyrics: isBrowsingLyrics,
            playbackFocusRequestGeneration: playbackFocusRequestGeneration
        )
    }

    private var requestedFocusLyricID: LyricLine.ID? {
        seekFeedback?.lyricID
            ?? playbackFocus?.lyricID
            ?? highlightedLyricID
    }

    private func lyricFocusEffectAnimation(
        for highlightedLyricID: LyricLine.ID?
    ) -> Animation? {
        guard !accessibilityReduceMotion else { return nil }
        let movementDuration = LyricPlaybackTimeline.focusAnimationDuration(
            for: highlightedLyricID,
            in: lyrics
        )
        return .easeInOut(duration: max(movementDuration, 0.2))
    }

    private var lyricsFocusColorLeadTime: TimeInterval {
        min(
            max(
                settings.lyricsFocusColorLeadTime,
                AppSettings.lyricsFocusColorLeadTimeRange.lowerBound
            ),
            AppSettings.lyricsFocusColorLeadTimeRange.upperBound
        )
    }

    private var effectiveLyricsAdvanceTime: TimeInterval {
        settings.effectiveLyricsAdvanceTime(
            hasSyllableSyncedLyrics: hasSyllableSyncedLyrics
        )
    }

    private func remainingFocusDuration(
        for highlightedLyricID: LyricLine.ID
    ) -> TimeInterval? {
        guard player.isPlaying else { return nil }
        return LyricPlaybackTimeline.remainingFocusDuration(
            for: highlightedLyricID,
            at: player.estimatedProgress()
                + effectiveLyricsAdvanceTime,
            in: lyrics
        )
    }

    private func waitForLyricFrame(
        for id: LyricLine.ID
    ) async -> CGRect? {
        for attempt in 0..<30 {
            if let frame = lyricFrameByID[id] {
                return frame
            }
            guard !Task.isCancelled, attempt < 29 else { return nil }
            do {
                try await Task.sleep(for: .milliseconds(16))
            } catch {
                return nil
            }
        }
        return nil
    }

    private func waitForPreparedFocus(
        id: LyricLine.ID,
        viewportAnchorY: CGFloat,
        focusPosition: CGFloat
    ) async -> Bool {
        for attempt in 0..<30 {
            if let frame = lyricFrameByID[id] {
                let preparedAnchorY = frame.minY
                    + frame.height * focusPosition
                if abs(preparedAnchorY - viewportAnchorY) <= 2 {
                    return true
                }
            }
            guard !Task.isCancelled, attempt < 29 else { return false }
            do {
                try await Task.sleep(for: .milliseconds(16))
            } catch {
                return false
            }
        }
        return false
    }

    private func cascadeMoveFocus(
        to highlightedLyricID: LyricLine.ID?,
        viewportHeight: CGFloat,
        visibleViewportHeight: CGFloat,
        preloadLineCount: Int
    ) async {
        guard !isBrowsingLyrics else {
            resetMovementOffsets()
            startFocusColorTransition(to: highlightedLyricID)
            visualCascadeFocusLyricID = highlightedLyricID
            return
        }

        if let interlude = focusedInterlude {
            moveFocusToInterlude(
                interlude,
                animated: !isPreparingInitialFocus
            )
            return
        }

        guard let highlightedLyricID else {
            resetMovementOffsets()
            guard let firstLyricID = lyrics.first?.id else { return }
            await ensureFocusAlignment(
                to: firstLyricID,
                viewportHeight: viewportHeight,
                animated: false
            )
            return
        }
        let isInterludeHandoff = positionedInterludeID.flatMap {
            interludeByID[$0]
        }?.followingLyricID == highlightedLyricID
        let movementFocusLyricID = lyricMovementTransition?.focusID
            ?? visualCascadeFocusLyricID
            ?? scrollPositionID
        guard movementFocusLyricID != highlightedLyricID else {
            startFocusColorTransition(to: highlightedLyricID)
            visualCascadeFocusLyricID = highlightedLyricID
            await ensureFocusAlignment(
                to: highlightedLyricID,
                viewportHeight: viewportHeight,
                animated: !isPreparingInitialFocus
            )
            return
        }
        guard !isReverseFocusTransition(
            from: movementFocusLyricID,
            to: highlightedLyricID
        ) else {
            await moveFocusWithoutCascade(
                to: highlightedLyricID,
                viewportHeight: viewportHeight
            )
            return
        }
        let isManualSeekTransition =
            seekFeedback?.lyricID == highlightedLyricID
        guard isManualSeekTransition
                || isInterludeHandoff
                || isAdjacentFocusTransition(
                    from: movementFocusLyricID,
                    to: highlightedLyricID
                ) else {
            await moveFocusWithoutCascade(
                to: highlightedLyricID,
                viewportHeight: viewportHeight
            )
            return
        }

        guard !accessibilityReduceMotion,
              settings.lyricsFocusCascadeDelay > 0
                || settings.lyricsFocusCascadeDelayIncrease > 0 else {
            await moveFocusWithoutCascade(
                to: highlightedLyricID,
                viewportHeight: viewportHeight
            )
            return
        }
        let remainingDurationAtTransition = remainingFocusDuration(
            for: highlightedLyricID
        )
        guard let nextFocusFrame = await waitForLyricFrame(
            for: highlightedLyricID
        ) else {
            guard !Task.isCancelled else { return }
            await moveFocusWithoutCascade(
                to: highlightedLyricID,
                viewportHeight: viewportHeight
            )
            return
        }

        let focusPosition = lyricsFocusPosition(for: viewportHeight)
        let viewportAnchorY = viewportHeight * focusPosition
        let nextFocusAnchorY = nextFocusFrame.minY
            + nextFocusFrame.height * focusPosition
        let movementDistance = nextFocusAnchorY - viewportAnchorY
        guard abs(movementDistance) > 0.5 else {
            completeCascadeMovement(to: highlightedLyricID)
            return
        }

        var carriedMovementOffsets = lyricMovementOffsetByID
        var carriedMovementVelocities: [LyricLine.ID: CGFloat] = [:]
        if let presentationStates = lyricMovementTransition?
            .presentationStates(at: .now) {
            carriedMovementOffsets.merge(
                presentationStates.mapValues(\.offset),
                uniquingKeysWith: { _, presentationState in
                    presentationState
                }
            )
            carriedMovementVelocities = presentationStates.mapValues(
                \.velocity
            )
        }
        let initialVisibleIDs = lyricFrameByID
            .filter { entry in
                let frame = entry.value
                let carriedOffset = carriedMovementOffsets[
                    entry.key,
                    default: 0
                ]
                return Self.isLyricFrameVisible(
                    frame,
                    movementOffset: carriedOffset,
                    viewportHeight: visibleViewportHeight
                )
            }
            .sorted { left, right in
                let leftMinY = left.value.minY
                    + carriedMovementOffsets[left.key, default: 0]
                let rightMinY = right.value.minY
                    + carriedMovementOffsets[right.key, default: 0]
                return leftMinY < rightMinY
            }
            .map(\.key)
        let baseAnimationDuration = LyricPlaybackTimeline.focusAnimationDuration(
            for: highlightedLyricID,
            in: lyrics
        )
        let cascadeAnimationDuration = LyricPlaybackTimeline.focusCascadeAnimationDuration(
            baseDuration: baseAnimationDuration,
            preferredDuration: settings.lyricsFocusCascadeDuration
        )
        let prefersCascadeBounce = settings.lyricsFocusCascadeBounceEnabled
        let focusColorLeadTime = lyricsFocusColorLeadTime
        let destinationOffsets = focusedLineFollowingOffsets(
            for: highlightedLyricID
        )
        let retainedTopLyrics: [RetainedCascadeLyric] = initialVisibleIDs.compactMap { id in
            guard movementDistance > 0,
                  let frame = lyricFrameByID[id] else {
                return nil
            }
            let destinationMaxY =
                frame.maxY
                - movementDistance
                + destinationOffsets[id, default: 0]
            // Keep partially visible destination rows in LazyVStack. Hiding
            // one behind a retained copy makes the copy-to-row handoff look
            // like a spacing snap when the focused lyric spans multiple lines.
            guard destinationMaxY <= 0 else { return nil }
            return RetainedCascadeLyric(
                id: id,
                frame: frame,
                movementDistance: movementDistance
            )
        }
        let preparedMovementOffsets = Dictionary(
            uniqueKeysWithValues: lyrics.map { line in
                (
                    line.id,
                    movementDistance
                        + carriedMovementOffsets[line.id, default: 0]
                )
            }
        )
        let preparedMovementTransition = LyricMovementTransition(
            focusID: highlightedLyricID,
            initialOffsetsByID: preparedMovementOffsets,
            destinationOffsetsByID: destinationOffsets
        )

        var preparationTransaction = Transaction(animation: nil)
        preparationTransaction.disablesAnimations = true
        withTransaction(preparationTransaction) {
            retainedTopCascadeLyrics = retainedTopLyrics
            lyricMovementOffsetByID = preparedMovementOffsets
            lyricMovementTransition = preparedMovementTransition
            scrollPositionID = highlightedLyricID
        }

        let destinationIsPrepared = await waitForPreparedFocus(
            id: highlightedLyricID,
            viewportAnchorY: viewportAnchorY,
            focusPosition: focusPosition
        )
        guard !Task.isCancelled else { return }
        guard destinationIsPrepared else {
            completeCascadeMovement(to: highlightedLyricID)
            await ensureFocusAlignment(
                to: highlightedLyricID,
                viewportHeight: viewportHeight,
                animated: false
            )
            return
        }

        let destinationVisibleIDs = lyricFrameByID
            .filter { entry in
                Self.isLyricFrameVisible(
                    entry.value,
                    viewportHeight: visibleViewportHeight
                )
            }
            .sorted { left, right in
                left.value.minY < right.value.minY
            }
            .map(\.key)
        guard let highlightedIndex = lyricIndexByID[highlightedLyricID] else {
            completeCascadeMovement(to: highlightedLyricID)
            return
        }
        var movingIDSet = Set(initialVisibleIDs)
        movingIDSet.formUnion(destinationVisibleIDs)
        let guaranteedFutureEndIndex = min(
            highlightedIndex + Self.futureCascadeSafetyLineCount + 1,
            lyrics.endIndex
        )
        for index in highlightedIndex..<guaranteedFutureEndIndex {
            movingIDSet.insert(lyrics[index].id)
        }
        if preloadLineCount > 0,
           let bottomVisibleIndex = destinationVisibleIDs
            .compactMap({ lyricIndexByID[$0] })
            .max() {
            let preloadStartIndex = bottomVisibleIndex + 1
            let preloadEndIndex = min(
                preloadStartIndex + preloadLineCount,
                lyrics.endIndex
            )
            if preloadStartIndex < preloadEndIndex {
                for index in preloadStartIndex..<preloadEndIndex {
                    movingIDSet.insert(lyrics[index].id)
                }
            }
        }
        let movingIndexes = movingIDSet.compactMap { lyricIndexByID[$0] }
        guard let firstMovingIndex = movingIndexes.min(),
              let lastMovingIndex = movingIndexes.max() else {
            completeCascadeMovement(to: highlightedLyricID)
            return
        }
        let orderedMovingIDs = lyrics[firstMovingIndex...lastMovingIndex]
            .map(\.id)
        guard orderedMovingIDs.count > 1 else {
            completeCascadeMovement(to: highlightedLyricID)
            return
        }
        let movementOrderByID = Dictionary(
            uniqueKeysWithValues: orderedMovingIDs.map { id in
                let lineIndex = lyricIndexByID[id] ?? highlightedIndex
                let lineOrder = max(
                    lineIndex - highlightedIndex,
                    0
                )
                return (id, lineOrder)
            }
        )
        // Keep the focus line's start delay unchanged, while grading its
        // catch-up speed and bounce from the preceding line downward.
        let firstChasingIndex = max(
            highlightedIndex - 1,
            lyrics.startIndex
        )
        let chaseOrderByID: [LyricLine.ID: Int] = Dictionary(
            uniqueKeysWithValues: orderedMovingIDs.compactMap { id in
                guard let lineIndex = lyricIndexByID[id],
                      lineIndex >= firstChasingIndex else {
                    return nil
                }
                return (id, lineIndex - firstChasingIndex)
            }
        )
        let maximumChaseOrder = chaseOrderByID.values.max() ?? 0
        guard let cascadeTiming = LyricPlaybackTimeline.focusCascadeTiming(
            maximumLineOrder: maximumChaseOrder,
            preferredDelayPerLine:
                settings.lyricsFocusCascadeDelay,
            preferredDelayIncreasePerLine:
                settings.lyricsFocusCascadeDelayIncrease,
            followingLineBaseDelay:
                settings.lyricsFocusCascadeFollowingDelay,
            preferredCatchUpCompletionRatio:
                settings.lyricsFocusCascadeCatchUpRatio,
            focusColorLeadTime: focusColorLeadTime,
            baseAnimationDuration: baseAnimationDuration,
            preferredAnimationDuration: cascadeAnimationDuration,
            prefersBounce: prefersCascadeBounce,
            snapThreshold: settings.lyricsFocusSnapThreshold,
            remainingDuration: remainingDurationAtTransition
        ) else {
            completeCascadeMovement(to: highlightedLyricID)
            return
        }
        await animatePreparedCascade(
            orderedMovingIDs,
            to: highlightedLyricID,
            movementOrderByID: movementOrderByID,
            chaseOrderByID: chaseOrderByID,
            maximumChaseOrder: maximumChaseOrder,
            cascadeTiming: cascadeTiming,
            focusColorLeadTime: focusColorLeadTime,
            carriedVelocityByID: carriedMovementVelocities,
            transition: preparedMovementTransition
        )
    }

    private func animatePreparedCascade(
        _ orderedMovingIDs: [LyricLine.ID],
        to highlightedLyricID: LyricLine.ID,
        movementOrderByID: [LyricLine.ID: Int],
        chaseOrderByID: [LyricLine.ID: Int],
        maximumChaseOrder: Int,
        cascadeTiming: LyricFocusCascadeTiming,
        focusColorLeadTime: TimeInterval,
        carriedVelocityByID: [LyricLine.ID: CGFloat],
        transition: LyricMovementTransition
    ) async {
        let usesBounce = cascadeTiming.usesBounce
        let chaseSpeedGradient = min(
            max(
                settings.lyricsFocusCascadeChaseSpeedGradient,
                AppSettings.lyricsFocusCascadeChaseSpeedGradientRange.lowerBound
            ),
            AppSettings.lyricsFocusCascadeChaseSpeedGradientRange.upperBound
        )
        let slowestChaseDuration = cascadeTiming.lineTiming(
            for: 0
        ).duration
        let movementAnimations = Dictionary(
            uniqueKeysWithValues: orderedMovingIDs.map { id in
                let movementOrder = movementOrderByID[id, default: 0]
                let chaseOrder = chaseOrderByID[id]
                let movementTiming = cascadeTiming.lineTiming(
                    for: movementOrder
                )
                let chaseTiming = cascadeTiming.lineTiming(
                    for: chaseOrder ?? 0
                )
                let chaseDuration = slowestChaseDuration
                    + (
                        chaseTiming.duration
                            - slowestChaseDuration
                    ) * chaseSpeedGradient
                let destinationOffset = transition
                    .destinationOffsetsByID[id, default: 0]
                let initialOffset = transition.initialOffsetsByID[
                    id,
                    default: destinationOffset
                ]
                let movementDistance =
                    destinationOffset - initialOffset
                let carriedVelocity = carriedVelocityByID[id, default: 0]
                let rawInitialVelocity = abs(movementDistance) > 0.5
                    ? Double(carriedVelocity / movementDistance)
                    : 0
                let initialVelocity = rawInitialVelocity.isFinite
                    ? min(max(rawInitialVelocity, -12), 12)
                    : 0
                return (
                    id,
                    LyricMovementAnimationConfiguration(
                        delay: movementTiming.delay,
                        duration: chaseDuration,
                        usesBounce: usesBounce,
                        bounce: lyricFocusCascadeBounce(
                            chaseOrder: chaseOrder,
                            maximumChaseOrder: maximumChaseOrder
                        ),
                        initialVelocity: initialVelocity
                    )
                )
            }
        )
        guard !Task.isCancelled,
              lyricMovementTransition?.id == transition.id else { return }

        if focusColorLeadTime >= 0 {
            startFocusColorTransition(to: highlightedLyricID)
        }
        if focusColorLeadTime > 0 {
            do {
                try await Task.sleep(for: .seconds(focusColorLeadTime))
            } catch {
                return
            }
        }
        guard !Task.isCancelled,
              let preparedTransition = lyricMovementTransition,
              preparedTransition.id == transition.id else { return }

        let startedTransition = preparedTransition.starting(
            with: movementAnimations,
            at: .now
        )
        var movementTransaction = Transaction(animation: nil)
        movementTransaction.disablesAnimations = true
        withTransaction(movementTransaction) {
            lyricMovementTransition = startedTransition
            lyricMovementOffsetByID =
                preparedTransition.destinationOffsetsByID
        }
        visualCascadeFocusLyricID = highlightedLyricID

        let focusColorDelayAfterMovement = max(-focusColorLeadTime, 0)
        if focusColorDelayAfterMovement > 0 {
            do {
                try await Task.sleep(
                    for: .seconds(focusColorDelayAfterMovement)
                )
            } catch {
                return
            }
            guard !Task.isCancelled,
                  lyricMovementTransition?.id == transition.id else { return }
            startFocusColorTransition(to: highlightedLyricID)
        }

        let elapsedSinceMovementStart = startedTransition.startedAt.map {
            Date.now.timeIntervalSince($0)
        } ?? 0
        let remainingMovementDuration = max(
            startedTransition.completionDuration
                - elapsedSinceMovementStart,
            0
        ) + Self.cascadeSettlementGraceDuration
        if remainingMovementDuration > 0 {
            do {
                try await Task.sleep(
                    for: .seconds(remainingMovementDuration)
                )
            } catch {
                return
            }
        }
        guard !Task.isCancelled,
              lyricMovementTransition?.id == transition.id else { return }
        completeCascadeMovement(to: highlightedLyricID)
    }

    private func lyricFocusCascadeBounce(
        chaseOrder: Int?,
        maximumChaseOrder: Int
    ) -> Double {
        let maximumBounce = min(
            max(
                settings.lyricsFocusCascadeBounce,
                AppSettings.lyricsFocusCascadeBounceRange.lowerBound
            ),
            AppSettings.lyricsFocusCascadeBounceRange.upperBound
        )
        guard maximumBounce > 0, let chaseOrder else { return 0 }

        let bounceGradient = min(
            max(
                settings.lyricsFocusCascadeBounceGradient,
                AppSettings.lyricsFocusCascadeBounceGradientRange.lowerBound
            ),
            AppSettings.lyricsFocusCascadeBounceGradientRange.upperBound
        )
        let bouncingLineCount = max(maximumChaseOrder + 1, 1)
        let linePosition = min(
            max(chaseOrder, 0),
            maximumChaseOrder
        ) + 1
        let normalizedPosition =
            Double(linePosition) / Double(bouncingLineCount)
        let bounceScale =
            1 - (1 - normalizedPosition) * bounceGradient
        return maximumBounce * bounceScale
    }

    private func lyricMovementPhase(
        for id: LyricLine.ID
    ) -> LyricMovementPhase {
        let fallbackOffset = lyricMovementOffsetByID[id, default: 0]
        guard !accessibilityReduceMotion,
              let lyricMovementTransition else {
            return .stationary(offset: fallbackOffset)
        }
        return lyricMovementTransition.phase(
            for: id,
            fallbackOffset: fallbackOffset
        )
    }

    private func startFocusColorTransition(
        to highlightedLyricID: LyricLine.ID?
    ) {
        guard visualHighlightedLyricID != highlightedLyricID else {
            return
        }
        let now = Date.now
        let initialProgressByID: [LyricLine.ID: CGFloat]
        if let lyricFocusColorTransition {
            initialProgressByID =
                lyricFocusColorTransition
                    .presentationProgressByID(at: now)
        } else if let visualHighlightedLyricID {
            initialProgressByID = [visualHighlightedLyricID: 1]
        } else {
            initialProgressByID = [:]
        }
        let transition = LyricFocusColorTransition(
            initialProgressByID: initialProgressByID,
            destinationLyricID: highlightedLyricID,
            startedAt: now,
            duration: Self.focusColorTransitionDuration
        )

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            visualHighlightedLyricID = highlightedLyricID
            lyricFocusColorTransition = transition
        }
    }

    private func finishFocusColorTransition(
        _ transition: LyricFocusColorTransition
    ) async {
        let remainingDuration =
            transition.completionDate.timeIntervalSince(.now)
        if remainingDuration > 0 {
            do {
                try await Task.sleep(
                    for: .seconds(remainingDuration)
                )
            } catch {
                return
            }
        }
        guard !Task.isCancelled,
              lyricFocusColorTransition?.id == transition.id else {
            return
        }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            lyricFocusColorTransition = nil
        }
    }

    private func isAdjacentFocusTransition(
        from currentID: LyricLine.ID?,
        to nextID: LyricLine.ID
    ) -> Bool {
        guard let currentID,
              let currentIndex = lyricIndexByID[currentID],
              let nextIndex = lyricIndexByID[nextID] else {
            return false
        }
        return abs(nextIndex - currentIndex) == 1
    }

    private func isReverseFocusTransition(
        from currentID: LyricLine.ID?,
        to nextID: LyricLine.ID
    ) -> Bool {
        guard let currentID,
              let currentIndex = lyricIndexByID[currentID],
              let nextIndex = lyricIndexByID[nextID] else {
            return false
        }
        return nextIndex < currentIndex
    }

    private func moveFocusWithoutCascade(
        to id: LyricLine.ID,
        viewportHeight: CGFloat
    ) async {
        resetMovementOffsets()
        await ensureFocusAlignment(
            to: id,
            viewportHeight: viewportHeight,
            animated: true
        )
        await Task.yield()
        guard !Task.isCancelled else { return }
        let destinationOffsets = focusedLineFollowingOffsets(for: id)
        startFocusColorTransition(to: id)
        withAnimation(
            accessibilityReduceMotion
                ? nil
                : .easeInOut(
                    duration: LyricPlaybackTimeline.focusAnimationDuration(
                        for: id,
                        in: lyrics
                    )
                )
        ) {
            visualCascadeFocusLyricID = id
            lyricMovementOffsetByID = destinationOffsets
        }
        completeSeekFeedbackIfNeeded(for: id)
    }

    private func moveFocusToInterlude(
        _ interlude: LyricInterlude,
        animated: Bool
    ) {
        let update = {
            scrollPositionID = interlude.id
            visualCascadeFocusLyricID = nil
            lyricMovementOffsetByID.removeAll()
            lyricMovementTransition = nil
            retainedTopCascadeLyrics.removeAll()
            positionedInterludeID = interlude.id
        }

        guard animated,
              !accessibilityReduceMotion,
              scrollPositionID != interlude.id else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction, update)
            startFocusColorTransition(to: nil)
            return
        }

        withAnimation(.smooth(duration: 0.3), update)
        startFocusColorTransition(to: nil)
    }

    private func completeCascadeMovement(to id: LyricLine.ID) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrollPositionID = id
            visualCascadeFocusLyricID = id
            lyricMovementOffsetByID = focusedLineFollowingOffsets(for: id)
            lyricMovementTransition = nil
            retainedTopCascadeLyrics.removeAll()
        }
        startFocusColorTransition(to: id)
        completeSeekFeedbackIfNeeded(for: id)
    }

    private func resetMovementOffsets() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            lyricMovementOffsetByID = focusedLineFollowingOffsets(
                for:
                    visualCascadeFocusLyricID
                    ?? playbackFocus?.lyricID
                    ?? highlightedLyricID
            )
            lyricMovementTransition = nil
            retainedTopCascadeLyrics.removeAll()
        }
    }

    private func lyricNeighborIDs(
        around focusedLyricID: LyricLine.ID?
    ) -> (
        preceding: LyricLine.ID?,
        following: LyricLine.ID?
    ) {
        guard let focusedLyricID,
              let focusIndex = lyricIndexByID[focusedLyricID] else {
            return (nil, nil)
        }

        let precedingID = focusIndex > lyrics.startIndex
            ? lyrics[lyrics.index(before: focusIndex)].id
            : nil
        let followingIndex = lyrics.index(after: focusIndex)
        let followingID = followingIndex < lyrics.endIndex
            ? lyrics[followingIndex].id
            : nil
        return (precedingID, followingID)
    }

    private func lyricAccessibilityValue(
        isPlaybackLine: Bool,
        isBrowsingFocus: Bool
    ) -> String {
        switch (isPlaybackLine, isBrowsingFocus) {
        case (true, true): "当前播放，浏览焦点"
        case (true, false): "当前播放"
        case (false, true): "浏览焦点"
        case (false, false): ""
        }
    }

    nonisolated private static func lyricDistanceBlurRadius(
        forPixelDistance distance: CGFloat,
        lyricStride: CGFloat,
        intensity: CGFloat,
        focusProgress: CGFloat
    ) -> CGFloat {
        let lineDistance = distance / lyricStride
        let blurProgress = max(lineDistance - 1.35, 0)
        let baseRadius = min(blurProgress * 3.1, 10)
        let normalizedFocusProgress = min(
            max(focusProgress, 0),
            1
        )
        return baseRadius
            * intensity
            * (1 - normalizedFocusProgress)
    }

    nonisolated private static func isValidLyricFrame(
        _ frame: CGRect
    ) -> Bool {
        !frame.isNull
            && !frame.isInfinite
            && !frame.isEmpty
            && frame.minY.isFinite
            && frame.maxY.isFinite
    }

    nonisolated private static func isLyricFrameVisible(
        _ frame: CGRect,
        movementOffset: CGFloat = 0,
        viewportHeight: CGFloat
    ) -> Bool {
        guard isValidLyricFrame(frame),
              movementOffset.isFinite,
              viewportHeight.isFinite,
              viewportHeight > 0 else {
            return false
        }

        return frame.maxY + movementOffset > 0
            && frame.minY + movementOffset < viewportHeight
    }

    nonisolated private static func lyricVisualDistance(
        visualMidY: CGFloat,
        focusAnchorY: CGFloat,
        expandedBottomProgress: CGFloat
    ) -> CGFloat {
        let signedDistance = visualMidY - focusAnchorY
        guard signedDistance > 0 else {
            return abs(signedDistance)
        }
        let progress = min(max(expandedBottomProgress, 0), 1)
        let distanceScale =
            1
            + (expandedBottomDistanceScale - 1) * progress
        return signedDistance * distanceScale
    }

    nonisolated private static func lyricFocusBlurRadius(
        intensity: CGFloat,
        isPrecedingFocusLine: Bool,
        isFollowingFocusLine: Bool
    ) -> CGFloat {
        let precedingLineRadius: CGFloat = isPrecedingFocusLine ? 2.4 : 0
        let followingLineRadius: CGFloat = isFollowingFocusLine ? 0.7 : 0
        return (precedingLineRadius + followingLineRadius) * intensity
    }

    nonisolated private static func lyricOpacity(
        forPixelDistance distance: CGFloat,
        lyricStride: CGFloat,
        dimAmount: Double,
        focusProgress: CGFloat
    ) -> Double {
        let lineDistance = Double(distance / lyricStride)
        let baseOpacity: Double
        switch lineDistance {
        case ...1:
            baseOpacity = 1 - lineDistance * 0.44
        case ...2:
            baseOpacity = 0.56 - (lineDistance - 1) * 0.22
        default:
            baseOpacity = max(0.12, 0.34 - (lineDistance - 2) * 0.07)
        }
        let distanceOpacity =
            1 - (1 - baseOpacity) * dimAmount
        let normalizedFocusProgress = Double(
            min(max(focusProgress, 0), 1)
        )
        return distanceOpacity
            + (1 - distanceOpacity) * normalizedFocusProgress
    }

    nonisolated private static func lyricBottomRevealOpacity(
        frame: CGRect,
        movementOffset: CGFloat,
        viewportHeight: CGFloat
    ) -> Double {
        let visualMinY = frame.minY + movementOffset
        let revealDistance = min(max(frame.height * 0.8, 32), 72)
        let progress = (viewportHeight - visualMinY) / revealDistance
        return Double(min(max(progress, 0), 1))
    }

    nonisolated private static func lyricEmphasis(
        focusProgress: CGFloat,
        isBrowsingFocus: Bool,
        dimAmount: Double
    ) -> Double {
        let baseOpacity = isBrowsingFocus ? 0.7 : 0.52
        let unfocusedOpacity =
            1 - (1 - baseOpacity) * dimAmount
        let normalizedFocusProgress = Double(
            min(max(focusProgress, 0), 1)
        )
        return unfocusedOpacity
            + (1 - unfocusedOpacity) * normalizedFocusProgress
    }

    nonisolated private static func lyricGlowOverflow(
        isEnabled: Bool,
        fontSize: Double,
        intensity: Double
    ) -> CGFloat {
        guard isEnabled else { return 0 }
        return CGFloat(min(max(fontSize * intensity * 0.75, 16), 32))
    }

    private func schedulePlaybackFollowing() {
        guard isBrowsingLyrics, settings.lyricsAutoFollow else { return }
        let generation = browsingGeneration
        let delay = settings.lyricsFollowDelay

        Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard generation == browsingGeneration else { return }
            isBrowsingLyrics = false
        }
    }

    private func handleManualScrollOffsetChange(
        from oldOffset: CGFloat,
        to newOffset: CGFloat
    ) {
        guard isManuallyScrolling,
              let showsInterface = interfaceVisibilityTracker.update(
                offsetDelta: newOffset - oldOffset,
                hideThreshold: CGFloat(
                    settings.appleMusicLyricsScrollHideThreshold
                )
              ) else {
            return
        }

        onInterfaceVisibilityChange?(showsInterface)
    }

    private func requestPlaybackFocus() {
        browsingGeneration += 1
        isBrowsingLyrics = false
        playbackFocusRequestGeneration += 1
    }

    private func synchronizeFocusWithPlayback() {
        let interlude = focusedInterlude
        let playbackLyricID =
            playbackFocus?.lyricID
            ?? highlightedLyricID
        guard let focusID =
            interlude?.id
                ?? playbackLyricID
                ?? lyrics.first?.id else {
            return
        }
        let visualFocusID = interlude == nil
            ? playbackLyricID
            : nil
        guard scrollPositionID != focusID
                || visualHighlightedLyricID != visualFocusID
                || visualCascadeFocusLyricID != visualFocusID
                || isBrowsingLyrics else {
            return
        }

        browsingGeneration += 1
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isBrowsingLyrics = false
            scrollPositionID = focusID
            visualHighlightedLyricID = visualFocusID
            lyricFocusColorTransition = nil
            visualCascadeFocusLyricID = visualFocusID
            lyricMovementOffsetByID = interlude == nil
                ? focusedLineFollowingOffsets(
                    for: playbackLyricID
                )
                : [:]
            lyricMovementTransition = nil
            retainedTopCascadeLyrics.removeAll()
            positionedInterludeID = interlude?.id
        }
    }

    private func seek(to line: LyricLine) {
        guard settings.lyricsTapToSeek else { return }
        seekFeedback = LyricSeekFeedback(
            lyricID: line.id,
            previousFocusLyricID: visualCascadeFocusLyricID,
            playerSeekRevision: player.seekRevision + 1,
            startedAt: .now,
            minimumHoldDuration:
                accessibilityReduceMotion
                    ? 0
                    : LyricPlaybackTimeline.focusAnimationDuration(
                        for: line.id,
                        in: lyrics
                    )
        )
        browsingGeneration += 1
        isBrowsingLyrics = false
        player.seek(to: line.time)
    }

    private func holdSeekFeedbackUntilFocusCompletes(
        viewportHeight: CGFloat
    ) async {
        guard let feedback = seekFeedback else { return }

        for _ in 0..<250 {
            guard !Task.isCancelled,
                  seekFeedback == feedback else {
                return
            }

            if hasCompletedSeekMovement(
                feedback,
                viewportHeight: viewportHeight
            ) {
                completeSeekFeedback(
                    feedback
                )
                return
            }

            do {
                try await Task.sleep(for: .milliseconds(16))
            } catch {
                return
            }
        }

        guard seekFeedback == feedback else { return }
        completeSeekFeedback(
            feedback
        )
    }

    private func hasCompletedSeekMovement(
        _ feedback: LyricSeekFeedback,
        viewportHeight: CGFloat
    ) -> Bool {
        let id = feedback.lyricID
        guard visualCascadeFocusLyricID == id,
              Date.now.timeIntervalSince(feedback.startedAt)
                >= feedback.minimumHoldDuration,
              visualHighlightedLyricID == id,
              scrollPositionID == id,
              let frame = lyricFrameByID[id] else {
            return false
        }

        let movementOffset: CGFloat
        if lyricMovementTransition?.focusID == id,
           let presentation = lyricMovementTransition?
            .presentationStates(at: .now)[id] {
            movementOffset = presentation.offset
        } else {
            movementOffset = lyricMovementOffsetByID[id, default: 0]
        }

        let focusPosition = lyricsFocusPosition(for: viewportHeight)
        let visualAnchorY =
            frame.minY
            + movementOffset
            + frame.height * focusPosition
        let viewportAnchorY = viewportHeight * focusPosition
        return abs(visualAnchorY - viewportAnchorY) <= 2
    }

    private func completeSeekFeedback(
        _ feedback: LyricSeekFeedback
    ) {
        guard seekFeedback == feedback else { return }

        withAnimation(
            accessibilityReduceMotion
                ? nil
                : lyricFocusScaleAnimation(isFocused: true)
        ) {
            seekFeedback = nil
        }
    }

    private func completeSeekFeedbackIfNeeded(
        for lyricID: LyricLine.ID
    ) {
        guard let feedback = seekFeedback,
              feedback.lyricID == lyricID else {
            return
        }
        completeSeekFeedback(feedback)
    }

    private var lyricInteractionAccessibilityHint: String {
        switch (
            settings.lyricsTapToSeek,
            settings.lyricsLongPressToShare
        ) {
        case (true, true):
            "单击跳转到这行歌词，长按分享"
        case (true, false):
            "单击跳转到这行歌词"
        case (false, true):
            "长按分享这行歌词"
        case (false, false):
            "歌词交互已在设置中关闭"
        }
    }

    private func presentShare(for line: LyricLine) {
        guard settings.lyricsLongPressToShare,
              let song = player.currentSong else {
            return
        }
        onInterfaceInteraction?()
        lyricSharePresentation = LyricSharePresentation(
            song: song,
            lyric: line
        )
    }

    private func lyricShareText(
        for presentation: LyricSharePresentation
    ) -> String {
        let song = presentation.song
        let songURL = NeteaseShareResource.song(song).webURL.absoluteString
        return """
        \(presentation.lyric.text)
        ——《\(song.name)》· \(song.artistText)
        \(songURL)
        """
    }

    private func moveFocus(to id: LyricLine.ID, animated: Bool) {
        let update = {
            scrollPositionID = id
        }

        if animated, !accessibilityReduceMotion {
            withAnimation(
                .smooth(
                    duration: LyricPlaybackTimeline.focusAnimationDuration(
                        for: id,
                        in: lyrics
                    )
                ),
                update
            )
        } else {
            update()
        }
    }

    private func ensureFocusAlignment(
        to id: LyricLine.ID,
        viewportHeight: CGFloat,
        animated: Bool
    ) async {
        let focusPosition = lyricsFocusPosition(for: viewportHeight)
        let viewportAnchorY = viewportHeight * focusPosition

        if let frame = lyricFrameByID[id] {
            let currentAnchorY = frame.minY + frame.height * focusPosition
            if abs(currentAnchorY - viewportAnchorY) <= 2 {
                return
            }
        }

        for attempt in 0..<3 {
            guard !Task.isCancelled else { return }

            if scrollPositionID == id || attempt > 0 {
                var resetTransaction = Transaction(animation: nil)
                resetTransaction.disablesAnimations = true
                withTransaction(resetTransaction) {
                    scrollPositionID = nil
                }
                await Task.yield()
                guard !Task.isCancelled else { return }
            }

            moveFocus(to: id, animated: animated && attempt == 0)
            let isAligned = await waitForPreparedFocus(
                id: id,
                viewportAnchorY: viewportAnchorY,
                focusPosition: focusPosition
            )
            if isAligned {
                return
            }
        }
    }
}

private enum AppleMusicLyricsDisplayItem: Identifiable {
    case interlude(LyricInterlude)
    case lyric(LyricLine)

    var id: String {
        switch self {
        case let .interlude(interlude):
            interlude.id
        case let .lyric(line):
            line.id
        }
    }
}

private struct LyricFocusMovementTrigger: Hashable {
    let highlightedLyricID: LyricLine.ID?
    let interludeID: LyricInterlude.ID?
    let isBrowsingLyrics: Bool
    let playbackFocusRequestGeneration: Int
}

private struct LyricSeekFeedback: Hashable {
    let token = UUID()
    let lyricID: LyricLine.ID
    let previousFocusLyricID: LyricLine.ID?
    let playerSeekRevision: Int
    let startedAt: Date
    let minimumHoldDuration: TimeInterval
}

private struct RetainedCascadeLyric: Identifiable, Equatable {
    let id: LyricLine.ID
    let frame: CGRect
    let movementDistance: CGFloat
}

private nonisolated struct LyricGeometryMeasurement:
    Equatable,
    Sendable
{
    let frame: CGRect
    let layoutHeight: CGFloat
}
