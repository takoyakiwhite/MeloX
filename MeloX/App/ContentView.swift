import SwiftUI

private enum ContentSheet: String, Identifiable {
    case settings

    var id: String { rawValue }
}

private enum ContentRoute: Hashable {
    case privateMessages
    case songRecognition
}

private struct HeartModeLaunchReadiness: Equatable {
    let hasRestoredPlayback: Bool
    let isLoggedIn: Bool
    let canStartHeartMode: Bool
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(PlayerStore.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadStore.self) private var downloads
    @Environment(LyricsStore.self) private var lyrics
    @Environment(FloatingLyricsController.self) private var floatingLyrics

    @State private var selectedTab: AppTab
    @State private var navigationPaths = Dictionary(
        uniqueKeysWithValues: AppTab.allCases.map {
            ($0, NavigationPath())
        }
    )
    @State private var presentedSheet: ContentSheet?
    @State private var playerPresentation: PlayerPresentation?
    @State private var neteaseSharePresentation: NeteaseSharePresentation?
    @State private var nowPlayingSharePresentation: NeteaseSharePresentation?
    @State private var pendingMusicRoute: MusicRoute?
    @State private var isTabViewBottomAccessorySuppressed = false
    @State private var hasRestoredPlayback = false
    @State private var hasHandledHeartModeLaunch = false
    @State private var heartModeLaunchErrorMessage: String?
    @Namespace private var playerTransitionNamespace
    @Namespace private var musicNavigationNamespace

    private let playerTransitionID = "now-playing"

    init(initialTab: AppTab = .home) {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        Group {
            if settings.hasCompletedOnboarding {
                mainExperience
            } else {
                OnboardingView()
            }
        }
    }

