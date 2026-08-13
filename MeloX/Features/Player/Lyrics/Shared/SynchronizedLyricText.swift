import SwiftUI
import UIKit

enum SynchronizedLyricTextAlignment: Equatable {
    case leading
    case center
    case trailing

    var textAlignment: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var horizontalAlignment: HorizontalAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var scaleAnchor: UnitPoint {
        switch self {
        case .leading: .topLeading
        case .center: .top
        case .trailing: .topTrailing
        }
    }

    static func resolved(
        for line: LyricLine,
        duetLayoutEnabled: Bool
    ) -> SynchronizedLyricTextAlignment {
        guard duetLayoutEnabled,
              line.agent?.alignment == .flipped else {
            return .leading
        }
        return .trailing
    }
}

struct SynchronizedLyricText: View {
    static let interactionBackgroundVisualOverflow: CGFloat = 16

    private static let interactionBackgroundCornerRadius: CGFloat = 16

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.effectiveLyricsRefreshRate) private var effectiveLyricsRefreshRate
    @Environment(PlayerStore.self) private var player
    @Environment(AppSettings.self) private var settings

    let line: LyricLine
    let isPlaybackLine: Bool
    let isAnimationActive: Bool
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
    let motionProfile: AppleMusicLyricsMotionProfile?
    let suppressesTimedGlyphBlur: Bool
    let playbackScaleRange: ClosedRange<CGFloat>?
    let playbackScaleStartDelay: TimeInterval
    private let supplementalTextProfile:
        AppleMusicLyricsSupplementalTextProfile?
    private let synchronizedText: Text
    private let pseudoSynchronizedText: Text
    private let layoutStableText: Text
    private let hasPseudoSyllables: Bool
    private let timedPlaybackRange: ClosedRange<TimeInterval>?
    private let romanizationRows: [LyricRubyRow]
    private let primaryTrailingVisualOverflow: CGFloat

    init(
        line: LyricLine,
        isPlaybackLine: Bool,
        isAnimationActive: Bool = true,
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
        motionProfile: AppleMusicLyricsMotionProfile? = nil,
        suppressesTimedGlyphBlur: Bool = false,
        playbackScaleRange: ClosedRange<CGFloat>? = nil,
        playbackScaleStartDelay: TimeInterval = 0
    ) {
        self.line = line
        self.isPlaybackLine = isPlaybackLine
        self.isAnimationActive = isAnimationActive
        self.playbackFocusProgress = playbackFocusProgress
        self.usesPseudoTiming = usesPseudoTiming
        self.fontSize = fontSize
        let supplementalTextProfile = motionProfile == nil
            ? nil
            : AppleMusicLyricsSupplementalTextProfile.iOS26_6
        self.supplementalTextProfile = supplementalTextProfile
        self.romanizationFontSize = supplementalTextProfile == nil
            ? romanizationFontSize
                ?? max(fontSize * 0.55, 13 * fontScale)
            : UIFont.systemFont(
                ofSize: UIFont.preferredFont(
                    forTextStyle: .title3
                ).pointSize,
                weight: .bold
            ).pointSize
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
        self.motionProfile = motionProfile
        self.suppressesTimedGlyphBlur = suppressesTimedGlyphBlur
        // `LyricsSpecs.emphasizingScaleRange` belongs to the timed glyph
        // renderer. It must not become a scale on the complete lyric row.
        // Whole-line playback scaling remains an explicit opt-in used by
        // Skyline and floating lyrics only.
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
        hasPseudoSyllables = !pseudoSyllables.isEmpty
        let romanizationUnits =
            includesRomanization
                ? LyricRomanizationAligner.units(
                    for: line,
                    activeSyllables: activeSyllables
                )
                : []
        let romanizationPlan = LyricRubyLayoutPlanner.plan(
            for: romanizationUnits,
            fontSize: fontSize,
            romanizationFontSize:
                self.romanizationFontSize,
            primaryFontWeight: fontWeight,
            romanizationFontWeight:
                supplementalTextProfile == nil ? fontWeight : .bold,
            availableWidth: rubyLayoutWidth,
            minimumWordSpacing: CGFloat(
                supplementalTextProfile?
                    .transliterationMinimumWordSpacing
                    ?? max(self.romanizationFontSize * 0.18, 2)
            )
        )
        romanizationRows = romanizationPlan.rows
        let usesRomanizationLayout =
            showsRomanization
            && romanizationUnits.map(\.originalText).joined() == line.text
        let primaryLineBreakOffsets =
            usesRomanizationLayout
                ? romanizationPlan.sourceLineBreakCharacterOffsets
                : nil
        let primaryHorizontalOffsets =
            usesRomanizationLayout
                ? romanizationPlan
                    .sourceHorizontalOffsetsByCharacterOffset
                : [:]
        primaryTrailingVisualOverflow =
            primaryHorizontalOffsets.values.max() ?? 0
        synchronizedText = TimedLyricTextBuilder.text(
            from: line.syllables,
            constrainedWidth: timedLayoutWidth,
            fontSize: fontSize * calculationScale,
            fontWeight: fontWeight,
            forcedLineBreakCharacterOffsets: primaryLineBreakOffsets,
            forcedHorizontalOffsetsByCharacterOffset:
                primaryHorizontalOffsets
        )
        pseudoSynchronizedText = TimedLyricTextBuilder.text(
            from: pseudoSyllables,
            constrainedWidth: timedLayoutWidth,
            fontSize: fontSize * calculationScale,
            fontWeight: fontWeight,
            forcedLineBreakCharacterOffsets: primaryLineBreakOffsets,
            forcedHorizontalOffsetsByCharacterOffset:
                primaryHorizontalOffsets
        )
        layoutStableText = TimedLyricTextBuilder.text(
            from: line.text,
            constrainedWidth: layoutWidth,
            fontSize: fontSize * calculationScale,
            fontWeight: fontWeight,
            forcedLineBreakCharacterOffsets: primaryLineBreakOffsets,
            forcedHorizontalOffsetsByCharacterOffset:
                primaryHorizontalOffsets
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
        LyricSupplementalTextLayout(
            transliterationExpansion:
                displaysRomanization ? 1 : 0,
            translationExpansion:
                displaysTranslation ? 1 : 0,
            transliterationSpacing: transliterationSpacing,
            translationSpacing: translationSpacing,
            translationBottomPadding: translationBottomPadding
        ) {
            primaryLyric
                .animation(
                    accessibilityReduceMotion ? nil : .easeInOut(duration: 0.28),
                    value: legacyTimedLyricAnimationValue
                )
                .lyricSupplementalTextRole(.primary)

            if hasIncludedRomanization, !romanizationRows.isEmpty {
                romanizationLyric
                    .opacity(displaysRomanization ? 1 : 0)
                    .offset(
                        y: supplementalVerticalOffset(
                            isShowing: displaysRomanization
                        )
                    )
                    .animation(
                        resolvedAnnotationAnimation(
                            isShowing: displaysRomanization,
                            fallback: annotationVisibilityAnimation
                        ),
                        value: displaysRomanization
                    )
                    .lyricSupplementalTextRole(.transliteration)
                    .accessibilityHidden(true)
            }

            if hasIncludedTranslation,
               let translation = normalizedTranslation {
                translationText(translation)
                    .opacity(displaysTranslation ? 1 : 0)
                    .offset(
                        y: supplementalVerticalOffset(
                            isShowing: displaysTranslation
                        )
                    )
                    .animation(
                        resolvedAnnotationAnimation(
                            isShowing: displaysTranslation,
                            fallback: annotationVisibilityAnimation
                        ),
                        value: displaysTranslation
                    )
                    .lyricSupplementalTextRole(.translation)
            }
        }
        .animation(
            resolvedAnnotationAnimation(
                isShowing: displaysRomanization,
                fallback: annotationLayoutAnimation
            ),
            value: displaysRomanization
        )
        .animation(
            resolvedAnnotationAnimation(
                isShowing: displaysTranslation,
                fallback: annotationLayoutAnimation
            ),
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

    private var romanizationLyric: some View {
        rubyText(
            at: timedPlaybackRange?.lowerBound ?? line.time,
            appliesTimingEffects: false
        )
        .opacity(presentsTimedRomanization ? 0 : 1)
        .overlay(alignment: alignment.frameAlignment) {
            if presentsTimedRomanization {
                TimelineView(
                    .animation(
                        minimumInterval:
                            effectiveLyricsRefreshRate.minimumInterval,
                        paused:
                            !player.isPlaying
                            || !isAnimationActive
                            || !displaysRomanization
                    )
                ) { context in
                    rubyText(
                        at: player.estimatedProgress(at: context.date)
                            + settings.wordByWordLyricsAdvanceTime
                            + (motionProfile?.animationHeadstart ?? 0),
                        appliesTimingEffects: true,
                        timingEffectsStrength:
                            timedLyricPresentationProgress
                    )
                }
            }
        }
    }

    private func translationText(
        _ text: String
    ) -> some View {
        Text(verbatim: text)
            .font(translationFont)
            .foregroundStyle(
                primaryColor.opacity(translationRelativeOpacity)
            )
            .multilineTextAlignment(alignment.textAlignment)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(
                maxWidth: .infinity,
                alignment: alignment.frameAlignment
            )
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { height in
                onAnnotationHeightChange?(height)
            }
    }

    private func resolvedAnnotationAnimation(
        isShowing: Bool,
        fallback: Animation?
    ) -> Animation? {
        guard !accessibilityReduceMotion else { return nil }
        guard let motionProfile else { return fallback }
        let spring = isShowing
            ? motionProfile.supplementalTextShowSpring
            : motionProfile.supplementalTextHideSpring
        return .interpolatingSpring(
            mass: spring.mass,
            stiffness: spring.stiffness,
            damping: spring.damping,
            initialVelocity: 0
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
        TimelineView(
            .animation(
                minimumInterval: effectiveLyricsRefreshRate.minimumInterval,
                paused: !player.isPlaying || !isAnimationActive
            )
        ) { context in
            let playbackTime = player.estimatedProgress(at: context.date)
                + settings.wordByWordLyricsAdvanceTime
                + (motionProfile?.animationHeadstart ?? 0)

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
                        timingEffectsStrength:
                            timedLyricPresentationProgress
                    )
                )
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
                centersLines: alignment == .center,
                trailingVisualOverflow:
                    primaryTrailingVisualOverflow
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
                motionProfile == nil
                    ? settings.lyricsGlowLongSyllablesOnly
                    : false,
            longSyllableDetectionMode:
                motionProfile == nil
                    ? settings.lyricsLongSyllableDetectionMode
                    : .character,
            longSyllableDurationThreshold:
                motionProfile == nil
                    ? settings.lyricsLongSyllableDurationThreshold
                    : settings.lyricsLongSyllableDurationThreshold,
            unplayedOpacity: unplayedOpacity,
            focusOpacityEndpoints: focusOpacityEndpoints,
            maximumUnplayedBlurRadius: maximumUnplayedBlurRadius,
            playedRise: playedRise,
            maximumLongSyllableScale: maximumLongSyllableScale,
            longSyllableExpansionPadding: longSyllableExpansionPadding,
            highlightGradientWidth: CGFloat(
                motionProfile == nil
                    ? settings.lyricsHighlightGradientWidth
                    : 1
            ),
            lineProgressionGradientFeather:
                motionProfile.map {
                    CGFloat($0.lineProgressionGradientFeather)
                },
            highlightGradientReduction: CGFloat(
                motionProfile == nil
                    ? settings.lyricsHighlightGradientReduction
                    : 0
            ),
            lineFinishProgressAnimationDuration:
                motionProfile?
                    .lineFinishProgressAnimationDuration,
            liftMode:
                motionProfile == nil
                    ? settings.lyricsLiftMode
                    : .character
        )
    }

    private func rubyText(
        at playbackTime: TimeInterval,
        appliesTimingEffects: Bool,
        timingEffectsStrength: Double = 1
    ) -> some View {
        LyricRubyText(
            rows: romanizationRows,
            romanizationFontSize: romanizationFontSize,
            fontWeight:
                supplementalTextProfile == nil ? fontWeight : .bold,
            primaryColor: primaryColor,
            romanizationOpacity: romanizationRelativeOpacity,
            staticRomanizationOpacity:
                staticRomanizationRelativeOpacity,
            alignment: alignment,
            lineHeightAdjustment: CGFloat(
                supplementalTextProfile?.transliterationSpacing
                    ?? 0
            ),
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

    /// Supplemental text follows the row's focus state even when the primary
    /// lyric has no word-level timing. Translation is a static label in Apple
    /// Music, so tying its color to `supportsTimedLyrics` makes LRC lines use
    /// the selected-text color instead of the selected-upcoming color.
    private var supplementalFocusProgress: Double {
        if let playbackFocusProgress {
            return Double(min(max(playbackFocusProgress, 0), 1))
        }
        return isPlaybackLine ? 1 : 0
    }

    private var presentsTimedLyrics: Bool {
        supportsTimedLyrics
            && (isPlaybackLine || timedLyricPresentationProgress > 0)
    }

    private var presentsTimedRomanization: Bool {
        presentsTimedLyrics
            && romanizationRows.contains { $0.hasTimedContent }
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

    private var customTranslationFontSize: CGFloat {
        max(
            CGFloat(settings.lyricsFontSize * settings.lyricsTranslationFontScale) * fontScale,
            13 * fontScale
        )
    }

    private var translationFont: Font {
        guard supplementalTextProfile != nil else {
            return .system(
                size: customTranslationFontSize,
                weight: fontWeight.swiftUIWeight
            )
        }
        return displaysRomanization && !romanizationRows.isEmpty
            ? .callout.bold()
            : .title3.bold()
    }

    private var normalizedTranslation: String? {
        guard let translation = line.translation?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !translation.isEmpty else {
            return nil
        }
        let original = line.text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard translation.compare(
            original,
            options: [.caseInsensitive]
        ) != .orderedSame else {
            return nil
        }
        return translation
    }

    private var hasIncludedTranslation: Bool {
        includesTranslation
            && normalizedTranslation != nil
    }

    private var hasIncludedRomanization: Bool {
        includesRomanization
            && line.romanization != nil
    }

    private var displaysTranslation: Bool {
        settings.lyricsTranslationEnabled
            && showsTranslation
            && hasIncludedTranslation
    }

    private var displaysRomanization: Bool {
        settings.lyricsRomanizationEnabled
            && showsRomanization
            && hasIncludedRomanization
    }

    private var transliterationSpacing: CGFloat {
        CGFloat(
            supplementalTextProfile?.transliterationSpacing
                ?? LyricAnnotationMetrics.verticalSpacing
        )
    }

    private var translationSpacing: CGFloat {
        CGFloat(
            supplementalTextProfile?.translationSpacing
                ?? LyricAnnotationMetrics.verticalSpacing
        )
    }

    private var translationBottomPadding: CGFloat {
        CGFloat(
            supplementalTextProfile?.translationBottomPadding ?? 0
        )
    }

    private func supplementalVerticalOffset(
        isShowing: Bool
    ) -> CGFloat {
        guard !isShowing else { return 0 }
        return CGFloat(
            supplementalTextProfile?.hiddenVerticalOffset ?? 0
        )
    }

    private var romanizationRelativeOpacity: Double {
        motionProfile == nil
            ? settings.lyricsRomanizationOpacity
            : 1
    }

    private var staticRomanizationRelativeOpacity: Double {
        motionProfile == nil
            ? settings.lyricsRomanizationOpacity
            : translationRelativeOpacity
    }

    private var translationRelativeOpacity: Double {
        if let focusOpacityEndpoints {
            return focusOpacityEndpoints.relativeUpcomingOpacity(
                at: supplementalFocusProgress
            )
        }
        return settings.lyricsTranslationOpacity
    }

    private var glowRadius: CGFloat {
        if let profile = motionProfile {
            return CGFloat(profile.glowRadius)
        }
        guard settings.lyricsGlowEnabled else { return 0 }
        return CGFloat(
            Double(fontSize)
                * 0.2
                * settings.lyricsGlowIntensity
        )
    }

    private var unplayedOpacity: Double {
        guard let motionProfile else { return 0.3 }
        return colorSchemeContrast == .increased
            ? motionProfile.increasedContrastSelectedUpcomingTextOpacity
            : motionProfile.selectedUpcomingTextOpacity
    }

    private var focusOpacityEndpoints: LyricFocusOpacityEndpoints? {
        guard let motionProfile else { return nil }
        if colorSchemeContrast == .increased {
            return LyricFocusOpacityEndpoints(
                deselected:
                    motionProfile.increasedContrastDeselectedTextOpacity,
                selected:
                    motionProfile.increasedContrastSelectedTextOpacity,
                selectedUpcoming:
                    motionProfile
                        .increasedContrastSelectedUpcomingTextOpacity
            )
        }
        return LyricFocusOpacityEndpoints(
            deselected: motionProfile.deselectedTextOpacity,
            selected: motionProfile.selectedTextOpacity,
            selectedUpcoming: motionProfile.selectedUpcomingTextOpacity
        )
    }

    private var glowOpacity: Double {
        if motionProfile != nil {
            return 0.4
        }
        guard settings.lyricsGlowEnabled else { return 0 }
        return min(settings.lyricsGlowIntensity, 1)
    }

    private var maximumUnplayedBlurRadius: CGFloat {
        if suppressesTimedGlyphBlur {
            return 0
        }
        if motionProfile != nil {
            // Line blur is handled by the outer Apple Music row layer. Keep
            // the glyph reveal crisp so hidden custom intensity values cannot
            // leak into the reconstructed preset.
            return 0
        }
        return CGFloat(settings.lyricsBlurIntensity) * 0.55 * fontScale
    }

    private var playedRise: CGFloat {
        guard !accessibilityReduceMotion else { return 0 }
        if let profile = motionProfile {
            return CGFloat(profile.syllableLift)
        }
        return min(max(fontSize * 0.1, 1.5), 6)
    }

    private var maximumLongSyllableScale: CGFloat {
        guard !accessibilityReduceMotion else { return 1 }
        if let motionProfile {
            // The authored syllable duration decides whether the long-tone
            // motion profile applies; no separate emphasis metadata exists.
            return CGFloat(
                motionProfile.emphasisScaleRange.upperBound
            )
        }
        if let playbackScaleRange {
            return playbackScaleRange.upperBound
        }
        return 1 + CGFloat(settings.lyricsLongToneExpansionAmount)
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

        let glowTailDuration = (motionProfile != nil
            || settings.lyricsGlowEnabled)
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
