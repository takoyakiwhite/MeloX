import SwiftUI

struct DesktopLyricsAppearanceSettingsView: View {
    @Environment(DesktopAppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        @Bindable var appleMusicLyrics = model.settings.appleMusicLyrics

        ScrollView {
            Form {
                Section("基础排版") {
                    LabeledContent("样式", value: LyricsStyle.appleMusic.title)

                    Picker(
                        "呈现方案",
                        selection: $appleMusicLyrics.motionPreset
                    ) {
                        ForEach(AppleMusicLyricsMotionPreset.allCases) {
                            preset in
                            Text(preset.title).tag(preset)
                        }
                    }

                    if appleMusicLyrics.usesAppleMusic26Motion {
                        LabeledContent(
                            "正文字号",
                            value: "24 / 28 / 38 / 50 / 72 磅（随列宽）"
                        )
                        LabeledContent("字体粗细", value: "粗体")
                    } else {
                        HStack {
                            Text("字体大小")
                            Slider(
                                value: $settings.lyricsFontSize,
                                in: AppSettings.desktopLyricsFontSizeRange,
                                step: 1
                            )
                            Text("\(Int(settings.lyricsFontSize.rounded())) 磅")
                                .monospacedDigit()
                                .frame(width: 62, alignment: .trailing)
                        }

                        Picker(
                            "字体粗细",
                            selection: $settings.lyricsFontWeight
                        ) {
                            ForEach(LyricsFontWeight.allCases) { weight in
                                Text(weight.title).tag(weight)
                            }
                        }
                    }

                    Text(appleMusicLyrics.motionPreset.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Apple Music 布局") {
                    Toggle(
                        "显示等待倒计时",
                        isOn: $settings.lyricsInterludeCountdownEnabled
                    )

                    if appleMusicLyrics.usesAppleMusic26Motion {
                        LabeledContent("失焦歌词缩放", value: "98%")
                        LabeledContent("歌词行间距", value: "25 磅")
                        LabeledContent("单句换行附加", value: "0 磅")
                        LabeledContent("段落组间距", value: "39 磅")
                        LabeledContent("首行起始位置", value: "60 磅")
                        LabeledContent(
                            "焦点位置规则",
                            value: "对齐主封面垂直中心"
                        )
                        LabeledContent("顶部安全补偿", value: "22 磅")
                        LabeledContent("顶部渐变结束", value: "8%")
                        LabeledContent(
                            "节奏指示器",
                            value: "3 点 · 高 40 · 18 + 11"
                        )
                        LabeledContent("双人声部宽度", value: "85%")
                        LabeledContent("背景声部间距", value: "15 磅")
                    } else {
                        HStack {
                            Text("当前歌词大小")
                            Slider(
                                value: $settings.lyricsCurrentLineScale,
                                in: AppSettings.lyricsCurrentLineScaleRange,
                                step: 0.01
                            )
                            Text(
                                "\(Int((settings.lyricsCurrentLineScale * 100).rounded()))%"
                            )
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                        }

                        HStack {
                            Text("歌词行距")
                            Slider(
                                value: $settings.lyricsLineSpacing,
                                in: AppSettings.desktopLyricsLineSpacingRange,
                                step: 1
                            )
                            Text("\(Int(settings.lyricsLineSpacing.rounded()))")
                                .monospacedDigit()
                                .frame(width: 48, alignment: .trailing)
                        }

                        HStack {
                            Text("焦点垂直位置")
                            Slider(
                                value: $settings.lyricsFocusPosition,
                                in: AppSettings.lyricsFocusPositionRange,
                                step: 0.01
                            )
                            Text(
                                "\(Int((settings.lyricsFocusPosition * 100).rounded()))%"
                            )
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                        }
                    }
                }

                Section("焦点与模糊") {
                    if appleMusicLyrics.usesAppleMusic26Motion {
                        LabeledContent("非焦点模糊", value: "3 磅")
                        LabeledContent("最大模糊", value: "4 磅")
                        LabeledContent("非焦点文字", value: "17.5%")
                        LabeledContent("焦点待播放文字", value: "35%")
                    } else {
                        HStack {
                            Text("基础模糊强度")
                            Slider(
                                value: $settings.lyricsBlurIntensity,
                                in: AppSettings.lyricsBlurIntensityRange,
                                step: 0.1
                            )
                            Text(
                                settings.lyricsBlurIntensity.formatted(
                                    .number.precision(.fractionLength(1))
                                )
                            )
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                        }

                        HStack {
                            Text("逐句模糊加强")
                            Slider(
                                value: $settings.lyricsDistanceBlurScale,
                                in: AppSettings.lyricsDistanceBlurScaleRange,
                                step: 0.05
                            )
                            Text(
                                "\(Int((settings.lyricsDistanceBlurScale * 100).rounded()))%"
                            )
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                        }

                        HStack {
                            Text("非焦点歌词变暗")
                            Slider(
                                value: $settings.lyricsDimAmount,
                                in: 0...1,
                                step: 0.1
                            )
                            Text(
                                "\(Int((settings.lyricsDimAmount * 100).rounded()))%"
                            )
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                        }
                    }
                }
            }
            .formStyle(.columns)
            .padding()
        }
        .scrollIndicators(.automatic)
    }
}
