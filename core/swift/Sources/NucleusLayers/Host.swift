public import NucleusAppHostProtocols
import NucleusTypes
import Synchronization

/// Runtime registry of the host-protocol references that NucleusLayers
/// reaches for at call sites (paint/image registration, lifecycle ops,
/// context id allocation, display link queries).
///
/// The assembly module (`NucleusAppHostBundle`) installs an instance at
/// compositor startup. Tests can install a mock instance directly via
/// a concrete host graph without involving the assembly layer.
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

/// Concrete host services carried by a commit sink and therefore by every
/// layers context. Lifecycle conformers are retained by resource values instead
/// of being rediscovered from a mutable process registry during deinit.
@MainActor
public final class LayerRuntimeHost: ~Sendable {
    public let operations: Host
    public let presentationCompletions: PresentationCompletionRegistry
    public nonisolated let lifecycle: LifecycleHost
    public nonisolated let resourceLifetime: LayerResourceLifetime

    public init(
        operations: Host,
        lifecycle: LifecycleHost,
        presentationCompletions: PresentationCompletionRegistry =
            PresentationCompletionRegistry()
    ) {
        self.operations = operations
        self.presentationCompletions = presentationCompletions
        self.lifecycle = lifecycle
        self.resourceLifetime = LayerResourceLifetime(lifecycle: lifecycle)
    }
}

public final class LayerResourceLifetime: Sendable {
    public let lifecycle: LifecycleHost

    public init(lifecycle: LifecycleHost) {
        self.lifecycle = lifecycle
    }
}

// MARK: - In-memory host

/// In-memory layers-host conformers for tools and tests that need to exercise
/// `PaintContent.register`, `IOSurfaceContent.bind`, `Context`
/// reserve/release, or `Context.queryDisplayLink()` without wiring a
/// real `RenderServer`. Tests opt in by calling
/// `LayerRuntimeHost.inMemory()` in their setup.
private final class InMemoryIdentityAllocator: Sendable {
    private let identifiers = Mutex((nextHandle: UInt64(1), nextContextID: UInt32(2)))

    func nextHandleValue() -> UInt64 {
        identifiers.withLock {
            let value = $0.nextHandle
            $0.nextHandle &+= 1
            precondition($0.nextHandle != 0, "in-memory resource identity exhausted")
            return value
        }
    }

    func nextContextIDValue() -> UInt32 {
        identifiers.withLock {
            let value = $0.nextContextID
            $0.nextContextID &+= 1
            precondition($0.nextContextID != 0, "in-memory context identity exhausted")
            return value
        }
    }
}

private final class InMemoryImageRegistrar: ImageRegistrar {
    private let identities: InMemoryIdentityAllocator

    init(identities: InMemoryIdentityAllocator) {
        self.identities = identities
    }

    func register(path: String, maxWidth: UInt32, maxHeight: UInt32) throws(ImageRegistrationError)
        -> UInt64
    {
        return identities.nextHandleValue()
    }

    func register(
        encoded: Span<UInt8>, maxWidth: UInt32, maxHeight: UInt32
    ) throws(ImageRegistrationError) -> UInt64 {
        return identities.nextHandleValue()
    }

    func register(
        pixels: Span<UInt8>, width: UInt32, height: UInt32, rowStride: UInt32,
        channelOrder: UInt8, isPremultiplied: Bool
    ) throws(ImageRegistrationError) -> UInt64 {
        return identities.nextHandleValue()
    }
}

private final class InMemoryPaintContentRegistrar: PaintContentRegistrar {
    private let identities: InMemoryIdentityAllocator

    init(identities: InMemoryIdentityAllocator) {
        self.identities = identities
    }

    func register(
        resourceHostHandle: UInt64,
        width: Float,
        height: Float,
        commands: Span<NucleusTypes.PaintCommand>,
        payload: Span<UInt8>
    ) throws(PaintContentRegistrationError) -> UInt64 {
        return identities.nextHandleValue()
    }
}

