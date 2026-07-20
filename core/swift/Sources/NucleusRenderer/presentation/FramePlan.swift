// Phase 9.8 — The reusable per-output Swift FramePlan.
//
// One native execution plan per output: ordered draw/clip/backdrop/transition/
// external commands, immutable resource handles + sampling descriptors, damage
// rectangles, the direct-scanout candidate, requested frame callbacks +
// presentation operations, diagnostic counters, and plan identity. Built by the
// presentation walk today; this is the Swift target it lowers into.
//
// The scanout/callback/operation/identity fields are the FramePlan
// superset the plan calls for. Variable collections reuse capacity across frames
// (`reset` keeps storage), mirroring the `UniqueArray` reuse contract.

// MARK: - Resource handles + descriptors

/// Opaque render-server texture handle. Mirrors `composition_plan.TextureHandle`
/// (`enum(u64)`, `invalid = 0`).
import NucleusRenderModel

struct TextureHandle: Equatable {
    var raw: UInt64 = 0
    static let invalid = TextureHandle(raw: 0)
    var isValid: Bool { raw != 0 }
    static func fromRaw(_ value: UInt64) -> TextureHandle { TextureHandle(raw: value) }
}

/// Which sampler/pipeline a textured draw uses. Mirrors `TextureQuadRole`.
enum TextureQuadRole {
    case content
    case paint
    case snapshot
    case remoteHost
    case shadow
    case fill
    case shell
    case unknown
}

/// Composite blend. Mirrors `BlendMode`.
enum BlendMode {
    case srcOver
    case src
}

/// Per-corner rounded mask in target-physical pixels. Mirrors `RRectMask`.
struct RRectMask: Equatable {
    var rect: PlanRect
    /// `[topLeft, topRight, bottomRight, bottomLeft]`.
    var radii: Float4 = (0, 0, 0, 0)

    static func == (lhs: RRectMask, rhs: RRectMask) -> Bool {
        lhs.rect == rhs.rect && float4Equal(lhs.radii, rhs.radii)
    }
}

/// Which foreground-vibrancy chroma-preserving filter a content draw runs.
/// Mirrors `ForegroundVibrancyVariant`.
enum ForegroundVibrancyVariant: UInt8 {
    case light = 0
    case dark = 1
}

/// Reference from a content draw to an upstream backdrop group. Mirrors
/// `ForegroundVibrancy`.
struct ForegroundVibrancy {
    var backdropGroupId: UInt64
    var variant: ForegroundVibrancyVariant
}

// MARK: - Draw commands

/// A textured draw. Mirrors `TextureQuad`.
struct TextureQuad {
    var layerId: UInt64 = 0
    var zBand: Int32 = 0
    var role: TextureQuadRole = .unknown
    var texture: TextureHandle?
    var dst: PlanRect
    var src: PlanRect
    var alpha: Float
    var blendMode: BlendMode = .srcOver
    var maskRRect: RRectMask?
    var opaqueRect: PlanRect?
    var foregroundVibrancy: ForegroundVibrancy?
    /// Layer-local logical paint damage. Nil means a complete texture rebuild.
    var localPaintDamage: Rect?
}

/// A solid fill. Mirrors `FillQuad`.
struct FillQuad {
    var zBand: Int32 = 0
    var dst: PlanRect
    var color: Float4
    var blendMode: BlendMode = .srcOver
    var maskRRect: RRectMask?
}

/// Vector visual-style draw emitted directly into the ordered command stream.
/// Background, borders, and corner geometry remain independent of content.
struct VisualStyleQuad {
    var dst: PlanRect
    var backgroundColor: Float4
    var borderWidths: Float4
    var borderTopColor: Float4
    var borderRightColor: Float4
    var borderBottomColor: Float4
    var borderLeftColor: Float4
    var cornerRadii: Float4
    var alpha: Float
}

struct ShadowMaterial {
    var layerId: UInt64
    var revision: UInt64
    var rasterWidth: Int32
    var rasterHeight: Int32
    var shapeRect: PlanRect
    var cornerRadii: Float4
    var blurSigma: Float
    var color: Float4
}

