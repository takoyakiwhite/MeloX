import SwiftUI

struct DesktopLyricsAnimationSettingsView: View {
    @Environment(DesktopAppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        @Bindable var appleMusicLyrics = model.settings.appleMusicLyrics

        ScrollView {
            Form {
                Section("性能") {
                    Picker(
                        "刷新频率",
                        selection: $settings.lyricsRefreshRate
                    ) {
                        ForEach(LyricsRefreshRate.allCases) { rate in
                            Text(rate.title).tag(rate)
                        }
                    }
                }

                if appleMusicLyrics.usesAppleMusic26Motion {
                    Section("Apple Music 26 参数") {
                        LabeledContent("正向逐行延迟", value: "50 毫秒")
                        LabeledContent("反向逐行延迟", value: "25 毫秒")
                        LabeledContent("前两行", value: "同时开始")
                        LabeledContent("行变更弹簧", value: "1 / 100 / 18")
                        LabeledContent("精确逐字行", value: "随行间隔动态响应")
                        LabeledContent("高光预启动", value: "100 毫秒")
                        LabeledContent("焦点模糊过渡", value: "120 毫秒")

                        Text("向前移动按歌词顺序错峰，向后移动按倒序错峰。带精确结束时间的逐字歌词会根据相邻行间隔重算物理弹簧。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    customMovementSection(settings: settings)
                    customBounceSection(settings: settings)
                }
            }
            .formStyle(.columns)
            .padding()
        }
        .scrollIndicators(.automatic)
    }

    @ViewBuilder
    private func customMovementSection(settings: AppSettings) -> some View {
        @Bindable var settings = settings

        Section("移动与追赶") {
            valueSlider(
                title: "基础拖尾延迟",
                value: $settings.lyricsFocusCascadeDelay,
                range: AppSettings.lyricsFocusCascadeDelayRange,
                step: 0.001,
                valueText: "\(Int((settings.lyricsFocusCascadeDelay * 1_000).rounded())) ms"
            )
            valueSlider(
                title: "逐句拖尾增量",
                value: $settings.lyricsFocusCascadeDelayIncrease,
                range: AppSettings.lyricsFocusCascadeDelayIncreaseRange,
                step: 0.001,
                valueText: "\(Int((settings.lyricsFocusCascadeDelayIncrease * 1_000).rounded())) ms"
            )
            valueSlider(
                title: "后续歌词启动延迟",
                value: $settings.lyricsFocusCascadeFollowingDelay,
                range: AppSettings.lyricsFocusCascadeFollowingDelayRange,
                step: 0.001,
                valueText: "\(Int((settings.lyricsFocusCascadeFollowingDelay * 1_000).rounded())) ms"
            )
            valueSlider(
                title: "拖尾追赶节奏",
                value: $settings.lyricsFocusCascadeCatchUpRatio,
                range: AppSettings.lyricsFocusCascadeCatchUpRatioRange,
                step: 0.01,
                valueText: "\(Int((settings.lyricsFocusCascadeCatchUpRatio * 100).rounded()))%"
            )
            valueSlider(
                title: "追赶速度梯度",
                value: $settings.lyricsFocusCascadeChaseSpeedGradient,
                range: AppSettings.lyricsFocusCascadeChaseSpeedGradientRange,
                step: 0.01,
                valueText: "\(Int((settings.lyricsFocusCascadeChaseSpeedGradient * 100).rounded()))%"
            )
            valueSlider(
                title: "位移收束时长",
                value: $settings.lyricsFocusCascadeDuration,
                range: AppSettings.lyricsFocusCascadeDurationRange,
                step: 0.01,
                valueText: "\(settings.lyricsFocusCascadeDuration.formatted(.number.precision(.fractionLength(2)))) s"
            )
            valueSlider(
                title: "瞬移阈值",
                value: $settings.lyricsFocusSnapThreshold,
                range: AppSettings.lyricsFocusSnapThresholdRange,
                step: 0.001,
                valueText: "\(Int((settings.lyricsFocusSnapThreshold * 1_000).rounded())) ms"
            )
        }
    }

    @ViewBuilder
    private func customBounceSection(settings: AppSettings) -> some View {
        @Bindable var settings = settings

        Section("回弹与焦点") {
            Toggle(
                "启用位移回弹",
                isOn: $settings.lyricsFocusCascadeBounceEnabled
            )
            if settings.lyricsFocusCascadeBounceEnabled {
                valueSlider(
                    title: "最大回弹弹性",
                    value: $settings.lyricsFocusCascadeBounce,
                    range: AppSettings.lyricsFocusCascadeBounceRange,
                    step: 0.01,
                    valueText: "\(Int((settings.lyricsFocusCascadeBounce * 100).rounded()))%"
                )
                valueSlider(
                    title: "回弹强度梯度",
                    value: $settings.lyricsFocusCascadeBounceGradient,
                    range: AppSettings.lyricsFocusCascadeBounceGradientRange,
                    step: 0.01,
                    valueText: "\(Int((settings.lyricsFocusCascadeBounceGradient * 100).rounded()))%"
                )
            }

            Toggle(
                "启用当前句回弹",
                isOn: $settings.lyricsFocusScaleBounceEnabled
            )
            if settings.lyricsFocusScaleBounceEnabled {
                valueSlider(
                    title: "当前句回弹时长",
                    value: $settings.lyricsFocusScaleBounceDuration,
                    range: AppSettings.lyricsFocusScaleBounceDurationRange,
                    step: 0.01,
                    valueText: "\(settings.lyricsFocusScaleBounceDuration.formatted(.number.precision(.fractionLength(2)))) s"
                )
                valueSlider(
                    title: "当前句回弹弹性",
                    value: $settings.lyricsFocusScaleBounce,
                    range: AppSettings.lyricsFocusScaleBounceRange,
                    step: 0.01,
                    valueText: "\(Int((settings.lyricsFocusScaleBounce * 100).rounded()))%"
                )
            }

            valueSlider(
                title: "焦点颜色提前",
                value: $settings.lyricsFocusColorLeadTime,
                range: AppSettings.lyricsFocusColorLeadTimeRange,
                step: 0.005,
                valueText: "\(Int((settings.lyricsFocusColorLeadTime * 1_000).rounded())) ms"
            )
        }
    }

    private func valueSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueText: String
    ) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range, step: step)
            Text(valueText)
                .monospacedDigit()
                .frame(width: 68, alignment: .trailing)
        }
    }
}
