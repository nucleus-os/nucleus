// The swift-java-extracted JNI facade over the C++-interop host core.
//
// swift-java (jextract, JNI mode) generates the Java binding + Java_… thunks from
// this type's `public` surface. The forked swift-java + swift-java-jni-core make the
// generated JNI thunks compile under C++ interop (the CJNIEnv / Cjobject C-ABI
// aliases), so this target is cxx-interop and imports NucleusAndroidCore directly:
// the facade holds a strong AndroidHostCore and calls its Swift API. There is no
// C-ABI seam — the former nucleus_core_* @_cdecl/@_silgen_name boundary is gone.
//
// Lifetime is owned by swift-java's SwiftArena, but Java-facing identity is a
// monotonic opaque ID in AndroidHostRegistry. Raw Swift addresses never cross the
// hand-written JNI boundary.
//
// The NDK-handle entry points (Surface / AssetManager) stay as hand-written thunks in
// AndroidJNI.swift; they retain a registry lookup for the call and invoke the
// `internal` owner-checked forwarders below.

import NucleusAndroidC
import NucleusAndroidCore

public final class AndroidHost {
    let core: AndroidHostCore
    private let ownerThread: AndroidOwnerThread
    private var registryID: UInt64 = 0
    private var closed = false

    public init() {
        core = AndroidHostCore()
        ownerThread = AndroidOwnerThread()
        registryID = AndroidHostRegistry.register(self)
    }

    deinit {
        AndroidHostRegistry.unregister(registryID, host: self)
        if !closed {
            guard ownerThread.isCurrent(operation: "AndroidHost.deinit") else {
                return
            }
            shutdownCore()
        }
    }

    // MARK: - swift-java-extracted surface (primitive / String only)

    public func hostID() -> Int64 {
        withActiveOwner(operation: "AndroidHost.hostID", neutral: 0) {
            Int64(bitPattern: registryID)
        }
    }

    public func close() -> Bool {
        guard ownerThread.isCurrent(operation: "AndroidHost.close") else {
            return false
        }
        if closed { return true }
        shutdownCore()
        closed = true
        AndroidHostRegistry.unregister(registryID, host: self)
        return true
    }

    public func start() -> Bool {
        withActiveOwner(operation: "AndroidHost.start", neutral: false) {
            core.start()
        }
    }

    public func stop() -> Bool {
        withActiveOwner(operation: "AndroidHost.stop", neutral: false) {
            core.stop()
        }
    }

    public func windowAttached() -> Bool {
        withActiveOwner(operation: "AndroidHost.windowAttached", neutral: false) {
            core.windowAttached()
        }
    }

    public func windowDetached() -> Bool {
        withActiveOwner(operation: "AndroidHost.windowDetached", neutral: false) {
            core.windowDetached()
        }
    }

    public func windowFocusChanged(_ hasFocus: Bool) -> Bool {
        withActiveOwner(
            operation: "AndroidHost.windowFocusChanged",
            neutral: false
        ) {
            core.windowFocusChanged(hasFocus)
        }
    }

    public func configurationChanged(_ width: Int32, _ height: Int32, _ density: Float) -> Bool {
        withActiveOwner(
            operation: "AndroidHost.configurationChanged",
            neutral: false
        ) {
            core.configurationChanged(width, height, density)
        }
    }

    public func frame(_ frameTimeNanos: Int64) -> Bool {
        withActiveOwner(operation: "AndroidHost.frame", neutral: false) {
            core.frame(frameTimeNanos)
        }
    }

    public func touchEvent(
        _ action: Int32,
        _ pointerId: Int32,
        _ pointerCount: Int32,
        _ x: Float,
        _ y: Float,
        _ pressure: Float,
        _ eventTimeNanos: Int64
    ) -> Bool {
        withActiveOwner(operation: "AndroidHost.touchEvent", neutral: false) {
            core.touchEvent(
                action,
                pointerId,
                pointerCount,
                x,
                y,
                pressure,
                eventTimeNanos)
        }
    }

    public func keyEvent(
        _ action: Int32,
        _ keyCode: Int32,
        _ repeatCount: Int32,
        _ metaState: Int32,
        _ eventTimeNanos: Int64
    ) -> Bool {
        withActiveOwner(operation: "AndroidHost.keyEvent", neutral: false) {
            core.keyEvent(
                action,
                keyCode,
                repeatCount,
                metaState,
                eventTimeNanos)
        }
    }

    public func imeStateChanged(_ active: Bool) -> Bool {
        withActiveOwner(operation: "AndroidHost.imeStateChanged", neutral: false) {
            core.imeStateChanged(active)
        }
    }

    public func eventQueueSmokeValue() -> Int32 {
        withActiveOwner(
            operation: "AndroidHost.eventQueueSmokeValue",
            neutral: -1
        ) {
            core.drainEventQueueSmokeValue()
        }
    }

