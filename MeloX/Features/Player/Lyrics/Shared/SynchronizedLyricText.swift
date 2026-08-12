import SwiftUI

enum SynchronizedLyricTextAlignment: Equatable {
    case leading
    case center

    var textAlignment: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        }
    }

    var horizontalAlignment: HorizontalAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        }
    }

    var scaleAnchor: UnitPoint {
        switch self {
        case .leading: .topLeading
        case .center: .top
        }
    }
}

struct SynchronizedLyricText: View {
    static let interactionBackgroundVisualOverflow: CGFloat = 16

    private static let interactionBackgroundCornerRadius: CGFloat = 16

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.effectiveLyricsRefreshRate) private var effectiveLyricsRefreshRate
    @Environment(PlayerStore.self) private var player
    @Environment(AppSettings.self) private var settings

    let line: LyricLine
    let isPlaybackLine: Bool
    let playbackFocusProgress: CGFloat?
    let usesPseudoTiming: Bool
    let fontSize: CGFloat
    let romanizationFontSize: CGFloat
    let fontWeight: LyricsFontWeight
    let alignment: SynchronizedLyricTextAlignment
    let fontScale: CGFloat
    let primaryColor: Color
    let showsTranslation: Bool
    let showsRomanization: Bool
    let includesTranslation: Bool
    let includesRomanization: Bool
    let reservesAnnotationSpace: Bool
    let onAnnotationHeightChange: ((CGFloat) -> Void)?
    let annotationLayoutAnimation: Animation?
    let annotationVisibilityAnimation: Animation?
    let interactionBackgroundOpacity: Double
    let visualScale: CGFloat
    let visualScaleAnimation: Animation?
    let promotedLayoutScale: CGFloat
    let layoutWidth: CGFloat?
    let playbackScaleRange: ClosedRange<CGFloat>?
    let playbackScaleStartDelay: TimeInterval
    private let synchronizedText: Text
    private let pseudoSynchronizedText: Text
    private let layoutStableText: Text
    private let hasPseudoSyllables: Bool
    private let timedPlaybackRange: ClosedRange<TimeInterval>?
    private let romanizationRows: [LyricRubyRow]

    init(
        line: LyricLine,
        isPlaybackLine: Bool,
        playbackFocusProgress: CGFloat? = nil,
        usesPseudoTiming: Bool,
        fontSize: CGFloat,
        romanizationFontSize: CGFloat? = nil,
        fontWeight: LyricsFontWeight = .bold,
        alignment: SynchronizedLyricTextAlignment = .leading,
        fontScale: CGFloat = 1,
        primaryColor: Color = .white,
        showsTranslation: Bool = true,
        showsRomanization: Bool = true,
        includesTranslation: Bool = true,
        includesRomanization: Bool = false,
        reservesAnnotationSpace: Bool = true,
        onAnnotationHeightChange: ((CGFloat) -> Void)? = nil,
        annotationLayoutAnimation: Animation? = nil,
        annotationVisibilityAnimation: Animation? = nil,
        interactionBackgroundOpacity: Double = 0,
        visualScale: CGFloat = 1,
        visualScaleAnimation: Animation? = nil,
        promotedLayoutScale: CGFloat = 1,
        layoutWidth: CGFloat? = nil,
        playbackScaleRange: ClosedRange<CGFloat>? = nil,
        playbackScaleStartDelay: TimeInterval = 0
    ) {
        self.line = line
        self.isPlaybackLine = isPlaybackLine
        self.playbackFocusProgress = playbackFocusProgress
        self.usesPseudoTiming = usesPseudoTiming
        self.fontSize = fontSize
        self.romanizationFontSize = romanizationFontSize
            ?? max(fontSize * 0.55, 13 * fontScale)
        self.fontWeight = fontWeight
        self.alignment = alignment
        self.fontScale = fontScale
        self.primaryColor = primaryColor
        self.showsTranslation = showsTranslation
        self.showsRomanization = showsRomanization
        self.includesTranslation = includesTranslation
        self.includesRomanization = includesRomanization
        self.reservesAnnotationSpace = reservesAnnotationSpace
        self.onAnnotationHeightChange = onAnnotationHeightChange
        self.annotationLayoutAnimation = annotationLayoutAnimation
        self.annotationVisibilityAnimation = annotationVisibilityAnimation
        self.interactionBackgroundOpacity =
            interactionBackgroundOpacity
        self.visualScale = visualScale
        self.visualScaleAnimation = visualScaleAnimation
        self.promotedLayoutScale = promotedLayoutScale
        self.layoutWidth = layoutWidth
        self.playbackScaleRange = playbackScaleRange
        self.playbackScaleStartDelay = playbackScaleStartDelay

        let pseudoSyllables = usesPseudoTiming
            ? line.makePseudoSyllables()
            : []
        let activeSyllables = line.syllables.isEmpty
            ? pseudoSyllables
            : line.syllables
        let timedLayoutWidth = layoutWidth.map {
            $0 / max(playbackScaleRange?.upperBound ?? 1, 1)
        }
        let calculationScale = promotedLayoutScale.isFinite
            ? max(promotedLayoutScale, 1)
            : 1
        let rubyLayoutWidth = timedLayoutWidth.map {
            $0 / calculationScale
        }
        synchronizedText = TimedLyricTextBuilder.text(
            from: line.syllables,
            constrainedWidth: timedLayoutWidth,
            fontSize: fontSize * calculationScale,
            fontWeight: fontWeight
        )
        pseudoSynchronizedText = TimedLyricTextBuilder.text(
            from: pseudoSyllables,
            constrainedWidth: timedLayoutWidth,
            fontSize: fontSize * calculationScale,
            fontWeight: fontWeight
        )
        layoutStableText = TimedLyricTextBuilder.text(
            from: line.text,
            constrainedWidth: layoutWidth,
            fontSize: fontSize * calculationScale,
            fontWeight: fontWeight
        )
        hasPseudoSyllables = !pseudoSyllables.isEmpty
        let romanizationUnits =
            includesRomanization && showsRomanization
                ? LyricRomanizationAligner.units(
                    for: line,
                    activeSyllables: activeSyllables
                )
                : []
        romanizationRows = LyricRubyLayoutPlanner.rows(
            for: romanizationUnits,
            fontSize: fontSize,
            romanizationFontSize:
                self.romanizationFontSize,
            fontWeight: fontWeight,
            availableWidth: rubyLayoutWidth
        )
        if let firstSyllable = activeSyllables.first,
           let lastSyllable = activeSyllables.last,
           lastSyllable.endTime > firstSyllable.startTime {
            timedPlaybackRange = firstSyllable.startTime...lastSyllable.endTime
        } else {
            timedPlaybackRange = nil
        }
    }

    var body: some View {
        LyricAnnotationLayout(
            expansion:
                reservesAnnotationSpace && displaysTranslation
                    ? 1
                    : 0,
            spacing: LyricAnnotationMetrics.verticalSpacing
        ) {
            primaryLyric
                .animation(
                    accessibilityReduceMotion ? nil : .easeInOut(duration: 0.28),
                    value: legacyTimedLyricAnimationValue
                )

            annotationStack
        }
        .animation(
            accessibilityReduceMotion ? nil : annotationLayoutAnimation,
            value: displaysAnnotations
        )
        .animation(
            accessibilityReduceMotion ? nil : annotationLayoutAnimation,
            value: displaysRomanization
        )
        .animation(
            accessibilityReduceMotion
                ? nil
                : annotationVisibilityAnimation,
            value: displaysRomanization
        )
        .animation(
            accessibilityReduceMotion ? nil : annotationLayoutAnimation,
            value: displaysTranslation
        )
        .multilineTextAlignment(alignment.textAlignment)
        .frame(
            width: normalizedLayoutWidth,
            alignment: alignment.frameAlignment
        )
        .background(alignment: .topLeading) {
            if interactionBackgroundOpacity > 0 {
                RoundedRectangle(
                    cornerRadius:
                        Self.interactionBackgroundCornerRadius
                            / effectiveVisualScale,
                    style: .continuous
                )
                .fill(
                    .white.opacity(
                        min(
                            max(interactionBackgroundOpacity, 0),
                            1
                        )
                    )
                )
                .padding(
                    -Self.interactionBackgroundVisualOverflow
                        / effectiveVisualScale
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .scaleEffect(
            visualScale,
            anchor: alignment.scaleAnchor
        )
        .animation(
            accessibilityReduceMotion ? nil : visualScaleAnimation,
            value: visualScale
        )
        .frame(maxWidth: .infinity, alignment: alignment.frameAlignment)
    }

    private var annotationStack: some View {
        VStack(
            alignment: alignment.horizontalAlignment,
            spacing: 0
        ) {
            // Keep the hidden translation mounted so its reveal starts from
            // an already measured height instead of invalidating the row.
            if hasIncludedTranslation,
               let translation = line.translation {
                annotationText(
                    translation,
                    fontSize: translationFontSize,
                    opacity: settings.lyricsTranslationOpacity
                )
            }
        }
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.height
        } action: { height in
            onAnnotationHeightChange?(height)
        }
        .opacity(displaysTranslation ? 1 : 0)
        .animation(
            accessibilityReduceMotion
                ? nil
                : annotationVisibilityAnimation,
            value: displaysTranslation
        )
    }

    private func annotationText(
        _ text: String,
        fontSize: CGFloat,
        opacity: Double
    ) -> some View {
        Text(verbatim: text)
            .font(
                .system(
                    size: fontSize,
                    weight: fontWeight.swiftUIWeight
                )
            )
            .foregroundStyle(.white.opacity(opacity))
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(
                maxWidth: .infinity,
                alignment: alignment.frameAlignment
            )
    }

    private var primaryLyric: some View {
        stablePrimaryLyric
            .opacity(presentsTimedLyrics ? 0 : 1)
            .overlay(alignment: alignment.frameAlignment) {
                if presentsTimedLyrics {
                    synchronizedPrimaryLyric
                }
            }
    }

    private var stablePrimaryLyric: some View {
        Group {
            if usesRubyLayout {
                rubyText(
                    at: timedPlaybackRange?.lowerBound ?? 0,
                    appliesTimingEffects: false
                )
            } else {
                stablePrimaryContent
                    .font(primaryFont)
                    .foregroundStyle(primaryColor)
                    .multilineTextAlignment(alignment.textAlignment)
                    .lineLimit(nil)
                    .fixedSize(
                        horizontal:
                            primaryLayoutWidth != nil
                                && alignment == .leading,
                        vertical: true
                    )
                    .textRenderer(
                        lyricTextRenderer(
                            at: timedPlaybackRange?.lowerBound ?? 0,
                            appliesTimingEffects: false
                        )
                    )
            }
        }
            .frame(
                width: primaryLayoutWidth,
                alignment: alignment.frameAlignment
            )
            .frame(
                maxWidth: .infinity,
                alignment: alignment.frameAlignment
            )
    }

    private var synchronizedPrimaryLyric: some View {
        let _ = player.lyricsTimingRevision
        let _ = player.seekRevision
        TimelineView(
            .animation(
                minimumInterval: effectiveLyricsRefreshRate.minimumInterval,
                paused: !player.isPlaying
            )
        ) { context in
            let playbackTime = player.estimatedProgress(at: context.date)
                + settings.wordByWordLyricsAdvanceTime

            Group {
                if usesRubyLayout {
                    rubyText(
                        at: playbackTime,
                        appliesTimingEffects: true,
                        timingEffectsStrength: 1
                    )
                } else {
                    activeSynchronizedText
                        .font(primaryFont)
                        .foregroundStyle(primaryColor)
                        .multilineTextAlignment(alignment.textAlignment)
                        .lineLimit(nil)
                        .fixedSize(
                            horizontal: alignment == .leading,
                            vertical: true
                        )
                        .textRenderer(
                            lyricTextRenderer(
                                at: playbackTime,
                                timingEffectsStrength: 1
                            )
                        )
                }
            }
                .frame(
                    width: timedLayoutWidth,
                    alignment: alignment.frameAlignment
                )
                .frame(
                    maxWidth: .infinity,
                    alignment: alignment.frameAlignment
                )
                .scaleEffect(
                    playbackPresentationScale(at: playbackTime),
                    anchor: .center
                )
        }
    }

    private var stablePrimaryContent: Text {
        supportsTimedLyrics
            ? activeSynchronizedText
            : layoutStableText
    }

    private func lyricTextRenderer(
        at playbackTime: TimeInterval,
        appliesTimingEffects: Bool = true,
        timingEffectsStrength: Double = 1
    ) -> LyricGlowTextRenderer {
        LyricGlowTextRenderer(
            playbackTime: playbackTime,
            style: lyricRendererStyle,
            layoutConfiguration: .init(
                width: rendererLayoutWidth,
                centersLines: alignment == .center
            ),
            appliesTimingEffects: appliesTimingEffects,
            timingEffectsStrength: timingEffectsStrength
        )
    }

    private var lyricRendererStyle: LyricGlowTextRenderer.Style {
        .init(
            glowRadius: glowRadius,
            glowOpacity: glowOpacity,
            glowsLongSyllablesOnly:
                settings.lyricsGlowLongSyllablesOnly,
            longSyllableDetectionMode:
                settings.lyricsLongSyllableDetectionMode,
            longSyllableDurationThreshold:
                settings.lyricsLongSyllableDurationThreshold,
            unplayedOpacity: 0.3,
            maximumUnplayedBlurRadius: maximumUnplayedBlurRadius,
            playedRise: playedRise,
            maximumLongSyllableScale: maximumLongSyllableScale,
            longSyllableExpansionPadding: longSyllableExpansionPadding,
            highlightGradientWidth: CGFloat(
                settings.lyricsHighlightGradientWidth
            ),
            highlightGradientReduction: CGFloat(
                settings.lyricsHighlightGradientReduction
            ),
            liftMode: settings.lyricsLiftMode
        )
    }

    private func rubyText(
        at playbackTime: TimeInterval,
        appliesTimingEffects: Bool,
        timingEffectsStrength: Double = 1
    ) -> some View {
        LyricRubyText(
            rows: romanizationRows,
            fontSize: fontSize,
            romanizationFontSize: romanizationFontSize,
            fontWeight: fontWeight,
            primaryColor: primaryColor,
            romanizationOpacity:
                settings.lyricsRomanizationOpacity,
            alignment: alignment,
            annotationExpansion:
                displaysRomanization ? 1 : 0,
            playbackTime: playbackTime,
            rendererStyle: lyricRendererStyle,
            appliesTimingEffects: appliesTimingEffects,
            timingEffectsStrength: timingEffectsStrength
        )
    }

    private var primaryLayoutWidth: CGFloat? {
        supportsTimedLyrics ? timedLayoutWidth : normalizedLayoutWidth
    }

    private var rendererLayoutWidth: CGFloat? {
        supportsTimedLyrics ? timedLayoutWidth : normalizedLayoutWidth
    }

    private var supportsTimedLyrics: Bool {
        (settings.lyricsWordByWord && line.isSyllableSynced)
            || (usesPseudoTiming && hasPseudoSyllables)
    }

    private var usesTimedLyrics: Bool {
        isPlaybackLine && supportsTimedLyrics
    }

    private var timedLyricPresentationProgress: Double {
        guard supportsTimedLyrics else { return 0 }
        guard let playbackFocusProgress else {
            return usesTimedLyrics ? 1 : 0
        }
        return Double(min(max(playbackFocusProgress, 0), 1))
    }

    private var presentsTimedLyrics: Bool {
        supportsTimedLyrics
            && (isPlaybackLine || timedLyricPresentationProgress > 0)
    }

    private var legacyTimedLyricAnimationValue: Bool {
        playbackFocusProgress == nil && usesTimedLyrics
    }

    private var activeSynchronizedText: Text {
        line.isSyllableSynced
            ? synchronizedText
            : pseudoSynchronizedText
    }

    private var primaryFont: Font {
        .system(size: fontSize, weight: fontWeight.swiftUIWeight)
    }

    private var translationFontSize: CGFloat {
        max(
            CGFloat(settings.lyricsFontSize * settings.lyricsTranslationFontScale) * fontScale,
            13 * fontScale
        )
    }

    private var hasIncludedTranslation: Bool {
        includesTranslation
            && settings.lyricsTranslationEnabled
            && line.translation != nil
    }

    private var hasIncludedRomanization: Bool {
        includesRomanization
            && settings.lyricsRomanizationEnabled
            && line.romanization != nil
    }

    private var displaysTranslation: Bool {
        showsTranslation && hasIncludedTranslation
    }

    private var displaysRomanization: Bool {
        showsRomanization && hasIncludedRomanization
    }

    private var displaysAnnotations: Bool {
        displaysRomanization || displaysTranslation
    }

    private var usesRubyLayout: Bool {
        displaysRomanization && !romanizationRows.isEmpty
    }

    private var glowRadius: CGFloat {
        guard settings.lyricsGlowEnabled else { return 0 }
        return CGFloat(
            Double(fontSize)
                * 0.2
                * settings.lyricsGlowIntensity
        )
    }

    private var glowOpacity: Double {
        guard settings.lyricsGlowEnabled else { return 0 }
        return min(settings.lyricsGlowIntensity, 1)
    }

    private var maximumUnplayedBlurRadius: CGFloat {
        CGFloat(settings.lyricsBlurIntensity) * 0.55 * fontScale
    }

    private var playedRise: CGFloat {
        guard !accessibilityReduceMotion else { return 0 }
        return min(max(fontSize * 0.1, 1.5), 6)
    }

    private var maximumLongSyllableScale: CGFloat {
        accessibilityReduceMotion
            ? 1
            : 1 + CGFloat(settings.lyricsLongToneExpansionAmount)
    }

    private var longSyllableExpansionPadding: CGFloat {
        fontSize
            * (maximumLongSyllableScale - 1)
            * CGFloat(1.2)
    }

    private var effectivePromotedLayoutScale: CGFloat {
        guard promotedLayoutScale.isFinite else { return 1 }
        return max(promotedLayoutScale, 1)
    }

    private var effectiveVisualScale: CGFloat {
        guard visualScale.isFinite else { return 1 }
        return max(visualScale, 1)
    }

    private var timedLayoutWidth: CGFloat? {
        guard let normalizedLayoutWidth,
              let maximumScale = playbackScaleRange?.upperBound else {
            return normalizedLayoutWidth
        }
        return normalizedLayoutWidth / max(maximumScale, 1)
    }

    private var normalizedLayoutWidth: CGFloat? {
        layoutWidth.map {
            $0 / effectivePromotedLayoutScale
        }
    }

    private func playbackScale(at playbackTime: TimeInterval) -> CGFloat {
        guard !accessibilityReduceMotion,
              let playbackScaleRange,
              let timedPlaybackRange else {
            return 1
        }

        let glowTailDuration = settings.lyricsGlowEnabled
            ? LyricGlowTextRenderer.glowTailDuration
            : 0
        let playbackScaleEndTime = timedPlaybackRange.upperBound
            + glowTailDuration
        let fullDuration = playbackScaleEndTime
            - timedPlaybackRange.lowerBound
        guard fullDuration > 0 else { return playbackScaleRange.upperBound }

        let minimumContinuationDuration = min(fullDuration * 0.35, 0.25)
        let maximumStartDelay = max(
            fullDuration - minimumContinuationDuration,
            0
        )
        let effectiveStartTime = timedPlaybackRange.lowerBound
            + min(max(playbackScaleStartDelay, 0), maximumStartDelay)
        let continuationDuration = playbackScaleEndTime
            - effectiveStartTime
        guard continuationDuration > 0 else {
            return playbackScaleRange.upperBound
        }

        let rawProgress = (playbackTime - effectiveStartTime)
            / continuationDuration
        let progress = min(max(rawProgress, 0), 1)
        let easedProgress = progress * progress * (3 - 2 * progress)
        return playbackScaleRange.lowerBound
            + (playbackScaleRange.upperBound - playbackScaleRange.lowerBound)
                * CGFloat(easedProgress)
    }

    private func playbackPresentationScale(
        at playbackTime: TimeInterval
    ) -> CGFloat {
        let activeScale = playbackScale(at: playbackTime)
        return 1
            + (activeScale - 1)
                * CGFloat(timedLyricPresentationProgress)
    }
}
