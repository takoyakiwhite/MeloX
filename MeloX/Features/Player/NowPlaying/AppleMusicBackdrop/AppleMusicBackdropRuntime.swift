import Darwin
import MetalKit
import ObjectiveC
import UIKit

@_silgen_name("MeloXCreateMediaCoreBackdropHost")
private func createMediaCoreBackdropHost(
    _ initializer: UnsafeRawPointer,
    _ classMetadata: UnsafeRawPointer,
    _ retainedImage: UnsafeMutableRawPointer,
    _ allowsDisplayCompositing: Bool
) -> UnsafeMutableRawPointer?

/// Loads Apple's private MediaCoreUI backdrop without linking it into the app.
/// Every private entry point is resolved and signature-checked at runtime so an
/// OS update falls back cleanly instead of jumping into an unknown function.
@MainActor
final class AppleMusicBackdropRuntime {
    static let shared = AppleMusicBackdropRuntime()

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/MediaCoreUI.framework/MediaCoreUI"
    private static let hostClassName =
        "_TtC11MediaCoreUI16BackdropHostView"

    private let frameworkHandle: UnsafeMutableRawPointer?
    private let hostClass: AnyClass?
    private let hostInitializer: UnsafeRawPointer?

    var isAvailable: Bool {
        frameworkHandle != nil
            && hostClass != nil
            && hostInitializer != nil
    }

    private init() {
#if !arch(arm64)
        frameworkHandle = nil
        hostClass = nil
        hostInitializer = nil
        return
#else
        guard #available(iOS 26.0, *) else {
            frameworkHandle = nil
            hostClass = nil
            hostInitializer = nil
            return
        }

        let handle = dlopen(
            Self.frameworkPath,
            RTLD_NOW | RTLD_LOCAL
        )
        frameworkHandle = handle

        guard handle != nil,
              let resolvedClass = NSClassFromString(
                  Self.hostClassName
              ),
              Self.isUIViewClass(resolvedClass),
              class_getInstanceVariable(
                  resolvedClass,
                  "renderer"
              ) != nil,
              class_getInstanceVariable(
                  resolvedClass,
                  "contentView"
              ) != nil,
              class_getInstanceVariable(
                  resolvedClass,
                  "image"
              ) != nil else {
            hostClass = nil
            hostInitializer = nil
            return
        }

        hostClass = resolvedClass
        hostInitializer = Self.resolveHostInitializer(
            in: resolvedClass
        )
#endif
    }

    func makeHostView(
        artwork: UIImage,
        isPaused: Bool,
        isBehindLyrics: Bool
    ) -> UIView? {
        guard let hostClass,
              let hostInitializer else {
            return nil
        }

        // MediaCoreUI's Swift initializer consumes a +1 UIImage reference.
        let retainedArtwork =
            Unmanaged.passRetained(artwork).toOpaque()
        let metadata = unsafeBitCast(
            hostClass,
            to: UnsafeRawPointer.self
        )
        guard let result = createMediaCoreBackdropHost(
            hostInitializer,
            metadata,
            retainedArtwork,
            true
        ) else {
            return nil
        }

        let object = Unmanaged<AnyObject>
            .fromOpaque(result)
            .takeRetainedValue()
        guard let view = object as? UIView else {
            return nil
        }

        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        configure(
            view,
            isPaused: isPaused,
            isBehindLyrics: isBehindLyrics
        )
        return view
    }

    @discardableResult
    func configure(
        _ hostView: UIView,
        isPaused: Bool,
        isBehindLyrics: Bool
    ) -> Bool {
        guard let hostClass,
              hostView.isKind(of: hostClass) else {
            return false
        }

        writeBool(
            isPaused,
            named: "isPaused",
            on: hostView
        )

        let renderer = objectIvar(
            named: "renderer",
            on: hostView
        )
        if let renderer {
            writeBool(
                isPaused,
                named: "_isPaused",
                on: renderer
            )
            writeFloat(
                isBehindLyrics ? 1 : 0,
                named: "pinchMix",
                on: renderer
            )
        }

        let metalView = firstMetalView(in: hostView)
        if let metalView {
            metalView.preferredFramesPerSecond =
                isBehindLyrics ? 120 : 60
            metalView.isPaused = isPaused
            if !isPaused {
                metalView.enableSetNeedsDisplay = false
            }
        }
        return renderer != nil && metalView != nil
    }

    private func firstMetalView(
        in view: UIView
    ) -> MTKView? {
        if let metalView = view as? MTKView {
            return metalView
        }
        if let contentView = objectIvar(
            named: "contentView",
            on: view
        ) as? MTKView {
            return contentView
        }
        for subview in view.subviews {
            if let metalView = firstMetalView(in: subview) {
                return metalView
            }
        }
        return nil
    }

    private func objectIvar(
        named name: String,
        on object: AnyObject
    ) -> AnyObject? {
        guard let ivar = class_getInstanceVariable(
            object_getClass(object),
            name
        ) else {
            return nil
        }
        return object_getIvar(object, ivar) as AnyObject?
    }

    private func writeBool(
        _ value: Bool,
        named name: String,
        on object: AnyObject
    ) {
        guard let ivar = class_getInstanceVariable(
            object_getClass(object),
            name
        ) else {
            return
        }
        let storage = Unmanaged.passUnretained(object)
            .toOpaque()
            .advanced(by: ivar_getOffset(ivar))
        storage.storeBytes(of: value, as: Bool.self)
    }

    private func writeFloat(
        _ value: Float,
        named name: String,
        on object: AnyObject
    ) {
        guard let ivar = class_getInstanceVariable(
            object_getClass(object),
            name
        ) else {
            return
        }
        let storage = Unmanaged.passUnretained(object)
            .toOpaque()
            .advanced(by: ivar_getOffset(ivar))
        storage.storeBytes(of: value, as: Float.self)
    }

    private static func isUIViewClass(
        _ candidate: AnyClass
    ) -> Bool {
        var current: AnyClass? = candidate
        while let type = current {
            if type === UIView.self {
                return true
            }
            current = class_getSuperclass(type)
        }
        return false
    }

    private static func resolveHostInitializer(
        in hostClass: AnyClass
    ) -> UnsafeRawPointer? {
        guard let method = class_getInstanceMethod(
            hostClass,
            NSSelectorFromString("initWithCoder:")
        ) else {
            return nil
        }
        let anchor = unsafeBitCast(
            method_getImplementation(method),
            to: UnsafeRawPointer.self
        )

        // The Swift-only initializer sits near the Objective-C coder thunk.
        // Match its register setup instead of assuming a fixed OS address.
        for distance in stride(
            from: 4,
            through: 0x2000,
            by: 4
        ) {
            let candidate = anchor.advanced(by: -distance)
            if isHostInitializer(candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func isHostInitializer(
        _ candidate: UnsafeRawPointer
    ) -> Bool {
        let words = candidate.assumingMemoryBound(
            to: UInt32.self
        )
        return words[0] == 0xD503_237F
            && words[1] == 0xD101_03FF
            && words[6] == 0xAA01_03F3
            && words[7] == 0xAA00_03F5
            && words[8] == 0xAA14_03E0
            && words[9] & 0xFC00_0000 == 0x9400_0000
    }
}
