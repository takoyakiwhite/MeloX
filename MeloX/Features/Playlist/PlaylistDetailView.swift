import SwiftUI

struct PlaylistDetailView: View {
    let id: Int
    private let initialPlaylist: Playlist
    private let prefersToplistLayout: Bool

    @Environment(NeteaseAPI.self) private var api
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerStore.self) private var player
    @Environment(DownloadStore.self) private var downloads
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.setTabViewBottomAccessorySuppressed)
    private var setTabViewBottomAccessorySuppressed

    @State private var playlist: Playlist?
    @State private var phase: LoadingPhase = .loading
    @State private var reloadToken = 0
    @State private var artworkPalette: ArtworkDetailPalette?
    @State private var blurredBackdropImage: CGImage?
    @State private var searchQuery = ""
    @State private var loadedTrackOffset = 0
    @State private var isLoadingMoreTracks = false
    @State private var loadMoreTracksError: String?
    @State private var isPreparingPlayback = false
    @State private var playbackErrorMessage: String?
    @State private var downloadCoordinator =
        MusicCollectionDownloadCoordinator()

    private let trackPageSize = 100

    init(playlist context: PlaylistRouteContext) {
        let cachedAssets = ArtworkAccentColorProvider.cachedDetailAssets(
            for: context.coverURLString.flatMap(URL.init(string:))
        )
        id = context.id
        initialPlaylist = context.playlistSummary
        prefersToplistLayout = false
        _artworkPalette = State(initialValue: cachedAssets?.palette)
        _blurredBackdropImage = State(
            initialValue: cachedAssets?.blurredBackdropImage
        )
    }

    init(toplist context: PlaylistRouteContext) {
        let cachedAssets = ArtworkAccentColorProvider.cachedDetailAssets(
            for: context.coverURLString.flatMap(URL.init(string:))
        )
        id = context.id
        initialPlaylist = context.playlistSummary
        prefersToplistLayout = true
        _artworkPalette = State(initialValue: cachedAssets?.palette)
        _blurredBackdropImage = State(
            initialValue: cachedAssets?.blurredBackdropImage
        )
    }

    var body: some View {
        PlaylistDetailContent(
            playlist: displayedPlaylist,
            toplistSummary: prefersToplistLayout ? initialPlaylist : nil,
            palette: resolvedPalette,
            blurredBackdropImage: blurredBackdropImage,
            searchQuery: searchQuery,
            isLoading: isInitialLoading,
            failureMessage: initialFailureMessage,
            hasMoreTracks: hasMoreTracks,
            loadedTrackOffset: loadedTrackOffset,
            isLoadingMoreTracks: isLoadingMoreTracks,
            loadMoreTracksError: loadMoreTracksError,
            isPreparingPlayback: isPreparingPlayback,
            downloadCoordinator:
                downloadsEnabled
                    ? downloadCoordinator
                    : nil,
            onRetry: { reloadToken += 1 },
            onRefresh: { await load() },
            onLoadMore: { await loadMoreTracks() },
            onPlayAll: { shuffled in
                await playAll(shuffled: shuffled)
            }
        )
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchQuery,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text(prefersToplistLayout ? "在排行榜中搜索" : "在歌单中搜索")
        )
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(interfaceColorScheme, for: .navigationBar, .tabBar)
        .toolbar {
            if downloadsEnabled,
               downloadCoordinator.isSelecting {
                downloadSelectionToolbar
            } else {
                playlistToolbar(for: displayedPlaylist)
            }
        }
        .toolbarVisibility(
            downloadsEnabled
                && downloadCoordinator.isSelecting
                ? .hidden
                : .automatic,
            for: .tabBar
        )
        .environment(\.colorScheme, interfaceColorScheme)
        .onAppear {
            updateTabViewBottomAccessoryVisibility()
        }
        .onChange(of: downloadCoordinator.isSelecting) {
            updateTabViewBottomAccessoryVisibility()
        }
        .onChange(of: downloadsEnabled) { _, isEnabled in
            if !isEnabled {
                downloadCoordinator.finishSelection()
            }
            updateTabViewBottomAccessoryVisibility()
        }
        .onDisappear {
            setTabViewBottomAccessorySuppressed(false)
        }
        .onChange(of: downloadableSongIDs) { _, songIDs in
            guard downloadCoordinator.isSelecting else { return }
            downloadCoordinator.retainSelection(in: Set(songIDs))
        }
        .task(id: reloadToken) {
            guard playlist == nil else { return }
            await load(waitingForNavigationTransition: true)
        }
        .task(id: artworkURL) {
            let transitionDelay = navigationTransitionDelay()
            defer { transitionDelay.cancel() }

            let loadedAssets = await ArtworkAccentColorProvider.shared.detailAssets(
                for: artworkURL,
                fallbackPrefersDarkAppearance: systemColorScheme == .dark
            )
            guard !Task.isCancelled else { return }
            let backdropAlreadyResolved = blurredBackdropImage != nil
                || loadedAssets.blurredBackdropImage == nil
            if artworkPalette == loadedAssets.palette,
               backdropAlreadyResolved {
                return
            }
            do {
                try await transitionDelay.value
            } catch {
                return
            }
            withAnimation(artworkTransitionAnimation) {
                artworkPalette = loadedAssets.palette
                blurredBackdropImage = loadedAssets.blurredBackdropImage
            }
        }
        .alert(
            "音乐库操作失败",
            isPresented: Binding(
                get: { library.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        library.clearError()
                    }
                }
            )
        ) {
            Button("好", role: .cancel) {
                library.clearError()
            }
        } message: {
            Text(library.errorMessage ?? "未知错误")
        }
        .alert(
            "无法准备下载",
            isPresented: Binding(
                get: {
                    downloadsEnabled
                        && downloadCoordinator.errorMessage != nil
                },
                set: { isPresented in
                    if !isPresented {
                        downloadCoordinator.clearError()
                    }
                }
            )
        ) {
            Button("好", role: .cancel) {
                downloadCoordinator.clearError()
            }
        } message: {
            Text(
                downloadCoordinator.errorMessage
                    ?? "无法读取\(collectionTitle)歌曲。"
            )
        }
        .alert(
            "无法播放全部",
            isPresented: Binding(
                get: { playbackErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        playbackErrorMessage = nil
                    }
                }
            )
        ) {
            Button("好", role: .cancel) {
                playbackErrorMessage = nil
            }
        } message: {
            Text(playbackErrorMessage ?? "无法读取完整歌单。")
        }
    }

    private var displayedPlaylist: Playlist {
        playlist ?? initialPlaylist
    }

    private var downloadsEnabled: Bool {
        settings.isContentFeatureEnabled(.downloads)
    }

    private var artworkURL: URL? {
        displayedPlaylist.artworkURL ?? initialPlaylist.artworkURL
    }

    private var collectionTitle: String {
        prefersToplistLayout ? "排行榜" : "歌单"
    }

    private var resolvedPalette: ArtworkDetailPalette {
        artworkPalette
            ?? .fallback(prefersDarkAppearance: systemColorScheme == .dark)
    }

    private var interfaceColorScheme: ColorScheme {
        resolvedPalette.colorScheme
    }

    private var artworkTransitionAnimation: Animation? {
        accessibilityReduceMotion ? nil : .easeOut(duration: 0.18)
    }

    private var isInitialLoading: Bool {
        guard playlist == nil else { return false }
        if case .loading = phase {
            return true
        }
        return false
    }

    private var initialFailureMessage: String? {
        guard playlist == nil, case .failed(let message) = phase else { return nil }
        return message
    }

    private var hasMoreTracks: Bool {
        guard case .loaded = phase,
              let playlist,
              !playlist.trackIDs.isEmpty else {
            return false
        }
        return loadedTrackOffset < playlist.trackIDs.count
    }

    private var downloadableSongIDs: [Int] {
        guard downloadsEnabled,
              let playlist else { return [] }
        let unavailableSongIDs = Set(downloads.downloads.map(\.id))
            .union(downloads.activeDownloads.keys)
        return MusicCollectionDownloadCoordinator.songIDs(
            in: playlist
        )
        .filter { !unavailableSongIDs.contains($0) }
    }

    private func updateTabViewBottomAccessoryVisibility() {
        setTabViewBottomAccessorySuppressed(
            downloadsEnabled
                && downloadCoordinator.isSelecting
        )
    }

    @ToolbarContentBuilder
    private func playlistToolbar(for playlist: Playlist) -> some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if downloadsEnabled,
               downloadCoordinator.isPreparing {
                ProgressView()
                    .accessibilityLabel(
                        "正在准备下载 \(downloadCoordinator.preparingSongCount) 首歌曲"
                    )
            }

            Menu {
                NeteaseShareMenuContent(resource: .playlist(playlist))
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("分享\(collectionTitle)")

            Menu {
                if downloadsEnabled {
                    MusicCollectionDownloadMenuContent(
                        coordinator: downloadCoordinator,
                        downloadableSongCount:
                            downloadableSongIDs.count,
                        onDownloadAll: { quality in
                            startDownloadAll(quality: quality)
                        }
                    )

                    Divider()
                }

                Button {
                    library.toggle(playlist: playlist)
                } label: {
                    Label(
                        library.contains(playlist: playlist) ? "取消收藏" : "收藏歌单",
                        systemImage: library.contains(playlist: playlist) ? "checkmark" : "plus"
                    )
                }

                Button {
                    Task { await load() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("更多")
        }
        .sharedBackgroundVisibility(.visible)
    }

    @ToolbarContentBuilder
    private var downloadSelectionToolbar: some ToolbarContent {
        MusicCollectionDownloadSelectionToolbar(
            coordinator: downloadCoordinator,
            downloadableSongIDs: downloadableSongIDs,
            onDownloadSelection: { quality in
                startSelectedDownloads(quality: quality)
            }
        )
    }

    private func startDownloadAll(quality: MusicQuality) {
        guard downloadsEnabled,
              let playlist else { return }
        Task {
            await downloadCoordinator.downloadAll(
                in: playlist,
                quality: quality,
                api: api,
                downloads: downloads
            )
        }
    }

    private func startSelectedDownloads(quality: MusicQuality) {
        guard downloadsEnabled,
              let playlist else { return }
        Task {
            await downloadCoordinator.downloadSelection(
                in: playlist,
                quality: quality,
                api: api,
                downloads: downloads
            )
        }
    }

    private func load(
        waitingForNavigationTransition: Bool = false
    ) async {
        let transitionDelay = navigationTransitionDelay(
            isEnabled: waitingForNavigationTransition
        )
        defer { transitionDelay.cancel() }

        phase = .loading
        loadedTrackOffset = 0
        loadMoreTracksError = nil
        do {
            let loadedPlaylist = try await api.playlist(
                id: id,
                trackLimit: trackPageSize
            )
            try await transitionDelay.value
            playlist = loadedPlaylist
            loadedTrackOffset = min(
                trackPageSize,
                loadedPlaylist.trackIDs.count
            )
            phase = .loaded
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func loadMoreTracks() async {
        guard let currentPlaylist = playlist,
              !isLoadingMoreTracks,
              loadedTrackOffset < currentPlaylist.trackIDs.count else {
            return
        }

        let requestedOffset = loadedTrackOffset
        let trackIDs = currentPlaylist.trackIDs.map(\.id)
        isLoadingMoreTracks = true
        loadMoreTracksError = nil
        defer {
            isLoadingMoreTracks = false
        }

        do {
            let page = try await api.songDetailsPage(
                ids: trackIDs,
                offset: requestedOffset,
                limit: trackPageSize
            )
            try Task.checkCancellation()
            guard playlist?.id == currentPlaylist.id,
                  loadedTrackOffset == requestedOffset else {
                return
            }

            var updatedPlaylist = playlist ?? currentPlaylist
            var loadedIDs = Set(updatedPlaylist.tracks.map(\.id))
            updatedPlaylist.tracks.append(
                contentsOf: page.songs.filter {
                    loadedIDs.insert($0.id).inserted
                }
            )
            playlist = updatedPlaylist
            loadedTrackOffset = page.nextOffset
        } catch is CancellationError {
            return
        } catch {
            loadMoreTracksError = error.localizedDescription
        }
    }

    private func playAll(shuffled: Bool) async {
        guard let currentPlaylist = playlist,
              !isPreparingPlayback else {
            return
        }

        isPreparingPlayback = true
        playbackErrorMessage = nil
        defer { isPreparingPlayback = false }

        do {
            let trackIDs = currentPlaylist.trackIDs.map(\.id)
            let songs = if trackIDs.isEmpty {
                currentPlaylist.tracks
            } else {
                try await api.songDetailsCollection(
                    ids: trackIDs,
                    prefetched: currentPlaylist.tracks
                )
            }
            try Task.checkCancellation()
            guard playlist?.id == currentPlaylist.id else { return }
            await player.playAll(
                shuffled ? songs.shuffled() : songs,
                sourceID: currentPlaylist.id
            )
        } catch is CancellationError {
            return
        } catch {
            playbackErrorMessage = error.localizedDescription
        }
    }

    private func navigationTransitionDelay(
        isEnabled: Bool = true
    ) -> Task<Void, Error> {
        Task {
            guard isEnabled else { return }
            try await Task.sleep(
                for: MusicNavigationTransitionTiming.settleDelay
            )
        }
    }
}
