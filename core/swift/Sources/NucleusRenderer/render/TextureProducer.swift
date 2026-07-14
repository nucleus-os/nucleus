// Phase 10b.4d — the texture producers: rasterize compositor-owned paint
// content and blurred shadows into cache textures. Each
// rasterization is keyed by (layer, content revision) so
// unchanged content is suppressed; the per-frame `ProducerWorkStats` count the
// repaints vs suppressions.
//
// The work-stats accumulation + the suppression decision are pure and tested
// hardware-independently; the rasterization into a cache surface runs
// best-effort over a real Graphite recorder.

import NucleusSkiaGraphiteBridge
import NucleusRenderModel

/// Per-frame counters of producer GPU work (a representative subset of the
/// counting fields).
struct ProducerWorkStats: Equatable {
    var paintRepaint: UInt64 = 0
    var shadowRepaint: UInt64 = 0
    var drawQuad: UInt64 = 0
    var texturePass: UInt64 = 0
    var invalidate: UInt64 = 0

    var total: UInt64 { paintRepaint + shadowRepaint + drawQuad + texturePass }
    var hasWork: Bool { total > 0 }

    mutating func merge(_ other: ProducerWorkStats) {
        paintRepaint += other.paintRepaint
        shadowRepaint += other.shadowRepaint
        drawQuad += other.drawQuad
        texturePass += other.texturePass
        invalidate += other.invalidate
    }
}

/// What kind of content a producer rasterizes (selects the work-stat counter).
enum ProducerKind: Hashable {
    case paint
    case shadow
}

struct ProducerCacheKey: Hashable {
    var layerId: UInt64
    var revision: UInt64
    var width: Int32
    var height: Int32
    var kind: ProducerKind
}

/// A drop-shadow decoration to rasterize: a blurred rounded rect.
struct ShadowDecoration {
    var width: Int32
    var height: Int32
    var shapeRect: PlanRect
    var cornerRadii: Float4
    var blurSigma: Float
    var color: nucleus.skia.Color
}

/// Rasterizes paint/shadow content into cache textures held in a
/// `TextureRegistry`, suppressing re-rasterization of unchanged content.
final class TextureProducer {
    let registry: TextureRegistry
    private var handlesByKey: [ProducerCacheKey: UInt64] = [:]
    private var keysByLayer: [UInt64: Set<ProducerCacheKey>] = [:]
    private var failedKeys: Set<ProducerCacheKey> = []
    private var stats = ProducerWorkStats()

    init(registry: TextureRegistry) {
        self.registry = registry
    }

    func handle(for key: ProducerCacheKey) -> UInt64? { handlesByKey[key] }

    var cachedTextureCount: Int { handlesByKey.count }

    static func supersededKeys(
        in keys: Set<ProducerCacheKey>, replacing key: ProducerCacheKey
    ) -> Set<ProducerCacheKey> {
        Set(keys.filter { $0.kind == key.kind && $0.revision != key.revision })
    }

    /// Reclaim the cache texture for a single layer (its content is gone). Releases
    /// the registry entry (refcount 1 → evict) and drops the mapping. No-op if the
    /// layer has no cached texture.
    func evict(layerId: UInt64) {
        for key in keysByLayer.removeValue(forKey: layerId) ?? [] {
            if let handle = handlesByKey.removeValue(forKey: key) {
                _ = registry.release(handle)
            }
        }
        failedKeys = Set(failedKeys.filter { $0.layerId != layerId })
    }

    /// Reclaim cache textures for every layer no longer live in the retained tree.
    /// Called once per render pass with the tree's live-layer set, so a destroyed
    /// layer's paint/decoration texture does not linger for the process lifetime.
    func retainOnly(liveLayerIds: Set<UInt64>) {
        let dead = keysByLayer.keys.filter { !liveLayerIds.contains($0) }
        for layerId in dead { evict(layerId: layerId) }
    }

