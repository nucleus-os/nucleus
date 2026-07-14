// Phase 10c.3 — the GPU-independent Swift paint-content store.
//
// Shell-authored paint (wallpaper tints, status pills, decorations) is published
// as a list of high-level draw commands, not pixels: the producer registers a
// command list and binds the returned handle as a layer's `.paint` content; the
// renderer rasterizes the command list into a texture at frame time. Storing the
// command list (rather than a rasterized image) keeps this store GPU-independent
// — it works in a headless bring-up where no Graphite recorder exists.
// Refcounted: registered at 1, evicted at 0.

// MARK: - Draw-command vocabulary

/// What a paint draw command paints. Wire-stable discriminants matching the
/// layers ABI (`nucleus_paint_command_kind`): the gaps (0, 3) are unused on
/// the wire.
public enum PaintDrawCommandKind: UInt32, Sendable {
    case rect = 1
    case roundedRect = 2
    case image = 4
    case line = 5
    case textLayout = 6
}

/// One resolved paint draw command. Geometry + style + resource handles; the
/// renderer maps `imageHandle`/`textLayoutHandle` to its image / text-layout
/// registries at rasterization time. Mirrors `artifact_store.PaintCommand`
/// (and the wire `nucleus_paint_command`).
public struct PaintDrawCommand: Equatable, Sendable {
    public var kind: PaintDrawCommandKind
    public var x: Float
    public var y: Float
    public var w: Float
    public var h: Float
    public var radius: Float
    public var strokeWidth: Float
    public var fontSize: Float
    /// Premultiplied-source RGBA (top-left, used directly by the rasterizer).
    public var color: Float4
    public var imageHandle: UInt64
    public var textLayoutHandle: UInt64

    public init(
        kind: PaintDrawCommandKind,
        x: Float, y: Float, w: Float, h: Float,
        radius: Float = 0, strokeWidth: Float = 0, fontSize: Float = 0,
        color: Float4 = (1, 1, 1, 1),
        imageHandle: UInt64 = 0, textLayoutHandle: UInt64 = 0
    ) {
        self.kind = kind
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.radius = radius
        self.strokeWidth = strokeWidth
        self.fontSize = fontSize
        self.color = color
        self.imageHandle = imageHandle
        self.textLayoutHandle = textLayoutHandle
    }

    public static func == (lhs: PaintDrawCommand, rhs: PaintDrawCommand) -> Bool {
        lhs.kind == rhs.kind && lhs.x == rhs.x && lhs.y == rhs.y &&
            lhs.w == rhs.w && lhs.h == rhs.h && lhs.radius == rhs.radius &&
            lhs.strokeWidth == rhs.strokeWidth && lhs.fontSize == rhs.fontSize &&
            float4Equal(lhs.color, rhs.color) &&
            lhs.imageHandle == rhs.imageHandle && lhs.textLayoutHandle == rhs.textLayoutHandle
    }
}

/// Map a wire discriminant to a draw-command kind, dropping unknown/unsupported
/// values (the wire reserves 0 and 3). Mirrors `paintCommandKind`.
public func paintDrawCommandKind(_ raw: UInt32) -> PaintDrawCommandKind? {
    PaintDrawCommandKind(rawValue: raw)
}

// MARK: - Store

/// Refcounted registry of paint command lists keyed by `PaintContentHandle`.
/// The renderer reads `commands(_:)` at frame time. Mirrors `PaintContentStore`.
public final class PaintContentStore: @unchecked Sendable {
    public struct Content: Sendable {
        public var commands: [PaintDrawCommand]
        public var width: Float
        public var height: Float

        public init(commands: [PaintDrawCommand], width: Float, height: Float) {
            self.commands = commands
            self.width = width
            self.height = height
        }
    }

    private struct Entry {
        var content: Content
        var refs: UInt32
    }

    private var entries: [PaintContentHandle: Entry] = [:]
    private var nextHandle: UInt64 = 1

    public init() {}

    public var count: Int { entries.count }

    /// Allocate a fresh non-zero handle (u64 wrap, skipping 0). Mirrors the
    /// handle minting in `PaintContentStore`.
    private func allocHandle() -> PaintContentHandle {
        let id = nextHandle
        nextHandle &+= 1
        if nextHandle == 0 { nextHandle = 1 }
        return PaintContentHandle(raw: id)
    }

    /// Register a command list at refcount 1 and return its handle. Mirrors
    /// `registerCommands`.
    @discardableResult
    public func register(
        _ commands: [PaintDrawCommand], width: Float, height: Float
    ) -> PaintContentHandle {
        let handle = allocHandle()
        entries[handle] = Entry(
            content: Content(commands: commands, width: width, height: height), refs: 1)
        return handle
    }

    /// Add one ref. No-op for an unknown handle. Mirrors `retain`.
    public func retain(_ handle: PaintContentHandle) {
        guard entries[handle] != nil else { return }
        entries[handle]!.refs &+= 1
    }

    /// Drop one ref; evict at zero. No-op for an unknown handle. Mirrors
    /// `release` (image-handle release inside a command is the renderer's image
    /// registry's concern — this store holds only the command list).
    public func release(_ handle: PaintContentHandle) {
        guard var entry = entries[handle] else { return }
        if entry.refs > 1 {
            entry.refs -= 1
            entries[handle] = entry
        } else {
            entries[handle] = nil
        }
    }

    /// The command list registered for `handle`, or nil if unknown. Mirrors
    /// `displayList`/`picture` queries.
    public func commands(_ handle: PaintContentHandle) -> [PaintDrawCommand]? {
        entries[handle]?.content.commands
    }

    public func content(_ handle: PaintContentHandle) -> Content? {
        entries[handle]?.content
    }
}
