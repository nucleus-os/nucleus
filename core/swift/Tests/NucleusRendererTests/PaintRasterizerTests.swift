import Testing
@testable import NucleusRenderer
import NucleusSkiaGraphiteBridge
import NucleusRenderModel
import NucleusTypes

/// Pixel coverage for the decode half of the paint pipeline.
///
/// The encoder (`PaintPayload.append`, driven by `GraphicsContext`) and the
/// Skia façade are each tested on their own. This is the seam between them —
/// payload decode, point scaling, and shading construction — where the two
/// sides can disagree without anything crashing: a transposed index yields a
/// plausible wrong picture, and a producer test that only checks for a non-nil
/// texture handle would still pass.
///
/// Runs on a CPU raster surface, so no GPU or Graphite recorder is involved.
@Suite struct PaintRasterizerTests {
    // MARK: - Harness

    private func render(
        width: Int32, height: Int32,
        commands: [PaintDrawCommand],
        payload: [UInt8],
        scaleX: Float = 1, scaleY: Float = 1,
        resolveImage: @escaping (UInt64) -> nucleus.skia.Image? = { _ in nil },
        resolveEffect: @escaping (UInt64) -> nucleus.skia.RuntimeEffect? = { _ in nil }
    ) -> [UInt8] {
        let surface = nucleus.skia.makeRasterSurface(width, height)
        guard surface.isValid() else { return [] }
        let canvas = surface.getCanvas()
        var clear = nucleus.skia.Color()
        clear.r = 0; clear.g = 0; clear.b = 0; clear.a = 1
        canvas.clear(clear)

        PaintRasterizer.draw(
            commands: commands, payload: payload, onto: canvas,
            scaleX: scaleX, scaleY: scaleY,
            resolveImage: resolveImage, resolveEffect: resolveEffect)

        var pixels = [UInt8](repeating: 0, count: Int(width * height) * 4)
        let ok = pixels.withUnsafeMutableBufferPointer { buf in
            surface.readPixelsRGBA(buf.baseAddress, buf.count, Int32(width * 4))
        }
        return ok ? pixels : []
    }

