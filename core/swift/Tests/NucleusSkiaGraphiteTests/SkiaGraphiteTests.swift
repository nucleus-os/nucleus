import Testing
import NucleusSkiaGraphiteBridge

// Proves the renderer's Skia link end to end: the nucleus::skia Graphite façade
// imports under C++ interop and links against the full GN/Ninja-built Skia
// archive set (Graphite/native Vulkan + codecs + text). A real raster Skia op runs
// (no GPU/Vulkan context needed for the CPU raster path).
@Test func graphiteFacadeLinksAndRunsRasterOp() {
    let px: [UInt8] = [
        255, 0, 0, 255,   0, 255, 0, 255,
        0, 0, 255, 255,   255, 255, 0, 255,
    ]
    let img = px.withUnsafeBufferPointer { buf in
        nucleus.skia.makeRasterImageRGBA(2, 2, buf.baseAddress, buf.count)
    }
    #expect(img.isValid())
    #expect(img.width() == 2)
    #expect(img.height() == 2)
}

// MARK: - Raster harness

/// Draw into a CPU raster surface and read the pixels back. Needs no Graphite
/// context, so the drawing façade is verifiable headless.
private func render(
    width: Int32, height: Int32, _ body: (nucleus.skia.Canvas) -> Void
) -> [UInt8] {
    let surface = nucleus.skia.makeRasterSurface(width, height)
    guard surface.isValid() else { return [] }
    let canvas = surface.getCanvas()
    var clear = nucleus.skia.Color()
    clear.r = 0; clear.g = 0; clear.b = 0; clear.a = 1
    canvas.clear(clear)
    body(canvas)

    var pixels = [UInt8](repeating: 0, count: Int(width * height) * 4)
    let ok = pixels.withUnsafeMutableBufferPointer { buf in
        surface.readPixelsRGBA(buf.baseAddress, buf.count, Int32(width * 4))
    }
    return ok ? pixels : []
}

