internal import struct NucleusTypes.Rect

//
// Mirrors `DisplayServer.renderTargetForOutput` + `fullUsableArea`: derive the
// presentation `RenderTarget` the FramePlan walk is parameterized by from a
// single output's authoritative metadata (logical rect, pixel size, fractional
// scale). The per-output metadata is Swift-owned; `NucleusCompositorServer.Display`
// supplies it from the Swift display layout. This derivation is proven in isolation.

/// One output's authoritative composition metadata — the Swift-owned per-display
/// state the cutover sources from `NucleusCompositorServer.Display`. Mirrors the fields
/// `renderTargetForOutput` reads off a `Display` (`id`, `logical_rect`,
/// `pixel_size`, `fractional_scale`).
struct OutputTargetMetadata {
    var outputId: DisplayID
    var logicalRect: LogicalRect
    var pixelSize: PixelSize
    var fractionalScale: Double
}

enum RenderTargetAssembly {
    /// Assemble the per-output `RenderTarget`. `scale` is the fractional scale
    /// narrowed to f32 (mirrors `@floatCast(output.fractional_scale)`); the
    /// overlay usable area spans the full output (dock/overlay insets are applied
    /// downstream). Mirrors `renderTargetForOutput`.
    static func make(_ output: OutputTargetMetadata) -> RenderTarget {
        RenderTarget(
            outputId: output.outputId,
            logicalRect: output.logicalRect,
            pixelSize: output.pixelSize,
            scale: Float(output.fractionalScale),
            fractionalScale: output.fractionalScale,
            overlayUsableArea: fullUsableArea(output.logicalRect))
    }

    /// The full-output usable area: the logical extent rounded up, clamped to a
    /// minimum of 1px. Mirrors `fullUsableArea`
    /// (`@intFromFloat(@max(1.0, @ceil(extent)))`).
    static func fullUsableArea(_ logicalRect: LogicalRect) -> UsableArea {
        let w = Int32(max(1.0, logicalRect.width.rounded(.up)))
        let h = Int32(max(1.0, logicalRect.height.rounded(.up)))
        return UsableArea(x: 0, y: 0, w: w, h: h)
    }
}
