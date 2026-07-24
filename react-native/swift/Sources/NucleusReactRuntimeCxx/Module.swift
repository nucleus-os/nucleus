import CxxStdlib
import NucleusReactRuntimeCxxBridge

public struct RuntimeMountReport: Sendable, Equatable {
    public var commitCount: UInt32
    public var mutationCount: UInt32
}

public struct RuntimeHostOperationError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

private func requireSuccess(_ result: nucleus.react.RuntimeHostResult) throws {
    guard result.succeeded else {
        throw RuntimeHostOperationError(message: String(result.error))
    }
}

// Retains a JS→native command closure behind an opaque pointer for the facade's C callback
// (a @convention(c) trampoline cannot capture).
final class CommandHandlerBox: Sendable {
    let handler: @MainActor @Sendable (String, String) -> Void

    init(
        _ handler: @escaping @MainActor @Sendable (
            String,
            String
        ) -> Void
    ) {
        self.handler = handler
    }

    static let callback: @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?
    ) -> Void = { context, command, argsJson in
        guard let context, let command else { return }
        let box = Unmanaged<CommandHandlerBox>
            .fromOpaque(context)
            .takeUnretainedValue()
        let commandValue = String(cString: command)
        let argsJsonValue = argsJson.map {
            String(cString: $0)
        } ?? ""
        // C++ holds the shared callback entry through this trampoline. Capture
        // the box into the task before returning so replacement or runtime
        // teardown may release the entry without invalidating queued delivery.
        Task { @MainActor [box] in
            box.handler(commandValue, argsJsonValue)
        }
    }

    static let release: @convention(c) (
        UnsafeMutableRawPointer?
    ) -> Void = { context in
        guard let context else { return }
        Unmanaged<CommandHandlerBox>.fromOpaque(context).release()
    }
}

final class JSWorkWakeHandlerBox: Sendable {
    let handler: @Sendable () -> Void
    init(_ handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }
}

@MainActor
public final class RuntimeHost {
    private var facade: nucleus.react.ReactRuntimeHostFacade
    public let mountConsumer: MountConsumer

    public init() throws {
        let consumer = MountConsumer()
        mountConsumer = consumer
        facade = nucleus.react.ReactRuntimeHostFacade()
        try requireSuccess(facade.initializationResult())
        let swiftObserver = SwiftMountingObserver(consumer)
        try requireSuccess(facade.setMountingObserver(
            nucleus.react.makeSwiftMountingObserverBridge(swiftObserver.toUnsafe())
        ))
        // Install the Swift text layout manager handle. The bridge
        // consumes it inside `FabricRuntime`'s ctor (during
        // `installFabric`) so it can be constructed with the
        // `ContextContainer` the runtime builds there.
        let swiftTextManager = SwiftTextLayoutManager(DefaultTextLayoutHandler())
        try requireSuccess(facade.setSwiftTextLayoutManagerHandle(swiftTextManager.toUnsafe()))
    }

    public func evaluateBytecode(at path: String) throws {
        try requireSuccess(facade.evaluateBytecode(std.string(path)))
    }

    public func installFabric() throws {
        try requireSuccess(facade.installFabric())
    }

    public func registerSurface(id: Int) throws {
        try requireSuccess(facade.registerSurface(CInt(id)))
    }

    public func configureSurface(id: Int, width: Double, height: Double) throws {
        try requireSuccess(facade.configureSurface(CInt(id), width, height))
    }

    /// Updates the `DeviceInfo` TurboModule's window/screen metrics so
    /// JS-side `Dimensions.get('window')` reflects the real output size.
    /// `width`/`height` are logical points. Defaults to `scale = 1.0`,
    /// `fontScale = 1.0` when those aren't known.
    public func setDisplayMetrics(
        width: Double,
        height: Double,
        scale: Double = 1.0,
        fontScale: Double = 1.0
    ) throws {
        try requireSuccess(facade.setDisplayMetrics(width, height, scale, fontScale))
    }

    public func stopSurface(id: Int) throws {
        try requireSuccess(facade.stopSurface(CInt(id)))
    }

    public func runApplication(surfaceID: Int, appKey: String) throws {
        try requireSuccess(facade.runApplication(CInt(surfaceID), std.string(appKey)))
    }

    public func evaluateJavaScriptSource(_ source: String, sourceUrl: String) throws {
        try requireSuccess(facade.evaluateJavaScriptSource(std.string(source), std.string(sourceUrl)))
    }

