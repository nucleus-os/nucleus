import NucleusTypes
import NucleusAppHostProtocols
import Synchronization

/// Runtime registry of the host-protocol references that NucleusLayers
/// reaches for at call sites (paint/image registration, lifecycle ops,
/// context id allocation, display link queries).
///
/// The assembly module (`NucleusAppHostBundle`) installs an instance at
/// compositor startup. Tests can install a mock instance directly via
/// `installHost(_:)` without involving the assembly layer.
///
/// NucleusLayers imports `NucleusAppHostProtocols` (low-level protocol
/// declarations) but never `NucleusAppHostBundle` (the production
/// assembly). The dep direction is core → protocols ← assembly.
@MainActor
public struct Host: Sendable {
    public let imageRegistrar: any ImageRegistrar
    public let paintContentRegistrar: any PaintContentRegistrar
    public let runtimeEffectRegistrar: any RuntimeEffectRegistrar
    public let iosurfaceBinder: any IOSurfaceBinder
    public let contextIDAllocator: any ContextIDAllocator
    public let displayLinkSource: any DisplayLinkSource
    public let implicitActionRegistrar: any ImplicitActionRegistrar

    public init(
        imageRegistrar: any ImageRegistrar,
        paintContentRegistrar: any PaintContentRegistrar,
        runtimeEffectRegistrar: any RuntimeEffectRegistrar,
        iosurfaceBinder: any IOSurfaceBinder,
        contextIDAllocator: any ContextIDAllocator,
        displayLinkSource: any DisplayLinkSource,
        implicitActionRegistrar: any ImplicitActionRegistrar
    ) {
        self.imageRegistrar = imageRegistrar
        self.paintContentRegistrar = paintContentRegistrar
        self.runtimeEffectRegistrar = runtimeEffectRegistrar
        self.iosurfaceBinder = iosurfaceBinder
        self.contextIDAllocator = contextIDAllocator
        self.displayLinkSource = displayLinkSource
        self.implicitActionRegistrar = implicitActionRegistrar
    }
}

public struct LifecycleHost: Sendable {
    public let imageLifecycle: any ImageLifecycle
    public let paintContentLifecycle: any PaintContentLifecycle
    public let runtimeEffectLifecycle: any RuntimeEffectLifecycle
    public let snapshotLifecycle: any SnapshotLifecycle
    public let iosurfaceLifecycle: any IOSurfaceLifecycle
    public let contextIDAllocator: any ContextIDAllocator

    public init(
        imageLifecycle: any ImageLifecycle,
        paintContentLifecycle: any PaintContentLifecycle,
        runtimeEffectLifecycle: any RuntimeEffectLifecycle,
        snapshotLifecycle: any SnapshotLifecycle,
        iosurfaceLifecycle: any IOSurfaceLifecycle,
        contextIDAllocator: any ContextIDAllocator
    ) {
        self.imageLifecycle = imageLifecycle
        self.paintContentLifecycle = paintContentLifecycle
        self.runtimeEffectLifecycle = runtimeEffectLifecycle
        self.snapshotLifecycle = snapshotLifecycle
        self.iosurfaceLifecycle = iosurfaceLifecycle
        self.contextIDAllocator = contextIDAllocator
    }
}

@MainActor
private var activeHost: Host?

// Read from off-main content deinits (`currentLifecycleHost`) while installed/
// cleared at bring-up/teardown, so it must be synchronized: the previous
// `nonisolated(unsafe)` plain var was a torn-read of a 5-existential struct. A
// Mutex makes each access atomic.
private let lifecycleHostBox = Mutex<LifecycleHost?>(nil)

@MainActor
public func currentHost() -> Host? {
    activeHost
}

public nonisolated func currentLifecycleHost() -> LifecycleHost? {
    lifecycleHostBox.withLock { $0 }
}

@MainActor
public func installHost(_ host: Host) {
    activeHost = host
}

public nonisolated func installLifecycleHost(_ host: LifecycleHost) {
    lifecycleHostBox.withLock { $0 = host }
}

@MainActor
public func clearHost() {
    activeHost = nil
}

public nonisolated func clearLifecycleHost() {
    lifecycleHostBox.withLock { $0 = nil }
}

// MARK: - Test stubs

/// Stub layers-host conformers for tests that need to exercise
/// `PaintContent.register`, `IOSurfaceContent.bind`, `Context`
/// reserve/release, or `Context.queryDisplayLink()` without wiring a
/// real `RenderServer`. Tests opt in by calling
/// `installStubHost()` in their setup.
@MainActor
public enum StubHost {
    nonisolated private static let identifiers = Mutex((nextHandle: UInt64(1), nextContextID: UInt32(2)))

    fileprivate nonisolated static func nextHandleValue() -> UInt64 {
        identifiers.withLock {
            let value = $0.nextHandle
            $0.nextHandle &+= 1
            return value
        }
    }

