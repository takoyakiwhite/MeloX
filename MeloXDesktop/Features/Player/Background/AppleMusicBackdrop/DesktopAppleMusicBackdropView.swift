import Foundation
import SwiftUI

/// macOS Music 1.6.6's `TSLBackdropMetalView` presentation reconstructed from
/// the app's model matrices, subdivided `CAMeshTransform` vertices, and AIR.
///
/// Performance notes:
/// - The three rotating artwork layers, Gaussian blur, and pinch warp run in a
///   downsampled render pass whose resolution is selected by the user in
///   Settings. The artwork source is only 300pt and the final backdrop is
///   heavily blurred, so the lower tiers keep the visible result while
///   reducing per-frame texture work by 2–16×.
/// - The timeline pauses whenever the window is inactive, playback is paused,
///   or Reduce Motion is enabled, and drops to 30Hz in Low Power Mode.
struct DesktopAppleMusicBackdropView: View {
    @Environment(\.accessibilityReduceMotion)
    private var accessibilityReduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    let artworkURL: URL?
    let motionIntensity: Double
    let renderQuality: PlayerBackgroundRenderQuality
    let isActive: Bool
    let isPlaying: Bool

    @State private var clock = DesktopAppleMusicBackdropClock()
    @State private var pinchMesh =
        DesktopAppleMusicPinchMeshStore.randomMesh()
    @State private var isLowPowerModeEnabled =
        ProcessInfo.processInfo.isLowPowerModeEnabled

    private static let standardRenderDimension: CGFloat = 640
    private static let lowPowerRenderDimension: CGFloat = 480

    var body: some View {
        GeometryReader { proxy in
            TimelineView(
                .animation(
                    minimumInterval: frameInterval,
                    paused: !isClockRunning
                )
            ) { context in
                let size = proxy.size
                let time = animationTime(at: context.date)

                ZStack {
                    Color(white: 0.30)

                    renderedBackdrop(
                        in: size,
                        time: time
                    )
                }
                .compositingGroup()
                .frame(width: size.width, height: size.height)
                .clipped()
            }
        }
        .onChange(of: isClockRunning, initial: true) { _, isRunning in
            clock.setRunning(isRunning, at: Date())
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .NSProcessInfoPowerStateDidChange
            )
        ) { _ in
            isLowPowerModeEnabled =
                ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    /// Runs the heavy rotation/blur/pinch work in a proportionally smaller
    /// coordinate space, then scales the result up to fill the window.
    private func renderedBackdrop(
        in size: CGSize,
        time: TimeInterval
    ) -> some View {
        let renderSize = renderSize(for: size)
        let scale = renderScale(from: size, to: renderSize)

        return ZStack {
            Color(white: 0.30)

            transformedArtwork(
                in: renderSize,
                time: time
            )
        }
        .frame(width: renderSize.width, height: renderSize.height)
        .saturation(1.3)
        .blur(
            radius: blurSigma(for: renderSize),
            opaque: true
        )
        .layerEffect(
            DesktopAppleMusicBackdropShader.pinch(
                size: renderSize,
                time: time,
                meshWarpTimeScale:
                    meshWarpTimeScale(for: size.width),
                blackScrimAlpha:
                    scrimAlpha(for: size.width),
                usesDarkAppearance:
                    colorScheme == .dark,
                averageLuminosity: 0.5,
                meshPositions: pinchMesh.positions,
                lookupOffsets: pinchMesh.lookupOffsets,
                lookupTriangles:
                    pinchMesh.lookupTriangles
            ),
            maxSampleOffset: renderSize
        )
        .scaleEffect(scale, anchor: .center)
        .frame(width: size.width, height: size.height)
    }

    @ViewBuilder
    private func transformedArtwork(
        in size: CGSize,
        time: TimeInterval
    ) -> some View {
        DesktopAppleMusicBackdropArtwork(artworkURL: artworkURL) { image in
            ZStack {
                transformedLayer(
                    image,
                    size: size,
                    translation: .zero,
                    basePeriod: 120,
                    time: time
                )

                transformedLayer(
                    image,
                    size: size,
                    translation: CGPoint(x: -0.5, y: -0.7),
                    basePeriod: 90,
                    time: time
                )

                transformedLayer(
                    image,
                    size: size,
                    translation: CGPoint(x: -0.95, y: 0.7),
                    basePeriod: 70,
                    time: time
                )
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private func transformedLayer(
        _ image: Image,
        size: CGSize,
        translation: CGPoint,
        basePeriod: TimeInterval,
        time: TimeInterval
    ) -> some View {
        let angle = cycleAngle(time: time, basePeriod: basePeriod)

        return image
            .resizable()
            .frame(width: size.width, height: size.width)
            .rotationEffect(angle)
            .offset(
                x: translation.x * size.width * 0.5,
                y: translation.y * size.width * 0.5
            )
            .rotationEffect(angle)
    }

    private func cycleAngle(
        time: TimeInterval,
        basePeriod: TimeInterval
    ) -> Angle {
        .radians(
            time
                * 2
                * .pi
                / (basePeriod * rendererSpeed)
        )
    }

    private var isClockRunning: Bool {
        isActive
            && scenePhase == .active
            && isPlaying
            && !accessibilityReduceMotion
    }

    private var frameInterval: TimeInterval {
        isLowPowerModeEnabled ? 1.0 / 30.0 : 1.0 / 60.0
    }

    private func animationTime(at date: Date) -> TimeInterval {
        clock.elapsed(at: date)
    }

    private var rendererSpeed: TimeInterval {
        if accessibilityReduceMotion {
            return 5
        }
        return 0.5 / max(motionIntensity, 0.1)
    }

    private func renderSize(for size: CGSize) -> CGSize {
        let maximumDimension = max(size.width, size.height)
        guard maximumDimension > 0,
              let renderDimension = resolvedRenderDimension else {
            return size
        }
        let downscale = min(
            renderDimension / maximumDimension,
            1
        )
        return CGSize(
            width: size.width * downscale,
            height: size.height * downscale
        )
    }

    private var resolvedRenderDimension: CGFloat? {
        switch renderQuality {
        case .automatic:
            return isLowPowerModeEnabled
                ? Self.lowPowerRenderDimension
                : Self.standardRenderDimension
        case .high:
            return nil
        case .standard:
            return Self.standardRenderDimension
        case .low:
            return Self.lowPowerRenderDimension
        }
    }

    private func renderScale(
        from size: CGSize,
        to renderSize: CGSize
    ) -> CGFloat {
        guard renderSize.width > 0 else { return 1 }
        return size.width / renderSize.width
    }

    private func scrimAlpha(for width: CGFloat) -> Double {
        let progress = min(max((width - 400) / 400, 0), 1)
        return 0.7 - 0.4 * Double(progress)
    }

    private func meshWarpTimeScale(for width: CGFloat) -> Double {
        let progress = min(max((width - 400) / 400, 0), 1)
        return min(max(10.5 - 9 * Double(progress), 0.1), 10)
    }

    private func blurSigma(for size: CGSize) -> CGFloat {
        let sigma = floor(hypot(size.width, size.height) * 0.045_394_707)
        return min(max(sigma, 4), 2_000)
    }
}
