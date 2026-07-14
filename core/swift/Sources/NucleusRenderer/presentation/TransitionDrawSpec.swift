// Phase 9.3 — Shared presentation-transition draw resolution.
//
// Live scene lowering and presented-snapshot capture both need the same answer
// for which textures participate in a transition material, how content samples
// resolve, and what progress the shader draws.
//
// The renderer-owned GPU `Texture` is abstracted behind `TransitionTexture` (a
// reference whose `imageId` models the image identity used for aliasing) and
// `TransitionTextureResolver` abstracts the resolver; the real GPU resolution
// binds at the renderer move (10b).

/// Renderer texture as the draw-spec sees it: dimensions + an image identity.
/// Two distinct handles alias when they wrap the same underlying image.
import NucleusRenderModel

protocol TransitionTexture: AnyObject {
    var width: UInt32 { get }
    var height: UInt32 { get }
    /// Identity of the backing image (`Texture.inner.image`).
    var imageId: UInt64 { get }
}

/// Resolves transition snapshot/external handles to live textures. Mirrors the
/// `resolver` duck-type (`resolveSnapshotTexture` / `lookupIOSurfaceTexture`).
protocol TransitionTextureResolver {
    func resolveSnapshotTexture(_ handle: SnapshotHandle) -> TransitionTexture?
    func lookupIOSurfaceTexture(_ id: IOSurfaceID) -> TransitionTexture?
}

/// Resolved per-side textures + samples + draw progress. Mirrors `Samples`.
struct TransitionSamples {
    var texturePrev: TransitionTexture
    var textureNext: TransitionTexture
    var fromSample: ResolvedContentSample
    var toSample: ResolvedContentSample
    var targetAliasesFrom: Bool
    var drawProgress: Float
}

/// Per-side visual footprint geometry. Mirrors `VisualGeometry`.
struct TransitionVisualGeometry: Equatable {
    var fromPosition: Point2D
    var toPosition: Point2D
    var fromW: Double
    var fromH: Double
    var toW: Double
    var toH: Double
}

/// Whether two textures alias: same handle, or same backing image. Mirrors
/// `texturesAlias`.
func texturesAlias(_ a: TransitionTexture, _ b: TransitionTexture) -> Bool {
    a === b || a.imageId == b.imageId
}

/// Horizontal source→logical oversample factor (≥1). Mirrors `sampleScaleX`.
func sampleScaleX(_ sample: ResolvedContentSample) -> Double {
    if sample.logicalW <= 0 || sample.srcSize.0 <= 0 { return 1.0 }
    return max(1.0, Double(sample.srcSize.0) / sample.logicalW)
}

/// Vertical source→logical oversample factor (≥1). Mirrors `sampleScaleY`.
func sampleScaleY(_ sample: ResolvedContentSample) -> Double {
    if sample.logicalH <= 0 || sample.srcSize.1 <= 0 { return 1.0 }
    return max(1.0, Double(sample.srcSize.1) / sample.logicalH)
}

/// Resolve the textures + samples + draw progress for a transition. Nil when a
/// required texture is unavailable. Mirrors `resolveSamples`.
func resolveTransitionSamples(
    _ resolver: TransitionTextureResolver,
    liveTargetSampleOverride: ContentSample?,
    content: LayerContent,
    _ trans: PresentationTransition
) -> TransitionSamples? {
    guard let texPrev = resolver.resolveSnapshotTexture(trans.fromTexture) else { return nil }
    let contentRevealHeld = trans.contentRevealHeld()
    let texNextResolved: TransitionTexture?
    if contentRevealHeld {
        texNextResolved = texPrev
    } else if !trans.toTexture.isNone {
        texNextResolved = resolver.resolveSnapshotTexture(trans.toTexture)
    } else {
        switch content {
        case .external(let id): texNextResolved = resolver.lookupIOSurfaceTexture(id)
        case .snapshot(let handle): texNextResolved = resolver.resolveSnapshotTexture(handle)
        default: texNextResolved = nil
        }
    }
    // `target_aliases_from` is reserved for a future live-target optimization
    // and is currently always false, so the next texture is the
    // resolved one or the resolution fails.
    let targetAliasesFrom = false
    guard let texNext = texNextResolved else { return nil }

    let fromSample = resolveContentSample(
        trans.fromSample,
        textureWidth: texPrev.width, textureHeight: texPrev.height,
        fallbackLogicalW: Double(trans.fromSize.w), fallbackLogicalH: Double(trans.fromSize.h))
    _ = liveTargetSampleOverride
    let toSample: ResolvedContentSample
    if contentRevealHeld || targetAliasesFrom {
        toSample = fromSample
    } else {
        toSample = resolveContentSample(
            trans.toSample,
            textureWidth: texNext.width, textureHeight: texNext.height,
            fallbackLogicalW: trans.toSize.w > 0 ? Double(trans.toSize.w) : fromSample.logicalW,
            fallbackLogicalH: trans.toSize.h > 0 ? Double(trans.toSize.h) : fromSample.logicalH)
    }
    let drawProgress: Float = (contentRevealHeld || targetAliasesFrom) ? 0 : trans.contentRevealProgress()
    return TransitionSamples(
        texturePrev: texPrev, textureNext: texNext,
        fromSample: fromSample, toSample: toSample,
        targetAliasesFrom: targetAliasesFrom, drawProgress: drawProgress)
}

/// Resolve the per-side visual footprint geometry. Mirrors `visualGeometry`.
func transitionVisualGeometry(
    _ trans: PresentationTransition,
    fromSample: ResolvedContentSample,
    toSample: ResolvedContentSample
) -> TransitionVisualGeometry {
    let expectedW: Double = (trans.contentRevealHeld() && trans.expectedToSize.w > 0) ? Double(trans.expectedToSize.w) : 0
    let expectedH: Double = (trans.contentRevealHeld() && trans.expectedToSize.h > 0) ? Double(trans.expectedToSize.h) : 0
    let toFootprintW = max(toSample.logicalW, expectedW)
    let toFootprintH = max(toSample.logicalH, expectedH)
    return TransitionVisualGeometry(
        fromPosition: trans.fromPosition, toPosition: trans.toPosition,
        fromW: fromSample.logicalW, fromH: fromSample.logicalH,
        toW: toFootprintW, toH: toFootprintH)
}
