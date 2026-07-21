// Retained-layer content, structural role, and backdrop-attachment value types.

// MARK: - Geometry aliases

/// A `[4]f32` payload (rect: x/y/w/h, or radii: tl/tr/br/bl); kept as a tuple
/// to match the value semantics.
public typealias Float4 = (Float, Float, Float, Float)

@inline(__always)
public func float4Equal(_ a: Float4, _ b: Float4) -> Bool {
    a.0 == b.0 && a.1 == b.1 && a.2 == b.2 && a.3 == b.3
}

// MARK: - Opaque render-resource handles

/// Renderer-owned immutable snapshot handle. The renderer resolves it
/// to a `*Texture` at draw time and owns the refcount. Mirrors `SnapshotHandle`
/// (`enum(u64)`, `none = 0`).
public struct SnapshotHandle: Equatable, Hashable, Sendable {
    public var raw: UInt64 = 0
    public init(raw: UInt64 = 0) { self.raw = raw }
    public static let none = SnapshotHandle(raw: 0)
    public var isNone: Bool { raw == 0 }
}

/// Render-server-owned paint-content handle resolved to a private display-list
/// store while repainting backing textures. Mirrors `PaintContentHandle`
/// (`enum(u64)`, `none = 0`).
public struct PaintContentHandle: Equatable, Hashable, Sendable {
    public var raw: UInt64 = 0
    public init(raw: UInt64 = 0) { self.raw = raw }
    public static let none = PaintContentHandle(raw: 0)
    public var isNone: Bool { raw == 0 }
}

/// Pure identity for an external client/compositor-owned IOSurface. Mirrors
/// `iosurface_types.IOSurfaceID` (`enum(u32)`, `none = 0`).
public struct IOSurfaceID: Equatable, Hashable, Sendable {
    public var raw: UInt32 = 0
    public init(raw: UInt32 = 0) { self.raw = raw }
    public static let none = IOSurfaceID(raw: 0)
    public var isNone: Bool { raw == 0 }
}

/// Target-context identity for a remote-host placeholder. Mirrors
/// `context_types.ContextID` (`enum(u32)`).
public struct ContextID: Equatable, Hashable, Sendable {
    public var raw: UInt32 = 0
    public init(raw: UInt32 = 0) { self.raw = raw }
}

// MARK: - Effect geometry

/// The geometry a backdrop/effect samples through. Mirrors `EffectShape`.
public enum EffectShape: Equatable, Sendable {
    case rect(Float4)
    case rrect(rect: Float4, radii: Float4)

    public static func == (lhs: EffectShape, rhs: EffectShape) -> Bool {
        switch (lhs, rhs) {
        case let (.rect(a), .rect(b)):
            return float4Equal(a, b)
        case let (.rrect(ar, arad), .rrect(br, brad)):
            return float4Equal(ar, br) && float4Equal(arad, brad)
        default:
            return false
        }
    }
}

/// Composite-time mask applied alongside the rounded-rect path. Mirrors
/// `BackdropMask`: `none`, `rounded_rect` radius, or an `image` alpha-mask.
public enum BackdropMask: Equatable, Sendable {
    case none
    case roundedRect(Float)
    case image(SnapshotHandle)
}

// MARK: - Content union

/// In-memory layer content. Structural kinds live on `LayerKind`; content lives
/// here. Mirrors `LayerContent`.
public enum LayerContent: Equatable, Sendable {
    case none
    case paint(PaintContentHandle)
    case external(IOSurfaceID)
    case snapshot(SnapshotHandle)
}

/// Wire-level initial content set on layer creation, resolved to `LayerContent`
/// by the applier. Mirrors `InitialContent`.
public enum InitialContent: Equatable, Sendable {
    case none
    case paint(PaintContentHandle)
    case external(IOSurfaceID)
    case snapshot(SnapshotHandle)

    /// The resolved `LayerContent` this initial content lowers to.
    public func resolved() -> LayerContent {
        switch self {
        case .none: return .none
        case .paint(let h): return .paint(h)
        case .external(let s): return .external(s)
        case .snapshot(let h): return .snapshot(h)
        }
    }
}

