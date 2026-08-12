import SwiftUI

enum AppleMusicLyricsPlaybackFocus: Hashable {
    case lyric(LyricLine.ID)
    case interlude(LyricInterlude.ID)

    var lyricID: LyricLine.ID? {
        guard case let .lyric(id) = self else { return nil }
        return id
    }

    var interludeID: LyricInterlude.ID? {
        guard case let .interlude(id) = self else { return nil }
        return id
    }
}

struct AppleMusicLyricsFocusCoordinator: View {
    @Environment(PlayerStore.self) private var player
    @Environment(AppSettings.self) private var settings

    let lyrics: [LyricLine]
    let interludes: [LyricInterlude]
    @Binding var playbackFocus: AppleMusicLyricsPlaybackFocus?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: player.lyricsTimingRevision) {
                synchronizeImmediately()
            }
            .task(id: synchronizationTrigger) {
                await synchronizeAtTransitions()
            }
    }

    private var synchronizationTrigger:
        AppleMusicLyricsFocusSynchronizationTrigger {
        AppleMusicLyricsFocusSynchronizationTrigger(
            songID: player.currentSong?.id,
            seekRevision: player.seekRevision,
            isPlaying: player.isPlaying,
            isEnabled: settings.lyricsInterludeCountdownEnabled,
            advanceTime: advanceTime,
            lyricCount: lyrics.count,
            firstLyricID: lyrics.first?.id,
            lastLyricID: lyrics.last?.id,
            interludeCount: interludes.count,
            firstInterludeID: interludes.first?.id,
            lastInterludeID: interludes.last?.id
        )
    }

    private func synchronizeImmediately() {
        let position = playbackPosition(
            at: player.estimatedProgress()
                + advanceTime
        )
        updatePlaybackFocus(to: position.focus)
    }

    private func synchronizeAtTransitions() async {
        while !Task.isCancelled {
            let adjustedProgress = player.estimatedProgress()
                + advanceTime
            let position = playbackPosition(at: adjustedProgress)
            updatePlaybackFocus(to: position.focus)

            guard player.isPlaying,
                  let nextTransitionTime = position.nextTransitionTime else {
                return
            }

            let remainingTime = nextTransitionTime
                - (
                    player.estimatedProgress()
                        + advanceTime
                )
            guard remainingTime > 0 else {
                await Task.yield()
                continue
            }

            do {
                try await Task.sleep(for: .seconds(remainingTime))
            } catch {
                return
            }
        }
    }

    private func playbackPosition(
        at playbackTime: TimeInterval
    ) -> AppleMusicLyricsPlaybackFocusPosition {
        let lyricPosition = LyricPlaybackTimeline.position(
            at: playbackTime,
            in: lyrics
        )
        let interludePosition = settings.lyricsInterludeCountdownEnabled
            ? LyricInterludeTimeline.position(
                at: playbackTime,
                in: interludes
            )
            : LyricInterludePlaybackPosition(
                activeInterludeID: nil,
                nextTransitionTime: nil
            )
        let activeInterlude = interludePosition.activeInterludeID
            .flatMap { activeInterludeID in
                interludes.first { $0.id == activeInterludeID }
            }
        let focus: AppleMusicLyricsPlaybackFocus?
        let interludeHandoffTime: TimeInterval?
        if let activeInterlude,
           lyricPosition.highlightedLyricID
            != activeInterlude.followingLyricID {
            if playbackTime < activeInterlude.countdownEndTime {
                focus = .interlude(activeInterlude.id)
                interludeHandoffTime = activeInterlude.countdownEndTime
            } else {
                // The dots finish slightly before the lyric starts. Begin the
                // same promotion used by an ordinary lyric change during this
                // handoff window instead of leaving an empty focused row.
                focus = .lyric(activeInterlude.followingLyricID)
                interludeHandoffTime = nil
            }
        } else {
            focus = lyricPosition.highlightedLyricID.map {
                .lyric($0)
            }
            interludeHandoffTime = nil
        }
        let nextTransitionTime = [
            lyricPosition.nextTransitionTime,
            interludePosition.nextTransitionTime,
            interludeHandoffTime,
        ]
        .compactMap { $0 }
        .min()

        return AppleMusicLyricsPlaybackFocusPosition(
            focus: focus,
            nextTransitionTime: nextTransitionTime
        )
    }

    private func updatePlaybackFocus(
        to focus: AppleMusicLyricsPlaybackFocus?
    ) {
        guard playbackFocus != focus else { return }
        playbackFocus = focus
    }

    private var advanceTime: TimeInterval {
        settings.effectiveLyricsAdvanceTime(for: lyrics)
    }
}

