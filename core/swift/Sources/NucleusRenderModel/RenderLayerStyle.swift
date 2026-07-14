// Phase 8.1 — Swift render-layer visual-style + backdrop vocabulary.
//
// The first slice of the render-server retained-layer model ported to Swift: the
// self-contained visual-style value types (`VisualStyle`, `BorderEdge`,
// `LayerShadow`) and the macOS-shaped backdrop enums. These are pure data + the
// shadow extent computation; the per-node
// `ModelState`/`PresentationState`, the backdrop attachment, content, and the
// tree itself follow in later 8.x slices. This is the dormant Swift authority
// the render-server tree collapses into. Nothing
// imports this yet.

// MARK: - Color

/// Unpremultiplied RGBA in [0, 1].
public typealias LayerColor = (r: Float, g: Float, b: Float, a: Float)

// MARK: - Visual style

/// One border edge: width + color. Mirrors `RenderLayer.BorderEdge`.
public struct BorderEdge: Equatable, Sendable {
    public var width: Float = 0
    public var color: LayerColor = (0, 0, 0, 0)

    public init(width: Float = 0, color: LayerColor = (0, 0, 0, 0)) {
        self.width = width
        self.color = color
    }

    public static func == (lhs: BorderEdge, rhs: BorderEdge) -> Bool {
        lhs.width == rhs.width && lhs.color == rhs.color
    }
}

/// A layer drop shadow. Mirrors `RenderLayer.LayerShadow`, including the
/// per-shadow `cornerRadius` override and the `outerExtent` halo computation.
public struct LayerShadow: Equatable, Sendable {
    public var offsetX: Float = 0
    public var offsetY: Float = 0
    public var blurRadius: Float = 0
    public var spreadRadius: Float = 0
    /// Per-shadow rounded-rect corner override (CALayer `shadowPath` for the
    /// common case); when > 0 the rasterizer uses this instead of the layer's
    /// `cornerRadii`.
    public var cornerRadius: Float = 0
    public var color: LayerColor = (0, 0, 0, 0)

    public init(
        offsetX: Float = 0,
        offsetY: Float = 0,
        blurRadius: Float = 0,
        spreadRadius: Float = 0,
        cornerRadius: Float = 0,
        color: LayerColor = (0, 0, 0, 0)
    ) {
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.blurRadius = blurRadius
        self.spreadRadius = spreadRadius
        self.cornerRadius = cornerRadius
        self.color = color
    }

    /// How far the rendered shadow extends past the layer bounds, per axis
    /// (symmetric). 3σ covers ~99% of Gaussian energy where σ = blurRadius/2,
    /// plus the offset. Zero when fully transparent. Mirrors `outerExtent`.
    public func outerExtent() -> (x: Float, y: Float) {
        guard color.a > 0 else { return (0, 0) }
        let sigma = blurRadius / 2.0
        return (
            x: (3.0 * sigma + abs(offsetX)).rounded(.up),
            y: (3.0 * sigma + abs(offsetY)).rounded(.up))
    }

    public static func == (lhs: LayerShadow, rhs: LayerShadow) -> Bool {
        lhs.offsetX == rhs.offsetX && lhs.offsetY == rhs.offsetY &&
            lhs.blurRadius == rhs.blurRadius && lhs.spreadRadius == rhs.spreadRadius &&
            lhs.cornerRadius == rhs.cornerRadius && lhs.color == rhs.color
    }
}

/// A layer's rasterizable visual style: background fill, four border edges, four
/// corner radii, and an optional shadow. Mirrors `RenderLayer.VisualStyle`.
public struct VisualStyle: Equatable, Sendable {
    public var backgroundColor: LayerColor = (0, 0, 0, 0)
    public var borderTop = BorderEdge()
    public var borderRight = BorderEdge()
    public var borderBottom = BorderEdge()
    public var borderLeft = BorderEdge()
    /// Top-left, top-right, bottom-right, bottom-left.
    public var cornerRadii: (Float, Float, Float, Float) = (0, 0, 0, 0)
    public var shadow: LayerShadow?

    public init(
        backgroundColor: LayerColor = (0, 0, 0, 0),
        borderTop: BorderEdge = BorderEdge(),
        borderRight: BorderEdge = BorderEdge(),
        borderBottom: BorderEdge = BorderEdge(),
        borderLeft: BorderEdge = BorderEdge(),
        cornerRadii: (Float, Float, Float, Float) = (0, 0, 0, 0),
        shadow: LayerShadow? = nil
    ) {
        self.backgroundColor = backgroundColor
        self.borderTop = borderTop
        self.borderRight = borderRight
        self.borderBottom = borderBottom
        self.borderLeft = borderLeft
        self.cornerRadii = cornerRadii
        self.shadow = shadow
    }

    public static func == (lhs: VisualStyle, rhs: VisualStyle) -> Bool {
        lhs.backgroundColor == rhs.backgroundColor &&
            lhs.borderTop == rhs.borderTop && lhs.borderRight == rhs.borderRight &&
            lhs.borderBottom == rhs.borderBottom && lhs.borderLeft == rhs.borderLeft &&
            lhs.cornerRadii == rhs.cornerRadii && lhs.shadow == rhs.shadow
    }
}

/// Sparse update for the whole `VisualStyle`. Mirrors `VisualStyleDelta`.
public enum VisualStyleDelta: Equatable, Sendable {
    case unchanged
    case set(VisualStyle)
    case clear
}

/// Independent update for just the shadow component, applied after a
/// `VisualStyleDelta` so one update can replace the style then patch the shadow.
/// Mirrors `ShadowDelta`.
public enum ShadowDelta: Equatable, Sendable {
    case unchanged
    case set(LayerShadow)
    case clear
}

// MARK: - Backdrop vocabulary

/// macOS-shaped material identity (the `NSVisualEffectView.Material` mirror plus
/// the Nucleus `default`/`shellOverlay` rows). Mirrors `BackdropMaterialRole`.
public enum BackdropMaterialRole: UInt8, Sendable, CaseIterable {
    case `default`
    case sidebar
    case hudWindow
    case menu
    case popover
    case titlebar
    case sheet
    case headerView
    case selection
    case underWindowBackground
    case underPageBackground
    case fullScreenUI
    case toolTip
    case windowBackground
    case contentBackground
    case shellOverlay
}

/// Desktop appearance preference, resolved to light/dark at lowering time.
/// Mirrors `AppearanceMode`.
public enum AppearanceMode: UInt8, Sendable {
    case auto
    case light
    case dark
}

/// Per-backdrop activation. `inactive` short-circuits to a solid fill;
/// `followsWindowActive` resolves from window focus at lowering time. Mirrors
/// `BackdropState`.
public enum BackdropState: UInt8, Sendable {
    case active
    case inactive
    case followsWindowActive
}

/// Per-layer foreground-vibrancy attribute. Mirrors `ForegroundVibrancyMode`.
public enum ForegroundVibrancyMode: UInt8, Sendable {
    case inherit
    case none
    case light
    case dark
}

/// AppKit `NSVisualEffectView.BlendingMode` mirror. Mirrors
/// `BackdropBlendingMode` (raw values pinned to the wire encoding).
public enum BackdropBlendingMode: UInt8, Sendable {
    case behindWindow = 0
    case withinWindow = 1
}
