import Foundation

enum AppleMusicLyricsMotionPreset: String, CaseIterable, Identifiable {
    case appleMusic26
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleMusic26:
            "Apple Music 26"
        case .custom:
            "自定义"
        }
    }

    var description: String {
        switch self {
        case .appleMusic26:
            "使用 iOS 26.6 的字体、间距、颜色、模糊与逐行错峰参数。"
        case .custom:
            "使用可编辑的字体、焦点、拖尾、追赶、回弹与排版参数。"
        }
    }
}
