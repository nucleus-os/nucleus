public import NucleusTypes

/// Composition-time rounded-rect clip applied to a layer's subtree.
/// Corresponds to the rect+per-corner-radii+local-transform shape used by Skia
/// `SkRRect` clips. The 3×3 transform applies to the clip path before it
/// is intersected with the layer's content; identity is the common case.
///
/// This is the generated wire type itself (`rect`/`radii` are `SIMD4<Float>`,
/// `antiAlias` is a `Bool`; the 3×3 `xform**` run stays scalar). The
/// named-field initializer — which restores the identity-transform defaults the
/// memberwise init zeroes — and the `GeometryRect` convenience are the
/// relocated conveniences.
public typealias ClipOp = NucleusTypes.ClipOp

extension NucleusTypes.ClipOp {
    public init(
        rectX: Float, rectY: Float, rectW: Float, rectH: Float,
        radiusTL: Float = 0, radiusTR: Float = 0, radiusBR: Float = 0, radiusBL: Float = 0,
        antiAlias: Bool = true,
        xform00: Float = 1, xform01: Float = 0, xform02: Float = 0,
        xform10: Float = 0, xform11: Float = 1, xform12: Float = 0,
        xform20: Float = 0, xform21: Float = 0, xform22: Float = 1
    ) {
        self.init(
            rect: SIMD4<Float>(rectX, rectY, rectW, rectH),
            radii: SIMD4<Float>(radiusTL, radiusTR, radiusBR, radiusBL),
            antiAlias: antiAlias,
            xform00: xform00, xform01: xform01, xform02: xform02,
            xform10: xform10, xform11: xform11, xform12: xform12,
            xform20: xform20, xform21: xform21, xform22: xform22
        )
    }

    /// Convenience constructor for the common case: axis-aligned rounded
    /// rect with uniform corner radius and identity transform.
    public init(rect: GeometryRect, cornerRadius: Float, antiAlias: Bool = true) {
        self.init(
            rectX: Float(rect.x), rectY: Float(rect.y),
            rectW: Float(rect.width), rectH: Float(rect.height),
            radiusTL: cornerRadius, radiusTR: cornerRadius,
            radiusBR: cornerRadius, radiusBL: cornerRadius,
            antiAlias: antiAlias
        )
    }
}
