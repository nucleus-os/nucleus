import Tracy

@MainActor
public final class Host {
    public enum RuntimeError: Error, Sendable, Equatable {
        case destroyed
    }

    private var runtimeHost: RuntimeHost?

    public init() throws {
        runtimeHost = try RuntimeHost()
    }

    isolated deinit {
        precondition(
            runtimeHost?.surfaceCount == 0,
            "RN Host deinitialized with live registered surfaces; "
                + "stop every surface before releasing the host")
        runtimeHost = nil
    }

    public func evaluateBundle(at path: String) throws {
        let runtimeHost = try requireHost()
        try Trace.zone("rn.host.evaluate_bundle", color: Trace.Color.yellow) {
            try runtimeHost.evaluateBytecode(at: path)
        }
    }

    public func installFabricRuntime() throws {
        let runtimeHost = try requireHost()
        try Trace.zone("rn.host.install_fabric", color: Trace.Color.yellow) {
            try runtimeHost.installFabric()
        }
    }

    public func registerSurface(id: Int) throws {
        let runtimeHost = try requireHost()
        try runtimeHost.registerSurface(id: id)
        runtimeHost.mountConsumer.registerSurface(surfaceID: id)
    }

    public func configureSurface(id: Int, width: Double, height: Double) throws {
        let runtimeHost = try requireHost()
        try Trace.zone("rn.host.configure_surface", color: Trace.Color.yellow) {
            try runtimeHost.configureSurface(id: id, width: width, height: height)
        }
    }

    public func setDisplayMetrics(
        width: Double,
        height: Double,
        scale: Double = 1.0,
        fontScale: Double = 1.0
    ) throws {
        let runtimeHost = try requireHost()
        try runtimeHost.setDisplayMetrics(
            width: width,
            height: height,
            scale: scale,
            fontScale: fontScale
        )
    }

    @MainActor
    public func stopSurface(id: Int) throws {
        let runtimeHost = try requireHost()
        try runtimeHost.stopSurface(id: id)
        runtimeHost.mountConsumer.unregisterContext(surfaceID: id)
    }

    public func runApplication(surfaceID: Int, appKey: String) throws {
        let runtimeHost = try requireHost()
        try Trace.zone("rn.host.run_application", color: Trace.Color.yellow) {
            try runtimeHost.runApplication(surfaceID: surfaceID, appKey: appKey)
        }
    }

    @discardableResult
    public func drainPendingJSCalls() throws -> UInt32 {
        let runtimeHost = try requireHost()
        return try runtimeHost.drainPendingJSCalls()
    }

    public func setJSWorkWakeHandler(
        _ handler: @escaping @Sendable () -> Void
    ) throws {
        try requireHost().setJSWorkWakeHandler(handler)
    }

    /// Emit a device event to JS (native → JS). JS receives it via
    /// `DeviceEventEmitter.addListener(name, …)`; `payloadJson` is the event body as JSON.
    /// This is the general native→JS push an embedding host uses for platform state (e.g. the
    /// shell's window list). The C++ emitter queues onto the JS runtime; the host
    /// itself remains main-actor-owned with the rest of runtime lifecycle.
    public func emitDeviceEvent(name: String, payloadJson: String = "") throws {
        let runtimeHost = try requireHost()
        try runtimeHost.emitDeviceEvent(name: name, payloadJson: payloadJson)
    }

    public func setAppState(_ state: String) throws {
        try requireHost().setAppState(state)
    }

    /// Install the JS→native command handler (the counterpart to `emitDeviceEvent`). JS
    /// invokes `NucleusHostCommand.invoke(command, argsJson)`; the runtime forwards it to
    /// `handler(command, argsJson)` asynchronously on `MainActor`. An embedding
    /// host routes these to its native services.
    public func setCommandHandler(
        _ handler:
            @escaping @MainActor @Sendable (
                String,
                String
            ) -> Void
    ) throws {
        let runtimeHost = try requireHost()
        try runtimeHost.setCommandHandler(handler)
    }

    public var surfaceCount: UInt32 {
        runtimeHost?.surfaceCount ?? 0
    }

    public var fabricMountReport: FabricMountReport {
        guard let runtimeHost else {
            return FabricMountReport(commitCount: 0, mutationCount: 0)
        }
        let report = runtimeHost.fabricMountReport
        return FabricMountReport(
            commitCount: report.commitCount,
            mutationCount: report.mutationCount
        )
    }

    package var mountConsumer: MountConsumer? {
        runtimeHost?.mountConsumer
    }

    @MainActor
    public func pendingMutationCount(surfaceID: Int) -> UInt32 {
        runtimeHost?.pendingMountEventCount(surfaceID: surfaceID) ?? 0
    }

    private func requireHost() throws -> RuntimeHost {
        guard let runtimeHost else {
            throw RuntimeError.destroyed
        }
        return runtimeHost
    }
}

public struct FabricMountReport: Sendable, Equatable {
    public var commitCount: UInt32
    public var mutationCount: UInt32
}
