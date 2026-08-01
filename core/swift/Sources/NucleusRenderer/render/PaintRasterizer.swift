// Paint-command rasterization: decode a stored command list + payload blob and
// draw it onto a canvas.
//
// Split out of `TextureProducer` so it does not require a Graphite recorder.
// The producer needs a GPU-backed offscreen surface, but *this* logic — payload
// decode, point scaling, shading construction — is where the authoring side and
// the rasterizing side can silently disagree, and a disagreement here yields a
// plausible wrong picture rather than a crash. Against a CPU raster surface it
// is verifiable headless, which is the only way to assert the pixels.

internal import NucleusRenderModel
import NucleusSkiaGraphiteBridge
internal import NucleusTypes

/// Safe facade over the Skia C++ paint bridge. Every pointer is borrowed only
/// for its enclosing buffer closure and all C++ values remain render-thread
/// confined.
@safe enum PaintRasterizer {
    static func paintColor(_ rgba: Color) -> nucleus.skia.Color {
        var color = nucleus.skia.Color()
        color.r = rgba.r
        color.g = rgba.g
        color.b = rgba.b
        color.a = rgba.a
        return color
    }

    static func scaledRect(_ command: PaintCommand, _ sx: Float, _ sy: Float) -> nucleus.skia.RectF
    {
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
        commands: [PaintCommand],
        payload: [UInt8],
        onto canvas: nucleus.skia.Canvas,
        scaleX sx: Float,
        scaleY sy: Float,
        resolveImage: (UInt64) -> nucleus.skia.Image?,
        resolveEffect: (UInt64) -> nucleus.skia.RuntimeEffect?
    ) {
        for command in commands {
            unsafe drawPaintCommand(
                command, payload: payload, onto: canvas, scaleX: sx, scaleY: sy,
                resolveImage: resolveImage, resolveEffect: resolveEffect)
        }
    }

    static func drawPaintCommand(
        _ command: PaintCommand,
        payload: [UInt8],
        onto canvas: nucleus.skia.Canvas,
        scaleX sx: Float,
        scaleY sy: Float,
        resolveImage: (UInt64) -> nucleus.skia.Image?,
        resolveEffect: (UInt64) -> nucleus.skia.RuntimeEffect?
    ) {
        // Save/restore are recording-state commands, not paint operations with
        // local geometry.
        if command.kind == .save {
            unsafe canvas.save()
            return
        }
        if command.kind == .restore {
            unsafe canvas.restore()
            return
        }

        // A clip must survive after its command-local matrix is gone. Applying a
        // matrix inside save/restore would restore the clip too, so map the path
        // through the complete device transform and clip without changing the CTM.
        if command.kind == .clipPath {
            guard
                let path = unsafe decodePath(
                    command, payload: payload,
                    scaleX: command.transform == nil ? sx : 1,
                    scaleY: command.transform == nil ? sy : 1)
            else { return }
            if let transform = command.transform {
                let matrix = deviceMatrix(transform, scaleX: sx, scaleY: sy)
                matrix.withUnsafeBufferPointer {
                    unsafe canvas.clipPathTransformed(path, $0.baseAddress, command.antialias)
                }
            } else {
                unsafe canvas.clipPath(path, command.antialias)
            }
            return
        }

        // Paint geometry stays local. Concatenating device scale with the command's
        // complete affine transform lets Skia transform paths as outlines, so
        // anisotropic stroke and radial-gradient behavior are not approximated by
        // one scalar.
        if let transform = command.transform {
            unsafe canvas.save()
            let matrix = deviceMatrix(transform, scaleX: sx, scaleY: sy)
            matrix.withUnsafeBufferPointer { unsafe canvas.concat($0.baseAddress) }
        }
        defer { if command.transform != nil { unsafe canvas.restore() } }

        // With a carried transform the canvas is already in the command's space, so
        // geometry and radii are used as authored rather than pre-scaled.
        let deviceScaleX = command.transform == nil ? sx : 1
        let deviceScaleY = command.transform == nil ? sy : 1
        // Stroke width and blur follow the same rule as geometry: the carried
        // matrix already scales them, so pre-scaling as well would apply it twice.
        guard
            let paint = skiaPaint(
                command, scaleX: deviceScaleX, scaleY: deviceScaleY
            )
        else { return }

        switch command.kind {
        case .rect:
            unsafe canvas.drawRect(scaledRect(command, deviceScaleX, deviceScaleY), paint)
        case .roundedRect:
            let radius = max(0, command.radius) * min(deviceScaleX, deviceScaleY)
            let radii = nucleus.skia.RRectRadii(
                topLeft: radius, topRight: radius,
                bottomRight: radius, bottomLeft: radius)
            unsafe canvas.drawRRect(scaledRect(command, deviceScaleX, deviceScaleY), radii, paint)
        case .path:
            unsafe drawPathCommand(
                command, payload: payload, onto: canvas, paint: paint,
                scaleX: deviceScaleX, scaleY: deviceScaleY,
                resolveEffect: resolveEffect)
        case .image:
            guard command.imageHandle != 0, let image = unsafe resolveImage(command.imageHandle)
            else { break }
            unsafe canvas.drawImageRect(
                image, nucleus.skia.RectF(),
                scaledRect(command, deviceScaleX, deviceScaleY), paint)
        case .textLayout:
            unsafe canvas.drawTextLayout(
                command.textLayoutHandle,
                scaledRect(command, deviceScaleX, deviceScaleY), command.color.a)
        case .clipPath, .save, .restore:
            break
        }
    }