    private func pixel(
        _ pixels: [UInt8], _ x: Int, _ y: Int, width: Int
    ) -> (UInt8, UInt8, UInt8, UInt8) {
        let i = (y * width + x) * 4
        return (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
    }

    /// Encode one path command the way `GraphicsContext` does.
    private func pathCommand(
        verbs: [PaintPathVerb],
        points: [Float],
        into payload: inout [UInt8],
        stroke: Bool = false,
        strokeWidth: Float = 0,
        shading: PaintDrawShading = .color,
        scalars: [Float] = [],
        colors: [Color] = [],
        effectHandle: UInt64 = 0,
        color: Float4 = (1, 1, 1, 1),
        transform: PaintDrawTransform? = nil
    ) -> PaintDrawCommand {
        let slice = PaintPayload.append(
            to: &payload, verbs: verbs, points: points, scalars: scalars, colors: colors)
        return PaintDrawCommand(
            kind: .path, x: 0, y: 0, w: 0, h: 0,
            strokeWidth: strokeWidth, color: color,
            effectHandle: effectHandle,
            payloadOffset: slice.offset, payloadLength: slice.length,
            stroke: stroke, antialias: false,
            transform: transform, shading: shading)
    }

    private func rectPath(_ x: Float, _ y: Float, _ w: Float, _ h: Float)
        -> ([PaintPathVerb], [Float]) {
        ([.move, .line, .line, .line, .close],
         [x, y, x + w, y, x + w, y + h, x, y + h])
    }

    // MARK: - Geometry

    @Test func imageCommandDrawsResolvedPixels() {
        let imageSurface = nucleus.skia.makeRasterSurface(2, 2)
        var red = nucleus.skia.Color()
        red.r = 1
        red.a = 1
        imageSurface.getCanvas().clear(red)
        let image = imageSurface.snapshotImage()
        let command = PaintDrawCommand(
            kind: .image, x: 0, y: 0, w: 20, h: 20,
            imageHandle: 7, antialias: false)

        let pixels = render(
            width: 20, height: 20, commands: [command], payload: [],
            resolveImage: { $0 == 7 ? image : nil })

        #expect(!pixels.isEmpty)
        let center = pixel(pixels, 10, 10, width: 20)
        #expect(center.0 > 200 && center.1 == 0 && center.2 == 0)
    }

    @Test func aFilledPathPaintsWhereItWasAuthored() {
        var payload: [UInt8] = []
        let (verbs, points) = rectPath(10, 10, 20, 20)
        let command = pathCommand(verbs: verbs, points: points, into: &payload)

        let pixels = render(width: 40, height: 40, commands: [command], payload: payload)
        #expect(!pixels.isEmpty)
        #expect(pixel(pixels, 20, 20, width: 40).0 > 200, "inside is painted")
        #expect(pixel(pixels, 2, 2, width: 40).0 == 0, "outside is not")
    }

    /// Points are authored in layer-local units and scaled into raster space.
    /// A geometry that lands correctly at 1x but not at 2x means the scale is
    /// being applied to the wrong floats.
    @Test func geometryScalesIntoRasterSpace() {
        var payload: [UInt8] = []
        let (verbs, points) = rectPath(5, 5, 10, 10)
        let command = pathCommand(verbs: verbs, points: points, into: &payload)

        let pixels = render(
            width: 40, height: 40, commands: [command], payload: payload,
            scaleX: 2, scaleY: 2)
        #expect(!pixels.isEmpty)
        // Authored 5..15 → raster 10..30.
        #expect(pixel(pixels, 20, 20, width: 40).0 > 200, "scaled interior is painted")
        #expect(pixel(pixels, 12, 12, width: 40).0 > 200, "scaled near-corner is painted")
        #expect(pixel(pixels, 6, 6, width: 40).0 == 0, "unscaled position is not painted")
    }

    /// An arc verb packs (origin, size, startAngle, sweepAngle). The first four
    /// floats scale; the two angles must not. Scaling the angles would rotate
    /// and resize the sweep — which reads as "the ring is wrong" rather than as
    /// a failure.
    @Test func arcAnglesAreNotScaledWithGeometry() {
        // A full circle: sweeping 360° is scale-invariant in *shape*, so if the
        // angles were scaled the sweep would no longer close the circle.
        var payload: [UInt8] = []
        // move (2 floats) + arc (6: oval origin, oval size, start, sweep).
        let command = pathCommand(
            verbs: [.move, .arc],
            points: [10, 10, /* oval */ 10, 10, 20, 20, /* angles */ 0, 360],
            into: &payload)

        let pixels = render(
            width: 80, height: 80, commands: [command], payload: payload,
            scaleX: 2, scaleY: 2)
        #expect(!pixels.isEmpty)
        // Authored oval 10..30 → raster 20..60; its centre is painted.
        #expect(pixel(pixels, 40, 40, width: 80).0 > 200, "the full circle is filled")
        #expect(pixel(pixels, 4, 4, width: 80).0 == 0, "nothing outside the oval")
    }

    /// Regression: Skia's `arcTo` emits nothing at a full sweep, so a
    /// 360-degree arc silently disappeared. That is not an edge case — it is
    /// `Path.addEllipse` (every dot indicator) and a progress ring at 100%.
    /// The facade now converts a full sweep to an oval.
    @Test func aFullSweepArcRendersRatherThanVanishing() {
        for sweep in [Float(360), -360, 540] {
            var payload: [UInt8] = []
            let command = pathCommand(
                verbs: [.arc], points: [10, 10, 20, 20, 0, sweep], into: &payload)
            let pixels = render(
                width: 40, height: 40, commands: [command], payload: payload)
            #expect(!pixels.isEmpty)
            #expect(
                pixel(pixels, 20, 20, width: 40).0 > 200,
                "a \(sweep)-degree sweep must render")
        }
    }

