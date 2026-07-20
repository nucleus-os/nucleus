/// Drop shadow on a `Layer`. It groups the supported `CALayer` shadow properties
/// (`shadowColor`, `shadowOpacity`, `shadowOffset`, `shadowRadius`) as a
/// single composite value carried over the wire — the high-level
/// `Layer.shadowColor` etc. accessors read and write the composite.
///
/// `opacity` and `color.a` are multiplicatively combined when rendered
/// (the same multiplication used by `CALayer.shadowOpacity` and
/// `shadowColor`). Default `opacity` is 0 — i.e. `.none` produces no
/// rendered shadow.
public struct Shadow: Sendable, Equatable {
    /// Horizontal offset in points. Positive = right.
    public var offsetX: Double
    /// Vertical offset in points. Positive = down (matches Skia/iOS;
    /// flipped from Cocoa where positive = up).
    public var offsetY: Double
    /// Gaussian blur radius in points. The renderer treats this as a CSS
    /// `box-shadow`-style blur radius (sigma = `blurRadius / 2`).
    public var blurRadius: Double
    /// Per-shadow shape override. CALayer's `shadowPath` equivalent for
    /// the common rounded-rect case: when > 0, the shadow is shaped as a
    /// rounded rect with this corner radius regardless of the layer's own
    /// `corner_radii`. Useful when the visible rounded shape lives on a
    /// child layer (e.g. a backdrop) but the shadow is attached to the
    /// parent container, which has no corner radii of its own. When 0,
    /// the shadow shape falls back to the layer's `visual_style`
    /// corner radii.
    public var cornerRadius: Double
    /// Multiplicative shadow alpha applied on top of `color.a`.
    public var opacity: Double
    /// Shadow color. Alpha contributes to the final visibility alongside
    /// `opacity`.
    public var color: Color

    public init(
        offsetX: Double = 0,
        offsetY: Double = 3,
        blurRadius: Double = 3,
        cornerRadius: Double = 0,
        opacity: Double = 0,
        color: Color = Color(0, 0, 0, 1)
    ) {
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.blurRadius = blurRadius
        self.cornerRadius = cornerRadius
        self.opacity = opacity
        self.color = color
    }

    /// Default-initialized shadow with `opacity = 0` — no rendered shadow.
    /// Matches `CALayer`'s default shadow state. Used as the encoder
    /// "absent" sentinel for the sparse `shadow` property bit.
    public static let none = Shadow()
}
