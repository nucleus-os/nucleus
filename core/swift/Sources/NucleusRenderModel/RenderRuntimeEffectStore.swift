// The GPU-independent Swift runtime-effect store.
//
// An SkSL program is registered by SOURCE, not by a compiled Skia object, so
// this store is GPU-independent in exactly the way `ImageStore` is: it holds
// the source + a refcount keyed by an opaque handle, and the renderer compiles
// lazily at rasterization time (when a paint command references the handle).
// Registration therefore works in a headless bring-up with no Graphite recorder.
//
// The split matters because compilation is the expensive half and does not
// depend on uniform values: uniforms ride the per-frame payload blob and change
// every frame, while the program does not. Caching the compiled program behind
// a handle is the whole point of this store.

/// A registered SkSL program source.
public struct RuntimeEffectSource: Equatable, Sendable {
    public var sksl: String

    public init(sksl: String) {
        self.sksl = sksl
    }
}

/// Refcounted registry of SkSL sources keyed by an opaque handle. The renderer
/// reads `source(_:)` to compile at frame time and caches the compiled program;
/// compile/cache is the renderer's job. Mirrors `ImageStore`.
public final class RuntimeEffectStore: @unchecked Sendable {
    private struct Entry {
        var source: RuntimeEffectSource
        var refs: UInt32
    }

    private var entries: [UInt64: Entry] = [:]
    /// Source → handle dedupe. The shell's effect set is small, fixed, and
    /// registered repeatedly as views come and go, so registering the same
    /// program twice must share one handle rather than recompile.
    private var byKey: [String: UInt64] = [:]
    private var nextHandle: UInt64 = 1

    /// Notified with a handle when its last reference is released and its
    /// source is evicted. The renderer installs this to drop the handle's
    /// compiled-program cache entry — handles are monotonic and never reused,
    /// so the compiled effect would otherwise persist until shutdown. Invoked
    /// on the store's single (compositor) thread, same as `release`.
    public var onEvict: ((UInt64) -> Void)?

    public init() {}

    public var count: Int { entries.count }

    private func allocHandle() -> UInt64 {
        let id = nextHandle
        nextHandle &+= 1
        if nextHandle == 0 { nextHandle = 1 }
        return id
    }

    /// Register (or dedupe to) an SkSL source, returning its handle at refcount
    /// ≥1. A repeat registration of the same source bumps the existing refcount.
    @discardableResult
    public func register(_ source: RuntimeEffectSource) -> UInt64 {
        if let handle = byKey[source.sksl] {
            entries[handle]!.refs &+= 1
            return handle
        }
        let handle = allocHandle()
        entries[handle] = Entry(source: source, refs: 1)
        byKey[source.sksl] = handle
        return handle
    }

    /// Add one ref. No-op for an unknown handle.
    public func retain(_ handle: UInt64) {
        guard entries[handle] != nil else { return }
        entries[handle]!.refs &+= 1
    }

    /// Drop one ref; evict at zero. No-op for an unknown handle.
    public func release(_ handle: UInt64) {
        guard var entry = entries[handle] else { return }
        if entry.refs > 1 {
            entry.refs -= 1
            entries[handle] = entry
        } else {
            byKey[entry.source.sksl] = nil
            entries[handle] = nil
            onEvict?(handle)
        }
    }

    /// The source registered for `handle`, or nil if unknown. The renderer
    /// compiles this at rasterization time.
    public func source(_ handle: UInt64) -> RuntimeEffectSource? {
        entries[handle]?.source
    }
}
