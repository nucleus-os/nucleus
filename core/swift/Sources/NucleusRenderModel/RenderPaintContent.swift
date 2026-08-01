//
// Shell-authored paint (wallpaper tints, status pills, decorations) is published
// as a list of high-level draw commands, not pixels: the producer registers a
// command list and binds the returned handle as a layer's `.paint` content; the
// renderer rasterizes the command list into a texture at frame time. Storing the
// command list (rather than a rasterized image) keeps this store GPU-independent
// — it works in a headless bring-up where no Graphite recorder exists.
// Refcounted: registered at 1, evicted at 0.

package import NucleusTypes
import Synchronization

// MARK: - Store

/// Refcounted registry of paint command lists keyed by `PaintContentHandle`.
/// The renderer reads `commands(_:)` at frame time. Mirrors `PaintContentStore`.
package final class PaintContentStore: Sendable {
    package struct Content: Sendable {
        package let commands: [PaintCommand]
        /// Unique image resources referenced by this immutable command list.
        /// The renderer consumes this directly instead of rescanning commands
        /// every frame to infer cache dependencies.
        package let imageDependencies: [UInt64]
        /// Variable-length data the commands index into via
        /// `payloadOffset`/`payloadLength`. Opaque to this store.
        package let payload: [UInt8]
        package let width: Float
        package let height: Float

        package init(
            commands: [PaintCommand], payload: [UInt8] = [],
            width: Float, height: Float
        ) {
            self.commands = commands
            self.imageDependencies = Array(
                Set(
                    commands.compactMap {
                        $0.kind == .image && $0.imageHandle != 0
                            ? $0.imageHandle
                            : nil
                    })
            ).sorted()
            self.payload = payload
            self.width = width
            self.height = height
        }
    }

    private struct Entry {
        var content: Content
        var refs: UInt32
    }

    private struct State {
        var entries: [PaintContentHandle: Entry] = [:]
        var nextHandle: UInt64 = 1
    }

    private let state = Mutex(State())

    package init() {}

    package var count: Int {
        state.withLock { $0.entries.count }
    }

    /// Register a command list at refcount 1 and return its handle. Mirrors
    /// `registerCommands`.
    @discardableResult
    package func register(
        _ commands: [PaintCommand], payload: [UInt8] = [],
        width: Float, height: Float
    ) -> PaintContentHandle {
        state.withLock {
            let handle = PaintContentHandle(raw: $0.nextHandle)
            $0.nextHandle &+= 1
            if $0.nextHandle == 0 { $0.nextHandle = 1 }
            $0.entries[handle] = Entry(
                content: Content(
                    commands: commands, payload: payload, width: width,
                    height: height),
                refs: 1)
            return handle
        }
    }

    /// Add one ref. No-op for an unknown handle. Mirrors `retain`.
    package func retain(_ handle: PaintContentHandle) {
        state.withLock {
            guard $0.entries[handle] != nil else { return }
            $0.entries[handle]!.refs &+= 1
        }
    }

    /// Drop one ref; evict at zero. No-op for an unknown handle. Mirrors
    /// `release` (image-handle release inside a command is the renderer's image
    /// registry's concern — this store holds only the command list).
    package func release(_ handle: PaintContentHandle) {
        state.withLock {
            guard var entry = $0.entries[handle] else { return }
            if entry.refs > 1 {
                entry.refs -= 1
                $0.entries[handle] = entry
            } else {
                $0.entries[handle] = nil
            }
        }
    }

    /// The command list registered for `handle`, or nil if unknown. Mirrors
    /// `displayList`/`picture` queries.
    package func commands(_ handle: PaintContentHandle) -> [PaintCommand]? {
        state.withLock { $0.entries[handle]?.content.commands }
    }

    package func content(_ handle: PaintContentHandle) -> Content? {
        state.withLock { $0.entries[handle]?.content }
    }
}