    /// A partial sweep still goes through `arcTo` and must not be filled like a
    /// closed shape.
    @Test func aPartialSweepArcIsNotAFullOval() {
        var payload: [UInt8] = []
        let command = pathCommand(
            verbs: [.arc], points: [10, 10, 20, 20, 0, 180],
            into: &payload, stroke: true, strokeWidth: 2)
        let pixels = render(width: 40, height: 40, commands: [command], payload: payload)
        #expect(!pixels.isEmpty)
        #expect(pixel(pixels, 20, 14, width: 40).0 == 0, "the unswept half stays clear")
    }

    @Test func aStrokedPathLeavesItsInteriorUnpainted() {
        var payload: [UInt8] = []
        let (verbs, points) = rectPath(10, 10, 20, 20)
        let command = pathCommand(
            verbs: verbs, points: points, into: &payload,
            stroke: true, strokeWidth: 2)

        let pixels = render(width: 40, height: 40, commands: [command], payload: payload)
        #expect(!pixels.isEmpty)
        #expect(pixel(pixels, 20, 10, width: 40).0 > 200, "the edge is stroked")
        #expect(pixel(pixels, 20, 20, width: 40).0 == 0, "the interior stays clear")
    }

    @Test func aCommandTransformAndBackingScaleApplyExactlyOnce() {
        var payload: [UInt8] = []
        let (verbs, points) = rectPath(0, 0, 10, 10)
        let command = pathCommand(
            verbs: verbs, points: points, into: &payload,
            transform: PaintDrawTransform(
                a: 2, b: 0, c: 0, d: 1, tx: 5, ty: 3))

        let pixels = render(
            width: 64, height: 32, commands: [command], payload: payload,
            scaleX: 2, scaleY: 2)
        // local 0...10 -> command x 5...25 -> backing x 10...50.
        #expect(pixel(pixels, 12, 8, width: 64).0 > 200)
        #expect(pixel(pixels, 48, 20, width: 64).0 > 200)
        #expect(pixel(pixels, 6, 8, width: 64).0 == 0)
        #expect(pixel(pixels, 54, 8, width: 64).0 == 0)
    }

    @Test func anisotropicScaleTransformsAStrokeAsAnOutline() {
        var payload: [UInt8] = []
        let command = pathCommand(
            verbs: [.move, .line],
            points: [10, 5, 10, 25],
            into: &payload,
            stroke: true, strokeWidth: 4,
            transform: PaintDrawTransform(
                a: 3, b: 0, c: 0, d: 1, tx: 0, ty: 0))

        let pixels = render(width: 64, height: 32, commands: [command], payload: payload)
        #expect(pixel(pixels, 25, 15, width: 64).0 > 200, "x scale widens the outline")
        #expect(pixel(pixels, 22, 15, width: 64).0 == 0, "outline has a finite edge")
        #expect(pixel(pixels, 30, 3, width: 64).0 == 0, "y width is not also tripled")
    }

    @Test func reflectionMapsGeometryWithoutStandardizingItAway() {
        var payload: [UInt8] = []
        let (verbs, points) = rectPath(5, 5, 10, 10)
        let command = pathCommand(
            verbs: verbs, points: points, into: &payload,
            transform: PaintDrawTransform(
                a: -1, b: 0, c: 0, d: 1, tx: 30, ty: 0))

        let pixels = render(width: 40, height: 24, commands: [command], payload: payload)
        #expect(pixel(pixels, 16, 10, width: 40).0 > 200)
        #expect(pixel(pixels, 24, 10, width: 40).0 > 200)
        #expect(pixel(pixels, 8, 10, width: 40).0 == 0)
    }

    @Test func aCollapsedTransformProducesNoVisibleStroke() {
        var payload: [UInt8] = []
        let command = pathCommand(
            verbs: [.move, .line],
            points: [5, 5, 25, 25],
            into: &payload,
            stroke: true, strokeWidth: 10,
            transform: PaintDrawTransform(
                a: 0, b: 0, c: 0, d: 0, tx: 20, ty: 20))

        let pixels = render(width: 40, height: 40, commands: [command], payload: payload)
        #expect(!pixels.isEmpty)
        for y in 0..<40 {
            for x in 0..<40 {
                #expect(pixel(pixels, x, y, width: 40).0 == 0)
            }
        }
    }

