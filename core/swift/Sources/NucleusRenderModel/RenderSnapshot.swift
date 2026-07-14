// Phase 8.10 — Swift snapshot handle registry.
//
// `SnapshotService` owns immutable snapshot handles used by presentation
// transitions and `.snapshot` layer contents. Entries carry an opaque
// `TextureHandle` plus size + provenance — no GPU-resource pointers cross this
// boundary. The Skia capture
// orchestration (`captureDeviceRect`/`captureWorldRect`, `RenderTextureCapture`)
// is renderer-owned and co-lands with the renderer move (10b); only the
// already-allocated-handle bookkeeping ports here. Nothing imports this yet.
//
// `TextureHandle` (canonically `composition_plan.TextureHandle`) is defined here
// as its first Swift consumer.

/// Opaque render-resource texture handle. Mirrors `composition_plan.TextureHandle`
/// (`enum(u64)`).
public struct TextureHandle: Equatable, Hashable, Sendable {
    public var raw: UInt64 = 0
    public init(raw: UInt64 = 0) { self.raw = raw }
}

/// Typed source for a snapshot capture. Mirrors `SnapshotSource`.
public enum SnapshotSource: Equatable, Sendable {
    case layerId(UInt64)
    case contextRoot(ContextID)
    case iosurface(IOSurfaceID)
}

/// Result of a capture: the registered handle + its pixel size. Mirrors
/// `CaptureResult`.
public struct CaptureResult: Equatable, Sendable {
    public var handle: SnapshotHandle
    public var size: Bounds

    public init(handle: SnapshotHandle, size: Bounds) {
        self.handle = handle
        self.size = size
    }
}

/// How a snapshot's backing texture was produced. Mirrors `SnapshotProvenance`.
public enum SnapshotProvenance: Equatable, Sendable {
    case unknown
    case liveIosurface(IOSurfaceID)
    case renderTexture
}

/// A registered snapshot: its opaque texture, size, provenance, and refcount.
/// Mirrors `SnapshotEntry`.
public struct SnapshotEntry: Equatable, Sendable {
    public var texture: TextureHandle
    public var size: Bounds
    public var provenance: SnapshotProvenance = .unknown
    public var refcount: UInt32 = 1

    public init(
        texture: TextureHandle,
        size: Bounds,
        provenance: SnapshotProvenance = .unknown,
        refcount: UInt32 = 1
    ) {
        self.texture = texture
        self.size = size
        self.provenance = provenance
        self.refcount = refcount
    }
}

/// Owns immutable snapshot handles and their refcounts. Mirrors
/// `SnapshotService`. A reference type — the service is shared, mutable
/// registry state.
public final class SnapshotService: @unchecked Sendable {
    private var entries: [SnapshotHandle: SnapshotEntry] = [:]
    private var nextHandle: UInt64 = 1
    /// Capture attempts blocked because the layer was a backdrop. Mirrors
    /// `backdrop_capture_blocks`.
    public var backdropCaptureBlocks: UInt64 = 0

    public init() {}

    /// Resolve a handle to its entry, or `nil` for `none`/unknown. Mirrors
    /// `resolve`.
    public func resolve(_ handle: SnapshotHandle) -> SnapshotEntry? {
        if handle.isNone { return nil }
        return entries[handle]
    }

    /// Add one ref to a live handle. No-op for `none`/unknown. Mirrors `retain`.
    public func retain(_ handle: SnapshotHandle) {
        if handle.isNone { return }
        guard entries[handle] != nil else { return }
        entries[handle]!.refcount &+= 1
    }

    /// Drop one ref. On the final ref, removes the entry and returns its texture
    /// handle for the resource owner to release; otherwise `nil`. Mirrors
    /// `release`.
    public func release(_ handle: SnapshotHandle) -> TextureHandle? {
        if handle.isNone { return nil }
        guard let entry = entries[handle] else { return nil }
        if entry.refcount > 1 {
            entries[handle]!.refcount -= 1
            return nil
        }
        entries[handle] = nil
        return entry.texture
    }

    /// Release every entry's texture through `releaser` and clear the registry.
    /// Mirrors `releaseAll`.
    public func releaseAll(_ releaser: (TextureHandle) -> Void) {
        for entry in entries.values { releaser(entry.texture) }
        entries.removeAll(keepingCapacity: true)
    }

    /// Register a service-owned texture under a fresh handle (unknown
    /// provenance). Mirrors `registerTextureHandle`.
    public func registerTextureHandle(_ texture: TextureHandle, size: Bounds) -> SnapshotHandle {
        registerTextureHandle(texture, size: size, provenance: .unknown)
    }

    /// Register a service-owned texture under a fresh handle with provenance.
    /// The handle counter wraps `u64` and skips `0`. Mirrors
    /// `registerTextureHandleWithProvenance`.
    public func registerTextureHandle(
        _ texture: TextureHandle, size: Bounds, provenance: SnapshotProvenance
    ) -> SnapshotHandle {
        let id = nextHandle
        nextHandle &+= 1
        if nextHandle == 0 { nextHandle = 1 }
        let handle = SnapshotHandle(raw: id)
        entries[handle] = SnapshotEntry(
            texture: texture, size: size, provenance: provenance, refcount: 1)
        return handle
    }
}
