import Foundation

struct LyricSyllable: Identifiable, Hashable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval

    var id: String {
        "\(startTime)-\(endTime)-\(text)"
    }
}

enum LyricLineTimingKind: Hashable, Sendable {
    /// The line carries an authored content duration, usually from YRC.
    case precise

    /// LRC only tells us when this line is replaced by the next one. Its
    /// inferred display duration must not be treated as sung-content timing.
    case lineSynchronized
}

struct LyricLine: Identifiable, Hashable {
    let id: String
    let time: TimeInterval
    let duration: TimeInterval?
    let timingKind: LyricLineTimingKind
    let text: String
    let syllables: [LyricSyllable]
    let romanization: String?
    let romanizationSyllables: [LyricSyllable]
    let translation: String?

    init(
        id: String? = nil,
        time: TimeInterval,
        duration: TimeInterval? = nil,
        timingKind: LyricLineTimingKind = .precise,
        text: String,
        syllables: [LyricSyllable] = [],
        romanization: String? = nil,
        romanizationSyllables: [LyricSyllable] = [],
        translation: String? = nil
    ) {
        self.id = id ?? Self.fallbackID(
            time: time,
            text: text
        )
        self.time = time
        self.duration = duration
        self.timingKind = timingKind
        self.text = text
        self.syllables = syllables
        self.romanization = romanization
        self.romanizationSyllables = romanizationSyllables
        self.translation = translation
    }

    init(
        id: String,
        copying line: LyricLine
    ) {
        self.init(
            id: id,
            time: line.time,
            duration: line.duration,
            timingKind: line.timingKind,
            text: line.text,
            syllables: line.syllables,
            romanization: line.romanization,
            romanizationSyllables: line.romanizationSyllables,
            translation: line.translation
        )
    }

    var isSyllableSynced: Bool {
        !syllables.isEmpty
    }

    static func fallbackID(
        time: TimeInterval,
        text: String
    ) -> String {
        "line:\(time.bitPattern):\(Self.stableTextHash(text))"
    }

    static func stableTextHash(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    var hasTranslation: Bool {
        guard let translation else { return false }
        return !translation
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    var hasRomanization: Bool {
        guard let romanization else { return false }
        return !romanization
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    func makePseudoSyllables() -> [LyricSyllable] {
        guard syllables.isEmpty,
              let duration,
              duration > 0 else { return [] }

        let characters = Array(text)
        guard !characters.isEmpty else { return [] }

        let characterDuration = duration / Double(characters.count)
        return characters.enumerated().map { index, character in
            let startTime = time + Double(index) * characterDuration
            return LyricSyllable(
                text: String(character),
                startTime: startTime,
                endTime: startTime + characterDuration
            )
        }
    }

    func attachingTranslation(_ translation: String?) -> LyricLine {
        LyricLine(
            id: id,
            time: time,
            duration: duration,
            timingKind: timingKind,
            text: text,
            syllables: syllables,
            romanization: romanization,
            romanizationSyllables: romanizationSyllables,
            translation: translation
        )
    }

    func attachingRomanization(
        _ romanization: String?,
        romanizationSyllables: [LyricSyllable] = []
    ) -> LyricLine {
        LyricLine(
            id: id,
            time: time,
            duration: duration,
            timingKind: timingKind,
            text: text,
            syllables: syllables,
            romanization: romanization,
            romanizationSyllables: romanizationSyllables,
            translation: translation
        )
    }

    func accessibilityText(
        includingTranslation: Bool,
        includingRomanization: Bool = false
    ) -> String {
        var components = [text]
        if includingRomanization, hasRomanization,
           let romanization {
            components.append("发音：\(romanization)")
        }
        if includingTranslation, hasTranslation,
           let translation {
            components.append("翻译：\(translation)")
        }
        return components.joined(separator: "，")
    }
}
