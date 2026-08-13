import SwiftUI

struct DesktopLyricLineView: View {
    private static let annotationSpacing =
        LyricAnnotationMetrics.verticalSpacing

    @Environment(DesktopAppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    let line: LyricLine
    let isPlaybackLine: Bool
    let isActualPlaybackLine: Bool
    let isScaleFocused: Bool
    let isPrecedingFocusLine: Bool
    let isFollowingFocusLine: Bool
    let actualHighlightedLyricID: LyricLine.ID?
    let visualHighlightedLyricID: LyricLine.ID?
    let focusColorTransition: LyricFocusColorTransition?
    let movementPhase: LyricMovementPhase
    let layoutWidth: CGFloat
    let visualFocusAnchorY: CGFloat
    let compact: Bool
    let allowsLyricBlur: Bool
    let foregroundColor: Color
    let hasTranslations: Bool
    let hasRomanizations: Bool
    let hasSyllableSyncedLyrics: Bool
    let onAnnotationHeightChange: (CGFloat) -> Void
    let onSeek: () -> Void

    var body: some View {
        let fontSize = compact ? min(lyricFontSize, 23) : lyricFontSize
        let romanizationFontSize = max(
            fontSize * CGFloat(model.settings.lyricsRomanizationFontScale),
            compact ? 11 : 13
        )
        let showsTranslation = showsLyricTranslation(
            isFocusedLine: isScaleFocused
        )
        let showsRomanization = showsLyricRomanization(
            isFocusedLine: isScaleFocused
        )
        let reservesAnnotationSpace = (
            model.settings.lyricsRomanizationEnabled
                && hasRomanizations
        ) || (
            model.settings.lyricsTranslationEnabled
                && hasTranslations
        )
        let annotationHeight = lyricAnnotationStrideHeight(
            fontSize: fontSize,
            romanizationFontSize: romanizationFontSize,
            reservesAnnotationSpace: reservesAnnotationSpace
        )
        let lineSpacing = DesktopLyricsLayoutMetrics.lineSpacing(
            setting: model.settings.lyricsLineSpacing,
            compact: compact
        )
        let lyricStride = max(
            fontSize * 1.2
                + annotationHeight
                + lineSpacing,
            1
        )
        let currentLineScale = lyricsCurrentLineScale
        let focusScaleAnimation = DesktopLyricsAnimations
            .focusScaleAnimation(
                settings: model.settings,
                highlightedID: actualHighlightedLyricID,
                lyrics: model.lyrics.lyrics,
                reduceMotion: reduceMotion,
                isFocused: isScaleFocused
            )
        let focusEffectAnimation = DesktopLyricsAnimations
            .focusEffectAnimation(
                highlightedID: visualHighlightedLyricID,
                lyrics: model.lyrics.lyrics,
                reduceMotion: reduceMotion
            )
        let focusBlurRadius = allowsLyricBlur ? self.focusBlurRadius : 0
        let blurIntensity = CGFloat(model.settings.lyricsBlurIntensity)
        let distanceBlurScale = allowsLyricBlur
            ? CGFloat(model.settings.lyricsDistanceBlurScale)
            : 0
        let dimAmount = min(max(model.settings.lyricsDimAmount, 0), 1)
        let isLineHovered = isHovered

        DesktopTargetDrivenLyricBlur(
            focusRadius: focusBlurRadius,
            focusAnimation: focusEffectAnimation,
            isHovered: isLineHovered
        ) {
            LifecycleAwareLyricMovement(phase: movementPhase) {
                movementOffset in
                LifecycleAwareLyricFocusColor(
                    lyricID: line.id,
                    focusedLyricID: visualHighlightedLyricID,
                    transition: focusColorTransition
                ) { focusProgress in
                    Button {
                        if model.settings.lyricsTapToSeek {
                            onSeek()
                            model.player.seek(to: line.time)
                        }
                    } label: {
                        SynchronizedLyricText(
                            line: line,
                            isPlaybackLine: isPlaybackLine,
                            playbackFocusProgress: focusProgress,
                            usesPseudoTiming:
                                model.settings.lyricsPseudoWordByWord
                                    && !hasSyllableSyncedLyrics,
                            allowsUnplayedBlur: allowsLyricBlur,
                            fontSize: fontSize,
                            romanizationFontSize: romanizationFontSize,
                            fontWeight: model.settings.lyricsFontWeight,
                            alignment: .resolved(
                                for: line,
                                duetLayoutEnabled:
                                    model.settings.lyricsDuetLayoutEnabled
                            ),
                            primaryColor: foregroundColor,
                            showsTranslation: showsTranslation,
                            showsRomanization: showsRomanization,
                            includesRomanization: true,
                            reservesAnnotationSpace: reservesAnnotationSpace,
                            onAnnotationHeightChange:
                                onAnnotationHeightChange,
                            annotationLayoutAnimation:
                                lyricAnnotationLayoutAnimation(),
                            annotationVisibilityAnimation:
                                lyricAnnotationVisibilityAnimation(
                                    focusScaleAnimation: focusScaleAnimation
                                ),
                            visualScale:
                                isScaleFocused ? currentLineScale : 1,
                            visualScaleAnimation: focusScaleAnimation,
                            promotedLayoutScale: currentLineScale,
                            layoutWidth: layoutWidth
                        )
                        .environment(model.player)
                        .environment(model.settings)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(
                        isHovered
                            ? 1
                            : lyricEmphasis(
                                focusProgress: focusProgress,
                                dimAmount: dimAmount
                            )
                    )
                    .visualEffect { content, geometry in
                        let frame = geometry.frame(
                            in: .scrollView(axis: .vertical)
                        )
                        let distance = abs(
                            frame.midY
                                + movementOffset
                                - visualFocusAnchorY
                        )
                        let blurRadius = Self.lyricDistanceBlurRadius(
                            forPixelDistance: distance,
                            lyricStride: lyricStride,
                            intensity: blurIntensity * distanceBlurScale,
                            focusProgress: focusProgress
                        )
                        let opacity = Self.lyricDistanceOpacity(
                            forPixelDistance: distance,
                            lyricStride: lyricStride,
                            dimAmount: dimAmount,
                            focusProgress: focusProgress
                        )
                        return content
                            .blur(
                                radius: isLineHovered ? 0 : blurRadius
                            )
                            .opacity(isLineHovered ? 1 : opacity)
                            .offset(y: movementOffset)
                    }
                }
            }
        }
        .contentShape(.rect)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                isHovered = true
            case .ended:
                isHovered = false
            }
        }
        .accessibilityLabel(
            line.accessibilityText(
                includingTranslation:
                    model.settings.lyricsTranslationEnabled
                        && showsTranslation,
                includingRomanization:
                    model.settings.lyricsRomanizationEnabled
                        && showsRomanization
            )
        )
        .accessibilityValue(isActualPlaybackLine ? "当前歌词" : "")
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.16),
            value: isHovered
        )
    }

    private var lyricFontSize: CGFloat {
        CGFloat(model.settings.lyricsFontSize)
    }

    private var lyricsCurrentLineScale: CGFloat {
        CGFloat(
            min(
                max(
                    model.settings.lyricsCurrentLineScale,
                    AppSettings.lyricsCurrentLineScaleRange.lowerBound
                ),
                AppSettings.lyricsCurrentLineScaleRange.upperBound
            )
        )
    }

    private var focusBlurRadius: CGFloat {
        let preceding: CGFloat = isPrecedingFocusLine ? 2.4 : 0
        let following: CGFloat = isFollowingFocusLine ? 0.7 : 0
        return (preceding + following)
            * CGFloat(model.settings.lyricsBlurIntensity)
    }

    private func showsLyricTranslation(
        isFocusedLine: Bool
    ) -> Bool {
        switch model.settings.lyricsTranslationDisplayMode {
        case .focusedLine: isFocusedLine
        case .allLines: true
        }
    }

    private func showsLyricRomanization(
        isFocusedLine: Bool
    ) -> Bool {
        switch model.settings.lyricsRomanizationDisplayMode {
        case .focusedLine: isFocusedLine
        case .allLines: true
        }
    }

    private func lyricAnnotationStrideHeight(
        fontSize: CGFloat,
        romanizationFontSize: CGFloat,
        reservesAnnotationSpace: Bool
    ) -> CGFloat {
        guard reservesAnnotationSpace else { return 0 }
        let displaysRomanizations = model.settings.lyricsRomanizationEnabled
            && hasRomanizations
        let displaysTranslations = model.settings.lyricsTranslationEnabled
            && hasTranslations
        let romanizationHeight = displaysRomanizations
            ? romanizationFontSize * 1.2 + Self.annotationSpacing
            : 0
        let translationHeight = displaysTranslations
            ? max(
                fontSize
                    * CGFloat(
                        model.settings.lyricsTranslationFontScale
                    ),
                compact ? 11 : 13
            ) * 1.2 + Self.annotationSpacing
            : 0
        return romanizationHeight + translationHeight
    }

    private func lyricAnnotationVisibilityAnimation(
        focusScaleAnimation: Animation?
    ) -> Animation? {
        guard !reduceMotion else { return nil }
        if usesFocusedLineAnnotationMode {
            return focusScaleAnimation
        }
        let duration = min(
            max(model.settings.lyricsFocusCascadeDuration * 0.7, 0.16),
            0.32
        )
        return .smooth(duration: duration)
    }

    private func lyricAnnotationLayoutAnimation() -> Animation? {
        guard !reduceMotion else { return nil }
        let duration = usesFocusedLineAnnotationMode
            ? DesktopLyricsAnimations.focusScaleDuration(
                settings: model.settings,
                highlightedID: actualHighlightedLyricID,
                lyrics: model.lyrics.lyrics
            )
            : min(
                max(model.settings.lyricsFocusCascadeDuration * 0.7, 0.16),
                0.32
            )
        return .smooth(duration: duration)
    }

    private var usesFocusedLineAnnotationMode: Bool {
        (
            model.settings.lyricsRomanizationEnabled
                && model.settings.lyricsRomanizationDisplayMode
                    == .focusedLine
        ) || (
            model.settings.lyricsTranslationEnabled
                && model.settings.lyricsTranslationDisplayMode
                    == .focusedLine
        )
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
        let normalizedFocusProgress = min(max(focusProgress, 0), 1)
        return baseRadius * intensity * (1 - normalizedFocusProgress)
    }

    nonisolated private static func lyricDistanceOpacity(
        forPixelDistance distance: CGFloat,
        lyricStride: CGFloat,
        dimAmount: Double,
        focusProgress: CGFloat
    ) -> Double {
        let lineDistance = Double(distance / lyricStride)
        let baseOpacity: Double = switch lineDistance {
        case ...1:
            1 - lineDistance * 0.44
        case ...2:
            0.56 - (lineDistance - 1) * 0.22
        default:
            max(0.12, 0.34 - (lineDistance - 2) * 0.07)
        }
        let distanceOpacity = 1 - (1 - baseOpacity) * dimAmount
        let normalizedFocusProgress = Double(
            min(max(focusProgress, 0), 1)
        )
        return distanceOpacity
            + (1 - distanceOpacity) * normalizedFocusProgress
    }

    private func lyricEmphasis(
        focusProgress: CGFloat,
        dimAmount: Double
    ) -> Double {
        let unfocusedOpacity = 1 - (1 - 0.52) * dimAmount
        let normalizedFocusProgress = Double(
            min(max(focusProgress, 0), 1)
        )
        return unfocusedOpacity
            + (1 - unfocusedOpacity) * normalizedFocusProgress
    }
}