    /// Asset smoke read by path. The Java String is marshalled by swift-java; it is
    /// re-bridged to a C string for the NDK AAssetManager read in AndroidAssetProvider.
    public func assetSmokeValue(_ path: String) -> Int32 {
        withActiveOwner(operation: "AndroidHost.assetSmokeValue", neutral: -1) {
            guard let manager = unsafe core.assetManager() else { return -1 }
            let provider = unsafe AndroidAssetProvider(manager: manager)
            let value: Int32
            do {
                value = try path.withCString {
                    try unsafe provider.smokeValue(path: $0)
                }
            } catch {
                core.setError(
                    AndroidErrorCode(
                        rawValue: assetProviderErrorCode(error)) ?? .none)
                return -1
            }
            _ = core.recordAssetSmoke(value)
            return value
        }
    }

    public func runtimeAttach() -> Bool {
        withActiveOwner(operation: "AndroidHost.runtimeAttach", neutral: false) {
            core.runtimeAttach()
        }
    }

    public func runtimeStart() -> Bool {
        withActiveOwner(operation: "AndroidHost.runtimeStart", neutral: false) {
            core.runtimeStart()
        }
    }

    public func runtimeFrame(_ frameTimeNanos: Int64) -> Bool {
        withActiveOwner(operation: "AndroidHost.runtimeFrame", neutral: false) {
            core.runtimeFrame(frameTimeNanos)
        }
    }

    public func runtimeStop() -> Bool {
        withActiveOwner(operation: "AndroidHost.runtimeStop", neutral: false) {
            core.runtimeStop()
        }
    }

    public func runtimeDetach() -> Bool {
        withActiveOwner(operation: "AndroidHost.runtimeDetach", neutral: false) {
            core.runtimeDetach()
        }
    }

    public func runtimeSmokeValue() -> Int32 {
        withActiveOwner(operation: "AndroidHost.runtimeSmokeValue", neutral: -1) {
            core.runtimeSmokeValue()
        }
    }

    public func runtimeVerificationValue() -> Int32 {
        withActiveOwner(
            operation: "AndroidHost.runtimeVerificationValue",
            neutral: -1
        ) {
            core.runtimeVerificationValue()
        }
    }

    public func renderSmokeValue() -> Int32 {
        withActiveOwner(operation: "AndroidHost.renderSmokeValue", neutral: -1) {
            core.renderSmokeValue()
        }
    }

    public func renderStatusCode() -> Int32 {
        withActiveOwner(operation: "AndroidHost.renderStatusCode", neutral: -1) {
            core.renderStatusCode()
        }
    }

    public func diagnosticValue(_ code: Int32) -> Int64 {
        withActiveOwner(operation: "AndroidHost.diagnosticValue", neutral: -1) {
            core.diagnosticValue(code)
        }
    }

    public func lastErrorCode() -> Int32 {
        guard ownerThread.isCurrent(operation: "AndroidHost.lastErrorCode")
        else {
            return AndroidErrorCode.owner_thread_violation.rawValue
        }
        guard !closed else { return AndroidErrorCode.invalid_handle.rawValue }
        return core.lastErrorCode()
    }

    // MARK: - Internal forwarders for the hand-written NDK-handle thunks

    func acceptsHandwrittenCall(_ operation: StaticString) -> Bool {
        !closed && ownerThread.isCurrent(operation: operation)
    }

    func setError(_ code: Int32) {
        core.setError(AndroidErrorCode(rawValue: code) ?? .none)
    }

    func configureContext(
        _ assetManager: UnsafeMutableRawPointer,
        _ density: Float,
        _ sdkInt: Int32,
        _ filesDir: UnsafePointer<CChar>,
        _ cacheDir: UnsafePointer<CChar>,
        _ packageName: UnsafePointer<CChar>
    ) -> Bool {
        unsafe core.configureContext(
            assetManager,
            density,
            sdkInt,
            String(cString: unsafe filesDir),
            String(cString: unsafe cacheDir),
            String(cString: unsafe packageName)
        )
    }

    func attachSurface(
        _ window: UnsafeMutableRawPointer,
        _ width: Int32,
        _ height: Int32,
        _ format: Int32
    ) -> UnsafeMutableRawPointer? {
        unsafe core.attachSurface(window, width, height, format)
    }

    func updateSurface(_ width: Int32, _ height: Int32, _ format: Int32) -> Bool {
        core.updateSurface(width, height, format)
    }

    func detachSurface() -> UnsafeMutableRawPointer? {
        unsafe core.detachSurface()
    }

    private func withActiveOwner<T>(
        operation: StaticString,
        neutral: T,
        _ body: () -> T
    ) -> T {
        guard ownerThread.isCurrent(operation: operation), !closed else {
            return neutral
        }
        return body()
    }

    private func shutdownCore() {
        if let window = unsafe core.teardown() {
            unsafe nucleus_android_window_release(window)
        }
    }
}