struct AppleMusicLyricInterludeView: View {
    @Environment(\.accessibilityReduceMotion)
    private var accessibilityReduceMotion
    @Environment(\.effectiveLyricsRefreshRate)
    private var effectiveLyricsRefreshRate
    @Environment(PlayerStore.self) private var player

    let interlude: LyricInterlude
    let advanceTime: TimeInterval
    let fontSize: CGFloat
    let onInterfaceInteraction: (() -> Void)?

    var body: some View {
        Group {
            if accessibilityReduceMotion {
                dots(
                    presentation: presentation(
                        at: player.estimatedProgress()
                            + advanceTime
                    )
                )
            } else {
                TimelineView(
                    .animation(
                        minimumInterval:
                            effectiveLyricsRefreshRate.minimumInterval,
                        paused: !player.isPlaying
                    )
                ) { timeline in
                    dots(
                        presentation: presentation(
                            at: player.estimatedProgress(
                                at: timeline.date
                            ) + advanceTime
                        )
                    )
                }
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: dotDiameter,
            alignment: .leading
        )
        .contentShape(.rect)
        .onTapGesture {
            onInterfaceInteraction?()
        }
        .accessibilityHidden(true)
    }

    private var dotDiameter: CGFloat {
        max(fontSize * 0.5, 10)
    }

    private var dotSpacing: CGFloat {
        max(fontSize * 0.35, 7)
    }

    private func dots(
        presentation: AppleMusicInterludeDotsPresentation
    ) -> some View {
        HStack(spacing: dotSpacing) {
            ForEach(presentation.dotOpacities.indices, id: \.self) {
                index in
                Circle()
                    .fill(
                        .white.opacity(
                            presentation.dotOpacities[index]
                        )
                    )
                    .frame(
                        width: dotDiameter,
                        height: dotDiameter
                    )
                    .scaleEffect(
                        presentation.dotScales[index]
                    )
            }
        }
        .scaleEffect(
            presentation.scale,
            anchor: .leading
        )
        .opacity(presentation.opacity)
    }

    private func presentation(
        at playbackTime: TimeInterval
    ) -> AppleMusicInterludeDotsPresentation {
        return AppleMusicInterludeDotsPresentation.make(
            playbackTime: playbackTime,
            interlude: interlude,
            reducesMotion: accessibilityReduceMotion
        )
    }
}

private struct AppleMusicLyricsFocusSynchronizationTrigger: Hashable {
    let songID: Int?
    let seekRevision: Int
    let isPlaying: Bool
    let isEnabled: Bool
    let advanceTime: TimeInterval
    let lyricCount: Int
    let firstLyricID: LyricLine.ID?
    let lastLyricID: LyricLine.ID?
    let interludeCount: Int
    let firstInterludeID: LyricInterlude.ID?
    let lastInterludeID: LyricInterlude.ID?
}

private struct AppleMusicLyricsPlaybackFocusPosition {
    let focus: AppleMusicLyricsPlaybackFocus?
    let nextTransitionTime: TimeInterval?
}

private struct AppleMusicInterludeDotsPresentation {
    private static let dotCount = 3
    private static let entryDelay: TimeInterval = 0.5
    private static let entryFadeDuration: TimeInterval = 0.5
    private static let entryScaleDuration: TimeInterval = 2
    private static let exitScaleDuration: TimeInterval = 0.75
    private static let exitFadeDuration: TimeInterval = 0.375
    private static let targetBreatheDuration: TimeInterval = 1.5
    private static let baseScale = 0.7

    let dotOpacities: [Double]
    let dotScales: [CGFloat]
    let scale: CGFloat
    let opacity: Double

