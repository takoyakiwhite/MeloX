import Foundation

enum AppleMusicLyricsMotionPreset: String, CaseIterable, Identifiable {
    case appleMusic26
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleMusic26: "Apple Music 26"
        case .custom: "自定义"
        }
    }

    var description: String {
        switch self {
        case .appleMusic26:
            "使用 macOS 26.6 Music 1.6.6 逆向得到的字体、间距、透明度、模糊和双向逐行错峰参数。"
        case .custom:
            "使用原有可编辑的字体、焦点、拖尾、追赶、回弹与排版参数。"
        }
    }
}
