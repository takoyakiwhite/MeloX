import SwiftUI

struct NowPlayingLyricsLanguageButton: View {
    @Environment(AppSettings.self) private var settings

    let hasTranslations: Bool
    let hasRomanizations: Bool

    var body: some View {
        @Bindable var settings = settings

        Menu {
            if hasRomanizations {
                Toggle(
                    "显示发音（罗马音）",
                    isOn: $settings.lyricsRomanizationEnabled
                )

                if supportsEditableAnnotationRange,
                   settings.lyricsRomanizationEnabled {
                    Picker(
                        "罗马音显示范围",
                        selection:
                            $settings.lyricsRomanizationDisplayMode
                    ) {
                        ForEach(
                            LyricsTranslationDisplayMode.allCases
                        ) { mode in
                            Text(mode.title)
                                .tag(mode)
                        }
                    }
                }
            }

            if hasTranslations {
                Toggle(
                    "显示翻译",
                    isOn: $settings.lyricsTranslationEnabled
                )

                if supportsEditableAnnotationRange,
                   settings.lyricsTranslationEnabled {
                    Picker(
                        "翻译显示范围",
                        selection:
                            $settings.lyricsTranslationDisplayMode
                    ) {
                        ForEach(
                            LyricsTranslationDisplayMode.allCases
                        ) { mode in
                            Text(mode.title)
                                .tag(mode)
                        }
                    }
                }
            }

        } label: {
            Image(systemName: "translate")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(
                    .white.opacity(
                        hasEnabledAnnotation
                            ? 0.18
                            : 0.1
                    ),
                    in: .circle
                )
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("翻译与发音")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(accessibilityHint)
    }

    private var usesAppleMusic26Presentation: Bool {
        settings.lyricsStyle == .appleMusic
            && settings.appleMusicLyrics.usesAppleMusic26Motion
    }

    private var supportsEditableAnnotationRange: Bool {
        settings.lyricsStyle == .appleMusic
            && !usesAppleMusic26Presentation
    }

    private var hasEnabledAnnotation: Bool {
        (hasRomanizations && settings.lyricsRomanizationEnabled)
            || (hasTranslations && settings.lyricsTranslationEnabled)
    }

    private var accessibilityValue: String {
        var enabledAnnotations: [String] = []
        if hasRomanizations && settings.lyricsRomanizationEnabled {
            enabledAnnotations.append("罗马音")
        }
        if hasTranslations && settings.lyricsTranslationEnabled {
            enabledAnnotations.append("翻译")
        }
        guard !enabledAnnotations.isEmpty else {
            return "标注已隐藏"
        }

        if usesAppleMusic26Presentation {
            return enabledAnnotations.joined(separator: "、")
        }
        guard supportsEditableAnnotationRange else {
            return enabledAnnotations.joined(separator: "、")
        }
        let scopes: [String] = [
            hasRomanizations && settings.lyricsRomanizationEnabled
                ? "罗马音\(settings.lyricsRomanizationDisplayMode.title)"
                : nil,
            hasTranslations && settings.lyricsTranslationEnabled
                ? "翻译\(settings.lyricsTranslationDisplayMode.title)"
                : nil,
        ].compactMap { $0 }
        return scopes.joined(separator: "，")
    }

    private var accessibilityHint: String {
        if usesAppleMusic26Presentation {
            return "选择是否显示罗马音和翻译"
        }
        if supportsEditableAnnotationRange {
            return "选择是否显示罗马音、翻译及标注范围"
        }
        return "选择是否显示罗马音和翻译"
    }
}
