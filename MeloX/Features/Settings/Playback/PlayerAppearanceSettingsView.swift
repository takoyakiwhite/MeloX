import SwiftUI

struct PlayerAppearanceSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                Picker(
                    "背景样式",
                    selection: $settings.playerBackgroundStyle
                ) {
                    ForEach(PlayerBackgroundStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }

                valueSlider(
                    title: "背景色彩",
                    value: $settings.playerBackgroundSaturation,
                    range: 0.4...1.2,
                    step: 0.05,
                    valueText:
                        "\(Int(settings.playerBackgroundSaturation * 100))%"
                )

                if settings.playerBackgroundStyle != .blurredArtwork {
                    valueSlider(
                        title: "动态速度",
                        value:
                            $settings
                                .playerBackgroundMotionIntensity,
                        range: 0.4...1.4,
                        step: 0.1,
                        valueText:
                            "\(Int(settings.playerBackgroundMotionIntensity * 100))%"
                    )

                    if settings.playerBackgroundStyle == .flowingLight {
                        Toggle(
                            "重拍暗角",
                            isOn:
                                $settings
                                    .playerBackgroundBeatEffectsEnabled
                        )
                    } else {
                        Toggle(
                            "随音乐响应",
                            isOn:
                                $settings
                                    .playerBackgroundAudioResponseEnabled
                        )
                    }
                } else {
                    valueSlider(
                        title: "背景模糊",
                        value: $settings.playerBackgroundBlur,
                        range: 0...140,
                        step: 5,
                        valueText:
                            "\(Int(settings.playerBackgroundBlur))"
                    )
                }

                Toggle(
                    "暂停时缩小封面",
                    isOn: $settings.shrinksPausedArtwork
                )
            } header: {
                Text("背景与封面")
            } footer: {
                Text(backgroundFooter)
            }

            Section {
                Picker(
                    "屏幕常亮",
                    selection: $settings.playerScreenAwakeMode
                ) {
                    ForEach(PlayerScreenAwakeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            } header: {
                Text("屏幕")
            } footer: {
                Text("决定竖屏播放器何时阻止自动锁屏；横屏天际歌词使用独立设置。")
            }
        }
        .navigationTitle("播放器界面")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var backgroundFooter: String {
        switch settings.playerBackgroundStyle {
        case .appleMusicBackdrop:
            "Apple Music 背景由公开的 SwiftUI 与 Metal API 实现；可选的音乐响应默认关闭，效果遵循“减少动态效果”和“调暗闪烁光线”设置。"
        case .flowingLight:
            "流动光影会从封面提取颜色；100% 是增强后的流动基准，速度和位移约为旧效果的 2 倍。开启“重拍暗角”后，Onset 达到 0.4 且 Beat 或 Downbeat 在前后 20 ms 内达到 0.4 时触发暗角；Downbeat 达到 0.6 时会略微加深。效果遵循系统的“减少动态效果”和“调暗闪烁光线”设置。"
        case .blurredArtwork:
            "模糊封面保留原有背景效果。背景选项会实时生效。"
        }
    }

    private func valueSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent(title, value: valueText)
            Slider(value: value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(valueText)
        }
    }
}