    private var mainExperience: some View {
        playerAwareTabView
            .environment(
                \.openMusicRoute,
                OpenMusicRouteAction(action: openMusicRoute)
            )
            .environment(
                \.openNeteaseShare,
                OpenNeteaseShareAction(action: openNeteaseShare)
            )
            .environment(
                \.setTabViewBottomAccessorySuppressed,
                SetTabViewBottomAccessorySuppressedAction {
                    isTabViewBottomAccessorySuppressed = $0
                }
            )
            .fullScreenCover(
                item: $playerPresentation,
                onDismiss: finishPendingSongNavigation
            ) { destination in
                switch destination {
                case .nowPlaying:
                    NowPlayingView(initialPage: initialNowPlayingPage)
                        .environment(
                            \.openMusicRoute,
                            OpenMusicRouteAction(action: openMusicRoute)
                        )
                        .environment(
                            \.openNeteaseShare,
                            OpenNeteaseShareAction { presentation in
                                presentNeteaseShare(
                                    presentation,
                                    fromNowPlaying: true
                                )
                            }
                        )
                        .sheet(item: $nowPlayingSharePresentation) {
                            presentation in
                            NeteaseShareSheet(presentation: presentation)
                        }
                        .presentationBackground(.clear)
                        .presentationContentInteraction(.resizes)
                        .navigationTransition(
                            .zoom(
                                sourceID: playerTransitionID,
                                in: playerTransitionNamespace
                            )
                        )
                }
            }
            .sheet(item: $neteaseSharePresentation) { presentation in
                NeteaseShareSheet(presentation: presentation)
            }
            .sheet(item: $presentedSheet) { destination in
                switch destination {
                case .settings:
                    NavigationStack {
                        SettingsView()
                            .musicDestinations(
                                in: musicNavigationNamespace
                            )
                    }
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
                    .presentationCornerRadius(32)
                }
            }
            .task {
                await player.restore()
                guard !Task.isCancelled else { return }
                hasRestoredPlayback = true
            }
            .task(
                id: HeartModeLaunchReadiness(
                    hasRestoredPlayback: hasRestoredPlayback,
                    isLoggedIn: library.isLoggedIn,
                    canStartHeartMode: library.canStartHeartMode
                )
            ) {
                await startHeartModeOnLaunchIfNeeded()
            }
            .task(id: player.currentSong?.id) {
                let song = player.currentSong
                let lyricSong = song?.isPodcastProgram == true
                    ? nil
                    : song
                await lyrics.load(for: lyricSong)
                guard !Task.isCancelled else { return }
                player.setNowPlayingLyrics(lyrics.lyrics, for: lyricSong?.id)
            }
            .task {
                await floatingLyrics.monitor()
            }
            .task(id: settings.cookie) {
                await library.refresh()
            }
            .background(alignment: .topLeading) {
                FloatingLyricsPictureInPictureSource(
                    controller: floatingLyrics
                )
                .frame(
                    width:
                        FloatingLyricsPictureInPictureSource
                            .sourceSize.width,
                    height:
                        FloatingLyricsPictureInPictureSource
                            .sourceSize.height
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .onChange(of: selectedTab) { _, tab in
                settings.lastSelectedTab = tab
            }
            .onChange(of: settings.visibleTabs) { _, tabs in
                guard !tabs.contains(selectedTab) else { return }
                if settings.homeTabs.contains(selectedTab),
                   tabs.contains(.home) {
                    selectedTab = .home
                } else if selectedTab.libraryPage != nil,
                   tabs.contains(.library) {
                    selectedTab = .library
                } else {
                    selectedTab = settings.fallbackNavigationTab
                }
            }
            .onChange(of: scenePhase) { _, phase in
                player.refreshLyricsNotification()
                switch phase {
                case .inactive, .background:
                    player.persistPlaybackStateForLifecycle()
                case .active:
                    player.refreshLyricsLiveActivity()
                @unknown default:
                    player.persistPlaybackStateForLifecycle()
                }
            }
            .onChange(of: floatingLyrics.restorationRequestID) {
                guard floatingLyrics.restorationRequestID > 0,
                      player.currentSong != nil else {
                    floatingLyrics.completeRestoration(success: false)
                    return
                }

                playerPresentation = .nowPlaying
                Task { @MainActor in
                    await Task.yield()
                    floatingLyrics.completeRestoration(success: true)
                }
            }
            .alert(
                "歌曲无法播放",
                isPresented: Binding(
                    get: { player.playbackIssue != nil },
                    set: { isPresented in
                        if !isPresented {
                            player.dismissPlaybackIssue()
                        }
                    }
                )
            ) {
                if player.canPlayNext {
                    Button("播放下一首") {
                        player.dismissPlaybackIssue()
                        Task { await player.next() }
                    }
                }
                Button("好", role: .cancel) {
                    player.dismissPlaybackIssue()
                }
            } message: {
                Text(player.playbackIssue?.message ?? "当前歌曲暂时无法播放。")
            }
            .alert(
                "无法自动启动心动模式",
                isPresented: Binding(
                    get: { heartModeLaunchErrorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            heartModeLaunchErrorMessage = nil
                        }
                    }
                )
            ) {
                Button("好", role: .cancel) {
                    heartModeLaunchErrorMessage = nil
                }
            } message: {
                Text(heartModeLaunchErrorMessage ?? "请稍后重试。")
            }
            .alert(
                "下载操作失败",
                isPresented: Binding(
                    get: {
                        AppFeatureAvailability.downloads
                            && downloads.errorMessage != nil
                    },
                    set: { isPresented in
                        if !isPresented {
                            downloads.clearError()
                        }
                    }
                )
            ) {
                Button("好", role: .cancel) {
                    downloads.clearError()
                }
            } message: {
                Text(downloads.errorMessage ?? "无法完成下载操作。")
            }
            .alert(
                "无法打开悬浮歌词",
                isPresented: Binding(
                    get: { floatingLyrics.errorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            floatingLyrics.dismissError()
                        }
                    }
                )
            ) {
                Button("好", role: .cancel) {
                    floatingLyrics.dismissError()
                }
            } message: {
                Text(
                    floatingLyrics.errorMessage
                        ?? "系统画中画暂时不可用。"
                )
            }
            .coordinateListenTogether()
            .recognizesClipboardLinksOnLaunch { song in
                openMusicRoute(.song(song))
            }
            .appLaunchExperience()
    }

