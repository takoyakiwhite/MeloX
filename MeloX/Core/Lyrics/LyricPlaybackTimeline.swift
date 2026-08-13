import Foundation

struct LyricPlaybackPosition: Equatable {
    let highlightedLyricID: LyricLine.ID?
    let nextTransitionTime: TimeInterval?
}

struct LyricFocusCascadeLineTiming: Equatable {
    let delay: TimeInterval
    let duration: TimeInterval
}

struct LyricFocusCascadeTiming: Equatable {
    let lineTimingsByLineOrder: [LyricFocusCascadeLineTiming]
    let usesBounce: Bool

    func lineTiming(for lineOrder: Int) -> LyricFocusCascadeLineTiming {
        guard !lineTimingsByLineOrder.isEmpty else {
            return LyricFocusCascadeLineTiming(delay: 0, duration: 0)
        }
        let index = min(
            max(lineOrder, lineTimingsByLineOrder.startIndex),
            lineTimingsByLineOrder.index(
                before: lineTimingsByLineOrder.endIndex
            )
        )
        return lineTimingsByLineOrder[index]
    }
}

enum LyricPlaybackTimeline {
    static func position(
        at playbackTime: TimeInterval,
        in lyrics: [LyricLine]
    ) -> LyricPlaybackPosition {
        guard !lyrics.isEmpty else {
            return LyricPlaybackPosition(
                highlightedLyricID: nil,
                nextTransitionTime: nil
            )
        }

        var lowerBound = lyrics.startIndex
        var upperBound = lyrics.endIndex
        while lowerBound < upperBound {
            let middleIndex = lowerBound + (upperBound - lowerBound) / 2
            if lyrics[middleIndex].time <= playbackTime {
                lowerBound = middleIndex + 1
            } else {
                upperBound = middleIndex
            }
        }

        let highlightedLyricID = lowerBound > lyrics.startIndex
            ? lyrics[lyrics.index(before: lowerBound)].id
            : nil
        let nextTransitionTime = lowerBound < lyrics.endIndex
            ? lyrics[lowerBound].time
            : nil
        return LyricPlaybackPosition(
            highlightedLyricID: highlightedLyricID,
            nextTransitionTime: nextTransitionTime
        )
    }

    static func focusAnimationDuration(
        for highlightedLyricID: LyricLine.ID?,
        in lyrics: [LyricLine]
    ) -> TimeInterval {
        guard let availableDuration = availableFocusDuration(
            for: highlightedLyricID,
            in: lyrics
        ) else {
            return 0.3
        }

        return min(max(availableDuration * 0.35, 0.05), 0.3)
    }

    static func focusCascadeAnimationDuration(
        baseDuration: TimeInterval,
        preferredDuration: TimeInterval
    ) -> TimeInterval {
        let duration = baseDuration.isFinite
            ? max(baseDuration, 0)
            : 0
        let configuredDuration = preferredDuration.isFinite
            ? max(preferredDuration, 0)
            : 0
        return max(duration, configuredDuration)
    }

