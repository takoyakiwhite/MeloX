import SwiftUI

struct DesktopSidebar: View {
    @Environment(DesktopAppModel.self) private var model
    @State private var sidebarFrame = CGRect(
        x: 8,
        y: 8,
        width: 199,
        height: 0
    )

    private let primarySections: [DesktopSection] = [
        .search,
        .home,
        .discovery,
        .radio,
    ]
    private let librarySections: [DesktopSection] = [
        .songs,
        .playlists,
        .podcasts,
        .downloads,
        .cloud,
        .recent,
    ]

    var body: some View {
        @Bindable var ui = model.ui

        TabView(selection: $ui.selection) {
            ForEach(primarySections.filter(model.isSectionEnabled)) { section in
                tab(for: section)
            }

            TabSection("音乐库") {
                ForEach(librarySections.filter(model.isSectionEnabled)) { section in
                    tab(for: section)
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .overlay(alignment: .bottomLeading) {
            pinnedFooter
                .frame(width: max(sidebarFrame.width, 1))
                .padding(.leading, max(sidebarFrame.minX, 0))
                .padding(.bottom, max(sidebarFrame.minY, 0))
        }
        .toolbar(removing: .sidebarToggle)
        .background {
            DesktopSidebarVisibilityLock(
                sidebarFrame: $sidebarFrame,
                reservedBottomInset: pinnedFooterHeight
            )
                .frame(width: 0, height: 0)
        }
        .onChange(
            of: model.settings.contentFeatures.disabledFeatures
        ) { _, _ in
            model.ensureSelectedSectionIsEnabled()
        }
    }

    private var pinnedFooterHeight: CGFloat {
        loadingMessage == nil ? 50 : 86
    }

    private var pinnedFooter: some View {
        VStack(spacing: 0) {
            if let loadingMessage {
                Text(loadingMessage)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .padding(.horizontal, 10)
                    .accessibilityLabel(loadingMessage)
                    .transition(.opacity)
            }

            DesktopSidebarAccountFooter()
        }
        .animation(.easeInOut(duration: 0.18), value: loadingMessage)
    }

    private var loadingMessage: String? {
        if let message = model.ui.presentedLoadingMessage {
            return message
        }
        if model.settings.isContentFeatureEnabled(.cloudMusic),
           model.cloud.isUploading {
            return "正在上传音乐…"
        }
        if let message = model.ui.contextualLoadingMessage {
            return message
        }
        if model.library.phase == .loading
            || (model.settings.isContentFeatureEnabled(.cloudMusic)
                && model.cloud.phase == .loading) {
            return "正在载入云端资料库…"
        }
        if model.settings.isContentFeatureEnabled(.cloudMusic),
           model.cloud.isLoadingMore {
            return "正在载入更多云盘歌曲…"
        }
        if model.library.isLoadingMoreFavoriteSongs {
            return "正在载入更多收藏歌曲…"
        }
        if model.settings.isContentFeatureEnabled(.podcasts),
           model.library.isLoadingMoreSubscribedPodcasts {
            return "正在载入更多订阅播客…"
        }
        if model.home.phase == .loading {
            return "正在载入推荐内容…"
        }
        if model.player.isLoading {
            return "正在载入歌曲…"
        }
        if model.lyrics.isLoading {
            return "正在载入歌词…"
        }
        return nil
    }

    private func tab(
        for section: DesktopSection
    ) -> some TabContent<DesktopSection> {
        Tab(
            section.title,
            systemImage: section.systemImage,
            value: section
        ) {
            DesktopTabPage(section: section)
                .toolbar(removing: .sidebarToggle)
        }
    }
}

struct DesktopSidebarAccountFooter: View {
    @Environment(DesktopAppModel.self) private var model

    var body: some View {
        Button {
            model.ui.sheet = .account
        } label: {
            HStack(spacing: 9) {
                if let profile = model.library.profile {
                    DesktopCircularArtworkView(url: profile.artworkURL)
                        .frame(width: 30, height: 30)
                } else {
                    ZStack {
                        Circle()
                            .fill(Color(red: 0.48, green: 0.63, blue: 0.88).gradient)
                        Text("洛")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 30, height: 30)
                }

                Text(model.library.profile?.nickname ?? "未登录")
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .frame(height: 50)
    }
}