    // MARK: - Shading

    /// Gradient parameters are split across payload regions: geometry and stops
    /// in the scalar region, colors in the color region. If the decoder read
    /// the stop offset wrong, the ramp would run the wrong way or not at all.
    @Test func aLinearGradientRampsAlongItsAuthoredAxis() {
        var payload: [UInt8] = []
        let (verbs, points) = rectPath(0, 0, 40, 40)
        let command = pathCommand(
            verbs: verbs, points: points, into: &payload,
            shading: .linearGradient,
            scalars: [0, 0, 40, 0, 0, 1],  // from (0,0) to (40,0), stops at 0 and 1
            colors: [Color(r: 0, g: 0, b: 0, a: 1), Color(r: 1, g: 1, b: 1, a: 1)])

        let pixels = render(width: 40, height: 40, commands: [command], payload: payload)
        #expect(!pixels.isEmpty)
        let left = pixel(pixels, 1, 20, width: 40).0
        let right = pixel(pixels, 38, 20, width: 40).0
        #expect(right > left, "the ramp runs along the authored axis")
        #expect(right > 200 && left < 60, "the ramp spans its full range")
    }

    /// Gradient geometry lives in the same authored space as the path, so it
    /// has to scale with it. A gradient that did not scale would compress into
    /// a corner of a scaled shape.
    @Test func gradientGeometryScalesWithTheGeometry() {
        var payload: [UInt8] = []
        let (verbs, points) = rectPath(0, 0, 20, 20)
        let command = pathCommand(
            verbs: verbs, points: points, into: &payload,
            shading: .linearGradient,
            scalars: [0, 0, 20, 0, 0, 1],
            colors: [Color(r: 0, g: 0, b: 0, a: 1), Color(r: 1, g: 1, b: 1, a: 1)])

        let pixels = render(
            width: 40, height: 40, commands: [command], payload: payload,
            scaleX: 2, scaleY: 2)
        #expect(!pixels.isEmpty)
        // The ramp must still span the full scaled width, not stop halfway.
        #expect(pixel(pixels, 38, 20, width: 40).0 > 200, "the ramp reaches the far edge")
    }

    @Test func radialGradientBecomesAnEllipseUnderAnisotropicTransform() {
        var payload: [UInt8] = []
        let command = pathCommand(
            verbs: [.move, .arc, .close],
            points: [20, 10, 0, 0, 20, 20, 0, 360],
            into: &payload,
            shading: .radialGradient,
            scalars: [10, 10, 10, 0, 1],
            colors: [
                Color(r: 1, g: 1, b: 1, a: 1),
                Color(r: 0, g: 0, b: 0, a: 1),
            ],
            transform: PaintDrawTransform(
                a: 2, b: 0, c: 0, d: 1, tx: 0, ty: 0))

        let pixels = render(width: 40, height: 20, commands: [command], payload: payload)
        #expect(pixel(pixels, 20, 10, width: 40).0 > 220, "center stays bright")
        #expect(pixel(pixels, 36, 10, width: 40).0 < 80, "x radius becomes 20")
        #expect(pixel(pixels, 20, 18, width: 40).0 < 80, "y radius remains 10")
    }

    @Test func aRuntimeEffectShadesThePath() {
        let effect = nucleus.skia.makeRuntimeEffect(
            "half4 main(float2 p) { return half4(1, 0, 0, 1); }")
        #expect(effect.isValid())

        var payload: [UInt8] = []
        let (verbs, points) = rectPath(0, 0, 20, 20)
        let command = pathCommand(
            verbs: verbs, points: points, into: &payload,
            shading: .effect, effectHandle: 7)

        let pixels = render(
            width: 20, height: 20, commands: [command], payload: payload,
            resolveEffect: { $0 == 7 ? effect : nil })
        #expect(!pixels.isEmpty)
        let p = pixel(pixels, 10, 10, width: 20)
        #expect(p.0 > 200 && p.1 < 50, "the effect painted red")
    }