    static func make(
        playbackTime: TimeInterval,
        interlude: LyricInterlude,
        reducesMotion: Bool
    ) -> AppleMusicInterludeDotsPresentation {
        let duration = max(
            interlude.countdownEndTime - interlude.startTime,
            0.001
        )
        let elapsed = clamped(
            playbackTime - interlude.startTime,
            minimum: 0,
            maximum: duration
        )
        let remaining = interlude.countdownEndTime - playbackTime
        guard playbackTime < interlude.countdownEndTime else {
            return AppleMusicInterludeDotsPresentation(
                dotOpacities: Array(repeating: 0, count: dotCount),
                dotScales: Array(repeating: 1, count: dotCount),
                scale: 0,
                opacity: 0
            )
        }

        let dotsDuration = max(duration - exitScaleDuration, 0.001)
        let dotOpacities = (0..<dotCount).map { index in
            let segmentOffset =
                dotsDuration * Double(index) / Double(dotCount)
            let progress =
                (
                    (elapsed - segmentOffset)
                        * Double(dotCount)
                        / dotsDuration
                ) * 0.75
            return clamped(
                progress,
                minimum: 0.25,
                maximum: 1
            )
        }
        let thirdDotProgress = smoothStep(
            clamped(
                (dotOpacities[dotCount - 1] - 0.25) / 0.75,
                minimum: 0,
                maximum: 1
            )
        )
        let dotScales = (0..<dotCount).map { index in
            guard index == dotCount - 1, !reducesMotion else {
                return CGFloat(1)
            }
            return CGFloat(1 + thirdDotProgress * 0.26)
        }
        var globalOpacity: Double
        switch elapsed {
        case ..<entryDelay:
            globalOpacity = 0
        case ..<(entryDelay + entryFadeDuration):
            globalOpacity =
                (elapsed - entryDelay) / entryFadeDuration
        default:
            globalOpacity = 1
        }
        if remaining < exitFadeDuration {
            globalOpacity *= clamped(
                remaining / exitFadeDuration,
                minimum: 0,
                maximum: 1
            )
        }

        let scale: Double
        if reducesMotion {
            scale = baseScale
        } else {
            let breatheCount = max(
                ceil(duration / targetBreatheDuration),
                1
            )
            let breatheDuration = duration / breatheCount
            var animatedScale =
                sin(
                    1.5 * .pi
                        - (elapsed / breatheDuration) * 2
                ) / 20 + 1

            if elapsed < entryScaleDuration {
                animatedScale *= easeOutExpo(
                    elapsed / entryScaleDuration
                )
            }
            if remaining < exitScaleDuration {
                let exitProgress =
                    (exitScaleDuration - remaining)
                        / exitScaleDuration
                        / 2
                animatedScale *= 1 - easeInOutBack(
                    clamped(
                        exitProgress,
                        minimum: 0,
                        maximum: 0.5
                    )
                )
            }
            scale = max(animatedScale, 0) * baseScale
        }

        return AppleMusicInterludeDotsPresentation(
            dotOpacities: dotOpacities,
            dotScales: dotScales,
            scale: CGFloat(scale),
            opacity: clamped(
                globalOpacity,
                minimum: 0,
                maximum: 1
            )
        )
    }

    private static func smoothStep(_ value: Double) -> Double {
        value * value * (3 - 2 * value)
    }

    private static func easeOutExpo(_ value: Double) -> Double {
        value >= 1 ? 1 : 1 - pow(2, -10 * value)
    }

    private static func easeInOutBack(_ value: Double) -> Double {
        let firstCoefficient = 1.70158
        let secondCoefficient = firstCoefficient * 1.525
        if value < 0.5 {
            return (
                pow(2 * value, 2)
                    * (
                        (secondCoefficient + 1) * 2 * value
                            - secondCoefficient
                    )
            ) / 2
        }
        return (
            pow(2 * value - 2, 2)
                * (
                    (secondCoefficient + 1) * (value * 2 - 2)
                        + secondCoefficient
                )
                + 2
        ) / 2
    }

    private static func clamped(
        _ value: Double,
        minimum: Double,
        maximum: Double
    ) -> Double {
        min(max(value, minimum), maximum)
    }
}
