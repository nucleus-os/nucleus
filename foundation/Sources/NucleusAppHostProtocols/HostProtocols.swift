public import NucleusTypes

public enum ImageRegistrationError: Error, Sendable, Equatable {
    case invalidHandle
    case invalidArgument
    case outOfMemory
    case backendFailure
}

public enum PaintContentRegistrationError: Error, Sendable, Equatable {
    case invalidHandle
    case invalidArgument
    case outOfMemory
}

public enum RuntimeEffectRegistrationError: Error, Sendable, Equatable {
    case invalidHandle
    case invalidArgument
    case outOfMemory
}

public enum IOSurfaceBindError: Error, Sendable, Equatable {
    case invalidArgument
}

public enum ContextIDError: Error, Sendable, Equatable {
    case outOfMemory
    case contextIDExhausted
}

public enum DisplayLinkError: Error, Sendable, Equatable {
    case invalidArgument
}

@MainActor
public protocol ImageRegistrar: AnyObject {
    func register(path: String, maxWidth: UInt32, maxHeight: UInt32) throws(ImageRegistrationError) -> UInt64

    /// Register encoded bytes already in memory — a `data:` URI, or any blob
    /// with no path to point at.
    func register(
        encoded: Span<UInt8>, maxWidth: UInt32, maxHeight: UInt32
    ) throws(ImageRegistrationError) -> UInt64

    /// Register decoded pixels, as notifications deliver them over D-Bus.
    ///
    /// `rowStride` is separate from `width` because senders pad rows, and
    /// `channelOrder` because they disagree about byte order. Both are the
    /// sender's to state, not ours to assume.
    func register(
        pixels: Span<UInt8>, width: UInt32, height: UInt32, rowStride: UInt32,
        channelOrder: UInt8, isPremultiplied: Bool
    ) throws(ImageRegistrationError) -> UInt64
}

@MainActor
public protocol PaintContentRegistrar: AnyObject {
    /// `payload` carries the variable-length data commands reference through
    /// `payloadOffset`/`payloadLength` — path verbs and points, gradient stops,
    /// effect uniforms. It is opaque here; only the rasterizer interprets it.
    func register(
        resourceHostHandle: UInt64,
        width: Float,
        height: Float,
        commands: Span<NucleusTypes.PaintCommand>,
        payload: Span<UInt8>
    ) throws(PaintContentRegistrationError) -> UInt64
}

/// Registers an SkSL program source and returns a handle. Compilation happens
/// in the renderer at rasterization time, so registration is GPU-independent.
@MainActor
public protocol RuntimeEffectRegistrar: AnyObject {
    func register(sksl: String) throws(RuntimeEffectRegistrationError) -> UInt64
}

@MainActor
public protocol IOSurfaceBinder: AnyObject {
    func bind(iosurfaceID: UInt64) throws(IOSurfaceBindError) -> UInt64
}

public protocol ContextIDAllocator: AnyObject, Sendable {
    func reserve() throws(ContextIDError) -> UInt32
    func release(_ id: UInt32)
}

@MainActor
public protocol DisplayLinkSource: AnyObject {
    func query(contextID: UInt32) throws(DisplayLinkError) -> NucleusTypes.PresentReport
}

@MainActor
public protocol ImplicitActionRegistrar: AnyObject {
    func register(rows: Span<NucleusTypes.ImplicitActionRow>)
}

public protocol PaintContentLifecycle: AnyObject, Sendable {
    func retain(resourceHostHandle: UInt64, handle: UInt64)
    func release(resourceHostHandle: UInt64, handle: UInt64)
}

public protocol ImageLifecycle: AnyObject, Sendable {
    func retain(resourceHostHandle: UInt64, handle: UInt64)
    func release(resourceHostHandle: UInt64, handle: UInt64)
}

/// Refcount hooks for a registered SkSL program. Handle-only, like
/// `IOSurfaceLifecycle`: the effect store is process-global, so there is no
/// per-resource-host scoping to carry.
public protocol RuntimeEffectLifecycle: AnyObject, Sendable {
    func retain(handle: UInt64)
    func release(handle: UInt64)
}

public protocol SnapshotLifecycle: AnyObject, Sendable {
    func retain(resourceHostHandle: UInt64, handle: UInt64)
    func release(resourceHostHandle: UInt64, handle: UInt64)
}

public protocol IOSurfaceLifecycle: AnyObject, Sendable {
    func retain(handle: UInt64)
    func release(handle: UInt64)
}
