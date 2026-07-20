import NucleusRenderModel
import NucleusSkiaGraphiteBridge
@testable import NucleusRenderer
import Testing

@Suite struct PaintDamageTests {
    @Test func rasterDamageRoundsOutwardAndClipsToTheBacking() {
        let damage = TextureProducer.rasterDamage(
            Rect(x: 1.25, y: -2, w: 3.5, h: 4.5),
            scaleX: 2,
            scaleY: 2,
            width: 16,
            height: 8)

        #expect(damage == PlanRect(x: 2, y: 0, w: 8, h: 5))
        #expect(TextureProducer.rasterDamage(
            Rect(x: 0, y: 0, w: 8, h: 4),
            scaleX: 2,
            scaleY: 2,
            width: 16,
            height: 8) == nil)
    }

    @Test func localizedRepaintPreservesPixelsOutsideTheDamageClip() {
        let width: Int32 = 8
        let height: Int32 = 4
        let previous = nucleus.skia.makeRasterSurface(width, height)
        let previousCanvas = previous.getCanvas()
        var red = nucleus.skia.Color()
        red.r = 1
        red.a = 1
        previousCanvas.clear(red)
        let previousImage = previous.snapshotImage()

        let next = nucleus.skia.makeRasterSurface(width, height)
        let localized = TextureProducer.repaint(
            canvas: next.getCanvas(),
            previousImage: previousImage,
            damage: PlanRect(x: 2, y: 0, w: 2, h: 4),
            width: width,
            height: height
        ) { canvas in
            var blue = nucleus.skia.Color()
            blue.b = 1
            blue.a = 1
            var paint = nucleus.skia.Paint()
            paint.color = blue
            paint.blend = .src
            canvas.drawRect(
                nucleus.skia.RectF(
                    x: 0,
                    y: 0,
                    width: Float(width),
                    height: Float(height)),
                paint)
        }

        var pixels = [UInt8](
            repeating: 0,
            count: Int(width * height) * 4)
        let read = pixels.withUnsafeMutableBufferPointer {
            next.readPixelsRGBA(
                $0.baseAddress,
                $0.count,
                width * 4)
        }
        #expect(localized)
        #expect(read)
        #expect(pixel(pixels, x: 0, y: 1, width: Int(width)) == (255, 0, 0, 255))
        #expect(pixel(pixels, x: 2, y: 1, width: Int(width)) == (0, 0, 255, 255))
        #expect(pixel(pixels, x: 6, y: 1, width: Int(width)) == (255, 0, 0, 255))
    }

    @Test func presentationProjectsLocalPaintDamageThroughPlacementAndScale() throws {
        var tree = LayerTree()
        var layer = Layer(id: 7, kind: .container)
        layer.model.properties.position = Point2D(x: 10, y: 20)
        layer.model.properties.anchorPoint = Point2D(x: 0, y: 0)
        layer.model.properties.bounds = Bounds(w: 100, h: 80)
        layer.model.content = .paint(PaintContentHandle(raw: 9))
        layer.presentation.content = .paint(PaintContentHandle(raw: 9))
        layer.damage.markContent(Rect(x: 5, y: 6, w: 10, h: 12))
        tree.insertLayer(layer)
        tree.contextRoots[compositorContextId] = [7]
        let target = RenderTarget(
            outputId: 1,
            logicalRect: LogicalRect(
                x: 0,
                y: 0,
                width: 200,
                height: 200),
            pixelSize: PixelSize(width: 400, height: 400),
            scale: 1,
            fractionalScale: 2,
            overlayUsableArea: UsableArea())

        let plan = PresentationWalk.buildFramePlan(
            tree: tree,
            target: target,
            frame: FrameInfo(outputId: 1))
        let snapshot = try #require(plan.layerSnapshots[7])
        let quad = try #require(plan.ops.compactMap {
            if case .textureQuad(let quad) = $0 {
                return quad
            }
            return nil
        }.first)

        #expect(snapshot.localizedContentDamage == PhysicalRect(
            x: 30,
            y: 52,
            width: 20,
            height: 24))
        #expect(quad.localPaintDamage == Rect(
            x: 5,
            y: 6,
            w: 10,
            h: 12))
    }

    private func pixel(
        _ pixels: [UInt8],
        x: Int,
        y: Int,
        width: Int
    ) -> (UInt8, UInt8, UInt8, UInt8) {
        let index = (y * width + x) * 4
        return (
            pixels[index],
            pixels[index + 1],
            pixels[index + 2],
            pixels[index + 3])
    }
}
