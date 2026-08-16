import SwiftUI

enum DesktopAppleMusicBackdropShader {
    static func pinch(
        size: CGSize,
        time: TimeInterval,
        meshWarpTimeScale: Double,
        blackScrimAlpha: Double,
        usesDarkAppearance: Bool,
        averageLuminosity: Double,
        meshPositions: Data,
        lookupOffsets: Data,
        lookupTriangles: Data
    ) -> Shader {
        ShaderLibrary.desktopAppleMusicBackdropPinch(
            .float2(size),
            .float(time),
            .float(meshWarpTimeScale),
            .float(blackScrimAlpha),
            .float(usesDarkAppearance ? 1 : 0),
            .float(averageLuminosity),
            .data(meshPositions),
            .data(lookupOffsets),
            .data(lookupTriangles)
        )
    }
}
