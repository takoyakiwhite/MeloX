import SwiftUI

struct LyricsContentSettingsView: View {
    @Environment(AppSettings.self) private var settings

    private var usesWordByWordPresentation: Bool {
        settings.lyricsWordByWord || settings.lyricsPseudoWordByWord
    }

    private var usesAppleMusic26Motion: Bool {
        settings.lyricsStyle == .appleMusic
            && settings.appleMusicLyrics.usesAppleMusic26Motion
    }

    private var usesCustomAppleMusicPresentation: Bool {
        settings.lyricsStyle == .appleMusic
            && !settings.appleMusicLyrics.usesAppleMusic26Motion
    }

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                Toggle(
                    "显示发音（罗马音）",
                    isOn: $settings.lyricsRomanizationEnabled
                )

                Toggle(
                    "显示歌词翻译",
                    isOn: $settings.lyricsTranslationEnabled
                )

                if usesCustomAppleMusicPresentation,
                   settings.lyricsRomanizationEnabled {
                    Picker(
                        "罗马音显示范围",
                        selection:
                            $settings
                                .lyricsRomanizationDisplayMode
                    ) {
                        ForEach(
                            LyricsTranslationDisplayMode.allCases
                        ) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                }

                if usesCustomAppleMusicPresentation,
                   settings.lyricsTranslationEnabled {
                    Picker(
                        "翻译显示范围",
                        selection:
                            $settings
                                .lyricsTranslationDisplayMode
                    ) {
                        ForEach(
                            LyricsTranslationDisplayMode.allCases
                        ) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                }
            } header: {
                Text("翻译与发音")
            } footer: {
                Text("使用网易云提供的 yromalrc/romalrc 与 ytlrc/tlyric。Apple Music 样式将罗马音作为主歌词下方、按原词位置对齐的副行；翻译位于下一层，保持静态整行显示。")
            }

            if usesCustomAppleMusicPresentation,
               settings.lyricsRomanizationEnabled {
                Section {
                    valueSlider(
                        title: "罗马音大小",
                        value: $settings.lyricsRomanizationFontScale,
                        range: 0.5...0.8,
                        step: 0.05,
                        valueText:
                            "\(Int(settings.lyricsRomanizationFontScale * 100))%"
                    )

                    valueSlider(
                        title: "罗马音亮度",
                        value: $settings.lyricsRomanizationOpacity,
                        range: 0.4...0.9,
                        step: 0.05,
                        valueText:
                            "\(Int(settings.lyricsRomanizationOpacity * 100))%"
                    )
                } header: {
                    Text("罗马音样式")
                }
            }

            if usesCustomAppleMusicPresentation,
               settings.lyricsTranslationEnabled {
                Section {
                    valueSlider(
                        title: "翻译歌词大小",
                        value: $settings.lyricsTranslationFontScale,
                        range: 0.5...0.8,
                        step: 0.05,
                        valueText:
                            "\(Int(settings.lyricsTranslationFontScale * 100))%"
                    )

                    valueSlider(
                        title: "翻译歌词亮度",
                        value: $settings.lyricsTranslationOpacity,
                        range: 0.4...0.9,
                        step: 0.05,
                        valueText:
                            "\(Int(settings.lyricsTranslationOpacity * 100))%"
                    )
                } header: {
                    Text("翻译样式")
                }
            }

            Section {
                Toggle(
                    "AMLL TTML 歌词",
                    isOn: $settings.lyricsAMLLSourceEnabled
                )

                Toggle(
                    "QQ 音乐歌词补全",
                    isOn: $settings.lyricsQQMusicSourceEnabled
                )
            } header: {
                Text("歌词来源")
            } footer: {
                Text("开启后会直接访问对应歌词服务。优先级为 AMLL TTML、网易云 YRC、QQ QRC、网易云 LRC、QQ LRC。")
            }

            Section {
                Toggle(
                    "双人歌词分列显示",
                    isOn: $settings.lyricsDuetLayoutEnabled
                )
            } header: {
                Text("演唱者布局")
            } footer: {
                Text("根据歌词中的演唱者标记，将不同演唱者分别靠左、靠右显示；合唱保持靠左。")
            }

            Section {
                Toggle(
                    "使用官方逐字歌词",
                    isOn: $settings.lyricsWordByWord
                )

                Toggle(
                    "无 YRC 时启用伪逐字",
                    isOn: $settings.lyricsPseudoWordByWord
                )
            } header: {
                Text("逐字歌词")
            } footer: {
                Text("官方逐字歌词使用 YRC 时间轴；伪逐字仅在没有 YRC 时按行时长估算，准确度较低。")
            }

            if usesWordByWordPresentation {
                if usesAppleMusic26Motion {
                    Section {
                        LabeledContent("高光渐变", value: "30 磅")
                        LabeledContent("音节抬升", value: "2 磅")
                        LabeledContent("辉光半径", value: "5 磅")
                        LabeledContent("长音最大强调", value: "114%")

                        valueSlider(
                            title: "网易 YRC 长音阈值",
                            value:
                                $settings
                                    .lyricsLongSyllableDurationThreshold,
                            range:
                                AppSettings
                                    .lyricsLongSyllableDurationThresholdRange,
                            step: 0.05,
                            valueText:
                                "\(settings.lyricsLongSyllableDurationThreshold.formatted(.number.precision(.fractionLength(2)))) 秒"
                        )
                    } header: {
                        Text("Apple Music 26 逐字")
                    } footer: {
                        Text("根据逐字歌词中音节持续的时间识别长音；阈值越高，触发长音效果的音节越少。")
                    }
                }

                if !usesAppleMusic26Motion {
                    Section {
                        Picker(
                            "抬升方式",
                            selection: $settings.lyricsLiftMode
                        ) {
                            ForEach(LyricsLiftMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        valueSlider(
                            title: "高光渐变宽度",
                            value:
                                $settings.lyricsHighlightGradientWidth,
                            range:
                                AppSettings
                                    .lyricsHighlightGradientWidthRange,
                            step: 0.1,
                            valueText:
                                "\(settings.lyricsHighlightGradientWidth.formatted(.number.precision(.fractionLength(1)))) 个字宽"
                        )

                        valueSlider(
                            title: "渐变削减程度",
                            value:
                                $settings
                                    .lyricsHighlightGradientReduction,
                            range:
                                AppSettings
                                    .lyricsHighlightGradientReductionRange,
                            step: 0.05,
                            valueText: settings
                                .lyricsHighlightGradientReduction
                                .formatted(
                                    .percent.precision(
                                        .fractionLength(0)
                                    )
                                )
                        )
                    } header: {
                        Text("高光")
                    } footer: {
                        Text("抬升方式只改变按字或按词分组，不改变高光时间；渐变宽度和削减程度共同控制过渡范围。")
                    }

                    Section {
                        Picker(
                            "长音识别方式",
                            selection:
                                $settings
                                    .lyricsLongSyllableDetectionMode
                        ) {
                            ForEach(
                                LyricsLongSyllableDetectionMode.allCases
                            ) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        valueSlider(
                            title: "长音判定阈值",
                            value:
                                $settings
                                    .lyricsLongSyllableDurationThreshold,
                            range:
                                AppSettings
                                    .lyricsLongSyllableDurationThresholdRange,
                            step: 0.05,
                            valueText:
                                "\(settings.lyricsLongSyllableDurationThreshold.formatted(.number.precision(.fractionLength(2)))) 秒"
                        )

                        valueSlider(
                            title: "长音膨胀大小",
                            value:
                                $settings
                                    .lyricsLongToneExpansionAmount,
                            range:
                                AppSettings
                                    .lyricsLongToneExpansionAmountRange,
                            step: 0.01,
                            valueText: settings
                                .lyricsLongToneExpansionAmount
                                .formatted(
                                    .percent.precision(
                                        .fractionLength(0)
                                    )
                                )
                        )

                        Toggle(
                            "逐字歌词光效",
                            isOn: $settings.lyricsGlowEnabled
                        )

                        if settings.lyricsGlowEnabled {
                            Toggle(
                                "仅长音显示辉光",
                                isOn:
                                    $settings
                                        .lyricsGlowLongSyllablesOnly
                            )

                            valueSlider(
                                title: "逐字光效强度",
                                value: $settings.lyricsGlowIntensity,
                                range: 0.4...1.6,
                                step: 0.1,
                                valueText:
                                    settings.lyricsGlowIntensity
                                        .formatted(
                                            .number.precision(
                                                .fractionLength(1)
                                            )
                                        )
                            )
                        }
                    } header: {
                        Text("长音与光效")
                    } footer: {
                        Text("达到阈值的原文字或词会依次膨胀；罗马音不参与辉光、抬升或长音膨胀，翻译保持静态整行。")
                    }
                }
            }
        }
        .navigationTitle("翻译与逐字")
        .navigationBarTitleDisplayMode(.inline)
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