    /// Drain and reset the accumulated per-frame work stats.
    func drainStats() -> ProducerWorkStats {
        let s = stats
        stats = ProducerWorkStats()
        return s
    }

    func noteInvalidate() { stats.invalidate += 1 }

    /// Rasterize-or-reuse `layerId`'s content at `revision`. On a cache hit the
    /// work is suppressed and the existing handle returned; otherwise `draw`
    /// paints onto a fresh cache surface, the snapshot is registered, and the
    /// matching repaint counter is bumped. Returns nil only if a needed
    /// rasterization could not allocate a surface (no GPU).
    func produce(
        recorder: nucleus.skia.Recorder, layerId: UInt64, revision: UInt64,
        width: Int32, height: Int32, kind: ProducerKind,
        draw: (nucleus.skia.Canvas) -> Void
    ) -> UInt64? {
        let key = ProducerCacheKey(
            layerId: layerId, revision: revision,
            width: width, height: height, kind: kind)
        if let existing = handlesByKey[key] {
            // Cache hit: nothing to repaint.
            return existing
        }
        guard !failedKeys.contains(key) else { return nil }

        let surface = recorder.makeOffscreenSurface(width, height)
        guard surface.isValid() else {
            failedKeys.insert(key)
            return nil
        }
        let canvas = surface.getCanvas()
        var clear = nucleus.skia.Color()
        clear.a = 0  // transparent backing
        canvas.clear(clear)
        draw(canvas)

        let image = surface.snapshotImage()
        guard image.isValid() else {
            failedKeys.insert(key)
            return nil
        }

        // A revision replaces the layer's content, so every raster-size variant
        // of an older revision is unreachable. Keep scale variants for the current
        // revision, but release historical revisions before registering the new
        // image. Without this, an animated/repainted shell retained one dedicated
        // GPU image per commit until device-memory allocation failed.
        let superseded = Self.supersededKeys(
            in: keysByLayer[layerId, default: []], replacing: key)
        for oldKey in superseded {
            if let oldHandle = handlesByKey.removeValue(forKey: oldKey) {
                _ = registry.release(oldHandle)
            }
            keysByLayer[layerId]?.remove(oldKey)
            failedKeys.remove(oldKey)
        }
        failedKeys = Set(failedKeys.filter {
            !($0.layerId == layerId && $0.kind == kind && $0.revision != revision)
        })

        let handle = registry.allocHandle()
        registry.register(handle: handle, image: image, width: width, height: height, contentRevision: revision)
        handlesByKey[key] = handle
        keysByLayer[layerId, default: []].insert(key)
        failedKeys.remove(key)

        switch kind {
        case .paint: stats.paintRepaint += 1
        case .shadow: stats.shadowRepaint += 1
        }
        return handle
    }

    /// Rasterize a stored Swift paint command list into a cache texture for the
    /// plan's `.paint` quad. Commands are authored in layer-local paint units;
    /// `contentWidth`/`contentHeight` are the authored logical canvas projected at
    /// the output raster scale. Destination transforms never choose raster size.
    func producePaintCommands(
        recorder: nucleus.skia.Recorder,
        layerId: UInt64,
        revision: UInt64,
        commands: [PaintDrawCommand],
        authoredWidth: Float,
        authoredHeight: Float,
        contentWidth: Int32,
        contentHeight: Int32,
        resolveImage: (UInt64) -> nucleus.skia.Image?
    ) -> UInt64? {
        let width = max(1, contentWidth)
        let height = max(1, contentHeight)
        let sx = authoredWidth > 0 ? Float(width) / authoredWidth : 1
        let sy = authoredHeight > 0 ? Float(height) / authoredHeight : 1

        return produce(
            recorder: recorder, layerId: layerId, revision: revision,
            width: width, height: height, kind: .paint
        ) { canvas in
            for command in commands {
                drawPaintCommand(command, onto: canvas, scaleX: sx, scaleY: sy, resolveImage: resolveImage)
            }
        }
    }