    private static func deviceMatrix(
        _ transform: PaintTransform, scaleX sx: Float, scaleY sy: Float
    ) -> [Float] {
        [
            transform.a * sx, transform.c * sx, transform.tx * sx,
            transform.b * sy, transform.d * sy, transform.ty * sy,
            0, 0, 1,
        ]
    }

    /// Lower a decoded command's style onto a façade `Paint`. Until now this set
    /// only `color`, so stroke width, blend, alpha, blur, and saturation were
    /// carried through the pipeline and then dropped at the last step.
    static func skiaPaint(
        _ command: PaintCommand, scaleX sx: Float, scaleY sy: Float
    ) -> nucleus.skia.Paint? {
        var paint = nucleus.skia.Paint()
        paint.color = paintColor(command.color)
        paint.alpha = command.alpha
        paint.antialias = command.antialias
        guard
            nucleus.skia.setPaintBlend(
                &paint, Int32(command.blend.rawValue)),
            nucleus.skia.setPaintStyle(&paint, command.stroke ? 1 : 0),
            nucleus.skia.setPaintStrokeCap(
                &paint, Int32(command.strokeCap.rawValue)),
            nucleus.skia.setPaintStrokeJoin(
                &paint, Int32(command.strokeJoin.rawValue))
        else { return nil }
        paint.blurSigma = command.blurSigma * min(sx, sy)
        paint.saturation = command.saturation
        paint.tintsImage = command.tintsImage
        paint.strokeWidth = command.strokeWidth * min(sx, sy)
        return paint
    }

    /// Decode a command's payload slice into a Skia path and draw it with the
    /// requested shading. A payload that fails to decode is dropped rather than
    /// drawn from misread bytes; the decoder rejects out-of-range slices,
    /// inconsistent region sizes, and verbs that over-consume points.
    static func drawPathCommand(
        _ command: PaintCommand,
        payload: [UInt8],
        onto canvas: nucleus.skia.Canvas,
        paint: nucleus.skia.Paint,
        scaleX sx: Float,
        scaleY sy: Float,
        resolveEffect: (UInt64) -> nucleus.skia.RuntimeEffect?
    ) {
        guard
            let regions = PaintPayload.decode(
                payload, offset: command.payloadOffset, length: command.payloadLength),
            let path = unsafe makeSkiaPath(
                regions, evenOdd: command.evenOddFill, scaleX: sx, scaleY: sy)
        else { return }

        guard
            let shader = unsafe makeShader(
                command, regions: regions, scaleX: sx, scaleY: sy, resolveEffect: resolveEffect)
        else {
            unsafe canvas.drawPath(path, paint)
            return
        }
        unsafe canvas.drawPathWithShader(path, shader, paint)
    }

