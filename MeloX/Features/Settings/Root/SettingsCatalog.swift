import Foundation

enum SettingsRoute: Hashable {
    case accountHome
    case playback
    case playerAppearance
    case lyrics
    case systemPlayback
    case general
    case tabLayout
    case contentFeatures
    case content
    case storage
    case skylineLyrics
    case floatingLyrics
    case developer
    case about
}

struct SettingsCatalogSection: Identifiable {
    let title: String
    let items: [SettingsCatalogItem]

    var id: String { title }
}

struct SettingsCatalogItem {
    let route: SettingsRoute
    let title: String
    let subtitle: String
    let systemImage: String
    let keywords: [String]

    func matches(_ query: String) -> Bool {
        SettingsCatalog.matches(
            query,
            values: [title, subtitle] + keywords
        )
    }
}

enum SettingsCatalog {
    static let sections = [
        SettingsCatalogSection(
            title: "播放器",
            items: [
                SettingsCatalogItem(
                    route: .playback,
                    title: "播放与音频",
                    subtitle: "音质、音量、均衡器、自动混音与播放行为",
                    systemImage: "waveform",
                    keywords: [
                        "高品质",
                        "无损",
                        "上一首",
                        "页面记忆",
                        "心动模式",
                        "启动播放",
                        "交叉淡化",
                    ]
                ),
                SettingsCatalogItem(
                    route: .playerAppearance,
                    title: "播放器界面",
                    subtitle: "背景、封面反馈与屏幕常亮",
                    systemImage: "paintbrush",
                    keywords: [
                        "模糊",
                        "色彩",
                        "饱和度",
                        "暂停",
                        "自动锁屏",
                    ]
                ),
                SettingsCatalogItem(
                    route: .lyrics,
                    title: "歌词",
                    subtitle: "Apple Music 方案、演奏段、排版、逐字与交互",
                    systemImage: "quote.bubble",
                    keywords: [
                        "Apple Music",
                        "EVA",
                        "文字PV",
                        "字体",
                        "YRC",
                        "LRC",
                        "前奏",
                        "间奏",
                        "三点",
                        "罗马音",
                        "翻译",
                        "伪逐字",
                        "辉光",
                        "刷新率",
                    ]
                ),
            ]
        ),
        SettingsCatalogSection(
            title: "系统与扩展歌词",
            items: [
                SettingsCatalogItem(
                    route: .systemPlayback,
                    title: "系统歌词显示",
                    subtitle: "播放信息、通知横幅、锁定屏幕与灵动岛歌词",
                    systemImage: "lock.display",
                    keywords: [
                        "控制中心",
                        "系统歌词",
                        "通知歌词",
                        "静音通知",
                        "横幅",
                        "Notification",
                        "Live Activity",
                        "标题格式",
                        "副标题",
                        "封面",
                        "播放进度",
                    ]
                ),
                SettingsCatalogItem(
                    route: .skylineLyrics,
                    title: "全屏天际歌词",
                    subtitle: "横屏布局、背景文字与动态效果",
                    systemImage: "rectangle.landscape.rotate",
                    keywords: [
                        "横屏",
                        "字号",
                        "漂移",
                        "倾斜",
                        "背景歌词",
                    ]
                ),
                SettingsCatalogItem(
                    route: .floatingLyrics,
                    title: "悬浮窗歌词",
                    subtitle: "画中画歌词、翻译与下一句",
                    systemImage: "pip",
                    keywords: [
                        "画中画",
                        "悬浮歌词",
                        "其他应用",
                        "歌词大小",
                    ]
                ),
            ]
        ),
        SettingsCatalogSection(
            title: "内容与存储",
            items: [
                SettingsCatalogItem(
                    route: .contentFeatures,
                    title: "功能模块",
                    subtitle: "启用或停用播客、下载、云盘与最近播放",
                    systemImage: "switch.2",
                    keywords: [
                        "开关",
                        "隐藏",
                        "播客",
                        "广播",
                        "下载",
                        "云盘",
                        "最近播放",
                        "播放记录",
                    ]
                ),
                SettingsCatalogItem(
                    route: .content,
                    title: "发现内容",
                    subtitle: "新碟地区、歌单信息与听歌识曲",
                    systemImage: "rectangle.stack",
                    keywords: [
                        "华语",
                        "欧美",
                        "韩国",
                        "日本",
                        "播放量",
                        "听歌识曲",
                        "麦克风",
                        "识别时长",
                        "持续识别",
                    ]
                ),
                SettingsCatalogItem(
                    route: .storage,
                    title: "存储管理",
                    subtitle:
                        AppFeatureAvailability.downloads
                            ? "空间统计、下载管理与缓存清理"
                            : "空间统计与缓存清理",
                    systemImage: "internaldrive",
                    keywords:
                        AppFeatureAvailability.downloads
                            ? [
                                "下载",
                                "自动缓存",
                                "存储",
                                "空间",
                                "清理",
                                "临时文件",
                                "数据库",
                                "触发次数",
                                "缓存音质",
                                "删除下载",
                            ]
                            : [
                                "存储",
                                "空间",
                                "清理",
                                "临时文件",
                                "数据库",
                            ]
                ),
            ]
        ),
        SettingsCatalogSection(
            title: "界面与应用",
            items: [
                SettingsCatalogItem(
                    route: .tabLayout,
                    title: "页面与标签栏",
                    subtitle: "调整首页、标签栏与音乐库中的页面",
                    systemImage: "rectangle.3.group",
                    keywords: [
                        "首页",
                        "TabView",
                        "标签栏",
                        "排序",
                        "推荐",
                        "播客",
                        "云盘",
                        "歌曲",
                        "歌单",
                        "历史",
                    ] + (AppFeatureAvailability.downloads ? ["下载"] : [])
                ),
                SettingsCatalogItem(
                    route: .general,
                    title: "通用",
                    subtitle: "主题、启动页面、剪贴板链接与音乐库记忆",
                    systemImage: "gearshape",
                    keywords: [
                        "主题",
                        "浅色",
                        "深色",
                        "跟随系统",
                        "默认页面",
                        "上次页面",
                        "首页",
                        "发现",
                        "音乐库",
                        "搜索",
                        "剪贴板",
                        "歌曲链接",
                        "一起听链接",
                        "网易云链接",
                    ]
                ),
            ]
        ),
        SettingsCatalogSection(
            title: "关于与开发",
            items: [
                SettingsCatalogItem(
                    route: .about,
                    title: "关于 MeloX",
                    subtitle: "版本、更新、社区与开源许可",
                    systemImage: "info.circle",
                    keywords: [
                        "GitHub",
                        "Telegram",
                        "更新日志",
                        "检查更新",
                        "声明",
                    ]
                ),
                SettingsCatalogItem(
                    route: .developer,
                    title: "开发者选项",
                    subtitle: "BeatNet 分析与播放器调试工具",
                    systemImage: "hammer",
                    keywords: [
                        "BeatNet",
                        "节拍",
                        "重拍",
                        "Onset",
                        "调试",
                        "Core ML",
                        "全曲分析",
                    ]
                ),
            ]
        ),
    ]

