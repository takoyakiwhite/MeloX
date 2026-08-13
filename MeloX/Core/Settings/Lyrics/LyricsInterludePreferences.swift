import Foundation
import Observation

nonisolated enum LyricsInterludePresentationMode:
    String,
    CaseIterable,
    Identifiable,
    Sendable
{
    case hidden
    case preciseTiming
    case automatic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hidden:
            "关闭"
        case .preciseTiming:
            "仅精确时间轴"
        case .automatic:
            "自动（含 LRC 推断）"
        }
    }

    var description: String {
        switch self {
        case .hidden:
            "不插入前奏或间奏焦点。"
        case .preciseTiming:
            "只根据 YRC 的音节结束时间识别演奏空档。"
        case .automatic:
            "优先使用 YRC 精确时间；普通 LRC 则根据文字长度估算本句演唱结束时间。"
        }
    }

}

@MainActor
@Observable
final class LyricsInterludePreferences {
    static let inferredGapDurationRange = 3.0...12.0
    static let defaultMode: LyricsInterludePresentationMode = .automatic
    static let defaultMinimumInferredGapDuration = 4.0

    private enum Key {
        static let mode = "melox.lyrics.interlude.mode"
        static let minimumInferredGapDuration =
            "melox.lyrics.interlude.minimumInferredGapDuration"
        static let legacyEnabled = "lyricsInterludeCountdownEnabled"
    }

    var mode: LyricsInterludePresentationMode {
        didSet { defaults.set(mode.rawValue, forKey: Key.mode) }
    }

    var minimumInferredGapDuration: TimeInterval {
        didSet {
            defaults.set(
                minimumInferredGapDuration,
                forKey: Key.minimumInferredGapDuration
            )
        }
    }

    @ObservationIgnored
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let storedMode = defaults.string(forKey: Key.mode),
           let mode = LyricsInterludePresentationMode(
               rawValue: storedMode
           ) {
            self.mode = mode
        } else if let legacyEnabled = defaults.object(
            forKey: Key.legacyEnabled
        ) as? Bool {
            mode = legacyEnabled ? .automatic : .hidden
        } else {
            mode = Self.defaultMode
        }

        let storedMinimum = defaults.object(
            forKey: Key.minimumInferredGapDuration
        ) as? Double ?? Self.defaultMinimumInferredGapDuration
        minimumInferredGapDuration = min(
            max(storedMinimum, Self.inferredGapDurationRange.lowerBound),
            Self.inferredGapDurationRange.upperBound
        )
    }

    func reset() {
        mode = Self.defaultMode
        minimumInferredGapDuration =
            Self.defaultMinimumInferredGapDuration
    }
}
