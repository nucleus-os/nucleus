// The GPU-independent Swift image store.
//
// The layers `ImageRegistrar` registers an image by *description* — a file path,
// encoded bytes, or raw pixels — never by a decoded Skia object. So the store
// stays GPU-independent: it holds the description plus a refcount keyed by an
// opaque handle, and the renderer decodes/uploads lazily at rasterization time
// (when a paint `.image` command references the handle). Registration therefore
// works in a headless bring-up where no Graphite recorder exists.

/// Where an image's bytes come from.
public enum ImageContent: Equatable, Sendable {
    /// A file to decode. The overwhelmingly common case.
    case file(path: String)
    /// Encoded bytes already in memory — a `data:` URI, or anything else that
    /// arrives as a blob with no path to point at.
    case encoded(bytes: [UInt8])
    /// Decoded pixels, as notifications deliver them over D-Bus.
    case raw(RawPixelBuffer)
}

/// A registered image source: what to draw, and the bounds to decode within.
public struct ImageSource: Equatable, Sendable {
    public var content: ImageContent
    public var maxWidth: UInt32
    public var maxHeight: UInt32

    public init(content: ImageContent, maxWidth: UInt32 = 0, maxHeight: UInt32 = 0) {
        self.content = content
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
    }

    public init(path: String, maxWidth: UInt32, maxHeight: UInt32) {
        self.init(content: .file(path: path), maxWidth: maxWidth, maxHeight: maxHeight)
    }

    /// The file path, when this source is one. Nil for in-memory sources.
    public var path: String? {
        if case .file(let path) = content { return path }
        return nil
    }

    /// The key two registrations must share to be the same registration.
    ///
    /// Bounds are part of it because they are part of what gets decoded. Content
    /// contributes a path directly, and a hash otherwise — raw pixels have no
    /// name, and a notification re-sending an unchanged icon on every update
    /// would otherwise register a fresh decode each time.
    var dedupeKey: String {
        let contentKey: String
        switch content {
        case .file(let path):
            contentKey = "f:\(path)"
        case .encoded(let bytes):
            contentKey = "e:\(bytes.count):\(ImageSource.hash(bytes))"
        case .raw(let buffer):
            contentKey = "r:\(buffer.contentHash())"
        }
        return "\(maxWidth)x\(maxHeight):\(contentKey)"
    }

    /// FNV-1a, matching `RawPixelBuffer.contentHash`.
    static func hash(_ bytes: [UInt8]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return hash
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
        source.dedupeKey
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
