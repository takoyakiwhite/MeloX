import SwiftUI

struct DesktopLyricsContentSettingsView: View {
    @Environment(DesktopAppModel.self) private var model

    private var usesWordByWordPresentation: Bool {
        model.settings.lyricsWordByWord
            || model.settings.lyricsPseudoWordByWord
    }

    var body: some View {
        @Bindable var settings = model.settings

        ScrollView {
            Form {
                Section("翻译与发音") {
                    Toggle(
                        "显示发音（罗马音）",
                        isOn: $settings.lyricsRomanizationEnabled
                    )
                    if settings.lyricsRomanizationEnabled {
                        Picker(
                            "罗马音显示范围",
                            selection:
                                $settings.lyricsRomanizationDisplayMode
                        ) {
                            ForEach(
                                LyricsTranslationDisplayMode.allCases
                            ) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }

                        HStack {
                            Text("罗马音大小")
                            Slider(
                                value:
                                    $settings.lyricsRomanizationFontScale,
                                in: 0.5...0.8,
                                step: 0.05
                            )
                            Text(
                                "\(Int((settings.lyricsRomanizationFontScale * 100).rounded()))%"
                            )
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                        }

                        HStack {
                            Text("罗马音亮度")
                            Slider(
                                value: $settings.lyricsRomanizationOpacity,
                                in: 0.4...0.9,
                                step: 0.05
                            )
                            Text(
                                "\(Int((settings.lyricsRomanizationOpacity * 100).rounded()))%"
                            )
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                        }
                    }

                    Toggle(
                        "显示歌词翻译",
                        isOn: $settings.lyricsTranslationEnabled
                    )
                    if settings.lyricsTranslationEnabled {
                        Picker(
                            "翻译显示范围",
                            selection:
                                $settings.lyricsTranslationDisplayMode
                        ) {
                            ForEach(
                                LyricsTranslationDisplayMode.allCases
                            ) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }

                        HStack {
                            Text("翻译歌词大小")
                            Slider(
                                value: $settings.lyricsTranslationFontScale,
                                in: 0.5...0.8,
                                step: 0.05
                            )
                            Text(
                                "\(Int((settings.lyricsTranslationFontScale * 100).rounded()))%"
                            )
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                        }

                        HStack {
                            Text("翻译歌词亮度")
                            Slider(
                                value: $settings.lyricsTranslationOpacity,
                                in: 0.4...0.9,
                                step: 0.05
                            )
                            Text(
                                "\(Int((settings.lyricsTranslationOpacity * 100).rounded()))%"
                            )
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                        }
                    }
                }

                Section("歌词来源") {
                    Toggle(
                        "AMLL TTML 歌词",
                        isOn: $settings.lyricsAMLLSourceEnabled
                    )
                    Toggle(
                        "QQ 音乐歌词补全",
                        isOn: $settings.lyricsQQMusicSourceEnabled
                    )
                    Text("开启后会直接访问对应歌词服务。优先级为 AMLL TTML、网易云 YRC、QQ QRC、网易云 LRC、QQ LRC。")
                        .foregroundStyle(.secondary)
                }

                Section("演唱者布局") {
                    Toggle(
                        "双人歌词分列显示",
                        isOn: $settings.lyricsDuetLayoutEnabled
                    )
                    Text("根据歌词中的演唱者标记，将不同演唱者分别靠左、靠右显示；合唱保持靠左。")
                        .foregroundStyle(.secondary)
                }

                Section("逐字歌词") {
                    Toggle(
                        "使用官方逐字歌词",
                        isOn: $settings.lyricsWordByWord
                    )
                    Toggle(
                        "无 YRC 时启用伪逐字",
                        isOn: $settings.lyricsPseudoWordByWord
                    )
                }

                if usesWordByWordPresentation {
                    Section("高光") {
                        Picker(
                            "抬升方式",
                            selection: $settings.lyricsLiftMode
                        ) {
                            ForEach(LyricsLiftMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        HStack {
                            Text("高光渐变宽度")
                            Slider(
                                value:
                                    $settings.lyricsHighlightGradientWidth,
                                in:
                                    AppSettings
                                        .lyricsHighlightGradientWidthRange,
                                step: 0.1
                            )
                            Text(
                                settings.lyricsHighlightGradientWidth
                                    .formatted(
                                        .number.precision(
                                            .fractionLength(1)
                                        )
                                    )
                            )
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                        }

                        HStack {
                            Text("渐变削减程度")
                            Slider(
                                value:
                                    $settings
                                        .lyricsHighlightGradientReduction,
                                in:
                                    AppSettings
                                        .lyricsHighlightGradientReductionRange,
                                step: 0.05
                            )
                            Text(
                                "\(Int((settings.lyricsHighlightGradientReduction * 100).rounded()))%"
                            )
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                        }
                    }

                    Section("长音与光效") {
                        Picker(
                            "长音识别方式",
                            selection:
                                $settings.lyricsLongSyllableDetectionMode
                        ) {
                            ForEach(
                                LyricsLongSyllableDetectionMode.allCases
                            ) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        HStack {
                            Text("长音判定阈值")
                            Slider(
                                value:
                                    $settings
                                        .lyricsLongSyllableDurationThreshold,
                                in:
                                    AppSettings
                                        .lyricsLongSyllableDurationThresholdRange,
                                step: 0.05
                            )
                            Text(
                                "\(settings.lyricsLongSyllableDurationThreshold, specifier: "%.2f") s"
                            )
                            .monospacedDigit()
                            .frame(width: 64, alignment: .trailing)
                        }

                        HStack {
                            Text("长音膨胀大小")
                            Slider(
                                value:
                                    $settings.lyricsLongToneExpansionAmount,
                                in:
                                    AppSettings
                                        .lyricsLongToneExpansionAmountRange,
                                step: 0.01
                            )
                            Text(
                                "\(Int((settings.lyricsLongToneExpansionAmount * 100).rounded()))%"
                            )
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                        }

                        Toggle(
                            "逐字歌词光效",
                            isOn: $settings.lyricsGlowEnabled
                        )
                        if settings.lyricsGlowEnabled {
                            Toggle(
                                "仅长音显示辉光",
                                isOn:
                                    $settings.lyricsGlowLongSyllablesOnly
                            )
                            HStack {
                                Text("逐字光效强度")
                                Slider(
                                    value: $settings.lyricsGlowIntensity,
                                    in:
                                        AppSettings
                                            .lyricsGlowIntensityRange,
                                    step: 0.1
                                )
                                Text(
                                    settings.lyricsGlowIntensity.formatted(
                                        .number.precision(
                                            .fractionLength(1)
                                        )
                                    )
                                )
                                .monospacedDigit()
                                .frame(width: 48, alignment: .trailing)
                            }
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