    /// Rasterize a drop-shadow decoration (blurred rounded rect filling the cache).
    func produceShadow(
        recorder: nucleus.skia.Recorder, layerId: UInt64, revision: UInt64, shadow: ShadowDecoration
    ) -> UInt64? {
        produce(
            recorder: recorder, layerId: layerId, revision: revision,
            width: shadow.width, height: shadow.height, kind: .shadow
        ) { canvas in
            var rect = nucleus.skia.RectF()
            rect.x = shadow.shapeRect.x; rect.y = shadow.shapeRect.y
            rect.width = shadow.shapeRect.w; rect.height = shadow.shapeRect.h
            var paint = nucleus.skia.Paint()
            paint.color = shadow.color
            paint.blurSigma = shadow.blurSigma
            let radii = nucleus.skia.RRectRadii(
                topLeft: shadow.cornerRadii.0, topRight: shadow.cornerRadii.1,
                bottomRight: shadow.cornerRadii.2, bottomLeft: shadow.cornerRadii.3)
            canvas.drawRRect(rect, radii, paint)
        }
    }

    private func paintColor(_ rgba: Float4) -> nucleus.skia.Color {
        var color = nucleus.skia.Color()
        color.r = rgba.0
        color.g = rgba.1
        color.b = rgba.2
        color.a = rgba.3
        return color
    }

    private func scaledRect(_ command: PaintDrawCommand, _ sx: Float, _ sy: Float) -> nucleus.skia.RectF {
        var rect = nucleus.skia.RectF()
        rect.x = command.x * sx
        rect.y = command.y * sy
        rect.width = command.w * sx
        rect.height = command.h * sy
        return rect
    }

    private func drawPaintCommand(
        _ command: PaintDrawCommand,
        onto canvas: nucleus.skia.Canvas,
        scaleX sx: Float,
        scaleY sy: Float,
        resolveImage: (UInt64) -> nucleus.skia.Image?
    ) {
        var paint = nucleus.skia.Paint()
        paint.color = paintColor(command.color)

        switch command.kind {
        case .rect:
            canvas.drawRect(scaledRect(command, sx, sy), paint)
        case .roundedRect:
            let radius = max(0, command.radius) * min(sx, sy)
            let radii = nucleus.skia.RRectRadii(
                topLeft: radius, topRight: radius,
                bottomRight: radius, bottomLeft: radius)
            canvas.drawRRect(scaledRect(command, sx, sy), radii, paint)
        case .line:
            canvas.drawRect(lineRect(command, scaleX: sx, scaleY: sy), paint)
        case .image:
            guard command.imageHandle != 0, let image = resolveImage(command.imageHandle) else { break }
            canvas.drawImageRect(image, nucleus.skia.RectF(), scaledRect(command, sx, sy), paint)
        case .textLayout:
            canvas.drawTextLayout(command.textLayoutHandle, scaledRect(command, sx, sy), command.color.3)
        }
    }

    private func lineRect(_ command: PaintDrawCommand, scaleX sx: Float, scaleY sy: Float) -> nucleus.skia.RectF {
        let x0 = command.x * sx
        let y0 = command.y * sy
        let x1 = (command.x + command.w) * sx
        let y1 = (command.y + command.h) * sy
        let stroke = max(1, command.strokeWidth * min(sx, sy))
        var rect = nucleus.skia.RectF()
        if abs(x1 - x0) >= abs(y1 - y0) {
            rect.x = min(x0, x1)
            rect.y = min(y0, y1) - stroke * 0.5
            rect.width = max(stroke, abs(x1 - x0))
            rect.height = stroke
        } else {
            rect.x = min(x0, x1) - stroke * 0.5
            rect.y = min(y0, y1)
            rect.width = stroke
            rect.height = max(stroke, abs(y1 - y0))
        }
        return rect
    }
}