/// A padded shadow draw. `material` is rasterized before command recording.
struct ShadowQuad {
    var zBand: Int32 = 0
    var texture: TextureHandle?
    var material: ShadowMaterial? = nil
    var dst: PlanRect
    var src: PlanRect
    var alpha: Float
}

/// The cross-content transition material. Mirrors `TransitionMaterial`.
enum TransitionMaterial {
    case crossfade
}

/// A presentation-transition draw. Mirrors `TransitionQuad`.
struct TransitionQuad {
    var layerId: UInt64 = 0
    var zBand: Int32 = 0
    var material: TransitionMaterial = .crossfade
    var texturePrev: TextureHandle?
    var textureNext: TextureHandle?
    var anchorPrev: (Float, Float) = (0, 0)
    var sideSizePrev: (Float, Float)
    var srcOriginPrev: (Float, Float) = (0, 0)
    var sampleSizePrev: (Float, Float)
    var anchorNext: (Float, Float) = (0, 0)
    var sideSizeNext: (Float, Float)
    var srcOriginNext: (Float, Float) = (0, 0)
    var sampleSizeNext: (Float, Float)
    var dst: PlanRect
    var progress: Float = 0
    var alpha: Float = 1.0
    var cornerRadii: Float4 = (0, 0, 0, 0)
}

/// One ordered visual operation. Mirrors `Op`.
enum PlanOp {
    case textureQuad(TextureQuad)
    case fillQuad(FillQuad)
    case visualStyle(VisualStyleQuad)
    case shadowQuad(ShadowQuad)
    case transitionQuad(TransitionQuad)
    case backdrop(ExecSpec)
}

// MARK: - Ordered backdrop commands

/// A fully resolved backdrop execution spec. Mirrors `ExecSpec`.
struct ExecSpec {
    var layerId: UInt64
    var zBand: Int32 = 0
    var groupId: UInt64
    var blendingMode: BackdropBlendingMode = .behindWindow
    var region: PlanRect
    var shape: EffectShape
    var mask: BackdropMask
    var tintRgba: Float4 = (0, 0, 0, 0)
    var tintBlend: Float = 0
    var alpha: Float = 1
    var enabled: Bool = true
    var passes: UInt8 = 3
    var offset: Float = 3
    var saturation: Float = 1.5
    var noise: Float = 0.02
    var solidFallbackRgba: Float4 = (0, 0, 0, 0)
    var foregroundVariant: ForegroundVibrancyVariant = .light
}

// MARK: - Frame metadata + plan identity

/// Output + target metadata for one frame. Mirrors `FrameInfo`, plus the plan
/// identity the FramePlan superset carries.
struct FrameInfo {
    var outputId: UInt64 = 0
    var width: UInt32 = 0
    var height: UInt32 = 0
    var scale: Float = 1
    var frameSerial: UInt64 = 0
    var fullDamage: Bool = false
    var damageBounds: PlanRect?
    /// FramePlan identity: a per-construction serial + the output-scale
    /// generation (changes when pixel size / scale changes).
    var planSerial: UInt64 = 0
    var scaleGeneration: UInt64 = 0
}

/// The direct-scanout candidate for this frame: the root surface eligible to
/// scan out the primary plane, or a disqualification. Mirrors the scanout slot
/// the 10a `DrmScanout` evaluator populates; `disqualificationReason` is the
/// `ScanoutBlockReason` code (0 = eligible).
struct DirectScanoutPlan {
    var candidateLayerId: UInt64
    var eligible: Bool
    var disqualificationReason: UInt32 = 0
}

/// Aggregate counters describing the emitted plan. Diagnostic only.
struct PlanCounters: Equatable {
    var textureQuads: UInt64 = 0
    var fillQuads: UInt64 = 0
    var shadowQuads: UInt64 = 0
    var transitionQuads: UInt64 = 0
    var backdropDraws: UInt64 = 0
    var damageRects: UInt64 = 0
}