    // MARK: - Clip and state

    @Test func clipPathConstrainsLaterCommands() {
        var payload: [UInt8] = []
        let (clipVerbs, clipPoints) = rectPath(0, 0, 20, 40)
        let clipSlice = PaintPayload.append(
            to: &payload, verbs: clipVerbs, points: clipPoints)
        let clip = PaintDrawCommand(
            kind: .clipPath, x: 0, y: 0, w: 0, h: 0,
            payloadOffset: clipSlice.offset, payloadLength: clipSlice.length,
            antialias: false)

        let (fillVerbs, fillPoints) = rectPath(0, 0, 40, 40)
        let fill = pathCommand(verbs: fillVerbs, points: fillPoints, into: &payload)

        let pixels = render(
            width: 40, height: 40, commands: [clip, fill], payload: payload)
        #expect(!pixels.isEmpty)
        #expect(pixel(pixels, 10, 20, width: 40).0 > 200, "inside the clip paints")
        #expect(pixel(pixels, 30, 20, width: 40).0 == 0, "outside the clip does not")
    }

    @Test func aTransformedClipPersistsForLaterCommands() {
        var payload: [UInt8] = []
        let (clipVerbs, clipPoints) = rectPath(0, 0, 10, 40)
        let clipSlice = PaintPayload.append(
            to: &payload, verbs: clipVerbs, points: clipPoints)
        let clip = PaintDrawCommand(
            kind: .clipPath, x: 0, y: 0, w: 0, h: 0,
            payloadOffset: clipSlice.offset, payloadLength: clipSlice.length,
            antialias: false,
            transform: PaintDrawTransform(
                a: 1, b: 0, c: 0, d: 1, tx: 10, ty: 0))

        let (fillVerbs, fillPoints) = rectPath(0, 0, 40, 40)
        let fill = pathCommand(verbs: fillVerbs, points: fillPoints, into: &payload)
        let pixels = render(
            width: 40, height: 40, commands: [clip, fill], payload: payload)
        #expect(pixel(pixels, 15, 20, width: 40).0 > 200)
        #expect(pixel(pixels, 5, 20, width: 40).0 == 0)
        #expect(pixel(pixels, 25, 20, width: 40).0 == 0)
    }

    @Test func anEmptyPathProducesAnEmptyClip() {
        var payload: [UInt8] = []
        let clipSlice = PaintPayload.append(to: &payload)
        let clip = PaintDrawCommand(
            kind: .clipPath, x: 0, y: 0, w: 0, h: 0,
            payloadOffset: clipSlice.offset, payloadLength: clipSlice.length,
            antialias: false,
            transform: PaintDrawTransform(
                a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0))
        let (fillVerbs, fillPoints) = rectPath(0, 0, 40, 40)
        let fill = pathCommand(verbs: fillVerbs, points: fillPoints, into: &payload)

        let pixels = render(
            width: 40, height: 40, commands: [clip, fill], payload: payload)
        #expect(pixel(pixels, 20, 20, width: 40).0 == 0)
    }

