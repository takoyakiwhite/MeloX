import SwiftUI

struct LyricsSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    LyricsAppearanceSettingsView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("外观与排版")
                            Text("呈现方案、前奏/间奏、字体、焦点和模糊")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "textformat.size")
                    }
                }

                NavigationLink {
                    LyricsContentSettingsView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("翻译与逐字")
                            Text("翻译、YRC、伪逐字、高光与长音")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "character.book.closed")
                    }
                }

                NavigationLink {
                    LyricsInteractionSettingsView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("交互与同步")
                            Text("跳转、自动跟随、提前量和界面隐藏")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "hand.tap")
                    }
                }

                NavigationLink {
                    LyricsAnimationSettingsView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("动画与性能")
                            Text("时间轴刷新、拖尾、追赶和回弹")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "sparkles")
                    }
                }
            } header: {
                Text("竖屏歌词")
            } footer: {
                Text("当前使用“\(settings.lyricsStyle.title)”样式。全屏天际歌词和悬浮窗歌词可在设置总览中单独调整。")
            }
        }
        .navigationTitle("歌词")
        .navigationBarTitleDisplayMode(.inline)
    }
}
