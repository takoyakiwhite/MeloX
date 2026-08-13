import SwiftUI

struct LyricsAnimationSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        @Bindable var appleMusicLyrics = settings.appleMusicLyrics

        Form {
            Section {
                Picker(
                    "逐字与时间轴刷新率",
                    selection: $settings.lyricsRefreshRate
                ) {
                    ForEach(LyricsRefreshRate.allCases) { refreshRate in
                        Text(refreshRate.title).tag(refreshRate)
                    }
                }
            } header: {
                Text("性能")
            } footer: {
                Text("控制逐字高光、歌词焦点、错峰移动与演奏段指示器的逐帧更新。越高越流畅，也越耗电；低电量模式和高负载文字PV会自动限制为 30 FPS。")
            }

            if settings.lyricsStyle == .appleMusic,
               appleMusicLyrics.motionPreset == .custom {
                Section {
                    valueSlider(
                        title: "基础拖尾延迟",
                        value: $settings.lyricsFocusCascadeDelay,
                        range: AppSettings.lyricsFocusCascadeDelayRange,
                        step: 0.001,
                        valueText:
                            "\(Int((settings.lyricsFocusCascadeDelay * 1_000).rounded())) 毫秒"
                    )

                    valueSlider(
                        title: "逐句拖尾增量",
                        value: $settings.lyricsFocusCascadeDelayIncrease,
                        range:
                            AppSettings
                                .lyricsFocusCascadeDelayIncreaseRange,
                        step: 0.001,
                        valueText:
                            "\(Int((settings.lyricsFocusCascadeDelayIncrease * 1_000).rounded())) 毫秒/句"
                    )

                    valueSlider(
                        title: "后续歌词启动延迟",
                        value: $settings.lyricsFocusCascadeFollowingDelay,
                        range:
                            AppSettings
                                .lyricsFocusCascadeFollowingDelayRange,
                        step: 0.001,
                        valueText:
                            "\(Int((settings.lyricsFocusCascadeFollowingDelay * 1_000).rounded())) 毫秒"
                    )

                    valueSlider(
                        title: "拖尾追赶节奏",
                        value: $settings.lyricsFocusCascadeCatchUpRatio,
                        range:
                            AppSettings
                                .lyricsFocusCascadeCatchUpRatioRange,
                        step: 0.01,
                        valueText:
                            "\(Int((settings.lyricsFocusCascadeCatchUpRatio * 100).rounded()))%"
                    )

                    valueSlider(
                        title: "追赶速度梯度",
                        value:
                            $settings
                                .lyricsFocusCascadeChaseSpeedGradient,
                        range:
                            AppSettings
                                .lyricsFocusCascadeChaseSpeedGradientRange,
                        step: 0.01,
                        valueText:
                            "\(Int((settings.lyricsFocusCascadeChaseSpeedGradient * 100).rounded()))%"
                    )

                    valueSlider(
                        title: "位移收束时长",
                        value: $settings.lyricsFocusCascadeDuration,
                        range:
                            AppSettings
                                .lyricsFocusCascadeDurationRange,
                        step: 0.01,
                        valueText:
                            "\(settings.lyricsFocusCascadeDuration.formatted(.number.precision(.fractionLength(2)))) 秒"
                    )

                    valueSlider(
                        title: "瞬移阈值",
                        value: $settings.lyricsFocusSnapThreshold,
                        range: AppSettings.lyricsFocusSnapThresholdRange,
                        step: 0.001,
                        valueText:
                            "\(Int((settings.lyricsFocusSnapThreshold * 1_000).rounded())) 毫秒"
                    )
                } header: {
                    Text("移动与追赶")
                } footer: {
                    Text("后续行会按拖尾参数依次启动并追赶；剩余时间短于瞬移阈值时会直接对齐。")
                }

                Section {
                    Toggle(
                        "启用位移回弹",
                        isOn:
                            $settings
                                .lyricsFocusCascadeBounceEnabled
                    )

                    if settings.lyricsFocusCascadeBounceEnabled {
                        valueSlider(
                            title: "最大回弹弹性",
                            value: $settings.lyricsFocusCascadeBounce,
                            range:
                                AppSettings
                                    .lyricsFocusCascadeBounceRange,
                            step: 0.01,
                            valueText:
                                "\(Int((settings.lyricsFocusCascadeBounce * 100).rounded()))%"
                        )

                        valueSlider(
                            title: "回弹强度梯度",
                            value:
                                $settings
                                    .lyricsFocusCascadeBounceGradient,
                            range:
                                AppSettings
                                    .lyricsFocusCascadeBounceGradientRange,
                            step: 0.01,
                            valueText:
                                "\(Int((settings.lyricsFocusCascadeBounceGradient * 100).rounded()))%"
                        )
                    }

                    Toggle(
                        "启用升格回弹",
                        isOn:
                            $settings
                                .lyricsFocusScaleBounceEnabled
                    )

                    if settings.lyricsFocusScaleBounceEnabled {
                        valueSlider(
                            title: "升格回弹时长",
                            value:
                                $settings
                                    .lyricsFocusScaleBounceDuration,
                            range:
                                AppSettings
                                    .lyricsFocusScaleBounceDurationRange,
                            step: 0.01,
                            valueText:
                                "\(settings.lyricsFocusScaleBounceDuration.formatted(.number.precision(.fractionLength(2)))) 秒"
                        )

                        valueSlider(
                            title: "升格回弹弹性",
                            value: $settings.lyricsFocusScaleBounce,
                            range:
                                AppSettings
                                    .lyricsFocusScaleBounceRange,
                            step: 0.01,
                            valueText:
                                "\(Int((settings.lyricsFocusScaleBounce * 100).rounded()))%"
                        )
                    }

                    valueSlider(
                        title: "焦点颜色提前",
                        value: $settings.lyricsFocusColorLeadTime,
                        range:
                            AppSettings
                                .lyricsFocusColorLeadTimeRange,
                        step: 0.005,
                        valueText:
                            "\(Int((settings.lyricsFocusColorLeadTime * 1_000).rounded())) 毫秒"
                    )
                } header: {
                    Text("回弹与焦点")
                } footer: {
                    Text("位移回弹作用于整页移动，升格回弹作用于当前行放大；焦点颜色可设置为先于或晚于移动变化。")
                }
            } else if settings.lyricsStyle == .appleMusic {
                Section {
                    LabeledContent("正向逐行延迟", value: "50 毫秒")
                    LabeledContent("反向逐行延迟", value: "25 毫秒")
                    LabeledContent("行变更弹簧", value: "1 / 100 / 18")
                    LabeledContent("精确逐字行", value: "随行间隔动态响应")
                } header: {
                    Text("Apple Music 26 参数")
                } footer: {
                    Text("正向移动时前两行同时开始，后续行每行延迟 50 毫秒；反向移动使用倒序和 25 毫秒步进。含精确行结束时间的逐字歌词按相邻行间隔计算动态弹簧，普通时间轴使用质量 1、刚度 100、阻尼 18。")
                }
            }
        }
        .navigationTitle("动画与性能")
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
