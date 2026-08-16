import AppKit
import SwiftUI

struct DesktopSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(DesktopAppModel.self) private var model
    @State private var selection: DesktopSettingsTab = .general
    @State private var showsResetConfirmation = false
    @State private var isResettingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selection) {
                DesktopGeneralSettingsView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .tabItem { Label("通用", systemImage: "gearshape") }
                    .tag(DesktopSettingsTab.general)
                DesktopContentFeatureSettingsView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .tabItem { Label("功能", systemImage: "switch.2") }
                    .tag(DesktopSettingsTab.features)
                DesktopPlaybackAndLyricsSettingsView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .tabItem { Label("播放", systemImage: "play.circle") }
                    .tag(DesktopSettingsTab.playback)
                DesktopFileSettingsView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .tabItem { Label("文件", systemImage: "folder") }
                    .tag(DesktopSettingsTab.files)
                DesktopAdvancedSettingsView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .tabItem { Label("高级", systemImage: "gearshape.2") }
                    .tag(DesktopSettingsTab.advanced)
            }
            .tabViewStyle(.automatic)
            .toggleStyle(.checkbox)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 12) {
                Button {
                    openWindow(id: "about")
                } label: {
                    Image(systemName: "questionmark")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.bordered)
                .clipShape(.circle)
                .help("关于 MeloX")

                Button("恢复默认值…", role: .destructive) {
                    showsResetConfirmation = true
                }
                .disabled(isResettingSettings)

                Spacer()

                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("好") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .tint(.red)
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .frame(height: 58)
        }
        .frame(width: 650, height: selection.contentHeight)
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.24),
            value: selection
        )
        .alert(
            "恢复默认设置？",
            isPresented: $showsResetConfirmation
        ) {
            Button("恢复默认值", role: .destructive) {
                resetPlayerSettings()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会恢复播放、歌词和扩展显示参数，不会影响账号、下载与音乐数据。")
        }
    }

    private func resetPlayerSettings() {
        guard !isResettingSettings else { return }
        isResettingSettings = true

        Task { @MainActor in
            await DesktopPlayerSettingsResetter.reset(model: model)
            isResettingSettings = false
        }
    }
}

private enum DesktopSettingsTab: Hashable {
    case general
    case features
    case playback
    case files
    case advanced

    var contentHeight: CGFloat {
        switch self {
        case .general: 570
        case .features: 480
        case .playback: 620
        case .files: 620
        case .advanced: 600
        }
    }
}

private struct DesktopPlaybackAndLyricsSettingsView: View {
    @State private var page: Page = .playback

