// backdrop bands. For each backdrop draw, sample the accumulator source (the
// prefix snapshot for `.behindWindow`, the live accumulator for `.withinWindow`),
// blur + saturate it, composite it back into the draw's region clipped to its
// shape, then apply the tint. The foreground-vibrancy material samples the
// backdrop content through a chroma-preserving runtime shader.

import NucleusSkiaGraphiteBridge
import NucleusRenderModel

enum Backdrop {
    static func rectF(_ r: PlanRect) -> nucleus.skia.RectF {
        var out = nucleus.skia.RectF()
        out.x = r.x; out.y = r.y; out.width = r.w; out.height = r.h
        return out
    }

    static func rectF(_ f: Float4) -> nucleus.skia.RectF {
        var out = nucleus.skia.RectF()
        out.x = f.0; out.y = f.1; out.width = f.2; out.height = f.3
        return out
    }

    static func color(_ c: Float4) -> nucleus.skia.Color {
        var out = nucleus.skia.Color()
        out.r = c.0; out.g = c.1; out.b = c.2; out.a = c.3
        return out
    }

    /// Gaussian sigma approximating the kawase blur pyramid: the per-pass
    /// offset scaled by the pass count.
    static func blurSigma(_ spec: ExecSpec) -> Float {
        max(0, spec.offset) * Float(max(1, Int(spec.passes)))
    }

    /// The chroma-preserving foreground-vibrancy SkSL: blend the sampled backdrop
    /// toward its luminance by `strength`, preserving alpha.
    static let vibrancySksl = """
    uniform shader content;
    uniform half strength;
    half4 main(float2 coord) {
        half4 px = content.eval(coord);
        half l = dot(px.rgb, half3(0.2126, 0.7152, 0.0722));
        return half4(mix(px.rgb, half3(l), strength), px.a);
    }
    """

    /// The luminance-blend strength for a vibrancy variant (dark mutes chroma more).
    static func vibrancyStrength(_ variant: ForegroundVibrancyVariant) -> Float {
        switch variant {
        case .light: return 0.15
        case .dark: return 0.35
        }
    }

    /// Build the foreground-vibrancy shader sampling `content` (the resolved
    /// backdrop-group image). Returns nil if the runtime effect fails to bind.
    static func makeVibrancyShader(
        variant: ForegroundVibrancyVariant, content: nucleus.skia.Image
    ) -> nucleus.skia.Shader? {
        let uniforms: [Float] = [vibrancyStrength(variant)]
        return uniforms.withUnsafeBufferPointer { up in
            vibrancySksl.withCString { src in
                let shader = nucleus.skia.makeRuntimeShaderWithImage(src, up.baseAddress, 1, content)
                return shader.isValid() ? shader : nil
            }
        }
    }

    /// Clip `canvas` to `shape` (caller has already `save`d).
    static func clip(to shape: EffectShape, on canvas: nucleus.skia.Canvas) {
        switch shape {
        case .rect(let r):
            canvas.clipRect(rectF(r), true)
        case .rrect(let r, let radii):
            let rr = nucleus.skia.RRectRadii(
                topLeft: radii.0, topRight: radii.1, bottomRight: radii.2, bottomLeft: radii.3)
            canvas.clipRRect(rectF(r), rr, true)
        }
    }

    /// Execute one backdrop command at its exact position in the frame stream.
    /// `liveSnapshot` is the accumulator immediately before this command;
    /// `prefix` is an optional explicit behind-window source.
    static func execute(
        _ spec: ExecSpec, liveSnapshot: nucleus.skia.Image, prefix: nucleus.skia.Image?,
        onto canvas: nucleus.skia.Canvas
    ) -> Int {
        guard spec.enabled else { return 0 }
        let source = spec.blendingMode == .behindWindow ? (prefix ?? liveSnapshot) : liveSnapshot
        guard source.isValid() else { return 0 }
        let region = rectF(spec.region)

        canvas.save()
        clip(to: spec.shape, on: canvas)

        var blurPaint = nucleus.skia.Paint()
        blurPaint.blurSigma = blurSigma(spec)
        blurPaint.saturation = spec.saturation
        blurPaint.alpha = spec.alpha
        // Sample the same region of the source and composite it back blurred.
        canvas.drawImageRect(source, region, region, blurPaint)

        if spec.tintBlend > 0 {
            var tint = nucleus.skia.Paint()
            tint.color = color(spec.tintRgba)
            tint.alpha = spec.tintBlend
            canvas.drawRect(region, tint)
        }
        canvas.restore()
        return 1
    }
}