    fileprivate nonisolated static func nextContextIDValue() -> UInt32 {
        identifiers.withLock {
            let value = $0.nextContextID
            $0.nextContextID &+= 1
            return value
        }
    }
}

private final class StubImageRegistrar: ImageRegistrar {
    func register(path: String, maxWidth: UInt32, maxHeight: UInt32) throws(ImageRegistrationError) -> UInt64 {
        return StubHost.nextHandleValue()
    }

    func register(
        encoded: Span<UInt8>, maxWidth: UInt32, maxHeight: UInt32
    ) throws(ImageRegistrationError) -> UInt64 {
        return StubHost.nextHandleValue()
    }

    func register(
        pixels: Span<UInt8>, width: UInt32, height: UInt32, rowStride: UInt32,
        channelOrder: UInt8, isPremultiplied: Bool
    ) throws(ImageRegistrationError) -> UInt64 {
        return StubHost.nextHandleValue()
    }
}

private final class StubPaintContentRegistrar: PaintContentRegistrar {
    func register(
        resourceHostHandle: UInt64,
        width: Float,
        height: Float,
        commands: Span<NucleusTypes.PaintCommand>,
        payload: Span<UInt8>
    ) throws(PaintContentRegistrationError) -> UInt64 {
        return StubHost.nextHandleValue()
    }
}

private final class StubRuntimeEffectRegistrar: RuntimeEffectRegistrar {
    func register(sksl: String) throws(RuntimeEffectRegistrationError) -> UInt64 {
        guard !sksl.isEmpty else { throw RuntimeEffectRegistrationError.invalidArgument }
        return StubHost.nextHandleValue()
    }
}

private final class StubIOSurfaceBinder: IOSurfaceBinder {
    func bind(iosurfaceID: UInt64) throws(IOSurfaceBindError) -> UInt64 {
        if iosurfaceID == 0 { throw .invalidArgument }
        return iosurfaceID
    }
}

private final class StubContextIDAllocator: ContextIDAllocator {
    func reserve() throws(ContextIDError) -> UInt32 {
        return StubHost.nextContextIDValue()
    }

    func release(_ id: UInt32) {}
}

private final class StubDisplayLinkSource: DisplayLinkSource {
    func query(contextID: UInt32) throws(DisplayLinkError) -> NucleusTypes.PresentReport {
        return NucleusTypes.PresentReport(
            predictedPresentationNs: 1,
            targetPresentationNs: 2,
            nextPresentId: 1
        )
    }
}

private final class StubImplicitActionRegistrar: ImplicitActionRegistrar {
    func register(rows: Span<NucleusTypes.ImplicitActionRow>) {}
}

private final class StubImageLifecycle: ImageLifecycle {
    func retain(resourceHostHandle: UInt64, handle: UInt64) {}
    func release(resourceHostHandle: UInt64, handle: UInt64) {}
}

private final class StubRuntimeEffectLifecycle: RuntimeEffectLifecycle {
    func retain(handle: UInt64) {}
    func release(handle: UInt64) {}
}

private final class StubPaintContentLifecycle: PaintContentLifecycle {
    func retain(resourceHostHandle: UInt64, handle: UInt64) {}
    func release(resourceHostHandle: UInt64, handle: UInt64) {}
}

private final class StubSnapshotLifecycle: SnapshotLifecycle {
    func retain(resourceHostHandle: UInt64, handle: UInt64) {}
    func release(resourceHostHandle: UInt64, handle: UInt64) {}
}

private final class StubIOSurfaceLifecycle: IOSurfaceLifecycle {
    func retain(handle: UInt64) {}
    func release(handle: UInt64) {}
}

/// Install a stub layers host suitable for tests. Stub implementations
/// hand out monotonically increasing handles / context ids; lifecycle
/// methods are no-ops. Real conformer behavior must be tested through
/// production wiring, not stubs.
@MainActor
public func installStubHost() {
    installHost(Host(
        imageRegistrar: StubImageRegistrar(),
        paintContentRegistrar: StubPaintContentRegistrar(),
        runtimeEffectRegistrar: StubRuntimeEffectRegistrar(),
        iosurfaceBinder: StubIOSurfaceBinder(),
        contextIDAllocator: StubContextIDAllocator(),
        displayLinkSource: StubDisplayLinkSource(),
        implicitActionRegistrar: StubImplicitActionRegistrar()
    ))
    installLifecycleHost(LifecycleHost(
        imageLifecycle: StubImageLifecycle(),
        paintContentLifecycle: StubPaintContentLifecycle(),
        runtimeEffectLifecycle: StubRuntimeEffectLifecycle(),
        snapshotLifecycle: StubSnapshotLifecycle(),
        iosurfaceLifecycle: StubIOSurfaceLifecycle(),
        contextIDAllocator: StubContextIDAllocator()
    ))
}