    /// Decode a command's payload into a Skia path, or nil if it does not
    /// decode. Shared by path draws and clips.
    static func decodePath(
        _ command: PaintCommand, payload: [UInt8], scaleX sx: Float, scaleY sy: Float
    ) -> nucleus.skia.Path? {
        guard
            let regions = PaintPayload.decode(
                payload, offset: command.payloadOffset, length: command.payloadLength)
        else { return nil }
        return unsafe makeSkiaPath(
            regions, evenOdd: command.evenOddFill, scaleX: sx, scaleY: sy)
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
                unsafe nucleus.skia.makePath(
                    verbBuffer.baseAddress, verbBuffer.count,
                    pointBuffer.baseAddress, pointBuffer.count, evenOdd)
            }
        }
        return unsafe path.isValid() ? path : nil
    }

    /// Build the shader for a command's shading, or nil for a plain color fill
    /// (and for a shading whose parameters do not decode, which falls back to
    /// the command color rather than dropping the draw entirely).
    static func makeShader(
        _ command: PaintCommand,
        regions: PaintPayload.Regions,
        scaleX sx: Float,
        scaleY sy: Float,
        resolveEffect: (UInt64) -> nucleus.skia.RuntimeEffect?
    ) -> nucleus.skia.Shader? {
        let scalars = regions.scalars
        var colors: [nucleus.skia.Color] = []
        colors.reserveCapacity(regions.colors.count)
        for color in regions.colors {
            colors.append(paintColor(color))
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
                unsafe withStops(positions, count: colors.count) { p in
                    unsafe nucleus.skia.makeLinearGradient(
                        scalars[0] * sx, scalars[1] * sy, scalars[2] * sx, scalars[3] * sy,
                        c.baseAddress, p, c.count, .clamp)
                }
            }
        case .radialGradient:
            guard scalars.count >= 3, colors.count >= 2 else { return nil }
            let positions = stops(after: 3)
            return colors.withUnsafeBufferPointer { c in
                unsafe withStops(positions, count: colors.count) { p in
                    unsafe nucleus.skia.makeRadialGradient(
                        scalars[0] * sx, scalars[1] * sy, scalars[2] * min(sx, sy),
                        c.baseAddress, p, c.count, .clamp)
                }
            }
        case .sweepGradient:
            guard scalars.count >= 4, colors.count >= 2 else { return nil }
            let positions = stops(after: 4)
            return colors.withUnsafeBufferPointer { c in
                unsafe withStops(positions, count: colors.count) { p in
                    unsafe nucleus.skia.makeSweepGradient(
                        scalars[0] * sx, scalars[1] * sy, scalars[2], scalars[3],
                        c.baseAddress, p, c.count, .clamp)
                }
            }
        case .effect:
            guard command.effectHandle != 0,
                let effect = unsafe resolveEffect(command.effectHandle)
            else { return nil }
            return scalars.withUnsafeBufferPointer { u in
                unsafe effect.makeShader(u.baseAddress, u.count)
            }
        }
    }

    /// Gradient stops are optional: a count mismatch means "distribute evenly",
    /// which Skia expresses as a null positions pointer.
    static func withStops<T>(
        _ positions: [Float], count: Int, _ body: (UnsafePointer<Float>?) -> T
    ) -> T {
        guard positions.count == count else { return body(nil) }
        return positions.withUnsafeBufferPointer { unsafe body($0.baseAddress) }
    }
}
