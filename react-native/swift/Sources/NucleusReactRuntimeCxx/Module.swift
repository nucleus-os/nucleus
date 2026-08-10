import CxxStdlib
import NucleusReactRuntimeCxxBridge
import NucleusTextRenderingBridge

package struct RuntimeMountReport: Sendable, Equatable {
    package var commitCount: UInt32
    package var mutationCount: UInt32
}

package struct RuntimeHostOperationError: Error, Sendable, Equatable, CustomStringConvertible {
    package let message: String
    package var description: String { message }
}

private func requireSuccess(_ result: nucleus.react.RuntimeHostResult) throws {
    guard result.succeeded else {
        throw RuntimeHostOperationError(message: String(result.error))
    }
}

private nonisolated func makeJSWorkWake(
    _ handler: @escaping @Sendable () -> Void
) -> nucleus.react.ReactRuntimeHostFacade.JSWorkWake {
    unsafe .init { handler() }
}

@MainActor
@safe package final class RuntimeHost {
    private var facade: nucleus.react.ReactRuntimeHostFacade
    package let mountConsumer: MountConsumer

    package init() throws {
        guard
            nucleus.text.installTextRenderingBridge()
                != nucleus.text.TextRenderingBridgeInstallStatus
                .conflictingProvider
        else {
            throw RuntimeHostOperationError(
                message:
                    "conflicting Graphite text borrow provider")
        }
        let consumer = MountConsumer()
        mountConsumer = consumer
        unsafe facade = nucleus.react.ReactRuntimeHostFacade()
        try requireSuccess(unsafe facade.initializationResult())
        try requireSuccess(
            unsafe facade.setMountingObserver(
                nucleus.react.makeMountingObserver(
                    .init { mutation in
                        consumer.didMount(mutation)
                    },
                    .init { surfaceID in
                        consumer.didFinishTransaction(surfaceID: surfaceID)
                    }
                )
            ))
        let textLayout = DefaultTextLayoutHandler()
        try requireSuccess(
            unsafe facade.setTextMeasureFunction(
                .init { request in
                    textLayout.measure(request)
                }
            ))
    }

    package func evaluateBytecode(at path: String) throws {
        try requireSuccess(unsafe facade.evaluateBytecode(std.string(path)))
    }

    package func installFabric() throws {
        try requireSuccess(unsafe facade.installFabric())
    }

    package func registerSurface(id: Int) throws {
        try requireSuccess(unsafe facade.registerSurface(CInt(id)))
    }

    package func configureSurface(id: Int, width: Double, height: Double) throws {
        try requireSuccess(
            unsafe facade.configureSurface(CInt(id), width, height))
    }

    /// Updates the `DeviceInfo` TurboModule's window/screen metrics so
    /// JS-side `Dimensions.get('window')` reflects the real output size.
    /// `width`/`height` are logical points. Defaults to `scale = 1.0`,
    /// `fontScale = 1.0` when those aren't known.
    package func setDisplayMetrics(
        width: Double,
        height: Double,
        scale: Double = 1.0,
        fontScale: Double = 1.0
    ) throws {
        try requireSuccess(
            unsafe facade.setDisplayMetrics(width, height, scale, fontScale))
    }

    package func stopSurface(id: Int) throws {
        try requireSuccess(unsafe facade.stopSurface(CInt(id)))
    }

    package func runApplication(surfaceID: Int, appKey: String) throws {
        try requireSuccess(
            unsafe facade.runApplication(CInt(surfaceID), std.string(appKey)))
    }

    package func evaluateJavaScriptSource(_ source: String, sourceUrl: String) throws {
        try requireSuccess(
            unsafe facade.evaluateJavaScriptSource(
                std.string(source),
                std.string(sourceUrl)))
    }

    @discardableResult
    package func evaluateJavaScriptForString(
        _ source: String,
        sourceUrl: String
    ) throws -> String {
        let result = unsafe facade.evaluateJavaScriptForString(
            std.string(source),
            std.string(sourceUrl))
        try requireSuccess(result)
        return String(result.stringValue)
    }

    @discardableResult
    package func drainPendingJSCalls() throws -> UInt32 {
        let result = unsafe facade.drainPendingJSCalls()
        try requireSuccess(result)
        return UInt32(result.unsignedValue)
    }

    /// Install the embedding event loop's cross-thread JS-work wake. The
    /// closure runs on whichever thread first queues work onto an empty
    /// invoker queue, and the runtime retires it once no signal can still
    /// reference it.
    package func setJSWorkWakeHandler(
        _ handler: @escaping @Sendable () -> Void
    ) throws {
        try requireSuccess(
            unsafe facade.setJSWorkWakeHandler(makeJSWorkWake(handler)))
    }

    /// Thread-safe. Schedules a JS-thread dispatch of a device event with the
    /// given name and optional JSON-encoded payload. The dispatch runs the next
    /// time `drainPendingJSCalls` runs on the JS thread, or immediately if
    /// called on the JS thread.
    package func emitDeviceEvent(name: String, payloadJson: String = "") throws {
        try requireSuccess(
            unsafe facade.emitDeviceEvent(
                std.string(name),
                std.string(payloadJson)))
    }

    package func setAppState(_ state: String) throws {
        try requireSuccess(unsafe facade.setAppState(std.string(state)))
    }

    /// Install the JS→native command handler. JS initiates
    /// `NucleusHostCommand.invoke(command, argsJson)` on the JS thread; Swift
    /// receives the copied values asynchronously on `MainActor`. The runtime
    /// owns the closure and drops it once no in-flight invocation can still
    /// reference it, so replacing the handler or tearing the runtime down
    /// releases the previous closure's captures exactly once.
    package func setCommandHandler(
        _ handler:
            @escaping @MainActor @Sendable (
                String,
                String
            ) -> Void
    ) throws {
        try requireSuccess(
            unsafe facade.setCommandHandler(
                .init { command, argsJson in
                    // Runs on the JS thread. Both parameters borrow locals the
                    // TurboModule call destroys on return, so copy them before
                    // the task rather than capturing the references.
                    let commandValue = String(command)
                    let argsJsonValue = String(argsJson)
                    Task { @MainActor in
                        handler(commandValue, argsJsonValue)
                    }
                }))
    }

    package var surfaceCount: UInt32 {
        UInt32(unsafe facade.surfaceCount())
    }

    package var fabricMountReport: RuntimeMountReport {
        let report = unsafe facade.readFabricMountReport()
        return RuntimeMountReport(
            commitCount: UInt32(report.commitCount),
            mutationCount: UInt32(report.mutationCount)
        )
    }

    @MainActor
    package func pendingMountEventCount(surfaceID: Int) -> UInt32 {
        mountConsumer.pendingCount(surfaceID: surfaceID)
    }

    nonisolated package static func hermesCanCreateRuntime() -> Bool {
        unsafe nucleus.react.ReactRuntimeHostFacade.hermesCanCreateRuntime()
    }

    nonisolated package static func hermesBytecodeVersion() -> UInt32 {
        UInt32(
            unsafe nucleus.react.ReactRuntimeHostFacade.hermesBytecodeVersion())
    }

    nonisolated package static func hermesIntlDateTimeFormatWorks() -> Bool {
        unsafe nucleus.react.ReactRuntimeHostFacade.hermesIntlDateTimeFormatWorks()
    }
}
