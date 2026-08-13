import Observation
import SwiftUI

@MainActor
@Observable
private final class DesktopSearchStore {
    var query = ""
    var kind: SearchKind = .songs
    var source: DesktopSearchSource = .catalog
    private(set) var payload: SearchPayload?
    private(set) var isSearching = false
    private(set) var errorMessage: String?

    @ObservationIgnored
    private var activeSearchID: UUID?

    func search(using model: DesktopAppModel) async {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            activeSearchID = nil
            isSearching = false
            payload = nil
            errorMessage = nil
            return
        }

        let searchID = UUID()
        activeSearchID = searchID
        isSearching = true
        errorMessage = nil
        defer {
            if activeSearchID == searchID {
                isSearching = false
            }
        }

        do {
            let loadedPayload: SearchPayload
            if source == .catalog {
                loadedPayload = try await model.api.search(
                    keyword,
                    kind: kind,
                    limit: 60
                )
            } else {
                loadedPayload = libraryPayload(
                    matching: keyword,
                    model: model
                )
            }
            guard activeSearchID == searchID else { return }
            payload = loadedPayload
        } catch is CancellationError {
            return
        } catch {
            guard activeSearchID == searchID else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func libraryPayload(
        matching keyword: String,
        model: DesktopAppModel
    ) -> SearchPayload {
        let library = model.library
        let songs = unique(
            library.favoriteSongs
                + (model.settings.isContentFeatureEnabled(
                    .listeningHistory
                ) ? library.recentSongs : []),
            by: \.id
        )
        let matchingSongs = songs.filter {
            matches(
                keyword,
                values: [$0.name, $0.artistText, $0.album?.name]
            )
        }
        let albums = unique(
            library.favoriteAlbums + songs.compactMap(\.album),
            by: \.id
        ).filter {
            matches(keyword, values: [$0.name, $0.artistText])
        }
        let artists = unique(
            library.favoriteArtists + songs.flatMap(\.artists),
            by: \.id
        ).filter {
            matches(keyword, values: [$0.name] + $0.aliases)
        }
        let playlists = library.favoritePlaylists.filter {
            matches(keyword, values: [$0.name, $0.creator?.nickname])
        }
        let podcasts = model.settings.isContentFeatureEnabled(.podcasts)
            ? library.subscribedPodcasts.filter {
                matches(keyword, values: [$0.name, $0.subtitle])
            }
            : []

        return SearchPayload(
            songs: matchingSongs,
            albums: albums,
            artists: artists,
            playlists: playlists,
            podcasts: podcasts
        )
    }

    private func matches(
        _ keyword: String,
        values: [String?]
    ) -> Bool {
        values.compactMap { $0 }.contains {
            $0.localizedCaseInsensitiveContains(keyword)
        }
    }

    private func unique<Element, ID: Hashable>(
        _ values: [Element],
        by keyPath: KeyPath<Element, ID>
    ) -> [Element] {
        var seen = Set<ID>()
        return values.filter { seen.insert($0[keyPath: keyPath]).inserted }
    }
}

private enum DesktopSearchSource: Hashable {
    case catalog
    case library
}

struct DesktopSearchView: View {
    @Environment(DesktopAppModel.self) private var model
    @State private var store = DesktopSearchStore()

    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 20)
    ]

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 0) {
            if !store.query.isEmpty {
                Picker("类型", selection: $store.kind) {
                    ForEach(availableSearchKinds) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 520)
                .padding(.horizontal, 34)
                .padding(.top, 18)
                .padding(.bottom, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            Divider()

            ScrollView {
                Group {
                    if let error = store.errorMessage {
                        ContentUnavailableView(
                            "搜索失败",
                            systemImage: "exclamationmark.magnifyingglass",
                            description: Text(error)
                        )
                        .frame(maxWidth: .infinity, minHeight: 320)
                    } else if let payload = store.payload {
                        results(payload)
                    } else if store.isSearching {
                        Color.clear
                            .frame(maxWidth: .infinity, minHeight: 320)
                    } else {
                        ContentUnavailableView(
                            "搜索 MeloX",
                            systemImage: "magnifyingglass",
                            description: Text("结果直接来自网易云音乐原始接口。")
                        )
                        .frame(maxWidth: .infinity, minHeight: 320)
                    }
                }
                .padding(.horizontal, 34)
                .padding(.vertical, 24)
            }
        }
        .desktopLoadingStatus(
            "正在搜索…",
            isPresented: store.isSearching
        )
        .animation(.smooth(duration: 0.22), value: store.query.isEmpty)
        .toolbar {
            if !model.ui.isNowPlayingPresented {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)

                        TextField("网易云音乐", text: $store.query)
                            .textFieldStyle(.plain)
                            .onSubmit {
                                Task { await store.search(using: model) }
                            }
                    }
                    .padding(.horizontal, 13)
                    .frame(width: 332, height: 36)
                    .background(.regularMaterial, in: .capsule)
                    .accessibilityElement(children: .contain)
                }

                ToolbarItem(placement: .primaryAction) {
                    Picker("搜索范围", selection: $store.source) {
                        Text("网易云音乐").tag(DesktopSearchSource.catalog)
                        Text("资料库").tag(DesktopSearchSource.library)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 164)
                }
            }
        }
        .task(id: searchRequestID) {
            guard !store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                await store.search(using: model)
                return
            }
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            await store.search(using: model)
        }
        .onChange(
            of: model.settings.isContentFeatureEnabled(.podcasts)
        ) { _, podcastsEnabled in
            if !podcastsEnabled, store.kind == .podcasts {
                store.kind = .songs
            }
        }
    }

    private var availableSearchKinds: [SearchKind] {
        SearchKind.allCases.filter {
            $0 != .podcasts
                || model.settings.isContentFeatureEnabled(.podcasts)
        }
    }

    private var searchRequestID: String {
        "\(store.source)-\(store.kind.rawValue)-\(store.query)"
    }

    @ViewBuilder
    private func results(_ payload: SearchPayload) -> some View {
        switch store.kind {
        case .songs:
            let songs = payload.songs ?? []
            if songs.isEmpty {
                emptyResults
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        DesktopTrackRow(
                            song: song,
                            index: index,
                            songs: songs,
                            showsArtwork: true
                        )
                    }
                }
            }
        case .albums:
            mediaGrid(payload.albums ?? [])
        case .artists:
            artistGrid(payload.artists ?? [])
        case .playlists:
            playlistGrid(payload.playlists ?? [])
        case .podcasts:
            podcastGrid(payload.podcasts ?? [])
        }
    }

    private var emptyResults: some View {
        ContentUnavailableView.search(text: store.query)
            .frame(maxWidth: .infinity, minHeight: 300)
    }

    @ViewBuilder
    private func mediaGrid(_ albums: [Album]) -> some View {
        if albums.isEmpty {
            emptyResults
        } else {
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(albums) { album in
                    DesktopMediaCard(
                        title: album.name,
                        subtitle: album.artistText,
                        artworkURL: album.artworkURL,
                        action: { model.ui.navigate(to: .album(album.id)) },
                        playAction: { play(album) }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func artistGrid(_ artists: [Artist]) -> some View {
        if artists.isEmpty {
            emptyResults
        } else {
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(artists) { artist in
                    DesktopMediaCard(
                        title: artist.name,
                        subtitle: artist.aliases.first,
                        artworkURL: artist.artworkURL,
                        isCircular: true,
                        action: { model.ui.navigate(to: .artist(artist.id)) }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func playlistGrid(_ playlists: [Playlist]) -> some View {
        if playlists.isEmpty {
            emptyResults
        } else {
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(playlists) { playlist in
                    DesktopMediaCard(
                        title: playlist.name,
                        subtitle: playlist.creator?.nickname,
                        artworkURL: playlist.artworkURL,
                        playCount: playlist.playCount,
                        showsPlayCount: model.settings.showPlayCount,
                        action: { model.ui.navigate(to: .playlist(playlist.id)) },
                        playAction: { play(playlist) }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func podcastGrid(_ podcasts: [Podcast]) -> some View {
        if podcasts.isEmpty {
            emptyResults
        } else {
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(podcasts) { podcast in
                    DesktopMediaCard(
                        title: podcast.name,
                        subtitle: podcast.subtitle,
                        artworkURL: podcast.artworkURL,
                        action: { model.ui.navigate(to: .podcast(podcast.id)) }
                    )
                }
            }
        }
    }

    private func play(_ album: Album) {
        Task {
            guard let detail = try? await model.api.album(id: album.id) else { return }
            await model.player.playAll(detail.1, sourceID: album.id)
        }
    }

    private func play(_ playlist: Playlist) {
        Task {
            guard let detail = try? await model.api.playlist(
                id: playlist.id,
                trackLimit: nil
            ) else { return }
            await model.player.playAll(detail.tracks, sourceID: playlist.id)
        }
    }
}
