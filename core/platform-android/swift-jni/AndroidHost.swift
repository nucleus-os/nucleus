// The swift-java-extracted JNI facade over the C++-interop host core.
//
// swift-java (jextract, JNI mode) generates the Java binding + Java_… thunks from
// this type's `public` surface. The forked swift-java + swift-java-jni-core make the
// generated JNI thunks compile under C++ interop (the CJNIEnv / Cjobject C-ABI
// aliases), so this target is cxx-interop and imports NucleusAndroidCore directly:
// the facade holds a strong AndroidHostCore and calls its Swift API. There is no
// C-ABI seam — the former nucleus_core_* @_cdecl/@_silgen_name boundary is gone.
//
// Lifetime is owned by swift-java's SwiftArena: the generated constructor allocates
// and retains an AndroidHost, and arena finalization runs `deinit`, which performs the
// ANativeWindow teardown and then releases the core via ARC.
//
// The NDK-handle entry points (Surface / AssetManager) stay as hand-written thunks in
// AndroidJNI.swift; they reconstruct this facade from its swift-java self-pointer and
// call the `internal` forwarders below.

import NucleusAndroidC
import NucleusAndroidCore

public final class AndroidHost {
    let core: AndroidHostCore

    public init() {
        core = AndroidHostCore()
    }

    deinit {
        // Release the retained ANativeWindow on teardown; the core is freed by ARC.
        if let window = core.teardown() {
            nucleus_android_window_release(window)
        }
    }

    // MARK: - swift-java-extracted surface (primitive / String only)

    public func start() -> Bool { core.start() }
    public func stop() -> Bool { core.stop() }

    public func windowAttached() -> Bool { core.windowAttached() }
    public func windowDetached() -> Bool { core.windowDetached() }
    public func windowFocusChanged(_ hasFocus: Bool) -> Bool { core.windowFocusChanged(hasFocus) }

    public func configurationChanged(_ width: Int32, _ height: Int32, _ density: Float) -> Bool {
        core.configurationChanged(width, height, density)
    }

    public func frame(_ frameTimeNanos: Int64) -> Bool { core.frame(frameTimeNanos) }

    public func touchEvent(
        _ action: Int32,
        _ pointerId: Int32,
        _ pointerCount: Int32,
        _ x: Float,
        _ y: Float,
        _ pressure: Float,
        _ eventTimeNanos: Int64
    ) -> Bool {
        core.touchEvent(action, pointerId, pointerCount, x, y, pressure, eventTimeNanos)
    }

    public func keyEvent(
        _ action: Int32,
        _ keyCode: Int32,
        _ repeatCount: Int32,
        _ metaState: Int32,
        _ eventTimeNanos: Int64
    ) -> Bool {
        core.keyEvent(action, keyCode, repeatCount, metaState, eventTimeNanos)
    }

    public func imeStateChanged(_ active: Bool) -> Bool { core.imeStateChanged(active) }

    public func eventQueueSmokeValue() -> Int32 { core.drainEventQueueSmokeValue() }

    /// Asset smoke read by path. The Java String is marshalled by swift-java; it is
    /// re-bridged to a C string for the NDK AAssetManager read in AndroidAssetProvider.
    public func assetSmokeValue(_ path: String) -> Int32 {
        guard let manager = core.assetManager() else { return -1 }
        let provider = AndroidAssetProvider(manager: manager)
        let value: Int32
        do {
            value = try path.withCString { try provider.smokeValue(path: $0) }
        } catch {
            core.setError(AndroidErrorCode(rawValue: assetProviderErrorCode(error)) ?? .none)
            return -1
        }
        _ = core.recordAssetSmoke(value)
        return value
    }

    public func runtimeAttach() -> Bool { core.runtimeAttach() }
    public func runtimeStart() -> Bool { core.runtimeStart() }
    public func runtimeFrame(_ frameTimeNanos: Int64) -> Bool { core.runtimeFrame(frameTimeNanos) }
    public func runtimeStop() -> Bool { core.runtimeStop() }
    public func runtimeDetach() -> Bool { core.runtimeDetach() }
    public func runtimeSmokeValue() -> Int32 { core.runtimeSmokeValue() }
    public func runtimeVerificationValue() -> Int32 { core.runtimeVerificationValue() }

    public func renderSmokeValue() -> Int32 { core.renderSmokeValue() }
    public func renderStatusCode() -> Int32 { core.renderStatusCode() }

    public func diagnosticValue(_ code: Int32) -> Int64 { core.diagnosticValue(code) }
    public func lastErrorCode() -> Int32 { core.lastErrorCode() }

    // MARK: - Internal forwarders for the hand-written NDK-handle thunks

    func setError(_ code: Int32) { core.setError(AndroidErrorCode(rawValue: code) ?? .none) }

    func configureContext(
        _ assetManager: UnsafeMutableRawPointer,
        _ density: Float,
        _ sdkInt: Int32,
        _ filesDir: UnsafePointer<CChar>,
        _ cacheDir: UnsafePointer<CChar>,
        _ packageName: UnsafePointer<CChar>
    ) -> Bool {
        core.configureContext(
            assetManager,
            density,
            sdkInt,
            String(cString: filesDir),
            String(cString: cacheDir),
            String(cString: packageName)
        )
    }

    func attachSurface(
        _ window: UnsafeMutableRawPointer,
        _ width: Int32,
        _ height: Int32,
        _ format: Int32
    ) -> UnsafeMutableRawPointer? {
        core.attachSurface(window, width, height, format)
    }

    func updateSurface(_ width: Int32, _ height: Int32, _ format: Int32) -> Bool {
        core.updateSurface(width, height, format)
    }

    func detachSurface() -> UnsafeMutableRawPointer? { core.detachSurface() }
}
