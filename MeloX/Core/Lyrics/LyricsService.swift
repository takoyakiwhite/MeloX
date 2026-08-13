import Foundation

@MainActor
final class LyricsService {
    private enum FetchEvent: Sendable {
        case amll(String)
        case netease(NeteaseLyricPayload)
        case qqMusic(QQLyricPayload)
    }

    private struct CacheKey: Hashable {
        let song: LyricsSongMetadata
        let usesAMLL: Bool
        let usesQQMusic: Bool
    }

    private let api: NeteaseAPI
    private let settings: AppSettings
    private let amllClient: AMLLLyricsClient
    private let qqMusicClient: QQMusicLyricsClient
    private var cache: [CacheKey: ResolvedLyrics] = [:]
    private var cacheOrder: [CacheKey] = []

    init(
        api: NeteaseAPI,
        settings: AppSettings,
        amllClient: AMLLLyricsClient = AMLLLyricsClient(),
        qqMusicClient: QQMusicLyricsClient = QQMusicLyricsClient()
    ) {
        self.api = api
        self.settings = settings
        self.amllClient = amllClient
        self.qqMusicClient = qqMusicClient
    }

    func load(
        for song: LyricsSongMetadata,
        onUpdate: @MainActor (ResolvedLyrics) -> Void
    ) async throws -> ResolvedLyrics {
        let usesAMLL = settings.lyricsAMLLSourceEnabled
        let usesQQMusic = settings.lyricsQQMusicSourceEnabled
        let cacheKey = CacheKey(
            song: song,
            usesAMLL: usesAMLL,
            usesQQMusic: usesQQMusic
        )
        var latest = cache[cacheKey]
        if let cached = latest {
            onUpdate(cached)
        }

        let api = api
        let amllClient = amllClient
        let qqMusicClient = qqMusicClient
        var sources = LyricSourceCollection()

        await withTaskGroup(of: FetchEvent?.self) { group in
            group.addTask {
                guard let payload = try? await api.neteaseLyrics(id: song.id) else {
                    return nil
                }
                return .netease(payload)
            }
            if usesAMLL {
                group.addTask {
                    guard let ttml = try? await amllClient.lyrics(songID: song.id) else {
                        return nil
                    }
                    return .amll(ttml)
                }
            }
            if usesQQMusic {
                group.addTask {
                    guard let payload = try? await qqMusicClient.lyrics(for: song) else {
                        return nil
                    }
                    return .qqMusic(payload)
                }
            }

            for await event in group {
                guard !Task.isCancelled, let event else { continue }
                switch event {
                case .amll(let ttml):
                    sources.amllTTML = ttml
                case .netease(let payload):
                    sources.netease = payload
                case .qqMusic(let payload):
                    sources.qqMusic = payload
                }

                guard let resolved = LyricSourceMerger.resolve(sources),
                      resolved != latest,
                      latest.map({ resolved.quality.rawValue >= $0.quality.rawValue }) ?? true else {
                    continue
                }
                latest = resolved
                onUpdate(resolved)
            }
        }

        try Task.checkCancellation()
        guard let latest else { throw LyricSourceError.noLyrics }
        store(latest, for: cacheKey)
        return latest
    }

    private func store(_ lyrics: ResolvedLyrics, for key: CacheKey) {
        cache[key] = lyrics
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        while cacheOrder.count > 48 {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }
}
