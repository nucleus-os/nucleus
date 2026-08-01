// Retained-layer content, structural role, and backdrop-attachment value types.

package import NucleusTypes

// MARK: - Geometry aliases

/// A `[4]f32` payload (rect: x/y/w/h, or radii: tl/tr/br/bl); kept as a tuple
/// to match the value semantics.
package typealias Float4 = (Float, Float, Float, Float)

package func float4Equal(_ a: Float4, _ b: Float4) -> Bool {
    a.0 == b.0 && a.1 == b.1 && a.2 == b.2 && a.3 == b.3
}

// MARK: - Opaque render-resource handles

/// Renderer-owned immutable snapshot handle. The renderer resolves it
/// to a `*Texture` at draw time and owns the refcount. Mirrors `SnapshotHandle`
/// (`enum(u64)`, `none = 0`).
package struct SnapshotHandle: Equatable, Hashable, Sendable {
    package var raw: UInt64 = 0
    package init(raw: UInt64 = 0) { self.raw = raw }
    package static let none = SnapshotHandle(raw: 0)
    package var isNone: Bool { raw == 0 }
}

/// Render-server-owned paint-content handle resolved to a private display-list
/// store while repainting backing textures. Mirrors `PaintContentHandle`
/// (`enum(u64)`, `none = 0`).
package struct PaintContentHandle: Equatable, Hashable, Sendable {
    package var raw: UInt64 = 0
    package init(raw: UInt64 = 0) { self.raw = raw }
    package static let none = PaintContentHandle(raw: 0)
    package var isNone: Bool { raw == 0 }
}

/// Pure identity for an external client/compositor-owned IOSurface. Mirrors
/// `iosurface_types.IOSurfaceID` (`enum(u32)`, `none = 0`).
package struct IOSurfaceID: Equatable, Hashable, Sendable {
    package var raw: UInt32 = 0
    package init(raw: UInt32 = 0) { self.raw = raw }
    package static let none = IOSurfaceID(raw: 0)
    package var isNone: Bool { raw == 0 }
}

/// Target-context identity for a remote-host placeholder. Mirrors
/// `context_types.ContextID` (`enum(u32)`).
package struct ContextID: Equatable, Hashable, Sendable {
    package var raw: UInt32 = 0
    package init(raw: UInt32 = 0) { self.raw = raw }
}

// MARK: - Effect geometry

/// The geometry a backdrop/effect samples through. Mirrors `EffectShape`.
package enum EffectShape: Equatable, Sendable {
    case rect(Float4)
    case rrect(rect: Float4, radii: Float4)

    package static func == (lhs: EffectShape, rhs: EffectShape) -> Bool {
        switch (lhs, rhs) {
        case (.rect(let a), .rect(let b)):
            return float4Equal(a, b)
        case (.rrect(let ar, let arad), .rrect(let br, let brad)):
            return float4Equal(ar, br) && float4Equal(arad, brad)
        default:
            return false
        }
    }
}

/// Composite-time mask applied alongside the rounded-rect path. Mirrors
/// `BackdropMask`: `none`, `rounded_rect` radius, or an `image` alpha-mask.
package enum BackdropMask: Equatable, Sendable {
    case none
    case roundedRect(Float)
    case image(SnapshotHandle)
}

// MARK: - Content union

/// In-memory layer content. Structural kinds live on `LayerKind`; content lives
/// here. Mirrors `LayerContent`.
package enum LayerContent: Equatable, Sendable {
    case none
    case paint(PaintContentHandle)
    case external(IOSurfaceID)
    case snapshot(SnapshotHandle)
}

/// Initial content set on layer creation, resolved to `LayerContent`
/// by the applier. Mirrors `InitialContent`.
package enum InitialContent: Equatable, Sendable {
    case none
    case paint(PaintContentHandle)
    case external(IOSurfaceID)
    case snapshot(SnapshotHandle)

    /// The resolved `LayerContent` this initial content lowers to.
    package func resolved() -> LayerContent {
        switch self {
        case .none: return .none
        case .paint(let h): return .paint(h)
        case .external(let s): return .external(s)
        case .snapshot(let h): return .snapshot(h)
        }
    }
}

/// Content delta on a property update. `unchanged` leaves content
/// untouched; every other case replaces it. Mirrors `ContentDelta`.
package enum ContentDelta: Equatable, Sendable {
    case unchanged
    case none
    case paint(PaintContentHandle)
    case external(IOSurfaceID)
    case snapshot(SnapshotHandle)

    /// Apply this delta to an existing content value, returning the result.
    /// `unchanged` is identity; all other cases overwrite.
    package func apply(to current: LayerContent) -> LayerContent {
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
package struct BackdropAttachment: Equatable, Sendable {
    package var materialRole: BackdropMaterialRole
    package var blendingMode: BackdropBlendingMode
    package var state: BackdropState
    package var appearance: BackdropAppearance
    package var emphasized: Bool
    package var mask: BackdropMask
    package var shape: EffectShape
    /// Producer tint blended over the live blur sample; `a` is the mix factor.
    package var tint: NucleusTypes.Color = NucleusTypes.Color()
    /// Material-level opacity attenuation (separate from `ModelProperties.opacity`).
    package var opacity: Float = 1
    /// Group identity for shared captures; `0` defers grouping to policy.
    package var groupId: UInt64 = 0

    package init(
        materialRole: BackdropMaterialRole,
        blendingMode: BackdropBlendingMode,
        state: BackdropState,
        appearance: BackdropAppearance,
        emphasized: Bool,
        mask: BackdropMask,
        shape: EffectShape,
        tint: NucleusTypes.Color = NucleusTypes.Color(),
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

    package static func == (lhs: BackdropAttachment, rhs: BackdropAttachment) -> Bool {
        lhs.materialRole == rhs.materialRole && lhs.blendingMode == rhs.blendingMode
            && lhs.state == rhs.state && lhs.appearance == rhs.appearance
            && lhs.emphasized == rhs.emphasized && lhs.mask == rhs.mask && lhs.shape == rhs.shape
            && lhs.tint == rhs.tint && lhs.opacity == rhs.opacity && lhs.groupId == rhs.groupId
    }
}

// MARK: - Structural kind

/// Backdrop-kind payload for `LayerKind.backdrop`.
package struct BackdropKindParams: Equatable, Sendable {
    package var materialRole: BackdropMaterialRole = .default
    package var appearance: BackdropAppearance = .auto
    package var state: BackdropState = .active
    package var emphasized: Bool = false
    package var mask: BackdropMask = .none
    package var shape: EffectShape

    package init(
        materialRole: BackdropMaterialRole = .default,
        appearance: BackdropAppearance = .auto,
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

    package static func == (lhs: BackdropKindParams, rhs: BackdropKindParams) -> Bool {
        lhs.materialRole == rhs.materialRole && lhs.appearance == rhs.appearance
            && lhs.state == rhs.state && lhs.emphasized == rhs.emphasized && lhs.mask == rhs.mask
            && lhs.shape == rhs.shape
    }
}

/// Structural layer roles carrying only role-typed payload. Content is split off
/// into `LayerContent`.
package enum LayerKind: Equatable, Sendable {
    case container
    case backdrop(BackdropKindParams)
    case remoteHost(ContextID)
}