    /// `save`/`restore` scope a clip. Without the restore the second fill would
    /// still be clipped — which is what an unbalanced stack looks like.
    @Test func restoreUndoesAClip() {
        var payload: [UInt8] = []
        let save = PaintDrawCommand(kind: .save, x: 0, y: 0, w: 0, h: 0)

        let (clipVerbs, clipPoints) = rectPath(0, 0, 20, 40)
        let clipSlice = PaintPayload.append(
            to: &payload, verbs: clipVerbs, points: clipPoints)
        let clip = PaintDrawCommand(
            kind: .clipPath, x: 0, y: 0, w: 0, h: 0,
            payloadOffset: clipSlice.offset, payloadLength: clipSlice.length,
            antialias: false)

        let restore = PaintDrawCommand(kind: .restore, x: 0, y: 0, w: 0, h: 0)
        let (fillVerbs, fillPoints) = rectPath(0, 0, 40, 40)
        let fill = pathCommand(verbs: fillVerbs, points: fillPoints, into: &payload)

        let pixels = render(
            width: 40, height: 40,
            commands: [save, clip, restore, fill], payload: payload)
        #expect(!pixels.isEmpty)
        #expect(
            pixel(pixels, 30, 20, width: 40).0 > 200,
            "after restore the clip no longer applies")
    }

    // MARK: - Malformed input

    /// A payload slice that does not decode must drop that draw, not paint
    /// arbitrary geometry from misread bytes. The surrounding commands still
    /// draw.
    @Test func anUndecodableCommandIsDroppedWithoutAffectingOthers() {
        var payload: [UInt8] = []
        let (verbs, points) = rectPath(0, 0, 40, 40)
        let good = pathCommand(verbs: verbs, points: points, into: &payload)

        // Length past the end of the blob.
        let bad = PaintDrawCommand(
            kind: .path, x: 0, y: 0, w: 0, h: 0,
            payloadOffset: 0, payloadLength: UInt32(payload.count + 64))

        let pixels = render(
            width: 40, height: 40, commands: [bad, good], payload: payload)
        #expect(!pixels.isEmpty)
        #expect(pixel(pixels, 20, 20, width: 40).0 > 200, "the valid command still drew")
    }

    @Test func aCommandWhoseVerbsOverConsumePointsIsDropped() {
        var payload: [UInt8] = []
        // Two verbs need four floats; supply two.
        let command = pathCommand(verbs: [.move, .line], points: [0, 0], into: &payload)

        let pixels = render(width: 20, height: 20, commands: [command], payload: payload)
        #expect(!pixels.isEmpty)
        #expect(pixel(pixels, 10, 10, width: 20).0 == 0, "nothing was drawn")
    }
}

/// Stroke caps and joins.
///
/// These were settable state on `GraphicsContext` that nothing encoded, so every
/// stroke painted butt-capped and miter-joined whatever the caller asked for.
/// Pixels are the only honest test: a cap is a few pixels past the end of a
/// line, and nothing short of drawing shows whether they are there.
@Suite struct StrokeCapJoinTests {
    private func render(
        _ commands: [PaintDrawCommand], payload: [UInt8], size: Int32 = 40
    ) -> [UInt8] {
        let surface = nucleus.skia.makeRasterSurface(size, size)
        guard surface.isValid() else { return [] }
        let canvas = surface.getCanvas()
        var clear = nucleus.skia.Color()
        clear.r = 0; clear.g = 0; clear.b = 0; clear.a = 1
        canvas.clear(clear)
        PaintRasterizer.draw(
            commands: commands, payload: payload, onto: canvas, scaleX: 1, scaleY: 1,
            resolveImage: { _ in nil }, resolveEffect: { _ in nil })

        var pixels = [UInt8](repeating: 0, count: Int(size * size) * 4)
        let ok = pixels.withUnsafeMutableBufferPointer {
            surface.readPixelsRGBA($0.baseAddress, $0.count, size * 4)
        }
        return ok ? pixels : []
    }

    private func red(_ pixels: [UInt8], _ x: Int, _ y: Int, size: Int = 40) -> UInt8 {
        pixels[(y * size + x) * 4]
    }

    /// A horizontal line from x=10 to x=30 at y=20, stroked 8 wide.
    private func line(
        into payload: inout [UInt8],
        cap: PaintDrawStrokeCap = .butt,
        join: PaintDrawStrokeJoin = .miter
    ) -> PaintDrawCommand {
        let slice = PaintPayload.append(
            to: &payload, verbs: [.move, .line], points: [10, 20, 30, 20],
            scalars: [], colors: [])
        return PaintDrawCommand(
            kind: .path, x: 0, y: 0, w: 0, h: 0,
            strokeWidth: 8, color: (1, 1, 1, 1),
            payloadOffset: slice.offset, payloadLength: slice.length,
            stroke: true, antialias: false,
            strokeCap: cap, strokeJoin: join)
    }