    @discardableResult
    public func evaluateJavaScriptForString(
        _ source: String,
        sourceUrl: String
    ) throws -> String {
        let result = facade.evaluateJavaScriptForString(std.string(source), std.string(sourceUrl))
        try requireSuccess(result)
        return String(result.stringValue)
    }

    @discardableResult
    public func drainPendingJSCalls() throws -> UInt32 {
        let result = facade.drainPendingJSCalls()
        try requireSuccess(result)
        return UInt32(result.unsignedValue)
    }

    /// Install the embedding event loop's cross-thread JS-work wake.
    public func setJSWorkWakeHandler(
        _ handler: @escaping @Sendable () -> Void
    ) throws {
        let box = JSWorkWakeHandlerBox(handler)
        // Ownership transfers to the C++ WakeEntry. Its release callback
        // balances passRetained on replacement, shutdown, or setup failure.
        let callback: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
            context in
            guard let context else { return }
            Unmanaged<JSWorkWakeHandlerBox>
                .fromOpaque(context)
                .takeUnretainedValue()
                .handler()
        }
        let release: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
            context in
            guard let context else { return }
            Unmanaged<JSWorkWakeHandlerBox>.fromOpaque(context).release()
        }
        try requireSuccess(facade.setJSWorkWakeHandler(
            callback,
            Unmanaged.passRetained(box).toOpaque(),
            release
        ))
    }

    /// Thread-safe. Schedules a JS-thread dispatch of a device event with the
    /// given name and optional JSON-encoded payload. The dispatch runs the next
    /// time `drainPendingJSCalls` runs on the JS thread, or immediately if
    /// called on the JS thread.
    public func emitDeviceEvent(name: String, payloadJson: String = "") throws {
        try requireSuccess(facade.emitDeviceEvent(std.string(name), std.string(payloadJson)))
    }

    public func setAppState(_ state: String) throws {
        try requireSuccess(facade.setAppState(std.string(state)))
    }

    /// Install the JS→native command handler. JS initiates
    /// `NucleusHostCommand.invoke(command, argsJson)` on the JS thread; Swift
    /// receives the copied values asynchronously on `MainActor`. The C++ shared
    /// handler owns the retained context and invokes `release` on replacement,
    /// teardown, or setup failure.
    public func setCommandHandler(
        _ handler: @escaping @MainActor @Sendable (
            String,
            String
        ) -> Void
    ) throws {
        let box = CommandHandlerBox(handler)
        try requireSuccess(facade.setCommandHandler(
            CommandHandlerBox.callback,
            Unmanaged.passRetained(box).toOpaque(),
            CommandHandlerBox.release
        ))
    }

    public var surfaceCount: UInt32 {
        UInt32(facade.surfaceCount())
    }

    public var fabricMountReport: RuntimeMountReport {
        let report = facade.readFabricMountReport()
        return RuntimeMountReport(
            commitCount: UInt32(report.commitCount),
            mutationCount: UInt32(report.mutationCount)
        )
    }

    @MainActor
    public func pendingMountEventCount(surfaceID: Int) -> UInt32 {
        mountConsumer.pendingCount(surfaceID: surfaceID)
    }

    nonisolated public static func hermesCanCreateRuntime() -> Bool {
        nucleus.react.ReactRuntimeHostFacade.hermesCanCreateRuntime()
    }

    nonisolated public static func hermesBytecodeVersion() -> UInt32 {
        UInt32(nucleus.react.ReactRuntimeHostFacade.hermesBytecodeVersion())
    }

    nonisolated public static func hermesIntlDateTimeFormatWorks() -> Bool {
        nucleus.react.ReactRuntimeHostFacade.hermesIntlDateTimeFormatWorks()
    }
}

public enum RuntimeCxxInteropSmoke {
    public static func greeting(for name: String) -> String {
        let bridge = nucleus.react.HelloBridge(std.string(name))
        return String(bridge.greet())
    }

    public static func hermesBytecodeVersionFromFacade() -> UInt32 {
        UInt32(nucleus.react.ReactRuntimeHostFacade.hermesBytecodeVersion())
    }

    public static func newFacadeSurfaceCount() -> UInt32 {
        let facade = nucleus.react.ReactRuntimeHostFacade()
        return UInt32(facade.surfaceCount())
    }
}
