// Retained-layer visual-style and backdrop value types.

package import NucleusTypes

// MARK: - Visual style

/// Border edges retain the same width and normalized color authored by the
/// producer, so the shared value remains canonical in renderer state.
package typealias BorderEdge = NucleusTypes.BorderEdge

/// A layer drop shadow. Mirrors `RenderLayer.LayerShadow`, including the
/// per-shadow `cornerRadius` override and the `outerExtent` halo computation.
package struct LayerShadow: Equatable, Sendable {
    package var offsetX: Float = 0
    package var offsetY: Float = 0
    package var blurRadius: Float = 0
    package var spreadRadius: Float = 0
    /// Per-shadow rounded-rect corner override (CALayer `shadowPath` for the
    /// common case); when > 0 the rasterizer uses this instead of the layer's
    /// `cornerRadii`.
    package var cornerRadius: Float = 0
    package var color: NucleusTypes.Color = NucleusTypes.Color()

    package init(
        offsetX: Float = 0,
        offsetY: Float = 0,
        blurRadius: Float = 0,
        spreadRadius: Float = 0,
        cornerRadius: Float = 0,
        color: NucleusTypes.Color = NucleusTypes.Color()
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
    package func outerExtent() -> (x: Float, y: Float) {
        guard color.a > 0 else { return (0, 0) }
        let sigma = blurRadius / 2.0
        return (
            x: (3.0 * sigma + abs(offsetX)).rounded(.up),
            y: (3.0 * sigma + abs(offsetY)).rounded(.up)
        )
    }

    package static func == (lhs: LayerShadow, rhs: LayerShadow) -> Bool {
        lhs.offsetX == rhs.offsetX && lhs.offsetY == rhs.offsetY && lhs.blurRadius == rhs.blurRadius
            && lhs.spreadRadius == rhs.spreadRadius && lhs.cornerRadius == rhs.cornerRadius
            && lhs.color == rhs.color
    }
}

/// A layer's rasterizable visual style: background fill, four border edges, four
/// corner radii, and an optional shadow. Mirrors `RenderLayer.VisualStyle`.
package struct VisualStyle: Equatable, Sendable {
    package var backgroundColor: NucleusTypes.Color = NucleusTypes.Color()
    package var borderTop = BorderEdge()
    package var borderRight = BorderEdge()
    package var borderBottom = BorderEdge()
    package var borderLeft = BorderEdge()
    /// Top-left, top-right, bottom-right, bottom-left.
    package var cornerRadii: (Float, Float, Float, Float) = (0, 0, 0, 0)
    package var shadow: LayerShadow?

    package init(
        backgroundColor: NucleusTypes.Color = NucleusTypes.Color(),
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

    package static func == (lhs: VisualStyle, rhs: VisualStyle) -> Bool {
        lhs.backgroundColor == rhs.backgroundColor && lhs.borderTop == rhs.borderTop
            && lhs.borderRight == rhs.borderRight && lhs.borderBottom == rhs.borderBottom
            && lhs.borderLeft == rhs.borderLeft && lhs.cornerRadii == rhs.cornerRadii
            && lhs.shadow == rhs.shadow
    }
}

/// Sparse update for the whole `VisualStyle`. Mirrors `VisualStyleDelta`.
package enum VisualStyleDelta: Equatable, Sendable {
    case unchanged
    case set(VisualStyle)
    case clear
}

/// Independent update for just the shadow component, applied after a
/// `VisualStyleDelta` so one update can replace the style then patch the shadow.
/// Mirrors `ShadowDelta`.
package enum ShadowDelta: Equatable, Sendable {
    case unchanged
    case set(LayerShadow)
    case clear
}

// MARK: - Backdrop vocabulary

/// macOS-shaped material identity (the `NSVisualEffectView.Material` mirror plus
/// the Nucleus `default`/`shellOverlay` rows). Raw values are dense catalog and
/// visual-signature indices.
package enum BackdropMaterialRole: UInt8, Sendable, CaseIterable {
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

package typealias BackdropAppearance = NucleusTypes.BackdropAppearance
package typealias BackdropState = NucleusTypes.BackdropState
package typealias ForegroundVibrancyMode = NucleusTypes.ForegroundVibrancyMode
package typealias BackdropBlendingMode = NucleusTypes.BackdropBlendingMode