private final class InMemoryRuntimeEffectRegistrar: RuntimeEffectRegistrar {
    private let identities: InMemoryIdentityAllocator

    init(identities: InMemoryIdentityAllocator) {
        self.identities = identities
    }

    func register(sksl: String) throws(RuntimeEffectRegistrationError) -> UInt64 {
        guard !sksl.isEmpty else { throw RuntimeEffectRegistrationError.invalidArgument }
        return identities.nextHandleValue()
    }
}

private final class InMemoryIOSurfaceBinder: IOSurfaceBinder {
    func bind(iosurfaceID: UInt64) throws(IOSurfaceBindError) -> UInt64 {
        if iosurfaceID == 0 { throw .invalidArgument }
        return iosurfaceID
    }
}

private final class InMemoryContextIDAllocator: ContextIDAllocator {
    private let identities: InMemoryIdentityAllocator

    init(identities: InMemoryIdentityAllocator) {
        self.identities = identities
    }

    func reserve() throws(ContextIDError) -> UInt32 {
        return identities.nextContextIDValue()
    }

    func release(_ id: UInt32) {}
}

private final class InMemoryDisplayLinkSource: DisplayLinkSource {
    func query(contextID: UInt32) throws(DisplayLinkError) -> NucleusTypes.PresentReport {
        return NucleusTypes.PresentReport(
            predictedPresentationNanoseconds: 1_000_000_000,
            targetPresentationNanoseconds: 1_016_666_667,
            nextPresentID: 1
        )
    }
}

private final class InMemoryImplicitActionRegistrar: ImplicitActionRegistrar {
    func register(rows: Span<NucleusTypes.ImplicitActionRow>) {}
}

private final class InMemoryImageLifecycle: ImageLifecycle {
    func retain(resourceHostHandle: UInt64, handle: UInt64) {}
    func release(resourceHostHandle: UInt64, handle: UInt64) {}
}

private final class InMemoryRuntimeEffectLifecycle: RuntimeEffectLifecycle {
    func retain(handle: UInt64) {}
    func release(handle: UInt64) {}
}

private final class InMemoryPaintContentLifecycle: PaintContentLifecycle {
    func retain(resourceHostHandle: UInt64, handle: UInt64) {}
    func release(resourceHostHandle: UInt64, handle: UInt64) {}
}

private final class InMemorySnapshotLifecycle: SnapshotLifecycle {
    func retain(resourceHostHandle: UInt64, handle: UInt64) {}
    func release(resourceHostHandle: UInt64, handle: UInt64) {}
}

private final class InMemoryIOSurfaceLifecycle: IOSurfaceLifecycle {
    func retain(handle: UInt64) {}
    func release(handle: UInt64) {}
}

@MainActor
extension LayerRuntimeHost {
    public static func inMemory() -> LayerRuntimeHost {
        let identities = InMemoryIdentityAllocator()
        let allocator = InMemoryContextIDAllocator(identities: identities)
        return LayerRuntimeHost(
            operations: Host(
                imageRegistrar: InMemoryImageRegistrar(identities: identities),
                paintContentRegistrar: InMemoryPaintContentRegistrar(
                    identities: identities),
                runtimeEffectRegistrar: InMemoryRuntimeEffectRegistrar(
                    identities: identities),
                iosurfaceBinder: InMemoryIOSurfaceBinder(),
                contextIDAllocator: allocator,
                displayLinkSource: InMemoryDisplayLinkSource(),
                implicitActionRegistrar: InMemoryImplicitActionRegistrar()),
            lifecycle: LifecycleHost(
                imageLifecycle: InMemoryImageLifecycle(),
                paintContentLifecycle: InMemoryPaintContentLifecycle(),
                runtimeEffectLifecycle: InMemoryRuntimeEffectLifecycle(),
                snapshotLifecycle: InMemorySnapshotLifecycle(),
                iosurfaceLifecycle: InMemoryIOSurfaceLifecycle(),
                contextIDAllocator: allocator))
    }
}
