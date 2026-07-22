import Testing
@testable import NucleusRenderer
import NucleusRenderModel

// RenderTarget assembly. Asserts the derivation mirrors the Zig
// renderTargetForOutput + fullUsableArea — field passthrough, the f32 scale
// narrowing, and the ceil/clamp full-output usable area across integer,
// fractional, and degenerate extents. Hardware-independent.
@Suite struct RenderTargetAssemblyTests {
    @Test func integerExtentHidpi() {
        // fields pass through, usable area exact.
        let hidpi = RenderTargetAssembly.make(OutputTargetMetadata(
            outputId: 7,
            logicalRect: LogicalRect(x: 0, y: 0, width: 1920, height: 1080),
            pixelSize: PixelSize(width: 3840, height: 2160),
            fractionalScale: 2.0))
        #expect(hidpi.outputId == 7, "hidpi-output-id")
        #expect(hidpi.logicalRect == LogicalRect(x: 0, y: 0, width: 1920, height: 1080), "hidpi-logical")
        #expect(hidpi.pixelSize == PixelSize(width: 3840, height: 2160), "hidpi-pixel")
        #expect(hidpi.fractionalScale == 2.0, "hidpi-fractional")
        #expect(hidpi.scale == 2.0, "hidpi-scale-narrowed")
        #expect(hidpi.overlayUsableArea == UsableArea(x: 0, y: 0, w: 1920, h: 1080), "hidpi-usable-exact")
    }

    @Test func fractionalScaleAndExtent() {
        // scale narrows, usable area rounds UP each axis.
        let fractional = RenderTargetAssembly.make(OutputTargetMetadata(
            outputId: 2,
            logicalRect: LogicalRect(x: 100, y: 50, width: 1706.6, height: 960.4),
            pixelSize: PixelSize(width: 2560, height: 1440),
            fractionalScale: 1.5))
        #expect(fractional.scale == Float(1.5), "fractional-scale")
        #expect(fractional.logicalRect.x == 100 && fractional.logicalRect.y == 50, "fractional-origin-preserved")
        #expect(fractional.overlayUsableArea == UsableArea(x: 0, y: 0, w: 1707, h: 961), "fractional-usable-ceil")
    }

    @Test func degenerateExtentClamps() {
        // degenerate/zero extent clamps to a 1px minimum each axis.
        let tiny = RenderTargetAssembly.make(OutputTargetMetadata(
            outputId: 1,
            logicalRect: LogicalRect(x: 0, y: 0, width: 0.2, height: 0),
            pixelSize: PixelSize(width: 1, height: 1),
            fractionalScale: 1.0))
        #expect(tiny.scale == 1.0, "tiny-scale")
        #expect(tiny.overlayUsableArea == UsableArea(x: 0, y: 0, w: 1, h: 1), "tiny-usable-clamped")
    }

    @Test func integerExtentNotInflated() {
        let exact = RenderTargetAssembly.fullUsableArea(
            LogicalRect(x: 0, y: 0, width: 1280, height: 800))
        #expect(exact == UsableArea(x: 0, y: 0, w: 1280, h: 800), "exact-no-inflate")
    }
}