    private func startHeartModeOnLaunchIfNeeded() async {
        guard !hasHandledHeartModeLaunch,
              hasRestoredPlayback else {
            return
        }
        guard settings.startsHeartModeOnLaunch else {
            hasHandledHeartModeLaunch = true
            return
        }
        guard library.isLoggedIn else {
            hasHandledHeartModeLaunch = true
            return
        }
        guard library.canStartHeartMode,
              let playlistID = library.likedPlaylistID,
              let seedSongID = library.randomHeartModeSeedSongID() else {
            return
        }

        hasHandledHeartModeLaunch = true
        do {
            try await player.playHeartMode(
                playlistID: playlistID,
                seedSongID: seedSongID
            )
        } catch is CancellationError {
            return
        } catch {
            heartModeLaunchErrorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private var playerAwareTabView: some View {
        if player.currentSong != nil {
            if #available(iOS 26.1, *) {
                tabs
                    .tabViewBottomAccessory(
                        isEnabled: !isTabViewBottomAccessorySuppressed
                    ) {
                        miniPlayer
                    }
            } else {
                tabs
                    .tabViewBottomAccessory {
                        if !isTabViewBottomAccessorySuppressed {
                            miniPlayer
                        }
                    }
            }
        } else {
            tabs
        }
    }

    private var miniPlayer: some View {
        MiniPlayerView(
            artworkTransitionID: playerTransitionID,
            artworkTransitionNamespace:
                playerTransitionNamespace
        ) {
            playerPresentation = .nowPlaying
        }
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            ForEach(settings.visibleTabs) { tab in
                Tab(
                    tab.title,
                    systemImage: tab.systemImage,
                    value: tab,
                    role: tab == .search ? .search : nil
                ) {
                    NavigationStack(
                        path: navigationPathBinding(for: tab)
                    ) {
                        tabRoot(for: tab)
                            .toolbar {
                                primaryToolbar(for: tab)
                            }
                            .navigationDestination(
                                for: ContentRoute.self
                            ) { route in
                                contentDestination(for: route)
                            }
                            .musicDestinations(
                                in: musicNavigationNamespace
                            )
                    }
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .environment(\.musicNavigationNamespace, musicNavigationNamespace)
    }

    @ViewBuilder
    private func tabRoot(for tab: AppTab) -> some View {
        switch tab {
        case .home:
            HomeView()
        case .recommended:
            HomeRecommendedView()
                .navigationTitle("推荐")
                .navigationBarTitleDisplayMode(.large)
        case .music:
            ExploreView(navigationTitle: "音乐")
        case .podcasts:
            PodcastHomeView()
        case .explore:
            ExploreView()
        case .library:
            LibraryView()
        case .search:
            SearchView()
        case .librarySongs,
             .libraryPlaylists,
             .libraryPodcasts,
             .libraryDownloads,
             .libraryCloud,
             .libraryHistory:
            if let page = tab.libraryPage {
                LibraryView(fixedPage: page)
            }
        }
    }

    @ToolbarContentBuilder
    private func primaryToolbar(
        for tab: AppTab
    ) -> some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if library.isLoggedIn {
                Button {
                    navigate(to: .privateMessages, in: tab)
                } label: {
                    Image(
                        systemName:
                            "bubble.left.and.bubble.right"
                    )
                }
                .accessibilityLabel("私信")
                .accessibilityHint("打开网易云私信")
            }

            Button {
                navigate(to: .songRecognition, in: tab)
            } label: {
                Image(systemName: "waveform")
            }
            .accessibilityLabel("听歌识曲")

            Button {
                presentedSheet = .settings
            } label: {
                accountToolbarLabel
            }
            .accessibilityLabel(accountToolbarAccessibilityLabel)
        }
    }

    @ViewBuilder
    private func contentDestination(
        for route: ContentRoute
    ) -> some View {
        switch route {
        case .privateMessages:
            NeteasePrivateMessagesView()
        case .songRecognition:
            SongRecognitionView()
        }
    }

    @ViewBuilder
    private var accountToolbarLabel: some View {
        if let profile = library.profile {
            AsyncImage(url: profile.artworkURL) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "person.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
            .background(.quaternary, in: .circle)
            .clipShape(.circle)
        } else {
            Image(
                systemName: library.isLoggedIn
                    ? "person.crop.circle.fill"
                    : "person.crop.circle"
            )
        }
    }

    private var accountToolbarAccessibilityLabel: String {
        if let profile = library.profile {
            return "\(profile.nickname)的账号与设置"
        }
        return library.isLoggedIn ? "账号与设置" : "登录与设置"
    }

    private func navigationPathBinding(
        for tab: AppTab
    ) -> Binding<NavigationPath> {
        Binding(
            get: {
                navigationPaths[tab] ?? NavigationPath()
            },
            set: {
                navigationPaths[tab] = $0
            }
        )
    }

    private var initialNowPlayingPage: NowPlayingPage {
        guard settings.rememberNowPlayingPage else { return .artwork }
        return NowPlayingPage(rawValue: settings.rememberedNowPlayingPage) ?? .artwork
    }

    private func openMusicRoute(_ route: MusicRoute) {
        guard playerPresentation == nil else {
            pendingMusicRoute = route
            playerPresentation = nil
            return
        }
        navigate(to: route)
    }

    private func openNeteaseShare(
        _ presentation: NeteaseSharePresentation
    ) {
        presentNeteaseShare(presentation, fromNowPlaying: false)
    }

    private func presentNeteaseShare(
        _ presentation: NeteaseSharePresentation,
        fromNowPlaying: Bool
    ) {
        Task { @MainActor in
            // Menu actions can fire before the system has completed
            // dismissing the menu. Present on the next settled UI turn.
            try? await Task.sleep(for: .milliseconds(140))
            if fromNowPlaying {
                nowPlayingSharePresentation = presentation
            } else {
                neteaseSharePresentation = presentation
            }
        }
    }

    private func finishPendingSongNavigation() {
        guard let route = pendingMusicRoute else { return }
        pendingMusicRoute = nil
        navigate(to: route)
    }

    private func navigate(
        to route: ContentRoute,
        in tab: AppTab
    ) {
        var path = navigationPaths[tab] ?? NavigationPath()
        path.append(route)
        navigationPaths[tab] = path
    }

    private func navigate(to route: MusicRoute) {
        var path = navigationPaths[selectedTab] ?? NavigationPath()
        path.append(route)
        navigationPaths[selectedTab] = path
    }
}