    /// The default: the stroke stops dead at the endpoint.
    @Test func aButtCapEndsAtTheEndpoint() {
        var payload: [UInt8] = []
        let pixels = render([line(into: &payload)], payload: payload)
        #expect(!pixels.isEmpty)
        #expect(red(pixels, 20, 20) > 200, "the line is drawn")
        #expect(red(pixels, 32, 20) == 0, "nothing past the endpoint")
    }

    /// A square cap extends by half the stroke width — 4px here, so x=32 is
    /// inside it and x=36 is not.
    @Test func aSquareCapExtendsPastTheEndpoint() {
        var payload: [UInt8] = []
        let pixels = render([line(into: &payload, cap: .square)], payload: payload)
        #expect(red(pixels, 32, 20) > 200, "the cap covers past the endpoint")
        #expect(red(pixels, 36, 20) == 0, "but only by half the stroke width")
    }

    /// A round cap also extends, but curves — so it covers the centre line past
    /// the endpoint while leaving the corner of that extension empty.
    @Test func aRoundCapIsRoundedRatherThanSquare() {
        var payload: [UInt8] = []
        let pixels = render([line(into: &payload, cap: .round)], payload: payload)
        #expect(red(pixels, 32, 20) > 200, "covered along the centre")
        #expect(red(pixels, 33, 17) == 0, "the corner a square cap would fill is empty")
    }

    /// The corner treatment of a bent stroke. A mitered corner comes to a point
    /// past the join; a bevelled one is cut off, so the outermost corner pixel
    /// distinguishes them.
    @Test func joinsDifferAtACorner() {
        func corner(_ join: PaintDrawStrokeJoin) -> [UInt8] {
            var payload: [UInt8] = []
            let slice = PaintPayload.append(
                to: &payload, verbs: [.move, .line, .line],
                points: [10, 30, 20, 10, 30, 30], scalars: [], colors: [])
            let command = PaintDrawCommand(
                kind: .path, x: 0, y: 0, w: 0, h: 0,
                strokeWidth: 8, color: (1, 1, 1, 1),
                payloadOffset: slice.offset, payloadLength: slice.length,
                stroke: true, antialias: false,
                strokeCap: .butt, strokeJoin: join)
            return render([command], payload: payload)
        }

        let mitered = corner(.miter)
        let bevelled = corner(.bevel)
        #expect(!mitered.isEmpty && !bevelled.isEmpty)
        // The apex sits above the join; a miter fills it and a bevel does not.
        #expect(red(mitered, 20, 6) > 200, "the miter comes to a point")
        #expect(red(bevelled, 20, 6) == 0, "the bevel is cut off")
    }
}

/// Rotated draws.
///
/// A command whose transform rotates or skews states geometry in its own space
/// and carries the matrix. Before that, the recorder folded the transform into
/// the geometry by taking an axis-aligned bounding box — so a rotated image,
/// glyph run, or background box drew upright at the wrong size, and nothing
/// indicated the rotation had been dropped.
@Suite struct RotatedDrawTests {
    private func render(_ commands: [PaintDrawCommand], size: Int32 = 40) -> [UInt8] {
        let surface = nucleus.skia.makeRasterSurface(size, size)
        guard surface.isValid() else { return [] }
        let canvas = surface.getCanvas()
        var clear = nucleus.skia.Color()
        clear.r = 0; clear.g = 0; clear.b = 0; clear.a = 1
        canvas.clear(clear)
        PaintRasterizer.draw(
            commands: commands, payload: [], onto: canvas, scaleX: 1, scaleY: 1,
            resolveImage: { _ in nil }, resolveEffect: { _ in nil })

        var pixels = [UInt8](repeating: 0, count: Int(size * size) * 4)
        let ok = pixels.withUnsafeMutableBufferPointer {
            surface.readPixelsRGBA($0.baseAddress, $0.count, size * 4)
        }
        return ok ? pixels : []
    }

