// Phase 10c.3 cutover — the GPU-independent Swift image store.
//
// The layers `ImageRegistrar` registers an image by FILE PATH (+ a max decode
// size), not by pixels or a decoded Skia object — so the store is GPU-independent:
// it holds the path + bounds + a refcount keyed by an opaque handle, and the
// renderer decodes/uploads the file lazily at rasterization time (when a paint
// `.image` command references the handle). This keeps image registration working
// in a headless bring-up where no Graphite recorder exists.

/// A registered image source: the file to decode and the max decode bounds.
public struct ImageSource: Equatable, Sendable {
    public var path: String
    public var maxWidth: UInt32
    public var maxHeight: UInt32

    public init(path: String, maxWidth: UInt32, maxHeight: UInt32) {
        self.path = path
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
    }
}

/// Refcounted registry of image sources keyed by an opaque handle. The renderer
/// reads `source(_:)` to decode/upload at frame time; decode/cache is the
/// renderer's job.
public final class ImageStore: @unchecked Sendable {
    private struct Entry {
        var source: ImageSource
        var refs: UInt32
    }

    private var entries: [UInt64: Entry] = [:]
    /// Path → handle dedupe so repeated registrations of the same source (same
    /// path + bounds) share one handle + bump its refcount.
    private var byKey: [String: UInt64] = [:]
    private var nextHandle: UInt64 = 1

    /// Notified with a handle when its last reference is released and its source is
    /// evicted. The renderer installs this to drop the handle's decoded-image cache
    /// entry — handles are monotonic and never reused, so the decoded GPU image would
    /// otherwise persist until shutdown. Invoked on the store's single (compositor)
    /// thread, same as `release`.
    public var onEvict: ((UInt64) -> Void)?

    public init() {}

    public var count: Int { entries.count }

    private func key(_ source: ImageSource) -> String {
        "\(source.maxWidth)x\(source.maxHeight):\(source.path)"
    }

    private func allocHandle() -> UInt64 {
        let id = nextHandle
        nextHandle &+= 1
        if nextHandle == 0 { nextHandle = 1 }
        return id
    }

    /// Register (or dedupe to) an image source, returning its handle at refcount
    /// ≥1. A repeat registration of the same source bumps the existing refcount.
    /// Mirrors `adoptPrepared` keyed on the source.
    @discardableResult
    public func register(_ source: ImageSource) -> UInt64 {
        let k = key(source)
        if let handle = byKey[k] {
            entries[handle]!.refs &+= 1
            return handle
        }
        let handle = allocHandle()
        entries[handle] = Entry(source: source, refs: 1)
        byKey[k] = handle
        return handle
    }

    /// Add one ref. No-op for an unknown handle. Mirrors `retain`.
    public func retain(_ handle: UInt64) {
        guard entries[handle] != nil else { return }
        entries[handle]!.refs &+= 1
    }

    /// Drop one ref; evict at zero. No-op for an unknown handle. Mirrors `release`.
    public func release(_ handle: UInt64) {
        guard var entry = entries[handle] else { return }
        if entry.refs > 1 {
            entry.refs -= 1
            entries[handle] = entry
        } else {
            byKey[key(entry.source)] = nil
            entries[handle] = nil
            onEvict?(handle)
        }
    }

    /// The source registered for `handle`, or nil if unknown. The renderer
    /// decodes/uploads this at rasterization time.
    public func source(_ handle: UInt64) -> ImageSource? {
        entries[handle]?.source
    }
}
