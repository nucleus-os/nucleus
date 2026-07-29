import NucleusSkiaGraphiteBridge
import NucleusRenderModel
import NucleusTypes
import Testing
@testable import NucleusRenderer

@Test
func rendererTreatsTextAsAnOptionalInstalledCapability() {
    #expect(!nucleus.skia.hasTextLayoutBorrow())
    let surface = unsafe nucleus.skia.makeRasterSurface(2, 2)
    #expect(unsafe surface.isValid())
    let canvas = unsafe surface.getCanvas()
    let background = nucleus.skia.Color(
        r: 0.25, g: 0.5, b: 0.75, a: 1)
    unsafe canvas.clear(background)

    let command = PaintCommand(
        kind: .textLayout,
        x: 0, y: 0, w: 2, h: 2,
        color: Color(r: 1, g: 1, b: 1, a: 1),
        textLayoutHandle: 1)
    unsafe PaintRasterizer.draw(
        commands: [command],
        payload: [],
        onto: canvas,
        scaleX: 1,
        scaleY: 1,
        resolveImage: { _ in nil },
        resolveEffect: { _ in nil })

    var pixels = [UInt8](repeating: 0, count: 16)
    let copied = pixels.withUnsafeMutableBufferPointer {
        unsafe surface.readPixelsRGBA(
            $0.baseAddress, $0.count, 8)
    }
    #expect(copied)
    #expect(pixels == [
        64, 128, 191, 255, 64, 128, 191, 255,
        64, 128, 191, 255, 64, 128, 191, 255,
    ])
}
