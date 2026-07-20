// Phase 10c.3 — the GPU-independent Swift paint-content store.
//
// Shell-authored paint (wallpaper tints, status pills, decorations) is published
// as a list of high-level draw commands, not pixels: the producer registers a
// command list and binds the returned handle as a layer's `.paint` content; the
// renderer rasterizes the command list into a texture at frame time. Storing the
// command list (rather than a rasterized image) keeps this store GPU-independent
// — it works in a headless bring-up where no Graphite recorder exists.
// Refcounted: registered at 1, evicted at 0.

import Synchronization

// MARK: - Draw-command vocabulary

/// What a paint draw command paints. Densely numbered: the discriminants are
/// not stable across anything, because nothing serializes them.
public enum PaintDrawCommandKind: UInt32, Sendable {
    case rect = 0
    case roundedRect = 1
    case image = 2
    case path = 3
    case textLayout = 4
    case clipPath = 5
    case save = 6
    case restore = 7
}

/// Mirrors `NucleusTypes.PaintShading`; duplicated rather than imported
/// because this module deliberately resolves no dependencies.
public enum PaintDrawShading: UInt32, Sendable {
    case color = 0
    case linearGradient = 1
    case radialGradient = 2
    case sweepGradient = 3
    case effect = 4
}

/// Compositing mode for a draw command. Mirrors `NucleusTypes.PaintBlendMode`
/// and `nucleus::skia::BlendMode`; duplicated rather than imported because
/// this module deliberately resolves no dependencies.
/// An affine transform carried by a paint command.
public struct PaintDrawTransform: Equatable, Sendable {
    public var a: Float
    public var b: Float
    public var c: Float
    public var d: Float
    public var tx: Float
    public var ty: Float

    public init(a: Float, b: Float, c: Float, d: Float, tx: Float, ty: Float) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }
}

/// Stroke end and corner treatment. Mirrors Skia, and CoreGraphics before it.
public enum PaintDrawStrokeCap: UInt8, Sendable, Equatable {
    case butt, round, square
}

public enum PaintDrawStrokeJoin: UInt8, Sendable, Equatable {
    case miter, round, bevel
}

public enum PaintDrawBlendMode: UInt32, Sendable {
    case srcOver = 0
    case src = 1
    case multiply = 2
    case screen = 3
    case plus = 4
    case overlay = 5
    case dstIn = 6
    case dstOut = 7
}

