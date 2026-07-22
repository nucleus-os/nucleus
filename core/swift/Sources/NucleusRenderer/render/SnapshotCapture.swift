// Renderer-owned snapshot capture: allocate a render texture, draw a
// device/world rect of the source into it, snapshot the result, and register it
// in the texture registry. RenderCore then interns the texture in SnapshotService
// and owns submission/retirement ordering.

import NucleusSkiaGraphiteBridge

/// A render-into-texture target: a fresh surface to draw a capture into, then
/// `finish` to snapshot + register the result.
final class CaptureTarget {
    let surface: nucleus.skia.Surface
    let width: Int32
    let height: Int32

    init(surface: nucleus.skia.Surface, width: Int32, height: Int32) {
        self.surface = surface
        self.width = width
        self.height = height
    }

    var canvas: nucleus.skia.Canvas { surface.getCanvas() }

    /// Snapshot the drawn content, register it under a fresh handle, return it.
    func finish(into registry: TextureRegistry, contentRevision: UInt64) -> UInt64? {
        let image = surface.snapshotImage()
        guard image.isValid() else { return nil }
        let handle = registry.allocRendererHandle()
        registry.register(
            key: .renderer(handle), image: image, width: width, height: height,
            contentRevision: contentRevision)
        return handle
    }
}

enum SnapshotCapture {
    /// The device-space pixel size of a world rect mapped through a uniform
    /// `scale` (the translate+scale the compositor uses), rounded out. Pure.
    static func deviceSize(localWidth: Float, localHeight: Float, scale: Float) -> (width: Int32, height: Int32) {
        let w = Int32(max(0, (localWidth * scale).rounded()))
        let h = Int32(max(0, (localHeight * scale).rounded()))
        return (w, h)
    }

    /// Allocate a render texture to draw a capture into. Mirrors
    /// `RenderTextureCapture.begin`. Nil if the surface cannot be allocated.
    static func begin(recorder: nucleus.skia.Recorder, width: Int32, height: Int32) -> CaptureTarget? {
        guard width > 0, height > 0 else { return nil }
        let surface = recorder.makeOffscreenSurface(width, height)
        guard surface.isValid() else { return nil }
        return CaptureTarget(surface: surface, width: width, height: height)
    }

    /// Capture a device-space rect of `source` into a fresh registered texture.
    /// Mirrors `captureDeviceRect`: snap the `(srcX, srcY, width, height)` region
    /// into a new image at origin. Returns the registry handle.
    static func captureDeviceRect(
        recorder: nucleus.skia.Recorder, source: nucleus.skia.Image,
        srcX: Float, srcY: Float, width: Int32, height: Int32,
        into registry: TextureRegistry, contentRevision: UInt64
    ) -> UInt64? {
        guard source.isValid(),
              let target = begin(recorder: recorder, width: width, height: height) else { return nil }
        let canvas = target.canvas
        var clear = nucleus.skia.Color()
        clear.a = 0
        canvas.clear(clear)

        var src = nucleus.skia.RectF()
        src.x = srcX; src.y = srcY; src.width = Float(width); src.height = Float(height)
        var dst = nucleus.skia.RectF()
        dst.x = 0; dst.y = 0; dst.width = Float(width); dst.height = Float(height)
        canvas.drawImageRect(source, src, dst, nucleus.skia.Paint())

        return target.finish(into: registry, contentRevision: contentRevision)
    }

    /// Capture a world rect: map a local rect through `(originX, originY, scale)`
    /// to device space, then capture. Mirrors `captureWorldRect`.
    static func captureWorldRect(
        recorder: nucleus.skia.Recorder, source: nucleus.skia.Image,
        originX: Float, originY: Float, scale: Float, localWidth: Float, localHeight: Float,
        into registry: TextureRegistry, contentRevision: UInt64
    ) -> UInt64? {
        let size = deviceSize(localWidth: localWidth, localHeight: localHeight, scale: scale)
        return captureDeviceRect(
            recorder: recorder, source: source,
            srcX: originX, srcY: originY, width: size.width, height: size.height,
            into: registry, contentRevision: contentRevision)
    }
}
