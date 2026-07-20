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

import Synchronization

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
public final class RuntimeEffectStore: Sendable {
    private struct Entry {
        var source: RuntimeEffectSource
        var refs: UInt32
    }

    private struct State {
        var entries: [UInt64: Entry] = [:]
        var byKey: [String: UInt64] = [:]
        var nextHandle: UInt64 = 1
        var evictedHandles: [UInt64] = []
    }

    private let state = Mutex(State())

    public init() {}

    public var count: Int {
        state.withLock { $0.entries.count }
    }

    /// Register (or dedupe to) an SkSL source, returning its handle at refcount
    /// ≥1. A repeat registration of the same source bumps the existing refcount.
    @discardableResult
    public func register(_ source: RuntimeEffectSource) -> UInt64 {
        state.withLock { state in
            if let handle = state.byKey[source.sksl] {
                state.entries[handle]!.refs &+= 1
                return handle
            }
            let handle = state.nextHandle
            state.nextHandle &+= 1
            if state.nextHandle == 0 { state.nextHandle = 1 }
            state.entries[handle] = Entry(source: source, refs: 1)
            state.byKey[source.sksl] = handle
            return handle
        }
    }

    /// Add one ref. No-op for an unknown handle.
    public func retain(_ handle: UInt64) {
        state.withLock {
            guard $0.entries[handle] != nil else { return }
            $0.entries[handle]!.refs &+= 1
        }
    }

    /// Drop one ref; evict at zero. No-op for an unknown handle.
    public func release(_ handle: UInt64) {
        state.withLock { state in
            guard var entry = state.entries[handle] else { return }
            if entry.refs > 1 {
                entry.refs -= 1
                state.entries[handle] = entry
            } else {
                state.byKey[entry.source.sksl] = nil
                state.entries[handle] = nil
                state.evictedHandles.append(handle)
            }
        }
    }

    /// The source registered for `handle`, or nil if unknown. The renderer
    /// compiles this at rasterization time.
    public func source(_ handle: UInt64) -> RuntimeEffectSource? {
        state.withLock { $0.entries[handle]?.source }
    }

    /// Take cache handles evicted since the previous render-owner drain.
    public func takeEvictedHandles() -> [UInt64] {
        state.withLock {
            let handles = $0.evictedHandles
            $0.evictedHandles.removeAll(keepingCapacity: true)
            return handles
        }
    }
}
