// The GPU-independent Swift image store.
//
// The layers `ImageRegistrar` registers an image by *description* — a file path,
// encoded bytes, or raw pixels — never by a decoded Skia object. So the store
// stays GPU-independent: it holds the description plus a refcount keyed by an
// opaque handle, and the renderer decodes/uploads lazily at rasterization time
// (when a paint `.image` command references the handle). Registration therefore
// works in a headless bring-up where no Graphite recorder exists.

import Synchronization

/// Where an image's bytes come from.
package enum ImageContent: Equatable, Sendable {
    /// A file to decode. The overwhelmingly common case.
    case file(path: String)
    /// Encoded bytes already in memory — a `data:` URI, or anything else that
    /// arrives as a blob with no path to point at.
    case encoded(bytes: [UInt8])
    /// Decoded pixels, as notifications deliver them over D-Bus.
    case raw(RawPixelBuffer)
}

/// A registered image source: what to draw, and the bounds to decode within.
package struct ImageSource: Equatable, Sendable {
    package var content: ImageContent
    package var maxWidth: UInt32
    package var maxHeight: UInt32

    package init(content: ImageContent, maxWidth: UInt32 = 0, maxHeight: UInt32 = 0) {
        self.content = content
        if case .raw(let buffer) = content {
            self.maxWidth =
                maxWidth > 0
                ? maxWidth
                : UInt32(clamping: buffer.width)
            self.maxHeight =
                maxHeight > 0
                ? maxHeight
                : UInt32(clamping: buffer.height)
        } else {
            self.maxWidth = maxWidth
            self.maxHeight = maxHeight
        }
    }

    package init(path: String, maxWidth: UInt32, maxHeight: UInt32) {
        self.init(content: .file(path: path), maxWidth: maxWidth, maxHeight: maxHeight)
    }

    /// The file path, when this source is one. Nil for in-memory sources.
    package var path: String? {
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

package enum ImageStoreMutation: Equatable, Sendable {
    case retry(handle: UInt64)
    case replace(handle: UInt64, source: ImageSource)
    case evict(handle: UInt64)
}

/// Refcounted registry of image sources keyed by an opaque handle. The renderer
/// reads `source(_:)` to decode/upload at frame time; decode/cache is the
/// renderer's job.
package final class ImageStore: Sendable {
    private struct Entry {
        var source: ImageSource
        var refs: UInt32
    }

    private struct State {
        var entries: [UInt64: Entry] = [:]
        var byKey: [String: UInt64] = [:]
        var nextHandle: UInt64 = 1
        var mutations: [ImageStoreMutation] = []
    }

    private let state = Mutex(State())

    package init() {}

    package var count: Int {
        state.withLock { $0.entries.count }
    }

    /// Register (or dedupe to) an image source, returning its handle at refcount
    /// ≥1. A repeat registration of the same source bumps the existing refcount.
    /// Mirrors `adoptPrepared` keyed on the source.
    @discardableResult
    package func register(_ source: ImageSource) -> UInt64 {
        state.withLock { state in
            let key = source.dedupeKey
            if let handle = state.byKey[key] {
                state.entries[handle]!.refs &+= 1
                return handle
            }
            let handle = state.nextHandle
            state.nextHandle &+= 1
            if state.nextHandle == 0 { state.nextHandle = 1 }
            state.entries[handle] = Entry(source: source, refs: 1)
            state.byKey[key] = handle
            return handle
        }
    }

    /// Add one ref. No-op for an unknown handle. Mirrors `retain`.
    package func retain(_ handle: UInt64) {
        state.withLock {
            guard $0.entries[handle] != nil else { return }
            $0.entries[handle]!.refs &+= 1
        }
    }

    /// Drop one ref; evict at zero. No-op for an unknown handle. Mirrors `release`.
    package func release(_ handle: UInt64) {
        state.withLock { state in
            guard var entry = state.entries[handle] else { return }
            if entry.refs > 1 {
                entry.refs -= 1
                state.entries[handle] = entry
            } else {
                state.byKey[entry.source.dedupeKey] = nil
                state.entries[handle] = nil
                state.mutations.append(.evict(handle: handle))
            }
        }
    }

    /// Start a new generation for the same source-bound handle.
    ///
    /// Failure is terminal until this operation is requested explicitly.
    @discardableResult
    package func retry(_ handle: UInt64) -> Bool {
        state.withLock { state in
            guard state.entries[handle] != nil else { return false }
            state.mutations.append(.retry(handle: handle))
            return true
        }
    }

    /// Preserve a handle while replacing its source intentionally.
    ///
    /// Ordinary registration of a different source allocates a different
    /// handle. Replacement refuses to steal a source identity already owned by
    /// another live handle.
    @discardableResult
    package func replace(
        _ handle: UInt64,
        with source: ImageSource
    ) -> Bool {
        state.withLock { state in
            guard var entry = state.entries[handle] else { return false }
            let newKey = source.dedupeKey
            if let owner = state.byKey[newKey], owner != handle {
                return false
            }
            state.byKey[entry.source.dedupeKey] = nil
            entry.source = source
            state.entries[handle] = entry
            state.byKey[newKey] = handle
            state.mutations.append(
                .replace(
                    handle: handle,
                    source: source))
            return true
        }
    }

    /// The source registered for `handle`, or nil if unknown. The renderer
    /// decodes/uploads this at rasterization time.
    package func source(_ handle: UInt64) -> ImageSource? {
        state.withLock { $0.entries[handle]?.source }
    }

    /// Take explicit lifecycle mutations since the prior render-owner drain.
    package func takeMutations() -> [ImageStoreMutation] {
        state.withLock {
            let mutations = $0.mutations
            $0.mutations.removeAll(keepingCapacity: true)
            return mutations
        }
    }
}
