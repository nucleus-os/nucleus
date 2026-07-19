// Paint-command rasterization: decode a stored command list + payload blob and
// draw it onto a canvas.
//
// Split out of `TextureProducer` so it does not require a Graphite recorder.
// The producer needs a GPU-backed offscreen surface, but *this* logic — payload
// decode, point scaling, shading construction — is where the authoring side and
// the rasterizing side can silently disagree, and a disagreement here yields a
// plausible wrong picture rather than a crash. Against a CPU raster surface it
// is verifiable headless, which is the only way to assert the pixels.

import NucleusSkiaGraphiteBridge
import NucleusRenderModel
import NucleusTypes

enum PaintRasterizer {
static func paintColor(_ rgba: Float4) -> nucleus.skia.Color {
    var color = nucleus.skia.Color()
    color.r = rgba.0
    color.g = rgba.1
    color.b = rgba.2
    color.a = rgba.3
    return color
}

static func scaledRect(_ command: PaintDrawCommand, _ sx: Float, _ sy: Float) -> nucleus.skia.RectF {
    var rect = nucleus.skia.RectF()
    rect.x = command.x * sx
    rect.y = command.y * sy
    rect.width = command.w * sx
    rect.height = command.h * sy
    return rect
}

/// Draw a whole command list. The single entry point; `TextureProducer` calls
/// this after allocating its cache surface.
static func draw(
    commands: [PaintDrawCommand],
    payload: [UInt8],
    onto canvas: nucleus.skia.Canvas,
    scaleX sx: Float,
    scaleY sy: Float,
    resolveImage: (UInt64) -> nucleus.skia.Image?,
    resolveEffect: (UInt64) -> nucleus.skia.RuntimeEffect?
) {
    for command in commands {
        drawPaintCommand(
            command, payload: payload, onto: canvas, scaleX: sx, scaleY: sy,
            resolveImage: resolveImage, resolveEffect: resolveEffect)
    }
}

static func drawPaintCommand(
    _ command: PaintDrawCommand,
    payload: [UInt8],
    onto canvas: nucleus.skia.Canvas,
    scaleX sx: Float,
    scaleY sy: Float,
    resolveImage: (UInt64) -> nucleus.skia.Image?,
    resolveEffect: (UInt64) -> nucleus.skia.RuntimeEffect?
) {
    let paint = skiaPaint(command, scaleX: sx, scaleY: sy)

    switch command.kind {
    case .rect:
        canvas.drawRect(scaledRect(command, sx, sy), paint)
    case .roundedRect:
        let radius = max(0, command.radius) * min(sx, sy)
        let radii = nucleus.skia.RRectRadii(
            topLeft: radius, topRight: radius,
            bottomRight: radius, bottomLeft: radius)
        canvas.drawRRect(scaledRect(command, sx, sy), radii, paint)
    case .path:
        drawPathCommand(
            command, payload: payload, onto: canvas, paint: paint,
            scaleX: sx, scaleY: sy, resolveEffect: resolveEffect)
    case .image:
        guard command.imageHandle != 0, let image = resolveImage(command.imageHandle) else { break }
        canvas.drawImageRect(image, nucleus.skia.RectF(), scaledRect(command, sx, sy), paint)
    case .textLayout:
        canvas.drawTextLayout(command.textLayoutHandle, scaledRect(command, sx, sy), command.color.3)
    case .clipPath:
        guard let path = decodePath(command, payload: payload, scaleX: sx, scaleY: sy) else { break }
        canvas.clipPath(path, command.antialias)
    case .save:
        canvas.save()
    case .restore:
        canvas.restore()
    }
}

/// Lower a decoded command's style onto a façade `Paint`. Until now this set
/// only `color`, so stroke width, blend, alpha, blur, and saturation were
/// carried through the pipeline and then dropped at the last step.
static func skiaPaint(
    _ command: PaintDrawCommand, scaleX sx: Float, scaleY sy: Float
) -> nucleus.skia.Paint {
    var paint = nucleus.skia.Paint()
    paint.color = paintColor(command.color)
    paint.alpha = command.alpha
    paint.antialias = command.antialias
    paint.blend = skiaBlendMode(command.blend)
    paint.blurSigma = command.blurSigma * min(sx, sy)
    paint.saturation = command.saturation
    paint.tintsImage = command.tintsImage
    paint.style = command.stroke ? .stroke : .fill
    paint.strokeWidth = command.strokeWidth * min(sx, sy)
    return paint
}

static func skiaBlendMode(_ blend: PaintDrawBlendMode) -> nucleus.skia.BlendMode {
    switch blend {
    case .srcOver: .srcOver
    case .src: .src
    case .multiply: .multiply
    case .screen: .screen
    case .plus: .plus
    case .overlay: .overlay
    case .dstIn: .dstIn
    case .dstOut: .dstOut
    }
}

/// Decode a command's payload slice into a Skia path and draw it with the
/// requested shading. A payload that fails to decode is dropped rather than
/// drawn from misread bytes; the decoder rejects out-of-range slices,
/// inconsistent region sizes, and verbs that over-consume points.
static func drawPathCommand(
    _ command: PaintDrawCommand,
    payload: [UInt8],
    onto canvas: nucleus.skia.Canvas,
    paint: nucleus.skia.Paint,
    scaleX sx: Float,
    scaleY sy: Float,
    resolveEffect: (UInt64) -> nucleus.skia.RuntimeEffect?
) {
    guard let regions = PaintPayload.decode(
        payload, offset: command.payloadOffset, length: command.payloadLength),
          let path = makeSkiaPath(regions, evenOdd: command.evenOddFill, scaleX: sx, scaleY: sy)
    else { return }

    guard let shader = makeShader(
        command, regions: regions, scaleX: sx, scaleY: sy, resolveEffect: resolveEffect)
    else {
        canvas.drawPath(path, paint)
        return
    }
    canvas.drawPathWithShader(path, shader, paint)
}

/// Decode a command's payload into a Skia path, or nil if it does not
/// decode. Shared by path draws and clips.
static func decodePath(
    _ command: PaintDrawCommand, payload: [UInt8], scaleX sx: Float, scaleY sy: Float
) -> nucleus.skia.Path? {
    guard let regions = PaintPayload.decode(
        payload, offset: command.payloadOffset, length: command.payloadLength)
    else { return nil }
    return makeSkiaPath(regions, evenOdd: command.evenOddFill, scaleX: sx, scaleY: sy)
}

/// Scale authored points into raster space and build the path. Arc verbs
/// encode (origin, size, angles): the first four floats scale, the two
/// angles must not.
static func makeSkiaPath(
    _ regions: PaintPayload.Regions, evenOdd: Bool, scaleX sx: Float, scaleY sy: Float
) -> nucleus.skia.Path? {
    var verbs: [UInt8] = []
    verbs.reserveCapacity(regions.verbs.count)
    for verb in regions.verbs { verbs.append(verb.rawValue) }

    var points = regions.points
    var cursor = 0
    for verb in regions.verbs {
        switch verb {
        case .arc:
            points[cursor] *= sx
            points[cursor + 1] *= sy
            points[cursor + 2] *= sx
            points[cursor + 3] *= sy
        default:
            var i = 0
            while i < verb.floatCount {
                points[cursor + i] *= sx
                points[cursor + i + 1] *= sy
                i += 2
            }
        }
        cursor += verb.floatCount
    }

    let path = verbs.withUnsafeBufferPointer { verbBuffer in
        points.withUnsafeBufferPointer { pointBuffer in
            nucleus.skia.makePath(
                verbBuffer.baseAddress, verbBuffer.count,
                pointBuffer.baseAddress, pointBuffer.count, evenOdd)
        }
    }
    return path.isValid() ? path : nil
}

/// Build the shader for a command's shading, or nil for a plain color fill
/// (and for a shading whose parameters do not decode, which falls back to
/// the command color rather than dropping the draw entirely).
static func makeShader(
    _ command: PaintDrawCommand,
    regions: PaintPayload.Regions,
    scaleX sx: Float,
    scaleY sy: Float,
    resolveEffect: (UInt64) -> nucleus.skia.RuntimeEffect?
) -> nucleus.skia.Shader? {
    let scalars = regions.scalars
    var colors: [nucleus.skia.Color] = []
    colors.reserveCapacity(regions.colors.count)
    for color in regions.colors {
        colors.append(paintColor((color.r, color.g, color.b, color.a)))
    }
    // Stops trail the geometry scalars, one per color.
    func stops(after geometry: Int) -> [Float] {
        Array(scalars.dropFirst(geometry))
    }

    switch command.shading {
    case .color:
        return nil
    case .linearGradient:
        guard scalars.count >= 4, colors.count >= 2 else { return nil }
        let positions = stops(after: 4)
        return colors.withUnsafeBufferPointer { c in
            withStops(positions, count: colors.count) { p in
                nucleus.skia.makeLinearGradient(
                    scalars[0] * sx, scalars[1] * sy, scalars[2] * sx, scalars[3] * sy,
                    c.baseAddress, p, c.count, .clamp)
            }
        }
    case .radialGradient:
        guard scalars.count >= 3, colors.count >= 2 else { return nil }
        let positions = stops(after: 3)
        return colors.withUnsafeBufferPointer { c in
            withStops(positions, count: colors.count) { p in
                nucleus.skia.makeRadialGradient(
                    scalars[0] * sx, scalars[1] * sy, scalars[2] * min(sx, sy),
                    c.baseAddress, p, c.count, .clamp)
            }
        }
    case .sweepGradient:
        guard scalars.count >= 4, colors.count >= 2 else { return nil }
        let positions = stops(after: 4)
        return colors.withUnsafeBufferPointer { c in
            withStops(positions, count: colors.count) { p in
                nucleus.skia.makeSweepGradient(
                    scalars[0] * sx, scalars[1] * sy, scalars[2], scalars[3],
                    c.baseAddress, p, c.count, .clamp)
            }
        }
    case .effect:
        guard command.effectHandle != 0,
              let effect = resolveEffect(command.effectHandle) else { return nil }
        return scalars.withUnsafeBufferPointer { u in
            effect.makeShader(u.baseAddress, u.count)
        }
    }
}

/// Gradient stops are optional: a count mismatch means "distribute evenly",
/// which Skia expresses as a null positions pointer.
static func withStops<T>(
    _ positions: [Float], count: Int, _ body: (UnsafePointer<Float>?) -> T
) -> T {
    guard positions.count == count else { return body(nil) }
    return positions.withUnsafeBufferPointer { body($0.baseAddress) }
}
}