private func pixel(_ pixels: [UInt8], _ x: Int, _ y: Int, width: Int) -> (UInt8, UInt8, UInt8, UInt8) {
    let i = (y * width + x) * 4
    return (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
}

private func opaqueWhite() -> nucleus.skia.Color {
    var c = nucleus.skia.Color()
    c.r = 1; c.g = 1; c.b = 1; c.a = 1
    return c
}

private func makePath(_ verbs: [UInt8], _ points: [Float], evenOdd: Bool = false) -> nucleus.skia.Path {
    verbs.withUnsafeBufferPointer { v in
        points.withUnsafeBufferPointer { p in
            nucleus.skia.makePath(v.baseAddress, v.count, p.baseAddress, p.count, evenOdd)
        }
    }
}

private let move = UInt8(nucleus.skia.PathVerb.move.rawValue)
private let line = UInt8(nucleus.skia.PathVerb.line.rawValue)
private let closeVerb = UInt8(nucleus.skia.PathVerb.close.rawValue)

// MARK: - Stroke vs fill

/// The defect this phase fixes: a paint carrying a `strokeWidth` but no stroke
/// style renders as a solid fill, because Skia defaults to fill. Nothing in the
/// tree rendered a border before, so nothing caught it. A stroked rect path must
/// leave its interior untouched.
@Test func strokedPathLeavesItsInteriorUnpainted() {
    let path = makePath(
        [move, line, line, line, closeVerb],
        [10, 10, 30, 10, 30, 30, 10, 30])

    let pixels = render(width: 40, height: 40) { canvas in
        var paint = nucleus.skia.Paint()
        paint.color = opaqueWhite()
        paint.style = .stroke
        paint.strokeWidth = 2
        paint.antialias = false
        canvas.drawPath(path, paint)
    }
    #expect(!pixels.isEmpty, "raster surface readback")

    // On the edge: painted.
    let onEdge = pixel(pixels, 20, 10, width: 40)
    #expect(onEdge.0 > 200, "stroke paints the edge")

    // Interior: untouched. This is what fails when style defaults to fill.
    let interior = pixel(pixels, 20, 20, width: 40)
    #expect(interior.0 == 0, "stroke must not fill the interior")

    // Outside: untouched.
    let outside = pixel(pixels, 2, 2, width: 40)
    #expect(outside.0 == 0, "stroke must not paint outside")
}

@Test func filledPathPaintsItsInterior() {
    let path = makePath(
        [move, line, line, line, closeVerb],
        [10, 10, 30, 10, 30, 30, 10, 30])

    let pixels = render(width: 40, height: 40) { canvas in
        var paint = nucleus.skia.Paint()
        paint.color = opaqueWhite()
        paint.style = .fill
        paint.antialias = false
        canvas.drawPath(path, paint)
    }
    #expect(!pixels.isEmpty)
    #expect(pixel(pixels, 20, 20, width: 40).0 > 200, "fill paints the interior")
    #expect(pixel(pixels, 2, 2, width: 40).0 == 0, "fill stays inside")
}

// MARK: - Path encoding

/// A verb array that runs past the supplied points is malformed. It must fail
/// loudly rather than yield a partially-built path that renders wrong geometry.
@Test func makePathRejectsTruncatedPointArray() {
    // Two verbs need four floats; supply two.
    let path = makePath([move, line], [0, 0])
    #expect(!path.isValid(), "truncated point array is rejected")
}

@Test func makePathAcceptsAnArcVerb() {
    let arc = UInt8(nucleus.skia.PathVerb.arcTo.rawValue)
    // arcTo consumes six floats: oval origin, oval size, start/sweep angles.
    let path = makePath([move, arc], [50, 10, 10, 10, 80, 80, 0, 270])
    #expect(path.isValid(), "arc verb builds a path")
}

/// An arc is a path verb rather than a `drawArc` facade call, so a countdown
/// ring is a stroked path with a round cap — one primitive, not a bespoke one.
@Test func strokedArcPaintsAnOpenRing() {
    let arc = UInt8(nucleus.skia.PathVerb.arcTo.rawValue)
    let path = makePath([move, arc], [50, 10, 10, 10, 40, 40, 0, 180])
    #expect(path.isValid())

    let pixels = render(width: 60, height: 60) { canvas in
        var paint = nucleus.skia.Paint()
        paint.color = opaqueWhite()
        paint.style = .stroke
        paint.strokeWidth = 3
        paint.strokeCap = .round
        canvas.drawPath(path, paint)
    }
    #expect(!pixels.isEmpty)
    // Sweeping 0°→180° covers the bottom of the oval; the centre stays clear.
    #expect(pixel(pixels, 30, 30, width: 60).0 == 0, "arc is not filled")
}

// MARK: - Gradients

@Test func linearGradientVariesAlongItsAxis() {
    var black = nucleus.skia.Color(); black.a = 1
    let colors = [black, opaqueWhite()]

    let pixels = colors.withUnsafeBufferPointer { c -> [UInt8] in
        let shader = nucleus.skia.makeLinearGradient(
            0, 0, 40, 0, c.baseAddress, nil, c.count, .clamp)
        guard shader.isValid() else { return [] }
        let path = makePath(
            [move, line, line, line, closeVerb],
            [0, 0, 40, 0, 40, 40, 0, 40])
        return render(width: 40, height: 40) { canvas in
            var paint = nucleus.skia.Paint()
            paint.color = opaqueWhite()
            canvas.drawPathWithShader(path, shader, paint)
        }
    }
    #expect(!pixels.isEmpty, "gradient shader built and drew")

    let left = pixel(pixels, 1, 20, width: 40).0
    let right = pixel(pixels, 38, 20, width: 40).0
    #expect(right > left, "linear gradient ramps along its axis")
}

@Test func gradientRequiresAtLeastTwoColors() {
    let one = [opaqueWhite()]
    let shader = one.withUnsafeBufferPointer { c in
        nucleus.skia.makeLinearGradient(0, 0, 10, 0, c.baseAddress, nil, c.count, .clamp)
    }
    #expect(!shader.isValid(), "a one-color gradient is rejected")
}

/// `SkShaders::SweepGradient` returns null unless startAngle < endAngle; the
/// facade rejects the inverted range rather than returning a shader that
/// silently draws nothing.
@Test func sweepGradientRejectsInvertedAngleRange() {
    var black = nucleus.skia.Color(); black.a = 1
    let colors = [black, opaqueWhite()]
    let shader = colors.withUnsafeBufferPointer { c in
        nucleus.skia.makeSweepGradient(20, 20, 270, 90, c.baseAddress, nil, c.count, .clamp)
    }
    #expect(!shader.isValid())
}

// MARK: - Transform

@Test func concatTranslatesSubsequentDraws() {
    let path = makePath(
        [move, line, line, line, closeVerb],
        [0, 0, 10, 0, 10, 10, 0, 10])

    let pixels = render(width: 40, height: 40) { canvas in
        var paint = nucleus.skia.Paint()
        paint.color = opaqueWhite()
        paint.antialias = false
        // Row-major translate by (20, 20).
        let m: [Float] = [1, 0, 20, 0, 1, 20, 0, 0, 1]
        m.withUnsafeBufferPointer { canvas.concat($0.baseAddress) }
        canvas.drawPath(path, paint)
    }
    #expect(!pixels.isEmpty)
    #expect(pixel(pixels, 25, 25, width: 40).0 > 200, "draw landed at the translated origin")
    #expect(pixel(pixels, 5, 5, width: 40).0 == 0, "nothing at the untranslated origin")
}

// MARK: - Clip

@Test func clipPathConstrainsSubsequentDraws() {
    let clip = makePath(
        [move, line, line, line, closeVerb],
        [0, 0, 20, 0, 20, 40, 0, 40])
    let fill = makePath(
        [move, line, line, line, closeVerb],
        [0, 0, 40, 0, 40, 40, 0, 40])

    let pixels = render(width: 40, height: 40) { canvas in
        var paint = nucleus.skia.Paint()
        paint.color = opaqueWhite()
        paint.antialias = false
        canvas.clipPath(clip, false)
        canvas.drawPath(fill, paint)
    }
    #expect(!pixels.isEmpty)
    #expect(pixel(pixels, 10, 20, width: 40).0 > 200, "inside the clip is painted")
    #expect(pixel(pixels, 30, 20, width: 40).0 == 0, "outside the clip is not")
}

// MARK: - Runtime effects

private let solidRed = """
half4 main(float2 p) { return half4(1, 0, 0, 1); }
"""

private let uniformColor = """
uniform float4 tint;
half4 main(float2 p) { return half4(tint); }
"""

/// Compilation is uniform-independent, so a compiled program is reusable across
/// uniform sets. This split is what lets the effect store cache compilation
/// behind a handle while uniforms ride the per-frame payload blob.
@Test func aCompiledEffectVendsShadersForDifferentUniformSets() {
    let effect = nucleus.skia.makeRuntimeEffect(uniformColor)
    #expect(effect.isValid(), "program compiles")

    let red: [Float] = [1, 0, 0, 1]
    let blue: [Float] = [0, 0, 1, 1]
    let redShader = red.withUnsafeBufferPointer { effect.makeShader($0.baseAddress, $0.count) }
    let blueShader = blue.withUnsafeBufferPointer { effect.makeShader($0.baseAddress, $0.count) }
    #expect(redShader.isValid(), "first uniform set binds")
    #expect(blueShader.isValid(), "second uniform set binds against the same program")
}

@Test func compilingInvalidSkslFails() {
    let effect = nucleus.skia.makeRuntimeEffect("this is not sksl")
    #expect(!effect.isValid())
}

/// A uniform buffer whose size does not match the program's declared uniforms
/// must fail rather than bind garbage.
@Test func mismatchedUniformSizeIsRejected() {
    let effect = nucleus.skia.makeRuntimeEffect(uniformColor)
    #expect(effect.isValid())
    let tooFew: [Float] = [1, 0]
    let shader = tooFew.withUnsafeBufferPointer { effect.makeShader($0.baseAddress, $0.count) }
    #expect(!shader.isValid(), "short uniform buffer is rejected")
}

@Test func aRuntimeEffectShaderPaintsThroughDrawPathWithShader() {
    let effect = nucleus.skia.makeRuntimeEffect(solidRed)
    #expect(effect.isValid())
    let shader = effect.makeShader(nil, 0)
    #expect(shader.isValid(), "a program with no uniforms binds an empty set")

    let path = makePath(
        [move, line, line, line, closeVerb],
        [0, 0, 20, 0, 20, 20, 0, 20])
    let pixels = render(width: 20, height: 20) { canvas in
        var paint = nucleus.skia.Paint()
        paint.color = opaqueWhite()
        paint.antialias = false
        canvas.drawPathWithShader(path, shader, paint)
    }
    #expect(!pixels.isEmpty)
    let p = pixel(pixels, 10, 10, width: 20)
    #expect(p.0 > 200 && p.1 < 50 && p.2 < 50, "the effect painted red")
}

// MARK: - Stroked rounded rect

/// `ViewStyle` emits a border as a **rounded-rect** command carrying the stroke
/// flag, not as a path, so the stroke has to work on that draw call too. Phase
/// 3's coverage proved it for paths only; a border would still have filled if
/// `drawRRect` ignored the style.
@Test func aStrokedRoundedRectLeavesItsInteriorUnpainted() {
    let pixels = render(width: 40, height: 40) { canvas in
        var paint = nucleus.skia.Paint()
        paint.color = opaqueWhite()
        paint.style = .stroke
        paint.strokeWidth = 2
        paint.antialias = false
        var rect = nucleus.skia.RectF()
        rect.x = 10; rect.y = 10; rect.width = 20; rect.height = 20
        let radii = nucleus.skia.RRectRadii(
            topLeft: 4, topRight: 4, bottomRight: 4, bottomLeft: 4)
        canvas.drawRRect(rect, radii, paint)
    }
    #expect(!pixels.isEmpty)
    #expect(pixel(pixels, 20, 10, width: 40).0 > 200, "the border edge paints")
    #expect(pixel(pixels, 20, 20, width: 40).0 == 0, "the interior stays unpainted")
    #expect(pixel(pixels, 2, 2, width: 40).0 == 0, "nothing paints outside")
}

/// The regression this guards: a fill-styled paint carrying a stroke width
/// paints the whole shape. That is exactly what borders did before this work.
@Test func aFilledRoundedRectPaintsItsInteriorEvenWithAStrokeWidth() {
    let pixels = render(width: 40, height: 40) { canvas in
        var paint = nucleus.skia.Paint()
        paint.color = opaqueWhite()
        paint.strokeWidth = 2  // set, but style stays .fill
        paint.antialias = false
        var rect = nucleus.skia.RectF()
        rect.x = 10; rect.y = 10; rect.width = 20; rect.height = 20
        let radii = nucleus.skia.RRectRadii(
            topLeft: 4, topRight: 4, bottomRight: 4, bottomLeft: 4)
        canvas.drawRRect(rect, radii, paint)
    }
    #expect(!pixels.isEmpty)
    #expect(
        pixel(pixels, 20, 20, width: 40).0 > 200,
        "a stroke width alone does not stroke — the style is what matters")
}
