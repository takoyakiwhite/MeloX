import Foundation

enum LyricShareExcerptRangeResolver {
    static func range(
        firstStart: TimeInterval,
        lastStart: TimeInterval,
        lastDuration: TimeInterval?,
        lastSyllableEndTimes: [TimeInterval]
    ) -> ClosedRange<TimeInterval>? {
        guard firstStart.isFinite,
              firstStart >= 0,
              lastStart.isFinite,
              lastStart >= firstStart else {
            return nil
        }

        let syllableEnd = lastSyllableEndTimes
            .filter { $0.isFinite && $0 >= lastStart }
            .max()
        let durationEnd: TimeInterval? = lastDuration.flatMap {
            duration -> TimeInterval? in
            guard duration.isFinite, duration >= 0 else { return nil }
            let end = lastStart + duration
            return end.isFinite ? end : nil
        }

        guard let end = syllableEnd ?? durationEnd,
              end >= firstStart else {
            return nil
        }
        return firstStart...end
    }
}