    private func red(_ pixels: [UInt8], _ x: Int, _ y: Int, size: Int = 40) -> UInt8 {
        pixels[(y * size + x) * 4]
    }

    /// A 45°-rotated square about the canvas centre. Its corners land on the
    /// axes and its edges pull away from the diagonals — a diamond. An
    /// axis-aligned box cannot produce that, which is what makes this decisive.
    private func rotatedSquare() -> PaintDrawCommand {
        let angle = Double.pi / 4
        let (c, s) = (Float(cos(angle)), Float(sin(angle)))
        // Rotate about (20, 20): translate out, rotate, translate back.
        return PaintDrawCommand(
            kind: .rect, x: -10, y: -10, w: 20, h: 20,
            color: (1, 1, 1, 1), antialias: false,
            transform: PaintDrawTransform(
                a: c, b: s, c: -s, d: c, tx: 20, ty: 20))
    }

    @Test func aRotatedRectDrawsRotated() {
        let pixels = render([rotatedSquare()])
        #expect(!pixels.isEmpty)
        #expect(red(pixels, 20, 20) > 200, "the centre is covered either way")
        // A 20x20 square rotated 45° has a half-diagonal of ~14, so it reaches
        // further along the axes than its unrotated half-width of 10.
        #expect(red(pixels, 20, 8) > 200, "the corner reaches up the axis")
        // ...and pulls in along the diagonals, where an upright square would be
        // solid.
        #expect(red(pixels, 12, 12) == 0, "the diagonal is outside the diamond")
    }

    /// The same geometry with no transform: an upright square, inverted at
    /// exactly the two probe points above. This is the picture the old encoder
    /// produced for a rotated draw.
    @Test func anUnrotatedRectIsTheOppositePicture() {
        let command = PaintDrawCommand(
            kind: .rect, x: 10, y: 10, w: 20, h: 20,
            color: (1, 1, 1, 1), antialias: false)
        let pixels = render([command])
        #expect(red(pixels, 20, 8) == 0, "an upright square does not reach here")
        #expect(red(pixels, 12, 12) > 200, "and is solid on the diagonal")
    }

    /// The transform must not leak into whatever is drawn next — it is scoped to
    /// its own command.
    @Test func aCarriedTransformDoesNotLeak() {
        let after = PaintDrawCommand(
            kind: .rect, x: 0, y: 0, w: 6, h: 6,
            color: (1, 1, 1, 1), antialias: false)
        let pixels = render([rotatedSquare(), after])
        #expect(red(pixels, 2, 2) > 200, "the second command drew at the origin")
    }

    /// Device scale composes with the carried matrix rather than replacing it.
    @Test func deviceScaleStillApplies() {
        let surface = nucleus.skia.makeRasterSurface(40, 40)
        let canvas = surface.getCanvas()
        var clear = nucleus.skia.Color()
        clear.r = 0; clear.g = 0; clear.b = 0; clear.a = 1
        canvas.clear(clear)
        // An unrotated-but-carried transform: identity linear part, translation
        // only, so the effect of the device scale is readable on its own.
        let command = PaintDrawCommand(
            kind: .rect, x: 0, y: 0, w: 5, h: 5,
            color: (1, 1, 1, 1), antialias: false,
            transform: PaintDrawTransform(a: 1, b: 0.0001, c: 0, d: 1, tx: 0, ty: 0))
        PaintRasterizer.draw(
            commands: [command], payload: [], onto: canvas, scaleX: 2, scaleY: 2,
            resolveImage: { _ in nil }, resolveEffect: { _ in nil })

        var pixels = [UInt8](repeating: 0, count: 40 * 40 * 4)
        _ = pixels.withUnsafeMutableBufferPointer {
            surface.readPixelsRGBA($0.baseAddress, $0.count, 40 * 4)
        }
        #expect(red(pixels, 8, 8) > 200, "a 5px square at 2x covers 10px")
        #expect(red(pixels, 12, 12) == 0, "and no further")
    }
}