    static func filteredSections(
        matching query: String
    ) -> [SettingsCatalogSection] {
        let normalizedQuery = normalized(query)
        guard !normalizedQuery.isEmpty else { return sections }

        return sections.compactMap { section in
            let items = section.items.filter {
                $0.matches(normalizedQuery)
            }
            guard !items.isEmpty else { return nil }
            return SettingsCatalogSection(
                title: section.title,
                items: items
            )
        }
    }

    static func matchesAccount(_ query: String) -> Bool {
        matches(
            query,
            values: [
                "网易云账号",
                "登录",
                "退出登录",
                "Cookie",
                "个人主页",
                "用户 ID",
            ]
        )
    }

    static func matchesReset(_ query: String) -> Bool {
        matches(
            query,
            values: [
                "恢复播放器默认设置",
                "重置",
                "还原",
                "播放器",
                "歌词",
                "均衡器",
                "自动混音",
            ]
        )
    }

    static func matches(
        _ query: String,
        values: [String]
    ) -> Bool {
        let normalizedQuery = normalized(query)
        guard !normalizedQuery.isEmpty else { return true }

        let searchableText = values
            .joined(separator: " ")
            .lowercased()

        return normalizedQuery
            .split(whereSeparator: \.isWhitespace)
            .allSatisfy { searchableText.contains($0) }
    }

    private static func normalized(_ query: String) -> String {
        query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
