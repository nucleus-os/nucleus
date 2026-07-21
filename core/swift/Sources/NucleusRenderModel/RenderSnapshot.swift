// Phase 8.10 — Swift snapshot handle registry.
//
// `SnapshotService` owns immutable handles used by `.snapshot` layer contents.
// Entries carry an opaque `TextureHandle` plus size and provenance; GPU-resource
// pointers never cross this boundary.
//
// `TextureHandle` (canonically `composition_plan.TextureHandle`) is defined here
// as its first Swift consumer.

import Synchronization

/// Opaque render-resource texture handle. Mirrors `composition_plan.TextureHandle`
/// (`enum(u64)`).
public struct TextureHandle: Equatable, Hashable, Sendable {
    public var raw: UInt64 = 0
    public init(raw: UInt64 = 0) { self.raw = raw }
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
public final class SnapshotService: Sendable {
    private struct State {
        var entries: [SnapshotHandle: SnapshotEntry] = [:]
        var nextHandle: UInt64 = 1
        var backdropCaptureBlocks: UInt64 = 0
    }

    private let state = Mutex(State())

    /// Capture attempts blocked because the layer was a backdrop. Mirrors
    /// `backdrop_capture_blocks`.
    public var backdropCaptureBlocks: UInt64 {
        get { state.withLock { $0.backdropCaptureBlocks } }
        set { state.withLock { $0.backdropCaptureBlocks = newValue } }
    }

    /// Number of live snapshot resources. This is an ownership counter, not a
    /// frame-timing metric: structural lifecycle tests use it to prove that
    /// transition teardown returns the registry to baseline.
    public var liveCount: Int {
        state.withLock { $0.entries.count }
    }

    public init() {}

    /// Resolve a handle to its entry, or `nil` for `none`/unknown. Mirrors
    /// `resolve`.
    public func resolve(_ handle: SnapshotHandle) -> SnapshotEntry? {
        if handle.isNone { return nil }
        return state.withLock { $0.entries[handle] }
    }

    /// Add one ref to a live handle. No-op for `none`/unknown. Mirrors `retain`.
    public func retain(_ handle: SnapshotHandle) {
        if handle.isNone { return }
        state.withLock {
            guard $0.entries[handle] != nil else { return }
            $0.entries[handle]!.refcount &+= 1
        }
    }

    /// Drop one ref. On the final ref, removes the entry and returns its texture
    /// handle for the resource owner to release; otherwise `nil`. Mirrors
    /// `release`.
    public func release(_ handle: SnapshotHandle) -> TextureHandle? {
        if handle.isNone { return nil }
        return state.withLock {
            guard let entry = $0.entries[handle] else { return nil }
            if entry.refcount > 1 {
                $0.entries[handle]!.refcount -= 1
                return nil
            }
            $0.entries[handle] = nil
            return entry.texture
        }
    }

    /// Release every entry's texture through `releaser` and clear the registry.
    /// Mirrors `releaseAll`.
    public func releaseAll(_ releaser: (TextureHandle) -> Void) {
        let textures = state.withLock {
            let textures = $0.entries.values.map(\.texture)
            $0.entries.removeAll(keepingCapacity: true)
            return textures
        }
        for texture in textures { releaser(texture) }
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
        state.withLock {
            let id = $0.nextHandle
            $0.nextHandle &+= 1
            if $0.nextHandle == 0 { $0.nextHandle = 1 }
            let handle = SnapshotHandle(raw: id)
            $0.entries[handle] = SnapshotEntry(
                texture: texture, size: size, provenance: provenance,
                refcount: 1)
            return handle
        }
    }
}