struct LayerFrameSnapshot: Equatable {
    var rect: PhysicalRect
    var visualSignature: UInt64
    var compositeSignature: UInt64 = 0
    var structural: Bool
    /// Per-frame content invalidation is intentionally excluded from equality.
    /// It forces the current footprint dirty once without making the following
    /// frame look changed merely because RetainedTreeStore cleared its flags.
    var contentDamaged: Bool = false
    /// Output-physical projection of a safe layer-local paint invalidation.
    var localizedContentDamage: PhysicalRect? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rect == rhs.rect
            && lhs.visualSignature == rhs.visualSignature
            && lhs.compositeSignature == rhs.compositeSignature
            && lhs.structural == rhs.structural
    }
}

// MARK: - The plan

/// One reusable per-output frame plan. Mirrors `CompositionPlan` and extends it
/// with the FramePlan superset (scanout candidate, frame callbacks, presentation
/// operations, counters, identity). Variable collections retain capacity across
/// `reset` for steady-state reuse.
final class FramePlan {
    var frame = FrameInfo()
    private(set) var ops: [PlanOp] = []
    private(set) var damageRects: [PlanRect] = []
    private(set) var sourceDamageRects: [PlanRect] = []
    private(set) var layerSnapshots: [UInt64: LayerFrameSnapshot] = [:]

    // FramePlan superset.
    var directScanout: DirectScanoutPlan?
    private(set) var frameCallbacks: [UInt64] = []
    private(set) var presentationOperations: [OperationID] = []
    var operationDeadlineNs: UInt64?
    var counters = PlanCounters()

    /// Reset for a new frame, retaining all storage capacity. Mirrors `reset`.
    func reset(_ frame: FrameInfo) {
        ops.removeAll(keepingCapacity: true)
        damageRects.removeAll(keepingCapacity: true)
        sourceDamageRects.removeAll(keepingCapacity: true)
        layerSnapshots.removeAll(keepingCapacity: true)
        frameCallbacks.removeAll(keepingCapacity: true)
        presentationOperations.removeAll(keepingCapacity: true)
        directScanout = nil
        operationDeadlineNs = nil
        counters = PlanCounters()
        self.frame = frame
    }

    func appendDamageRect(_ rect: PlanRect) {
        if rect.w <= 0 || rect.h <= 0 { return }
        damageRects.append(rect)
        counters.damageRects += 1
    }

    func appendSourceDamageRect(_ rect: PlanRect) {
        if rect.w <= 0 || rect.h <= 0 { return }
        sourceDamageRects.append(rect)
    }

    func recordLayerSnapshot(_ layerID: UInt64, _ snapshot: LayerFrameSnapshot) {
        layerSnapshots[layerID] = snapshot
    }

    /// Remove draws whose complete pixel footprint is hidden by opaque draws above
    /// them. Coverage uses inward-rounded opaque rectangles and outward-rounded
    /// candidate rectangles, so fractional geometry never causes false culling.
    func cullOccludedOps() {
        var opaque = Region()
        var kept: [PlanOp] = []
        kept.reserveCapacity(ops.count)
        for op in ops.reversed() {
            let bounds = Self.bounds(of: op).flatMap(Self.outwardRect)
            if let bounds, opaque.contains(bounds) { continue }
            kept.append(op)
            if let rect = Self.opaqueRect(of: op).flatMap(Self.inwardRect) {
                opaque.formUnion(rect)
            }
        }
        ops = kept.reversed()
        counters.textureQuads = 0
        counters.fillQuads = 0
        counters.shadowQuads = 0
        counters.transitionQuads = 0
        counters.backdropDraws = 0
        for op in ops {
            switch op {
            case .textureQuad: counters.textureQuads += 1
            case .fillQuad: counters.fillQuads += 1
            case .visualStyle: counters.fillQuads += 1
            case .shadowQuad: counters.shadowQuads += 1
            case .transitionQuad: counters.transitionQuads += 1
            case .backdrop: counters.backdropDraws += 1
            }
        }
    }