/// One resolved paint draw command. Geometry + style + resource handles; the
/// renderer maps `imageHandle`/`textLayoutHandle` to its image / text-layout
/// registries at rasterization time. This is the decoded stored form of
/// `NucleusTypes.PaintCommand`.
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
    /// Handle into the compiled-SkSL registry, or 0. Consumed from Phase 4.
    public var effectHandle: UInt64
    /// Slice of the recording's payload blob holding this command's
    /// variable-length data (path verbs/points, gradient stops, uniforms).
    public var payloadOffset: UInt32
    public var payloadLength: UInt32
    public var stroke: Bool
    public var antialias: Bool
    public var evenOddFill: Bool
    /// Recolour an image draw by its alpha. Meaningless on a shape, which
    /// already paints in `color`.
    public var tintsImage: Bool
    public var strokeCap: PaintDrawStrokeCap
    public var strokeJoin: PaintDrawStrokeJoin
    /// The command's own transform, when it has one. Its geometry is then
    /// stated in the space this maps *from*; without it, geometry is already in
    /// the destination space. NucleusUI records every paint operation with a
    /// transform; `nil` remains supported for lower-level producers.
    public var transform: PaintDrawTransform?
    public var shading: PaintDrawShading
    public var blend: PaintDrawBlendMode
    public var alpha: Float
    public var blurSigma: Float
    public var saturation: Float

    public init(
        kind: PaintDrawCommandKind,
        x: Float, y: Float, w: Float, h: Float,
        radius: Float = 0, strokeWidth: Float = 0, fontSize: Float = 0,
        color: Float4 = (1, 1, 1, 1),
        imageHandle: UInt64 = 0, textLayoutHandle: UInt64 = 0,
        effectHandle: UInt64 = 0,
        payloadOffset: UInt32 = 0, payloadLength: UInt32 = 0,
        stroke: Bool = false, antialias: Bool = true, evenOddFill: Bool = false,
        tintsImage: Bool = false,
        strokeCap: PaintDrawStrokeCap = .butt,
        strokeJoin: PaintDrawStrokeJoin = .miter,
        transform: PaintDrawTransform? = nil,
        shading: PaintDrawShading = .color,
        blend: PaintDrawBlendMode = .srcOver,
        alpha: Float = 1, blurSigma: Float = 0, saturation: Float = 1
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
        self.effectHandle = effectHandle
        self.payloadOffset = payloadOffset
        self.payloadLength = payloadLength
        self.stroke = stroke
        self.antialias = antialias
        self.evenOddFill = evenOddFill
        self.tintsImage = tintsImage
        self.strokeCap = strokeCap
        self.strokeJoin = strokeJoin
        self.transform = transform
        self.shading = shading
        self.blend = blend
        self.alpha = alpha
        self.blurSigma = blurSigma
        self.saturation = saturation
    }

    /// Hand-written only because `Float4` is a tuple and so not `Equatable`.
    /// **Every stored property must appear here.** This comparison is the
    /// re-registration gate: a field omitted here makes two visually different
    /// commands compare equal, and the repaint is silently dropped.
    public static func == (lhs: PaintDrawCommand, rhs: PaintDrawCommand) -> Bool {
        lhs.kind == rhs.kind && lhs.x == rhs.x && lhs.y == rhs.y &&
            lhs.w == rhs.w && lhs.h == rhs.h && lhs.radius == rhs.radius &&
            lhs.strokeWidth == rhs.strokeWidth && lhs.fontSize == rhs.fontSize &&
            float4Equal(lhs.color, rhs.color) &&
            lhs.imageHandle == rhs.imageHandle && lhs.textLayoutHandle == rhs.textLayoutHandle &&
            lhs.effectHandle == rhs.effectHandle &&
            lhs.payloadOffset == rhs.payloadOffset && lhs.payloadLength == rhs.payloadLength &&
            lhs.stroke == rhs.stroke && lhs.antialias == rhs.antialias &&
            lhs.evenOddFill == rhs.evenOddFill && lhs.tintsImage == rhs.tintsImage &&
            lhs.strokeCap == rhs.strokeCap && lhs.strokeJoin == rhs.strokeJoin &&
            lhs.transform == rhs.transform &&
            lhs.shading == rhs.shading &&
            lhs.blend == rhs.blend &&
            lhs.alpha == rhs.alpha && lhs.blurSigma == rhs.blurSigma &&
            lhs.saturation == rhs.saturation
    }
}

// `paintDrawCommandKind(_:)` is gone. It mapped a raw discriminant to a kind
// and returned nil for unknown values, which callers turned into a silently
// dropped draw. In-process an unknown kind is a programmer error, so the
// decode is now an exhaustive switch over the enum with no `default`.

// MARK: - Store

/// Refcounted registry of paint command lists keyed by `PaintContentHandle`.
/// The renderer reads `commands(_:)` at frame time. Mirrors `PaintContentStore`.
public final class PaintContentStore: Sendable {
    public struct Content: Sendable {
        public var commands: [PaintDrawCommand]
        /// Variable-length data the commands index into via
        /// `payloadOffset`/`payloadLength`. Opaque to this store.
        public var payload: [UInt8]
        public var width: Float
        public var height: Float

        public init(
            commands: [PaintDrawCommand], payload: [UInt8] = [],
            width: Float, height: Float
        ) {
            self.commands = commands
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

    public init() {}

    public var count: Int {
        state.withLock { $0.entries.count }
    }

    /// Register a command list at refcount 1 and return its handle. Mirrors
    /// `registerCommands`.
    @discardableResult
    public func register(
        _ commands: [PaintDrawCommand], payload: [UInt8] = [],
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
    public func retain(_ handle: PaintContentHandle) {
        state.withLock {
            guard $0.entries[handle] != nil else { return }
            $0.entries[handle]!.refs &+= 1
        }
    }

    /// Drop one ref; evict at zero. No-op for an unknown handle. Mirrors
    /// `release` (image-handle release inside a command is the renderer's image
    /// registry's concern — this store holds only the command list).
    public func release(_ handle: PaintContentHandle) {
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
    public func commands(_ handle: PaintContentHandle) -> [PaintDrawCommand]? {
        state.withLock { $0.entries[handle]?.content.commands }
    }

    public func content(_ handle: PaintContentHandle) -> Content? {
        state.withLock { $0.entries[handle]?.content }
    }
}
