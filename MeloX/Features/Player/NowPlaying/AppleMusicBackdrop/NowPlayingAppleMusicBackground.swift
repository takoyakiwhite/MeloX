import Nuke
import SwiftUI
import UIKit

struct NowPlayingAppleMusicBackground: View {
    @Environment(PlayerStore.self) private var player
    @Environment(\.accessibilityReduceMotion)
    private var accessibilityReduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.scenePhase) private var scenePhase

    let artworkURL: URL?
    let isBehindLyrics: Bool
    let motionIntensity: Double
    let saturation: Double
    let audioResponseEnabled: Bool

    @State private var systemArtwork: UIImage?
    @State private var loadedArtworkURL: URL?

    var body: some View {
        ZStack {
            if AppleMusicBackdropRuntime.shared.isAvailable,
               let systemArtwork {
                AppleMusicSystemBackdropView(
                    artwork: systemArtwork,
                    isPaused: pausesSystemBackdrop,
                    isBehindLyrics: isBehindLyrics
                )
                .id(loadedArtworkURL)
                .transition(.opacity)
            } else {
                AppleMusicFallbackBackdrop(
                    artworkURL: artworkURL,
                    isBehindLyrics: isBehindLyrics,
                    motionIntensity: motionIntensity,
                    saturation: saturation,
                    audioResponseEnabled:
                        audioResponseEnabled
                )
                .transition(.opacity)
            }
        }
        .animation(
            accessibilityReduceMotion
                ? nil
                : .timingCurve(
                    0,
                    0,
                    0.3,
                    1,
                    duration: 0.8
                ),
            value: loadedArtworkURL
        )
        .task(id: artworkURL) {
            await loadSystemArtwork()
        }
    }

    private var pausesSystemBackdrop: Bool {
        accessibilityReduceMotion
            || isLuminanceReduced
            || scenePhase != .active
            || !player.isPlaying
            || motionIntensity <= 0
    }

    private func loadSystemArtwork() async {
        guard AppleMusicBackdropRuntime.shared.isAvailable,
              let artworkURL else {
            systemArtwork = nil
            loadedArtworkURL = nil
            return
        }

        do {
            let request = ImageRequest(url: artworkURL)
            let image = try await ImagePipeline.shared.image(
                for: request
            )
            guard !Task.isCancelled else { return }
            systemArtwork = image
            loadedArtworkURL = artworkURL
        } catch {
            systemArtwork = nil
            loadedArtworkURL = nil
        }
    }
}