    var body: some View {
        VStack(spacing: 0) {
            Picker("播放设置", selection: $page) {
                Text("播放").tag(Page.playback)
                Text("歌词").tag(Page.lyrics)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 180)
            .padding(.top, 12)

            Group {
                switch page {
                case .playback:
                    DesktopPlaybackSettingsView()
                case .lyrics:
                    DesktopLyricsSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private enum Page: Hashable {
        case playback
        case lyrics
    }
}

private struct DesktopGeneralSettingsView: View {
    @Environment(DesktopAppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        @Bindable var recognition = model.settings.songRecognition

        Form {
            Section("外观") {
                Picker("外观", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Label(appearance.title, systemImage: appearance.systemImage)
                            .tag(appearance)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("显示播放次数", isOn: $settings.showPlayCount)
            }

            Section("内容") {
                Picker("新碟地区", selection: $settings.musicArea) {
                    Text("全部").tag("ALL")
                    Text("华语").tag("ZH")
                    Text("欧美").tag("EA")
                    Text("韩国").tag("KR")
                    Text("日本").tag("JP")
                }
                Picker("听歌识曲时长", selection: $recognition.duration) {
                    ForEach(SongRecognitionDuration.allCases) { duration in
                        Text("\(duration.title) · \(duration.detail)").tag(duration)
                    }
                }
            }

            Section("账户") {
                HStack(spacing: 12) {
                    DesktopArtworkView(
                        url: model.library.profile?.artworkURL,
                        cornerRadius: 999
                    )
                    .frame(width: 42, height: 42)
                    .clipShape(.circle)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.library.profile?.nickname ?? "未登录网易云音乐")
                            .font(.headline)
                        Text(model.library.isLoggedIn ? "收藏、歌单、云盘和记录已启用" : "登录后同步完整资料库")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.library.isLoggedIn ? "账户详情" : "登录") {
                        model.ui.sheet = model.library.isLoggedIn ? .account : .login
                    }
                }
            }

            Section("启动") {
                Toggle("启动时检查更新", isOn: $settings.checksUpdatesOnLaunch)
                Toggle("启动时识别剪贴板中的网易云链接", isOn: $settings.recognizesClipboardLinksOnLaunch)
                Toggle("启动时自动进入心动模式", isOn: $settings.startsHeartModeOnLaunch)
            }
        }
        .formStyle(.columns)
        .padding()
        .onChange(of: settings.musicArea) { _, _ in
            Task {
                await model.home.load(force: true)
            }
        }
    }
}

private struct DesktopPlaybackSettingsView: View {
    @Environment(DesktopAppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        @Bindable var equalizer = model.settings.equalizer
        @Bindable var autoMix = model.settings.autoMix

        ScrollView {
            Form {
            Section("音质与控制") {
                Picker("播放音质", selection: qualityBinding) {
                    ForEach(MusicQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                Picker("音量控制", selection: $settings.playerVolumeControlMode) {
                    ForEach(PlayerVolumeControlMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Toggle("再次点上一首时从头播放当前歌曲", isOn: $settings.previousRestartsCurrentSong)
            }

            Section("空间音频") {
                Picker("模式", selection: $settings.spatialAudioMode) {
                    ForEach(SpatialAudioMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text(settings.spatialAudioMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("实际效果取决于当前输出设备；固定与头部跟踪模式请在 macOS 控制中心中选择。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("正在播放") {
                Picker("背景", selection: $settings.playerBackgroundStyle) {
                    ForEach(PlayerBackgroundStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                Slider(
                    value: $settings.playerBackgroundMotionIntensity,
                    in: AppSettings.playerBackgroundMotionIntensityRange,
                    step: 0.1,
                    label: { Text("背景动效强度") },
                    minimumValueLabel: { Text("静止") },
                    maximumValueLabel: { Text("强") }
                )
                if settings.playerBackgroundStyle == .flowingLight {
                    Toggle(
                        "背景响应节拍",
                        isOn: $settings.playerBackgroundBeatEffectsEnabled
                    )
                }
                if settings.playerBackgroundStyle == .appleMusicBackdrop {
                    Picker(
                        "背景画质",
                        selection: $settings.playerBackgroundRenderQuality
                    ) {
                        ForEach(PlayerBackgroundRenderQuality.allCases) { quality in
                            Text(quality.title).tag(quality)
                        }
                    }
                    Text(settings.playerBackgroundRenderQuality.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(
                        "使用 Music 1.6.6 的三层旋转、响应式遮罩、1.3 倍饱和度与画面对角线模糊参数。"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Toggle("暂停时缩小封面", isOn: $settings.shrinksPausedArtwork)
                Toggle("记住播放器上次页面", isOn: $settings.rememberNowPlayingPage)
                Text(
                    settings.rememberNowPlayingPage
                        ? "再次打开播放器时恢复封面、歌词或队列页面。"
                        : "每次打开播放器时从歌词页面开始。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Picker("保持屏幕唤醒", selection: $settings.playerScreenAwakeMode) {
                    ForEach(
                        PlayerScreenAwakeMode.allCases.filter {
                            $0 != .hiddenLyricsInterface
                        }
                    ) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }

            Section("均衡器") {
                Toggle("启用均衡器", isOn: $equalizer.isEnabled)
                Picker(
                    "预设",
                    selection: Binding(
                        get: { equalizer.selectedPreset },
                        set: { equalizer.apply($0) }
                    )
                ) {
                    ForEach(AudioEqualizerPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                HStack {
                    Text("前级")
                    Slider(
                        value: Binding(
                            get: { equalizer.preamp },
                            set: { equalizer.setPreamp($0) }
                        ),
                        in: AudioEqualizerPreferences.preampRange
                    )
                    Text("\(equalizer.preamp, specifier: "%.1f") dB")
                        .monospacedDigit()
                        .frame(width: 66, alignment: .trailing)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(AudioEqualizerBand.allCases) { band in
                            VStack(spacing: 6) {
                                Slider(
                                    value: Binding(
                                        get: { equalizer.gain(for: band) },
                                        set: { equalizer.setGain($0, for: band) }
                                    ),
                                    in: AudioEqualizerPreferences.bandGainRange
                                )
                                .rotationEffect(.degrees(-90))
                                .frame(width: 78, height: 90)
                                Text(band.title)
                                    .font(.caption2)
                            }
                            .frame(width: 58)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }

            Section("自动混音") {
                Picker("模式", selection: $autoMix.mode) {
                    ForEach(AutoMixMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Picker("过渡长度", selection: $autoMix.transitionBars) {
                    ForEach(AutoMixTransitionBars.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                Picker("结尾处理", selection: $autoMix.tailCutBars) {
                    ForEach(AutoMixTailCutBars.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                Toggle("匹配速度", isOn: $autoMix.tempoMatchingEnabled)
                Toggle("跳过安静开头", isOn: $autoMix.skipsQuietOpening)
                Toggle("分析流媒体歌曲", isOn: $autoMix.analyzesStreamingTracks)
                Picker("分析失败时", selection: $autoMix.fallbackBehavior) {
                    ForEach(AutoMixFallbackBehavior.allCases) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }
            }
            }
            .formStyle(.columns)
            .padding()
        }
        .scrollIndicators(.automatic)
        .onChange(of: settings.playerVolumeControlMode) { _, _ in
            model.playbackVolume.applyControlMode()
        }
        .onChange(of: settings.spatialAudioMode) { _, _ in
            model.player.applySpatialAudioSettings()
        }
        .onChange(
            of: equalizer.configuration,
            initial: true
        ) { _, _ in
            model.player.applyEqualizerSettings()
        }
        .onChange(of: autoMix.configuration) { _, _ in
            model.player.applyAutoMixSettings()
        }
    }

    private var qualityBinding: Binding<MusicQuality> {
        Binding(
            get: { model.settings.quality },
            set: { model.player.selectPlaybackQuality($0) }
        )
    }
}

private struct DesktopFileSettingsView: View {
    @Environment(DesktopAppModel.self) private var model
    @State private var usage = ManagedStorageUsage.empty
    @State private var isWorking = false
    @State private var statusMessage: String?

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section("储存空间") {
                LabeledContent("下载") { Text(bytes(usage.downloadsBytes)) }
                LabeledContent("网络缓存") { Text(bytes(usage.networkCacheBytes)) }
                LabeledContent("临时分析文件") { Text(bytes(usage.temporaryFilesBytes)) }
                LabeledContent("资料库数据库") { Text(bytes(usage.databaseBytes)) }
                LabeledContent("MeloX 已管理") {
                    Text(bytes(usage.totalManagedBytes)).fontWeight(.semibold)
                }
            }

            Section("下载") {
                LabeledContent("已下载歌曲") {
                    Text(model.downloads.downloads.count.formatted())
                }
                LabeledContent("下载目录") {
                    Text(AppStorageLocations.downloadsDirectory().path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([
                        AppStorageLocations.downloadsDirectory()
                    ])
                }
                Button("修复下载资料库") {
                    _ = model.downloads.repairStorage()
                    Task { await refreshUsage() }
                }
            }

            Section("自动缓存") {
                Toggle("自动缓存经常播放的歌曲", isOn: $settings.automaticallyCachesFrequentlyPlayedSongs)
                Picker(
                    "缓存阈值",
                    selection: $settings.automaticCachePlaybackThreshold
                ) {
                    ForEach(
                        AppSettings.automaticCachePlaybackThresholdOptions,
                        id: \.self
                    ) { count in
                        Text("播放 \(count) 次后").tag(count)
                    }
                }
                Picker("缓存音质", selection: $settings.automaticCacheQuality) {
                    ForEach(MusicQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
            }

            Section("清理") {
                Button("清理网络与封面缓存") {
                    StorageMaintenance.clearNetworkAndArtworkCaches()
                    Task { await refreshUsage() }
                }
                Button("清理临时文件") {
                    Task { await clearTemporaryFiles() }
                }
                .disabled(isWorking)
                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.columns)
        .padding()
        .task { await refreshUsage() }
    }

    private func refreshUsage() async {
        usage = await StorageMaintenance.usage()
    }

    private func clearTemporaryFiles() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let reclaimed = try await StorageMaintenance.clearTemporaryFiles(
                preservingDownloadTransfers: !model.downloads.activeDownloads.isEmpty
            )
            statusMessage = "已清理 \(bytes(reclaimed))。"
            await refreshUsage()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

private struct DesktopAdvancedSettingsView: View {
    @Environment(DesktopAppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section("系统媒体") {
                Toggle("在系统正在播放中显示歌词", isOn: $settings.systemNowPlayingLyricsEnabled)
                TextField("标题格式", text: $settings.systemNowPlayingLyricsTitleFormat)
                TextField("副标题格式", text: $settings.systemNowPlayingLyricsSubtitleFormat)
            }

            Section("播放器调试") {
                Toggle("BeatNet 调试信息", isOn: $settings.beatNetDebugEnabled)
                Slider(
                    value: $settings.playerBackgroundBlur,
                    in: AppSettings.playerBackgroundBlurRange,
                    step: 5,
                    label: { Text("背景模糊") }
                )
                Slider(
                    value: $settings.playerBackgroundSaturation,
                    in: AppSettings.playerBackgroundSaturationRange,
                    step: 0.05,
                    label: { Text("背景饱和度") }
                )
            }

            Section("维护") {
                Button("再次显示欢迎对话框") {
                    settings.hasCompletedOnboarding = false
                    model.ui.sheet = .onboarding
                }
                Button("优化下载数据库") {
                    model.downloads.optimizeStorageDatabase()
                }
                Button("重置自动缓存播放统计") {
                    model.downloads.resetAutomaticCacheHistory()
                }
                Button("刷新所有网易云内容") {
                    Task { await model.refreshAll() }
                }
            }

            Section("隐私") {
                Text("账户 Cookie、下载资料库和播放设置仅保存在这台 Mac。听歌识曲只上传在本机生成的音频指纹。")
                    .foregroundStyle(.secondary)
                if model.library.isLoggedIn {
                    Button("退出网易云账户", role: .destructive) {
                        model.logOut()
                        Task { await DesktopNeteaseCookieStore.clear() }
                    }
                }
            }
        }
        .formStyle(.columns)
        .padding()
        .onChange(of: settings.systemNowPlayingLyricsEnabled) { _, _ in
            model.player.applySystemNowPlayingLyricsPreference()
        }
        .onChange(of: settings.systemNowPlayingLyricsTitleFormat) { _, _ in
            model.player.applySystemNowPlayingLyricsPreference()
        }
        .onChange(of: settings.systemNowPlayingLyricsSubtitleFormat) { _, _ in
            model.player.applySystemNowPlayingLyricsPreference()
        }
    }
}
