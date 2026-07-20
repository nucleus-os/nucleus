import NucleusUI
import NucleusUIEmbedder
import Tracy

public struct SurfacePublicationFailure: Error, Sendable, Equatable {
    public let surfaceID: Int
    public let detail: String

    public init(surfaceID: Int, detail: String) {
        self.surfaceID = surfaceID
        self.detail = detail
    }
}

@MainActor
public final class Host {
    public enum RuntimeError: Error, Sendable, Equatable {
        case destroyed
    }

    private var runtimeHost: RuntimeHost?
    var attachedSurfaceIDs: Set<Int> = []
    var surfaceRegistries: [Int: ViewComponentViewRegistry] = [:]
    var surfacePublishers: [Int: EmbeddedViewTreePublisher] = [:]
    private var surfacePublicationFailures:
        [Int: SurfacePublicationFailure] = [:]

    /// Receives publication failures from mount batches that arrive after the
    /// synchronous `attachSurface` call has returned. The failure also remains
    /// queryable through `publicationFailure(surfaceID:)`, so omitting this
    /// callback never discards the diagnostic.
    public var onSurfacePublicationFailure:
        (@MainActor (SurfacePublicationFailure) -> Void)?

    public init() throws {
        runtimeHost = try RuntimeHost()
    }

    isolated deinit {
        precondition(
            runtimeHost?.surfaceCount == 0
                && surfacePublishers.isEmpty
                && surfaceRegistries.isEmpty
                && attachedSurfaceIDs.isEmpty,
            "RN Host deinitialized with live registered or attached surfaces; "
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
        if let publisher = surfacePublishers[id] {
            try publisher.invalidate()
        }
        try runtimeHost.stopSurface(id: id)
        runtimeHost.mountConsumer.unregisterContext(surfaceID: id)
        surfacePublishers.removeValue(forKey: id)
        attachedSurfaceIDs.remove(id)
        surfaceRegistries.removeValue(forKey: id)
        surfacePublicationFailures.removeValue(forKey: id)
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
    /// `handler(command, argsJson)` on the JS thread. An embedding host (the shell) routes
    /// these to its native services (e.g. taskbar activate/close → the Wayland client).
    public func setCommandHandler(_ handler: @escaping (String, String) -> Void) throws {
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

    public var mountConsumer: MountConsumer? {
        runtimeHost?.mountConsumer
    }

    @MainActor
    public func pendingMutationCount(surfaceID: Int) -> UInt32 {
        runtimeHost?.pendingMountEventCount(surfaceID: surfaceID) ?? 0
    }

    public func publicationFailure(
        surfaceID: Int
    ) -> SurfacePublicationFailure? {
        surfacePublicationFailures[surfaceID]
    }

    func clearPublicationFailure(surfaceID: Int) {
        surfacePublicationFailures.removeValue(forKey: surfaceID)
    }

    func recordPublicationFailure(surfaceID: Int, error: any Error) {
        let failure = SurfacePublicationFailure(
            surfaceID: surfaceID,
            detail: String(describing: error))
        surfacePublicationFailures[surfaceID] = failure
        onSurfacePublicationFailure?(failure)
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
