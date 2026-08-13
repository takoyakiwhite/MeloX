import Foundation

struct LyricSharePresentation: Identifiable, Hashable {
    let song: Song
    let lyrics: [LyricLine]
    let initialLyricID: LyricLine.ID

    var id: String {
        "\(song.id)-\(initialLyricID)"
    }
}

struct LyricSharePayload: Identifiable {
    let id = UUID()
    let song: Song
    let lyrics: [LyricLine]

    var songURL: URL {
        NeteaseShareResource.song(song).webURL
    }

    var originalLyricsText: String {
        lyrics
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var subject: String {
        "\(song.name) — \(song.artistText)"
    }

    /// The excerpt ends at the last selected row's most specific model timing:
    /// syllable timing first, then its line duration (including inferred LRC
    /// duration). If neither exists, the private lyric payload is unavailable.
    var excerptRange: ClosedRange<TimeInterval>? {
        guard let first = lyrics.first,
              let last = lyrics.last else {
            return nil
        }
        return LyricShareExcerptRangeResolver.range(
            firstStart: first.time,
            lastStart: last.time,
            lastDuration: last.duration,
            lastSyllableEndTimes: last.syllables.map(\.endTime)
        )
    }
}