    static func focusCascadeTiming(
        maximumLineOrder: Int,
        preferredDelayPerLine: TimeInterval,
        preferredDelayIncreasePerLine: TimeInterval,
        followingLineBaseDelay: TimeInterval,
        preferredCatchUpCompletionRatio: Double,
        focusColorLeadTime: TimeInterval,
        baseAnimationDuration: TimeInterval,
        preferredAnimationDuration: TimeInterval,
        prefersBounce: Bool,
        snapThreshold: TimeInterval,
        remainingDuration: TimeInterval?
    ) -> LyricFocusCascadeTiming? {
        guard maximumLineOrder >= 0,
              preferredDelayPerLine.isFinite,
              preferredDelayPerLine >= 0,
              preferredDelayIncreasePerLine.isFinite,
              preferredDelayIncreasePerLine >= 0,
              followingLineBaseDelay.isFinite,
              followingLineBaseDelay >= 0,
              preferredCatchUpCompletionRatio.isFinite,
              focusColorLeadTime.isFinite,
              baseAnimationDuration.isFinite,
              baseAnimationDuration > 0 else {
            return nil
        }
        let delayPerLine = max(preferredDelayPerLine, 0)
        let delayIncreasePerLine = max(preferredDelayIncreasePerLine, 0)
        let baseDelayForFollowingLines = max(followingLineBaseDelay, 0)
        let catchUpCompletionRatio = min(
            max(preferredCatchUpCompletionRatio, 0),
            1
        )
        let fullAnimationDuration = focusCascadeAnimationDuration(
            baseDuration: baseAnimationDuration,
            preferredDuration: preferredAnimationDuration
        )
        guard let fullLineTimings = LyricFocusCascadePlanner.lineTimings(
            maximumLineOrder: maximumLineOrder,
            delayPerLine: delayPerLine,
            delayIncreasePerLine: delayIncreasePerLine,
            followingLineBaseDelay: baseDelayForFollowingLines,
            catchUpCompletionRatio: catchUpCompletionRatio,
            availableDuration: fullAnimationDuration
        ) else {
            return nil
        }
        let fullTiming = LyricFocusCascadeTiming(
            lineTimingsByLineOrder: fullLineTimings,
            usesBounce: prefersBounce
        )
        guard let remainingDuration, remainingDuration.isFinite else {
            return fullTiming
        }

        let availableDuration = remainingDuration
            - max(focusColorLeadTime, 0)
        let effectiveSnapThreshold = snapThreshold.isFinite
            ? max(snapThreshold, 0)
            : 0
        guard availableDuration.isFinite,
              availableDuration > 0,
              availableDuration >= effectiveSnapThreshold else {
            return nil
        }
        // Finish this cascade before the next lyric takes focus so a dense
        // timeline cannot leave the lower rows perpetually catching up.
        let availableAnimationDuration = min(
            fullAnimationDuration,
            availableDuration
        )
        guard let availableLineTimings = LyricFocusCascadePlanner.lineTimings(
            maximumLineOrder: maximumLineOrder,
            delayPerLine: delayPerLine,
            delayIncreasePerLine: delayIncreasePerLine,
            followingLineBaseDelay: baseDelayForFollowingLines,
            catchUpCompletionRatio: catchUpCompletionRatio,
            availableDuration: availableAnimationDuration
        ) else {
            return nil
        }
        return LyricFocusCascadeTiming(
            lineTimingsByLineOrder: availableLineTimings,
            usesBounce:
                prefersBounce
                    && availableAnimationDuration >= fullAnimationDuration
        )
    }

    static func remainingFocusDuration(
        for highlightedLyricID: LyricLine.ID?,
        at playbackTime: TimeInterval,
        in lyrics: [LyricLine]
    ) -> TimeInterval? {
        guard let highlightedLyricID,
              playbackTime.isFinite,
              let index = lyrics.firstIndex(where: { $0.id == highlightedLyricID }) else {
            return nil
        }
        let followingIndex = lyrics.index(after: index)
        guard followingIndex < lyrics.endIndex else { return nil }

        let remainingDuration = lyrics[followingIndex].time - playbackTime
        guard remainingDuration.isFinite else { return nil }
        return max(remainingDuration, 0)
    }

    private static func availableFocusDuration(
        for highlightedLyricID: LyricLine.ID?,
        in lyrics: [LyricLine]
    ) -> TimeInterval? {
        guard let highlightedLyricID,
              let index = lyrics.firstIndex(where: { $0.id == highlightedLyricID }) else {
            return nil
        }

        let followingIndex = lyrics.index(after: index)
        let availableDuration = followingIndex < lyrics.endIndex
            ? lyrics[followingIndex].time - lyrics[index].time
            : lyrics[index].duration
        guard let availableDuration,
              availableDuration.isFinite,
              availableDuration > 0 else {
            return nil
        }
        return availableDuration
    }
}
