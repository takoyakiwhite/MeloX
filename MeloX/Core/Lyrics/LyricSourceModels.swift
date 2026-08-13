import Foundation

enum LyricSource: String, Hashable, Sendable {
    case amll
    case netease
    case qqMusic

    var title: String {
        switch self {
        case .amll: "AMLL"
        case .netease: "网易云音乐"
        case .qqMusic: "QQ 音乐"
        }
    }
}

struct ResolvedLyrics: Hashable, Sendable {
    let source: LyricSource
    let quality: LyricQuality
    let lines: [LyricLine]
    let isPureMusic: Bool
}

enum LyricQuality: Int, Hashable, Sendable {
    case fallback
    case qqMusicLineSynchronized
    case neteaseLineSynchronized
    case qqMusicVerbatim
    case neteaseVerbatim
    case amllTTML
}

struct LyricsSongMetadata: Hashable, Sendable {
    let id: Int
    let title: String
    let album: String
    let artist: String
    let durationSeconds: Int

    init(song: Song) {
        id = song.id
        title = song.name
        album = song.album?.name ?? ""
        artist = song.artists.map(\.name).joined(separator: ",")
        durationSeconds = max(song.durationMS / 1_000, 0)
    }
}

struct NeteaseLyricPayload: Sendable {
    let yrc: String?
    let lrc: String?
    let translatedYRC: String?
    let translatedLRC: String?
    let romanizedYRC: String?
    let romanizedLRC: String?
    let isPureMusic: Bool
}

struct QQLyricPayload: Sendable {
    let verbatim: String?
    let lineSynchronized: String?
    let translation: String?
    let romanization: String?
}

enum LyricSourceError: LocalizedError {
    case invalidResponse
    case noLyrics

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "歌词服务返回了无法识别的数据。"
        case .noLyrics:
            "当前歌曲暂无滚动歌词。"
        }
    }
}
