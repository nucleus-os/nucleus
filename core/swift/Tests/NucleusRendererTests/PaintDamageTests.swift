import NucleusRenderModel
import NucleusSkiaGraphiteBridge
import Testing

@testable import NucleusRenderer

@Suite struct PaintDamageTests {
    @Test func rasterDamageRoundsOutwardAndClipsToTheBacking() {
        let damage = TextureProducer.rasterDamage(
            RenderRect(x: 1.25, y: -2, w: 3.5, h: 4.5),
            scaleX: 2,
            scaleY: 2,
            width: 16,
            height: 8)

        #expect(damage == PlanRect(x: 2, y: 0, w: 8, h: 5))
        #expect(
            TextureProducer.rasterDamage(
                RenderRect(x: 0, y: 0, w: 8, h: 4),
                scaleX: 2,
                scaleY: 2,
                width: 16,
                height: 8) == nil)
    }

    @Test func localizedRepaintPreservesPixelsOutsideTheDamageClip() {
        let width: Int32 = 8
        let height: Int32 = 4
        let previous = unsafe nucleus.skia.makeRasterSurface(width, height)
        let previousCanvas = unsafe previous.getCanvas()
        var red = nucleus.skia.Color()
        red.r = 1
        red.a = 1
        unsafe previousCanvas.clear(red)
        let previousImage = unsafe previous.snapshotImage()

        let next = unsafe nucleus.skia.makeRasterSurface(width, height)
        let localized = unsafe TextureProducer.repaint(
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
            unsafe canvas.drawRect(
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
        var pixelSpan = pixels.mutableSpan
        let read = unsafe next.readPixelsRGBA(&pixelSpan, width * 4)
        #expect(localized)
        #expect(read)
        #expect(pixel(pixels, x: 0, y: 1, width: Int(width)) == (255, 0, 0, 255))
        #expect(pixel(pixels, x: 2, y: 1, width: Int(width)) == (0, 0, 255, 255))
        #expect(pixel(pixels, x: 6, y: 1, width: Int(width)) == (255, 0, 0, 255))
    }

    @Test func presentationProjectsLocalPaintDamageThroughPlacementAndScale() throws {
        var tree = LayerTree()
        var transaction = Transaction(contextId: compositorContextId)
        transaction.created = [
            LayerCreated(
                nodeId: 7,
                kind: .container,
                position: Point2D(x: 10, y: 20),
                anchorPoint: Point2D(x: 0, y: 0),
                bounds: Bounds(w: 100, h: 80))
        ]
        transaction.inserted = [
            LayerInserted(nodeId: 7, parentId: 0, index: 0)
        ]
        var content = LayerPropertyUpdate(nodeId: 7)
        content.content = .paint(PaintContentHandle(raw: 9))
        content.contentDamage = RenderRect(x: 5, y: 6, w: 10, h: 12)
        transaction.propertyUpdates = [content]
        guard
            case .success = TransactionApplier.apply(
                transaction,
                to: &tree)
        else {
            Issue.record("paint-damage tree setup was rejected")
            return
        }
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
        let quad = try #require(
            plan.ops.compactMap {
                if case .textureQuad(let quad) = $0 {
                    return quad
                }
                return nil
            }.first)

        #expect(
            snapshot.localizedContentDamage
                == PhysicalRect(
                    x: 30,
                    y: 52,
                    width: 20,
                    height: 24))
        #expect(
            quad.localPaintDamage
                == RenderRect(
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
            pixels[index + 3]
        )
    }
}
