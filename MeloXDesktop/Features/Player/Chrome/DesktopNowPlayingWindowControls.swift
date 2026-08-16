import SwiftUI

struct DesktopNowPlayingWindowControls: View {
    let close: () -> Void
    let openMiniPlayer: () -> Void

    var body: some View {
        content.modifier(DesktopNowPlayingGlassCapsule())
    }

    private var content: some View {
        HStack(spacing: 9) {
            chromeButton(
                "退出播放器",
                systemImage: "xmark",
                action: close
            )
            chromeButton(
                "打开迷你播放器",
                systemImage: "pip.exit",
                action: openMiniPlayer
            )
        }
        .frame(width: 74, height: 36)
        .buttonStyle(.plain)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.white)
    }

    private func chromeButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 26, height: 26)
                .contentShape(.rect)
        }
        .accessibilityLabel(title)
        .help(title)
    }
}