    private static func bounds(of op: PlanOp) -> PlanRect? {
        switch op {
        case .textureQuad(let quad): return quad.dst
        case .fillQuad(let quad): return quad.dst
        case .visualStyle(let quad): return quad.dst
        case .shadowQuad(let quad): return quad.dst
        case .transitionQuad(let quad): return quad.dst
        case .backdrop(let spec): return spec.region
        }
    }

    private static func opaqueRect(of op: PlanOp) -> PlanRect? {
        switch op {
        case .textureQuad(let quad): return quad.opaqueRect
        case .fillQuad(let quad):
            return quad.color.3 >= 0.999 && quad.blendMode == .src && quad.maskRRect == nil
                ? quad.dst : nil
        case .visualStyle(let quad):
            let square = quad.cornerRadii.0 == 0 && quad.cornerRadii.1 == 0
                && quad.cornerRadii.2 == 0 && quad.cornerRadii.3 == 0
            return quad.alpha >= 0.999 && quad.backgroundColor.3 >= 0.999 && square
                ? quad.dst : nil
        case .shadowQuad, .transitionQuad, .backdrop: return nil
        }
    }

    private static func outwardRect(_ rect: PlanRect) -> RegionRect? {
        let x0 = rect.x.rounded(.down), y0 = rect.y.rounded(.down)
        let x1 = (rect.x + rect.w).rounded(.up), y1 = (rect.y + rect.h).rounded(.up)
        return integerRect(x0: x0, y0: y0, x1: x1, y1: y1)
    }

    private static func inwardRect(_ rect: PlanRect) -> RegionRect? {
        let x0 = rect.x.rounded(.up), y0 = rect.y.rounded(.up)
        let x1 = (rect.x + rect.w).rounded(.down), y1 = (rect.y + rect.h).rounded(.down)
        return integerRect(x0: x0, y0: y0, x1: x1, y1: y1)
    }

    private static func integerRect(x0: Float, y0: Float, x1: Float, y1: Float) -> RegionRect? {
        let dx0 = Double(x0), dy0 = Double(y0), dx1 = Double(x1), dy1 = Double(y1)
        let width = dx1 - dx0, height = dy1 - dy0
        guard dx0.isFinite, dy0.isFinite, dx1.isFinite, dy1.isFinite,
              width > 0, height > 0,
              dx0 >= Double(Int32.min), dy0 >= Double(Int32.min),
              dx1 <= Double(Int32.max), dy1 <= Double(Int32.max),
              width <= Double(Int32.max), height <= Double(Int32.max)
        else { return nil }
        return RegionRect(
            x: Int32(dx0), y: Int32(dy0),
            width: Int32(width), height: Int32(height))
    }

    func appendTextureQuad(_ quad: TextureQuad) {
        ops.append(.textureQuad(quad))
        counters.textureQuads += 1
    }

    func appendFillQuad(_ quad: FillQuad) {
        ops.append(.fillQuad(quad))
        counters.fillQuads += 1
    }

    func appendVisualStyle(_ quad: VisualStyleQuad) {
        ops.append(.visualStyle(quad))
        counters.fillQuads += 1
    }

    func appendShadowQuad(_ quad: ShadowQuad) {
        ops.append(.shadowQuad(quad))
        counters.shadowQuads += 1
    }

    func appendTransitionQuad(_ quad: TransitionQuad) {
        ops.append(.transitionQuad(quad))
        counters.transitionQuads += 1
    }

    /// Append a backdrop at its exact scene position. Backdrops are ordered
    /// commands, never a side list executed after unrelated foreground content.
    func appendBackdropExecSpec(_ draw: ExecSpec) {
        ops.append(.backdrop(draw))
        counters.backdropDraws += 1
    }

    func backdropDrawCount() -> Int {
        ops.reduce(into: 0) { count, op in
            if case .backdrop = op { count += 1 }
        }
    }

    func appendFrameCallback(_ surfaceId: UInt64) {
        frameCallbacks.append(surfaceId)
    }

    func appendPresentationOperation(_ op: OperationID) {
        presentationOperations.append(op)
    }

}
