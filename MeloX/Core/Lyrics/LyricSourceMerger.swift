import Foundation

struct LyricSourceCollection: Sendable {
    var amllTTML: String?
    var netease: NeteaseLyricPayload?
    var qqMusic: QQLyricPayload?
}

enum LyricSourceMerger {
    static func resolve(
        _ sources: LyricSourceCollection
    ) -> ResolvedLyrics? {
        if let ttml = normalized(sources.amllTTML) {
            let lines = TTMLLyricParser.parse(ttml)
            if !lines.isEmpty {
                return ResolvedLyrics(
                    source: .amll,
                    quality: .amllTTML,
                    lines: lines,
                    isPureMusic: sources.netease?.isPureMusic == true
                )
            }
        }

        if let netease = sources.netease,
           let yrc = normalized(netease.yrc),
           normalized(netease.translatedYRC) != nil
            || normalized(netease.translatedLRC) != nil {
            let lines = LyricParser.parse(
                yrc: yrc,
                lrc: netease.lrc ?? "",
                translatedYRC: netease.translatedYRC ?? "",
                translatedLRC: netease.translatedLRC ?? "",
                romanizedYRC: netease.romanizedYRC ?? "",
                romanizedLRC: netease.romanizedLRC ?? ""
            )
            if !lines.isEmpty {
                return ResolvedLyrics(
                    source: .netease,
                    quality: .neteaseVerbatim,
                    lines: lines,
                    isPureMusic: netease.isPureMusic
                )
            }
        }

        if let qqMusic = sources.qqMusic,
           let qrc = normalized(qqMusic.verbatim) {
            let normalizedQRC = QRCLyricNormalizer.normalize(qrc)
            let normalizedRomanization = qqMusic.romanization.map(
                QRCLyricNormalizer.normalize
            ) ?? ""
            let lines = LyricParser.parse(
                yrc: normalizedQRC,
                lrc: qqMusic.lineSynchronized ?? "",
                translatedLRC: qqMusic.translation ?? "",
                romanizedYRC: normalizedRomanization,
                romanizedLRC: qqMusic.romanization ?? "",
                duetLRC: sources.netease?.lrc
            )
            if !lines.isEmpty {
                return ResolvedLyrics(
                    source: .qqMusic,
                    quality: .qqMusicVerbatim,
                    lines: lines,
                    isPureMusic: sources.netease?.isPureMusic == true
                )
            }
        }

        if let netease = sources.netease,
           let lrc = normalized(netease.lrc) {
            let lines = LyricParser.parse(
                yrc: "",
                lrc: lrc,
                translatedLRC: netease.translatedLRC ?? "",
                romanizedLRC: netease.romanizedLRC ?? ""
            )
            if !lines.isEmpty {
                return ResolvedLyrics(
                    source: .netease,
                    quality: .neteaseLineSynchronized,
                    lines: lines,
                    isPureMusic: netease.isPureMusic
                )
            }
        }

        if let qqMusic = sources.qqMusic,
           let lrc = normalized(qqMusic.lineSynchronized) {
            let lines = LyricParser.parse(
                yrc: "",
                lrc: lrc,
                translatedLRC: qqMusic.translation ?? "",
                romanizedLRC: qqMusic.romanization ?? "",
                duetLRC: sources.netease?.lrc
            )
            if !lines.isEmpty {
                return ResolvedLyrics(
                    source: .qqMusic,
                    quality: .qqMusicLineSynchronized,
                    lines: lines,
                    isPureMusic: sources.netease?.isPureMusic == true
                )
            }
        }

        if sources.netease?.isPureMusic == true {
            return ResolvedLyrics(
                source: .netease,
                quality: .fallback,
                lines: [
                    LyricLine(
                        time: 0,
                        text: "纯音乐，请欣赏"
                    )
                ],
                isPureMusic: true
            )
        }
        return nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}
