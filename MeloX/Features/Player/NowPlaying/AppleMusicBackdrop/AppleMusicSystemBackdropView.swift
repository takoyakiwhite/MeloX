import SwiftUI
import UIKit

struct AppleMusicSystemBackdropView: UIViewRepresentable {
    let artwork: UIImage
    let isPaused: Bool
    let isBehindLyrics: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = AppleMusicBackdropRuntime.shared.makeHostView(
            artwork: artwork,
            isPaused: isPaused,
            isBehindLyrics: isBehindLyrics
        ) ?? UIView(frame: .zero)
        context.coordinator.apply(
            to: view,
            isPaused: isPaused,
            isBehindLyrics: isBehindLyrics
        )
        return view
    }

    func updateUIView(
        _ uiView: UIView,
        context: Context
    ) {
        context.coordinator.apply(
            to: uiView,
            isPaused: isPaused,
            isBehindLyrics: isBehindLyrics
        )
    }

    @MainActor
    final class Coordinator {
        private var retryTask: Task<Void, Never>?

        func apply(
            to hostView: UIView,
            isPaused: Bool,
            isBehindLyrics: Bool
        ) {
            retryTask?.cancel()
            if AppleMusicBackdropRuntime.shared.configure(
                hostView,
                isPaused: isPaused,
                isBehindLyrics: isBehindLyrics
            ) {
                return
            }

            retryTask = Task { @MainActor [weak hostView] in
                for _ in 0..<20 {
                    guard !Task.isCancelled,
                          let hostView else {
                        return
                    }
                    do {
                        try await Task.sleep(
                            for: .milliseconds(16)
                        )
                    } catch {
                        return
                    }
                    if AppleMusicBackdropRuntime.shared
                        .configure(
                            hostView,
                            isPaused: isPaused,
                            isBehindLyrics:
                                isBehindLyrics
                        ) {
                        return
                    }
                }
            }
        }

        deinit {
            retryTask?.cancel()
        }
    }
}
