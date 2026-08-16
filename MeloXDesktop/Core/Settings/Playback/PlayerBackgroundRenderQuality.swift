import Foundation

enum PlayerBackgroundRenderQuality: String, CaseIterable, Identifiable {
    case automatic
    case high
    case standard
    case low

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            "自动"
        case .high:
            "高"
        case .standard:
            "标准"
        case .low:
            "低"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            "根据系统状态自动选择渲染分辨率，低电量模式下使用更低画质。"
        case .high:
            "使用播放器窗口的原始分辨率，画质最佳，GPU 占用最高。"
        case .standard:
            "渲染最长边限制为 640pt，画质与性能平衡。"
        case .low:
            "渲染最长边限制为 480pt，更省电，画面略柔和。"
        }
    }
}