/// Wire-level content delta on a property update. `unchanged` leaves content
/// untouched; every other case replaces it. Mirrors `ContentDelta`.
public enum ContentDelta: Equatable, Sendable {
    case unchanged
    case none
    case paint(PaintContentHandle)
    case external(IOSurfaceID)
    case snapshot(SnapshotHandle)

    /// Apply this delta to an existing content value, returning the result.
    /// `unchanged` is identity; all other cases overwrite.
    public func apply(to current: LayerContent) -> LayerContent {
        switch self {
        case .unchanged: return current
        case .none: return .none
        case .paint(let h): return .paint(h)
        case .external(let s): return .external(s)
        case .snapshot(let h): return .snapshot(h)
        }
    }
}

// MARK: - Backdrop attachment

/// Per-layer backdrop attachment driving blur/tint/composite. Lives as a
/// property of any container layer (mirrors `CALayer.backgroundFilters`), not
/// nested inside `LayerKind`. Mirrors `BackdropAttachment`.
public struct BackdropAttachment: Equatable, Sendable {
    public var materialRole: BackdropMaterialRole
    public var blendingMode: BackdropBlendingMode
    public var state: BackdropState
    public var appearance: AppearanceMode
    public var emphasized: Bool
    public var mask: BackdropMask
    public var shape: EffectShape
    /// Producer tint blended over the live blur sample; `a` is the mix factor.
    public var tint: LayerColor = (0, 0, 0, 0)
    /// Material-level opacity attenuation (separate from `ModelProperties.opacity`).
    public var opacity: Float = 1
    /// Group identity for shared captures; `0` defers grouping to policy.
    public var groupId: UInt64 = 0

    public init(
        materialRole: BackdropMaterialRole,
        blendingMode: BackdropBlendingMode,
        state: BackdropState,
        appearance: AppearanceMode,
        emphasized: Bool,
        mask: BackdropMask,
        shape: EffectShape,
        tint: LayerColor = (0, 0, 0, 0),
        opacity: Float = 1,
        groupId: UInt64 = 0
    ) {
        self.materialRole = materialRole
        self.blendingMode = blendingMode
        self.state = state
        self.appearance = appearance
        self.emphasized = emphasized
        self.mask = mask
        self.shape = shape
        self.tint = tint
        self.opacity = opacity
        self.groupId = groupId
    }

    public static func == (lhs: BackdropAttachment, rhs: BackdropAttachment) -> Bool {
        lhs.materialRole == rhs.materialRole && lhs.blendingMode == rhs.blendingMode &&
            lhs.state == rhs.state && lhs.appearance == rhs.appearance &&
            lhs.emphasized == rhs.emphasized && lhs.mask == rhs.mask &&
            lhs.shape == rhs.shape && lhs.tint == rhs.tint &&
            lhs.opacity == rhs.opacity && lhs.groupId == rhs.groupId
    }
}

// MARK: - Structural kind

/// Backdrop-kind payload for `LayerKind.backdrop`.
public struct BackdropKindParams: Equatable, Sendable {
    public var materialRole: BackdropMaterialRole = .default
    public var appearance: AppearanceMode = .auto
    public var state: BackdropState = .active
    public var emphasized: Bool = false
    public var mask: BackdropMask = .none
    public var shape: EffectShape

    public init(
        materialRole: BackdropMaterialRole = .default,
        appearance: AppearanceMode = .auto,
        state: BackdropState = .active,
        emphasized: Bool = false,
        mask: BackdropMask = .none,
        shape: EffectShape
    ) {
        self.materialRole = materialRole
        self.appearance = appearance
        self.state = state
        self.emphasized = emphasized
        self.mask = mask
        self.shape = shape
    }

    public static func == (lhs: BackdropKindParams, rhs: BackdropKindParams) -> Bool {
        lhs.materialRole == rhs.materialRole && lhs.appearance == rhs.appearance &&
            lhs.state == rhs.state && lhs.emphasized == rhs.emphasized &&
            lhs.mask == rhs.mask && lhs.shape == rhs.shape
    }
}

/// Structural layer roles carrying only role-typed payload. Content is split off
/// into `LayerContent`.
public enum LayerKind: Equatable, Sendable {
    case container
    case backdrop(BackdropKindParams)
    case remoteHost(ContextID)
}
