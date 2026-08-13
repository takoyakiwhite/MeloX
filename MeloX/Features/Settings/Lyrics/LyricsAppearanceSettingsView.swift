import SwiftUI

struct LyricsAppearanceSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        @Bindable var appleMusicLyrics = settings.appleMusicLyrics
        @Bindable var interlude = settings.lyricsInterlude

        Form {
            Section {
                Picker("歌词样式", selection: $settings.lyricsStyle) {
                    ForEach(LyricsStyle.allCases) { style in
                        Label(style.title, systemImage: style.systemImage)
                            .tag(style)
                    }
                }

                if settings.lyricsStyle == .textPV {
                    NavigationLink {
                        TextPVSettingsView()
                    } label: {
                        LabeledContent(
                            "文字PV设置",
                            value: settings.textPV.style.title
                        )
                    }
                }

                if settings.lyricsStyle == .appleMusic {
                    Picker(
                        "呈现方案",
                        selection: $appleMusicLyrics.motionPreset
                    ) {
                        ForEach(AppleMusicLyricsMotionPreset.allCases) {
                            preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                }
            } header: {
                Text("样式")
            } footer: {
                Text(styleDescription)
            }

            Section {
                if appleMusicLyrics.usesAppleMusic26Motion,
                   settings.lyricsStyle == .appleMusic {
                    LabeledContent("正文字号", value: "36 磅")
                    LabeledContent("字体粗细", value: "粗体")
                } else {
                    valueSlider(
                        title: "字体大小",
                        value: $settings.lyricsFontSize,
                        range: 20...36,
                        step: 1,
                        valueText: "\(Int(settings.lyricsFontSize)) 磅"
                    )

                    Picker(
                        "字体粗细",
                        selection: $settings.lyricsFontWeight
                    ) {
                        ForEach(LyricsFontWeight.allCases) { weight in
                            Text(weight.title).tag(weight)
                        }
                    }
                }
            } header: {
                Text("基础排版")
            } footer: {
                Text(typographyDescription)
            }

            if settings.lyricsStyle == .appleMusic {
                Section {
                    Picker(
                        "前奏与间奏",
                        selection: $interlude.mode
                    ) {
                        ForEach(
                            LyricsInterludePresentationMode.allCases
                        ) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }

                    if interlude.mode == .automatic {
                        valueSlider(
                            title: "LRC 最短推断空档",
                            value:
                                $interlude
                                    .minimumInferredGapDuration,
                            range:
                                LyricsInterludePreferences
                                    .inferredGapDurationRange,
                            step: 0.5,
                            valueText:
                                "\(interlude.minimumInferredGapDuration.formatted(.number.precision(.fractionLength(1)))) 秒"
                        )
                    }

                    if appleMusicLyrics.motionPreset == .custom {
                        valueSlider(
                            title: "当前歌词大小",
                            value: $settings.lyricsCurrentLineScale,
                            range: AppSettings.lyricsCurrentLineScaleRange,
                            step: 0.01,
                            valueText:
                                "\(Int((settings.lyricsCurrentLineScale * 100).rounded()))%"
                        )

                        valueSlider(
                            title: "歌词行距",
                            value: $settings.lyricsLineSpacing,
                            range: 12...36,
                            step: 1,
                            valueText: "\(Int(settings.lyricsLineSpacing))"
                        )
                    } else {
                        LabeledContent("失焦歌词缩放", value: "98%")
                        LabeledContent("歌词行距", value: "25 磅")
                        LabeledContent("段落间距", value: "39 磅")
                        LabeledContent("首行起始位置", value: "60 磅")
                        LabeledContent("焦点垂直位置", value: "距顶部 12%")
                    }

                    if appleMusicLyrics.motionPreset == .custom {
                        valueSlider(
                            title: "焦点垂直位置",
                            value: $settings.lyricsFocusPosition,
                            range: AppSettings.lyricsFocusPositionRange,
                            step: 0.01,
                            valueText:
                                "距顶部 \(Int(settings.lyricsFocusPosition * 100))%"
                        )
                    }
                } header: {
                    Text("Apple Music 布局")
                } footer: {
                    Text(interludeDescription)
                }

                Section {
                    if appleMusicLyrics.motionPreset == .custom {
                        valueSlider(
                            title: "基础模糊强度",
                            value: $settings.lyricsBlurIntensity,
                            range: 0...2,
                            step: 0.1,
                            valueText:
                                settings.lyricsBlurIntensity.formatted(
                                    .number.precision(
                                        .fractionLength(1)
                                    )
                                )
                        )
                    } else {
                        LabeledContent("非焦点模糊", value: "3 磅")
                        LabeledContent("最大模糊", value: "4 磅")
                    }

                    Toggle(
                        appleMusicLyrics.usesAppleMusic26Motion
                            ? "手动浏览时清除行模糊"
                            : "手动浏览时统一变暗",
                        isOn:
                            $settings
                                .lyricsUsesUniformDimmingWhileBrowsing
                    )

                    if appleMusicLyrics.motionPreset == .custom {
                        valueSlider(
                            title: "默认逐句模糊加强",
                            value: $settings.lyricsDistanceBlurScale,
                            range: AppSettings.lyricsDistanceBlurScaleRange,
                            step: 0.05,
                            valueText:
                                "\(Int((settings.lyricsDistanceBlurScale * 100).rounded()))%"
                        )

                        valueSlider(
                            title: "隐藏 UI 逐句模糊加强",
                            value:
                                $settings
                                    .lyricsHiddenInterfaceBlurScale,
                            range: AppSettings.lyricsDistanceBlurScaleRange,
                            step: 0.05,
                            valueText:
                                "\(Int((settings.lyricsHiddenInterfaceBlurScale * 100).rounded()))%"
                        )
                    }

                    if appleMusicLyrics.motionPreset == .custom {
                        valueSlider(
                            title: "非焦点歌词变暗",
                            value: $settings.lyricsDimAmount,
                            range: 0...1,
                            step: 0.1,
                            valueText:
                                "\(Int(settings.lyricsDimAmount * 100))%"
                        )
                    } else {
                        LabeledContent("非焦点文字", value: "17.5%")
                        LabeledContent("待播放文字", value: "35%")
                    }
                } header: {
                    Text("Apple Music 焦点")
                } footer: {
                    Text("手动浏览时可保留当前播放句为唯一焦点；恢复跟随后重新应用逐句渐暗和模糊。")
                }
            }
        }
        .navigationTitle("外观与排版")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var styleDescription: String {
        guard settings.lyricsStyle == .appleMusic else {
            return settings.lyricsStyle.description
        }
        return settings.lyricsStyle.description
            + "\n"
            + settings.appleMusicLyrics.motionPreset.description
    }

    private var typographyDescription: String {
        if settings.lyricsStyle == .appleMusic,
           settings.appleMusicLyrics.usesAppleMusic26Motion {
            return "当前呈现使用固定 36 磅粗体；切换到自定义后可调整正文基准字号与粗细。"
        }
        return "字号是歌词正文基准，翻译按比例缩放；EVA 会继承字号缩放，文字PV保留模板排版与字形风格。"
    }

    private var interludeDescription: String {
        settings.lyricsInterlude.mode.description
            + " 指示器会作为独立歌词焦点滚入，结束时直接把焦点交给下一句。点的尺寸和时序固定使用 iOS 26.6 参数。"
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
