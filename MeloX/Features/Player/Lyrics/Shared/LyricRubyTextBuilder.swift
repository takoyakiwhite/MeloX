import SwiftUI

@MainActor
enum LyricRubyTextBuilder {
    static func romanizationText(
        from units: [LyricRubyPlacementUnit]
    ) -> Text {
        units.reduce(Text(verbatim: "")) { result, unit in
            guard let romanization = unit.lyric.romanizationText else {
                return result
            }
            let fragment: Text
            if hasTimedRomanization(unit.lyric) {
                fragment = timedText(
                    syllables:
                        unit.lyric.romanizationSyllables
                )
            } else {
                fragment = Text(verbatim: romanization)
            }
            let placedFragment = fragment.customAttribute(
                LyricRubyPlacementTextAttribute(
                    horizontalOffset: unit.romanizationOffset
                )
            )
            return Text("\(result)\(placedFragment)")
        }
    }

    static func hasTimedRomanization(
        _ unit: LyricRubyUnit
    ) -> Bool {
        guard unit.hasAuthoredRomanizationTiming,
              let source = unit.romanizationText else {
            return false
        }
        let syllables = unit.romanizationSyllables.filter {
            !$0.text.isEmpty
        }
        return !syllables.isEmpty
            && syllables.map(\.text).joined() == source
    }

    private static func timedText(
        syllables: [LyricSyllable]
    ) -> Text {
        syllables.filter { !$0.text.isEmpty }.reduce(
            Text(verbatim: "")
        ) {
            result,
            syllable in
            let isWhitespace = syllable.text.allSatisfy(\.isWhitespace)
            let fragment = Text(verbatim: syllable.text)
                .customAttribute(
                    LyricTimingTextAttribute(
                        startTime: syllable.startTime,
                        endTime: max(
                            syllable.endTime,
                            syllable.startTime
                        ),
                        syllableStartTime: syllable.startTime,
                        syllableEndTime: max(
                            syllable.endTime,
                            syllable.startTime
                        ),
                        characterIndex: 0,
                        characterCount: 1,
                        wordStartTime: syllable.startTime,
                        wordEndTime: max(
                            syllable.endTime,
                            syllable.startTime
                        ),
                        wordCharacterIndex: 0,
                        wordCharacterCount: 1,
                        usesWordTimingForLongTone: false,
                        isWhitespace: isWhitespace
                    )
                )
            return Text("\(result)\(fragment)")
        }
    }
}
