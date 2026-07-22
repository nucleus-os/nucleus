// The top-level per-frame renderer. `FrameDriver.renderFrame` builds a FramePlan
// from the retained tree, pre-resolves each texture handle to a GPU image, composites
// the operations onto the persistent output accumulator, executes backdrop bands,
// presents into the scanout surface, and submits through the C++ façade.
// `FrameDemand` is the Graphite-native analog of FrameDemand.collect +
// render_demand.shouldRenderThisVblank — the render-demand predicate the reactor
// uses to decide whether to render a vblank.

import NucleusSkiaGraphiteBridge
import VulkanC
import NucleusRenderModel

/// Per-frame render demand. `shouldRenderThisVblank` is the render predicate:
/// render when any continuous animation is active, a frame is explicitly due,
/// or new work is plausible since the last sample.
struct FrameDemand {
    var continuousActive: Bool = false
    var frameDue: Bool = false
    var workPlausible: Bool = false

    var shouldRenderThisVblank: Bool {
        continuousActive || frameDue || workPlausible
    }
}

@_spi(NucleusPlatform)
public struct RenderFrameTimings: Sendable, Equatable {
    public var planNs: UInt64 = 0
    public var resolveNs: UInt64 = 0
    public var accumulatorNs: UInt64 = 0
    public var damageNs: UInt64 = 0
    public var compositeNs: UInt64 = 0
    public var blitNs: UInt64 = 0
    public var frameSnapNs: UInt64 = 0
    public var uploadSnapNs: UInt64 = 0
    public var submitNs: UInt64 = 0
    public var totalNs: UInt64 = 0

    public init() {}
}

@_spi(NucleusPlatform)
public struct RenderFrameTelemetry: Sendable, Equatable {
    public var generation: UInt64 = 0
    public var outputID: UInt64 = 0
    public var frameSerial: UInt64 = 0
    public var operationCount: UInt64 = 0
    public var referencedSurfaceCount: UInt64 = 0
    public var changedSurfaceCount: UInt64 = 0
    public var damageRectCount: UInt64 = 0
    public var damagePixelCount: UInt64 = 0
    public var fullDamage: Bool = false
    public var paintRepaintCount: UInt64 = 0
    public var partialPaintRepaintCount: UInt64 = 0
    public var fullPaintRepaintCount: UInt64 = 0
    public var shadowRepaintCount: UInt64 = 0
    public var producerDrawCount: UInt64 = 0
    public var producerTexturePassCount: UInt64 = 0
    public var producerInvalidationCount: UInt64 = 0
    public var oldestCommitToRenderNs: UInt64 = 0
    public var clientCommitToRenderNs: [UInt64] = []
    public var acquireTargetNs: UInt64 = 0
    public var targetWrapNs: UInt64 = 0
    public var treeSnapshotNs: UInt64 = 0
    public var recordNs: UInt64 = 0
    public var backendFinalizeNs: UInt64 = 0
    public var backendPresentNs: UInt64 = 0
    public var recordToSubmitNs: UInt64 = 0
    public var timings = RenderFrameTimings()

    public init() {}
}

func elapsedNanoseconds(
    _ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant
) -> UInt64 {
    let parts = start.duration(to: end).components
    guard parts.seconds >= 0, parts.attoseconds >= 0 else { return 0 }
    return UInt64(parts.seconds) &* 1_000_000_000
        &+ UInt64(parts.attoseconds / 1_000_000_000)
}

struct FrameRenderResult {
    var opsDrawn: Int
    var backdropDraws: Int
    var presented: Bool
    var submitted: Bool
    var fullDamage: Bool
    var damageRectCount: Int
    var damagePixelCount: UInt64
    var acquireWaitCount: Int
    var acquiredSurfaceIDs: [UInt64]
    var referencedSurfaceIDs: [UInt64]
    /// Must remain false: no Swift callback fires during recording or submission.
    var callbackDuringRecord: Bool
    var timings: RenderFrameTimings
}

/// Owns the per-frame GPU state — the Graphite context + recorder, the texture
/// registry/producer, and per-output accumulators — and renders one frame.
final class FrameDriver {
    let resourceHost: SwiftResourceHost
    let context: nucleus.skia.GraphiteContext
    let recorder: nucleus.skia.Recorder
    /// Client uploads are recorded independently from frame drawing. They are
    /// snapped only when a frame is ready and inserted before that frame in one
    /// context submission.
    let uploadRecorder: nucleus.skia.Recorder
    let registry = TextureRegistry()
    let producer: TextureProducer
    private var accumulators: [UInt64: OutputAccumulator] = [:]
    private var previousLayerSnapshots: [UInt64: [UInt64: LayerFrameSnapshot]] = [:]
    private var submittedLayerSnapshots: [UInt64: [UInt64: LayerFrameSnapshot]] = [:]
    private var decodedImages: [UInt64: nucleus.skia.Image] = [:]
    /// Decodes off the render thread; results are adopted at the top of a frame.
    let decodeQueue: ImageDecodeQueue
    /// Compiled SkSL programs keyed by runtime-effect handle. Compilation is
    /// the expensive half and is uniform-independent, so it is cached here
    /// while uniforms are re-bound per draw.
    private var compiledEffects: [UInt64: nucleus.skia.RuntimeEffect] = [:]
    private var recording = false
    private var uploadsStaged = false
    private(set) var sawCallbackWhileRecording = false

    init?(
        context: nucleus.skia.GraphiteContext,
        resourceHost: SwiftResourceHost,
        wakeSink: any AsyncRenderWakeSink
    ) {
        guard context.isValid() else { return nil }
        let recorder = context.makeRecorder()
        let uploadRecorder = context.makeRecorder()
        guard recorder.isValid(), uploadRecorder.isValid() else { return nil }
        self.context = context
        self.resourceHost = resourceHost
        self.recorder = recorder
        self.uploadRecorder = uploadRecorder
        self.decodeQueue = ImageDecodeQueue(wakeSink: wakeSink)
        self.producer = TextureProducer(registry: registry)
    }

    /// Allocate or update a sampled client texture on the upload recorder. Pixel
    /// bytes are consumed by Graphite during this call; GPU work remains staged
    /// until the next successful frame submission.
    func stageClientUpload(
        replacing existing: nucleus.skia.UploadTexture?, pixels: [UInt8],
        width: Int32, height: Int32
    ) -> nucleus.skia.UploadTexture? {
        let texture: nucleus.skia.UploadTexture
        if let existing, existing.isValid(), existing.width() == width, existing.height() == height {
            texture = existing
        } else {
            texture = uploadRecorder.makeUploadTextureRGBA(width, height)
        }
        guard texture.isValid() else { return nil }
        let updated = pixels.withUnsafeBufferPointer {
            texture.updateRGBA($0.baseAddress, $0.count)
        }
        guard updated else { return nil }
        uploadsStaged = true
        return texture
    }

    /// Submit a standalone renderer-owned copy outside the presentation loop.
    /// Pending SHM upload work is ordered before it. An explicit-sync client
    /// acquire semaphore, when present, is consumed by this submission.
    func submitImmediate(
        _ recording: nucleus.skia.Recording,
        waitSemaphores: [VkSemaphore],
        submissionSerial: UInt64
    ) -> nucleus.skia.Status {
        let uploadRecording = uploadsStaged
            ? uploadRecorder.snapRecording()
            : nil
        uploadsStaged = false
        let waits: [UnsafeMutableRawPointer?] = waitSemaphores.map {
            UnsafeMutableRawPointer($0)
        }
        return waits.withUnsafeBufferPointer { waits in
            if let uploadRecording, uploadRecording.isValid() {
                return context.submitWithUploadAndSemaphores(
                    uploadRecording,
                    recording,
                    waits.baseAddress,
                    waits.count,
                    nil,
                    submissionSerial)
            }
            return context.submitWithSemaphores(
                recording,
                waits.baseAddress,
                waits.count,
                nil,
                submissionSerial)
        }
    }

    /// Drop GPU-backed images before the context tears down (lifetime invariant).
    func shutdown() {
        if uploadsStaged {
            // Cancel unsent transfer tasks before their backend textures are
            // released by RenderCore's client texture table.
            _ = uploadRecorder.snapRecording()
            uploadsStaged = false
        }
        decodeQueue.shutdown()
        registry.clear()
        decodedImages.removeAll()
        compiledEffects.removeAll()
        accumulators.removeAll()
    }

    /// The image behind a handle, if it has been decoded.
    ///
    /// Decoding is asynchronous, so this returns nil until the result arrives —
    /// a missing image draws nothing for a frame or two rather than blocking the
    /// frame that asked for it. A first-paint wallpaper decode is tens of
    /// milliseconds and would otherwise be a visible hitch.
    ///
    /// The bounds are the handle's identity, not a hint: `ImageStore` dedupes on
    /// `"WxH:path"`, so two handles for one path at different bounds are two
    /// distinct decodes and must stay that way.
    func decodedImage(handle: UInt64, source: ImageSource) -> nucleus.skia.Image? {
        if let existing = decodedImages[handle], existing.isValid() { return existing }

        // Without a worker there is nothing to wait for, so decode inline — the
        // behaviour before the queue existed, and the behaviour if a thread
        // could not be spawned.
        guard decodeQueue.hasWorkers else {
            let image = ImageDecodeQueue.decode(source)
            guard image.isValid() else { return nil }
            decodedImages[handle] = image
            return image
        }

        decodeQueue.submit(handle: handle, source: source)
        return nil
    }

    /// Adopt everything decoded since the last frame. Called at the top of a
    /// frame, which is the only point the cache may be written.
    func drainDecodedImages() {
        for result in decodeQueue.drain() {
            decodedImages[result.handle] = result.image
        }
    }

    var imageDecodeCompletionGeneration: UInt64 {
        decodeQueue.completionGeneration
    }

    /// Resolve a paint command's effect handle to a compiled program, compiling
    /// and caching on first use. Mirrors `resolvePaintImage`.
    func resolvePaintEffect(_ handle: UInt64) -> nucleus.skia.RuntimeEffect? {
        guard let source = resourceHost.runtimeEffects.source(handle) else { return nil }
        return compiledEffect(handle: handle, source: source)
    }

    func compiledEffect(handle: UInt64, source: RuntimeEffectSource) -> nucleus.skia.RuntimeEffect? {
        if let existing = compiledEffects[handle], existing.isValid() { return existing }
        let effect = nucleus.skia.makeRuntimeEffect(source.sksl)
        guard effect.isValid() else { return nil }
        compiledEffects[handle] = effect
        return effect
    }

    /// Drop a compiled-program cache entry after the render owner drains its
    /// source store's eviction queue. No-op for an unknown handle.
    func evictCompiledEffect(_ handle: UInt64) {
        compiledEffects[handle] = nil
    }

    /// Drop a decoded-image cache entry after the render owner drains its
    /// source store's eviction queue, so the decoded GPU image does not outlive
    /// its source. No-op for an unknown handle.
    func evictDecodedImage(_ handle: UInt64) {
        decodedImages[handle] = nil
        // A decode already in flight for this handle is now for a source that no
        // longer exists, and the handle may be re-registered — delivering the
        // stale result would draw the wrong picture.
        decodeQueue.cancel(handle: handle)
    }

    /// Reclaim producer cache textures for layers no longer in the retained tree.
    func collectProducerGarbage(liveLayerIds: Set<UInt64>) {
        producer.retainOnly(liveLayerIds: liveLayerIds)
    }

    func takeProducerWorkStats() -> ProducerWorkStats {
        producer.drainStats()
    }

    /// Poll Graphite's internal Vulkan submission fences and return the newest
    /// frame serial whose GPU-finished callback has run. This never waits.
    func pollCompletedSubmissionSerial() -> UInt64 {
        context.pollCompletedSubmissionSerial()
    }

    func takeCompletedSubmissionGpuElapsedNs(_ submissionSerial: UInt64) -> UInt64? {
        let elapsed = context.takeCompletedSubmissionGpuElapsedNs(submissionSerial)
        return elapsed == 0 ? nil : elapsed
    }

    /// Drop a detached output's persistent accumulator surface (a full output-sized
    /// GPU render target), so it does not leak for the process lifetime when an
    /// output is removed. No-op for an unknown output.
    func dropAccumulator(output: UInt64) {
        accumulators[output] = nil
        previousLayerSnapshots[output] = nil
        submittedLayerSnapshots[output] = nil
    }

    /// Make the last GPU-submitted frame authoritative only after its presentation
    /// backend accepted the image. A failed atomic/WSI present must leave damage
    /// comparison anchored to the last image accepted for presentation.
    func commitSubmittedSnapshot(output: UInt64) {
        guard let submitted = submittedLayerSnapshots.removeValue(forKey: output) else { return }
        previousLayerSnapshots[output] = submitted
    }

    func discardSubmittedSnapshot(output: UInt64) {
        submittedLayerSnapshots[output] = nil
    }

    /// The output's persistent composited accumulator, for screencopy/screenshot
    /// readback. nil until the output has recorded a frame.
    func accumulator(for output: UInt64) -> OutputAccumulator? {
        accumulators[output]
    }

    private func ensureAccumulator(output: UInt64, width: Int32, height: Int32) -> OutputAccumulator? {
        if let existing = accumulators[output] {
            return existing.ensure(recorder: recorder, width: width, height: height) ? existing : nil
        }
        guard let created = OutputAccumulator.create(
            recorder: recorder, outputId: output, width: width, height: height) else { return nil }
        accumulators[output] = created
        return created
    }

    private struct TextureReference {
        var role: TextureQuadRole
        var handle: TextureHandle
    }

    /// Collect every texture handle a plan references so they can be resolved
    /// before recording.
    private func referencedHandles(_ plan: FramePlan) -> [TextureReference] {
        var handles: [TextureReference] = []
        for op in plan.ops {
            switch op {
            case .textureQuad(let q):
                if let t = q.texture { handles.append(TextureReference(role: q.role, handle: t)) }
            case .shadowQuad(let q):
                if let t = q.texture { handles.append(TextureReference(role: .shadow, handle: t)) }
            case .fillQuad, .visualStyle, .backdrop: break
            }
        }
        return handles
    }

    /// Client surfaces actually sampled by this output's culled frame plan. Acquire
    /// fences for hidden, clipped, or other-output surfaces must not stall this queue.
    static func referencedClientSurfaceIDs(_ plan: FramePlan) -> [UInt64] {
        var ids = Set<UInt64>()
        for op in plan.ops {
            switch op {
            case .textureQuad(let quad):
                if quad.role == .content, let texture = quad.texture { ids.insert(texture.raw) }
            case .fillQuad, .visualStyle, .shadowQuad, .backdrop:
                break
            }
        }
        return ids.sorted()
    }

    private func producePaintTextures(
        plan: FramePlan,
        target: RenderTarget,
        resolvePaintContent: (PaintContentHandle) -> PaintContentStore.Content?,
        resolvePaintImage: (UInt64) -> nucleus.skia.Image?
    ) -> [UInt64: nucleus.skia.Image] {
        var resolved: [UInt64: nucleus.skia.Image] = [:]
        for op in plan.ops {
            guard case .textureQuad(let quad) = op,
                  quad.role == .paint,
                  let handle = quad.texture,
                  resolved[handle.raw] == nil,
                  let content = resolvePaintContent(PaintContentHandle(raw: handle.raw))
            else { continue }

            let produced = producer.producePaintCommands(
                recorder: recorder,
                layerId: quad.layerId,
                revision: handle.raw,
                commands: content.commands,
                payload: content.payload,
                authoredWidth: content.width,
                authoredHeight: content.height,
                contentWidth: pixelExtent(content.width * Float(target.fractionalScale)),
                contentHeight: pixelExtent(content.height * Float(target.fractionalScale)),
                localDamage: quad.localPaintDamage,
                resolveImage: resolvePaintImage,
                resolveEffect: resolvePaintEffect)
            if let produced, let image = registry.resolve(produced) {
                resolved[handle.raw] = image
            }
        }
        return resolved
    }

    private func produceShadowTextures(plan: FramePlan) -> [UInt64: nucleus.skia.Image] {
        var resolved: [UInt64: nucleus.skia.Image] = [:]
        for op in plan.ops {
            guard case .shadowQuad(let quad) = op,
                  let material = quad.material,
                  resolved[material.layerId] == nil
            else { continue }
            var color = nucleus.skia.Color()
            color.r = material.color.0
            color.g = material.color.1
            color.b = material.color.2
            color.a = material.color.3
            let decoration = ShadowDecoration(
                width: material.rasterWidth, height: material.rasterHeight,
                shapeRect: material.shapeRect, cornerRadii: material.cornerRadii,
                blurSigma: material.blurSigma, color: color)
            guard let handle = producer.produceShadow(
                recorder: recorder, layerId: material.layerId,
                revision: material.revision, shadow: decoration),
                let image = registry.resolve(handle)
            else { continue }
            resolved[material.layerId] = image
        }
        return resolved
    }

    private func pixelExtent(_ value: Float) -> Int32 {
        if !value.isFinite || value <= 1 { return 1 }
        let rounded = value.rounded(.up)
        if rounded >= Float(Int32.max) { return Int32.max }
        return Int32(rounded)
    }

    /// Per-frame WSI present parameters for the Vulkan swapchain path: the submit
    /// waits on `waitSemaphore`, signals `signalSemaphore`, and transitions the
    /// scanout image to `VK_IMAGE_LAYOUT_PRESENT_SRC_KHR` on `queueFamily`.
    struct PresentSubmit {
        var waitSemaphore: VkSemaphore?
        var signalSemaphore: VkSemaphore?
        var queueFamily: UInt32
    }

    struct DrmSubmit {
        var signalSemaphore: VkSemaphore
    }

    /// Every frame chooses one explicit asynchronous submission contract. Keeping
    /// offscreen work as a real case prevents a missing platform presenter from
    /// silently falling back to a CPU-synchronous Graphite submit.
    enum SubmissionMode {
        case swapchain(PresentSubmit)
        case drm(DrmSubmit)
        case offscreen
    }

    /// Render one frame for `target`'s output into `scanout`. `resolveContent`
    /// maps the emit's role-spaced texture handle to a GPU image; it is called
    /// only in the pre-resolve phase, never during recording or submit. When
    /// `submissionMode` makes the WSI, DRM, or offscreen completion contract
    /// explicit. All three paths submit asynchronously and advance `frameSerial`.
    /// Returns nil if the accumulator could not be prepared.
    func renderFrame(
        tree: LayerTree, target: RenderTarget, frame: FrameInfo,
        scanout: nucleus.skia.Surface,
        submissionMode: SubmissionMode,
        acquireWaitSemaphore: (UInt64) -> VkSemaphore? = { _ in nil },
        rootContexts: [ContextID] = [compositorContextId],
        lockContexts: Set<ContextID>? = nil,
        resolvePaintContent: (PaintContentHandle) -> PaintContentStore.Content?,
        resolvePaintImage: (UInt64) -> nucleus.skia.Image?,
        resolveContent: (TextureHandle) -> nucleus.skia.Image?
    ) -> FrameRenderResult? {
        let clock = ContinuousClock()
        let totalStart = clock.now
        var phaseStart = totalStart
        // Adopt finished decodes before anything reads the cache. This is the one
        // point in the frame where the decoded-image cache may be written, which
        // is what keeps it safe to leave unsynchronized.
        drainDecodedImages()
        let plan = PresentationWalk.buildFramePlan(
            tree: tree,
            target: target,
            frame: frame,
            rootContexts: rootContexts,
            lockContexts: lockContexts
        )
        let referencedSurfaceIDs = Self.referencedClientSurfaceIDs(plan)
        var acquiredSurfaceIDs: [UInt64] = []
        var frameAcquireWaits: [VkSemaphore] = []
        acquiredSurfaceIDs.reserveCapacity(referencedSurfaceIDs.count)
        frameAcquireWaits.reserveCapacity(referencedSurfaceIDs.count)
        for surfaceID in referencedSurfaceIDs {
            guard let semaphore = acquireWaitSemaphore(surfaceID) else { continue }
            acquiredSurfaceIDs.append(surfaceID)
            frameAcquireWaits.append(semaphore)
        }
        var timings = RenderFrameTimings()
        timings.planNs = elapsedNanoseconds(phaseStart, clock.now)

        // Pre-resolve all texture handles up front. `trackedResolve` flags if the
        // external resolver is ever called while recording — the pre-resolve here
        // runs before `recording` is set, so the flag must stay false.
        phaseStart = clock.now
        var resolved = producePaintTextures(
            plan: plan,
            target: target,
            resolvePaintContent: resolvePaintContent,
            resolvePaintImage: resolvePaintImage)
        let resolvedShadows = produceShadowTextures(plan: plan)
        func trackedResolve(_ handle: TextureHandle) -> nucleus.skia.Image? {
            if recording { sawCallbackWhileRecording = true }
            return resolveContent(handle)
        }
        for reference in referencedHandles(plan) where resolved[reference.handle.raw] == nil {
            if reference.role == .paint { continue }
            if let image = trackedResolve(reference.handle) { resolved[reference.handle.raw] = image }
        }
        timings.resolveNs = elapsedNanoseconds(phaseStart, clock.now)

        phaseStart = clock.now
        guard let accumulator = ensureAccumulator(
            output: target.outputId,
            width: Int32(target.pixelSize.width), height: Int32(target.pixelSize.height)) else { return nil }
        timings.accumulatorNs = elapsedNanoseconds(phaseStart, clock.now)

        phaseStart = clock.now
        let previous = previousLayerSnapshots[target.outputId]
        let damage = Self.planFrameDamage(
            plan: plan, previous: previous,
            forceFull: frame.fullDamage || accumulator.needsFullRedraw,
            width: target.pixelSize.width, height: target.pixelSize.height)
        plan.frame.fullDamage = damage.full
        plan.frame.damageBounds = damage.bounds.map(planRectFromDamageRect)
        for rect in damage.rects { plan.appendDamageRect(planRectFromDamageRect(rect)) }
        timings.damageNs = elapsedNanoseconds(phaseStart, clock.now)

        recording = true
        defer { recording = false }

        phaseStart = clock.now
        let canvas = accumulator.canvas
        let shouldComposite = damage.full || damage.bounds != nil
        if let bounds = damage.bounds, !damage.full {
            canvas.save()
            canvas.clipRect(NucleusRenderer.rectF(planRectFromDamageRect(bounds)), false)
        }
        if shouldComposite {
            var bg = nucleus.skia.Color()
            bg.a = 1  // opaque black
            canvas.clear(bg)
        }

        // Execute one ordered command stream. A backdrop snapshots exactly the
        // content preceding it, then later chrome/content naturally draws above.
        var drawn = 0
        var backdropDraws = 0
        for op in shouldComposite ? plan.ops : [] {
            if case .backdrop(let spec) = op {
                let source = accumulator.snapshotImage()
                backdropDraws += Backdrop.execute(
                    spec, liveSnapshot: source, prefix: source, onto: canvas)
            } else {
                drawn += NucleusRenderer.composite(
                    op: op, onto: canvas,
                    resolveTexture: { handle in resolved[handle.raw] },
                    resolveShadow: { layerId in resolvedShadows[layerId] })
            }
        }
        if damage.full { accumulator.markRedrawn() }
        if damage.bounds != nil, !damage.full { canvas.restore() }
        timings.compositeNs = elapsedNanoseconds(phaseStart, clock.now)

        // Present the composited accumulator into the scanout surface.
        phaseStart = clock.now
        let presented = accumulator.present(onto: scanout)
        timings.blitNs = elapsedNanoseconds(phaseStart, clock.now)
        guard presented else {
            timings.totalNs = elapsedNanoseconds(totalStart, clock.now)
            return FrameRenderResult(
                opsDrawn: drawn, backdropDraws: backdropDraws,
                presented: false, submitted: false,
                fullDamage: damage.full, damageRectCount: damage.rects.count,
                damagePixelCount: damage.bounds.map {
                    UInt64($0.width) * UInt64($0.height)
                } ?? 0,
                acquireWaitCount: frameAcquireWaits.count,
                acquiredSurfaceIDs: acquiredSurfaceIDs,
                referencedSurfaceIDs: referencedSurfaceIDs,
                callbackDuringRecord: sawCallbackWhileRecording,
                timings: timings)
        }

        // Submit is pure C++ — no Swift callback fires. The swapchain path submits
        // for presentation (acquire/present semaphores + PRESENT_SRC transition);
        // DRM signals an exportable semaphore that KMS waits on via IN_FENCE_FD.
        phaseStart = clock.now
        let recordingHandle = recorder.snapRecording()
        timings.frameSnapNs = elapsedNanoseconds(phaseStart, clock.now)
        phaseStart = clock.now
        let uploadRecording = uploadsStaged ? uploadRecorder.snapRecording() : nil
        timings.uploadSnapNs = elapsedNanoseconds(phaseStart, clock.now)
        let submitStatus: nucleus.skia.Status
        phaseStart = clock.now
        var waits: [UnsafeMutableRawPointer?] = frameAcquireWaits.map { UnsafeMutableRawPointer($0) }
        switch submissionMode {
        case .swapchain(let present):
            if let wait = present.waitSemaphore { waits.append(UnsafeMutableRawPointer(wait)) }
            let signal = present.signalSemaphore.map { UnsafeMutableRawPointer($0) }
            submitStatus = waits.withUnsafeBufferPointer { waits in
                if let uploadRecording, uploadRecording.isValid() {
                    return context.submitForPresentWithUpload(
                        scanout, uploadRecording, recordingHandle,
                        waits.baseAddress, waits.count, signal, present.queueFamily,
                        frame.frameSerial)
                }
                return context.submitForPresent(
                    scanout, recordingHandle, waits.baseAddress, waits.count,
                    signal, present.queueFamily, frame.frameSerial)
            }
        case .drm(let drmSubmit):
            let signal = UnsafeMutableRawPointer(drmSubmit.signalSemaphore)
            submitStatus = waits.withUnsafeBufferPointer { waits in
                if let uploadRecording, uploadRecording.isValid() {
                    return context.submitWithUploadAndSemaphores(
                        uploadRecording, recordingHandle, waits.baseAddress, waits.count,
                        signal, frame.frameSerial)
                }
                return context.submitWithSemaphores(
                    recordingHandle, waits.baseAddress, waits.count,
                    signal, frame.frameSerial)
            }
        case .offscreen:
            submitStatus = waits.withUnsafeBufferPointer { waits in
                if let uploadRecording, uploadRecording.isValid() {
                    return context.submitWithUploadAndSemaphores(
                        uploadRecording, recordingHandle, waits.baseAddress, waits.count,
                        nil, frame.frameSerial)
                }
                return context.submitWithSemaphores(
                    recordingHandle, waits.baseAddress, waits.count,
                    nil, frame.frameSerial)
            }
        }
        timings.submitNs = elapsedNanoseconds(phaseStart, clock.now)
        // A snapped recording cannot be replayed after insertion failure. Drop the
        // staged marker in every case; the surface's next commit can enqueue a new
        // generation while the last successfully registered texture stays visible.
        uploadsStaged = false

        let submitted = submitStatus == nucleus.skia.Status.ok
        if presented && submitted {
            submittedLayerSnapshots[target.outputId] = plan.layerSnapshots
        }
        timings.totalNs = elapsedNanoseconds(totalStart, clock.now)
        return FrameRenderResult(
            opsDrawn: drawn, backdropDraws: backdropDraws, presented: presented,
            submitted: submitted,
            fullDamage: damage.full, damageRectCount: damage.rects.count,
            damagePixelCount: damage.bounds.map {
                UInt64($0.width) * UInt64($0.height)
            } ?? 0,
            acquireWaitCount: frameAcquireWaits.count,
            acquiredSurfaceIDs: acquiredSurfaceIDs,
            referencedSurfaceIDs: referencedSurfaceIDs,
            callbackDuringRecord: sawCallbackWhileRecording,
            timings: timings)
    }

    struct FrameDamage {
        var rects: [PhysicalRect]
        var bounds: PhysicalRect?
        var full: Bool
    }

    static func planFrameDamage(
        plan: FramePlan, previous: [UInt64: LayerFrameSnapshot]?,
        forceFull: Bool, width: UInt32, height: UInt32
    ) -> FrameDamage {
        let fullRect = PhysicalRect(x: 0, y: 0, width: width, height: height)
        guard !forceFull, let previous else {
            return FrameDamage(rects: [fullRect], bounds: fullRect, full: true)
        }
        let accumulator = DamageAccumulator()
        let allIDs = Set(previous.keys).union(plan.layerSnapshots.keys)
        var structural = false
        for id in allIDs {
            let old = previous[id]
            let new = plan.layerSnapshots[id]
            structural = structural || old?.structural == true || new?.structural == true
            // A Wayland surface deliberately retains one stable texture handle
            // across buffer generations. Its geometry/signature can therefore be
            // unchanged while the sampled pixels are new; the render-model content
            // damage bit is the authoritative invalidation for that commit.
            if old != new || new?.contentDamaged == true {
                let canUseLocalizedContentDamage =
                    old?.rect == new?.rect
                        && old?.compositeSignature == new?.compositeSignature
                        && old?.structural == false
                        && new?.structural == false
                        && new?.contentDamaged == true
                if canUseLocalizedContentDamage,
                   let localized = new?.localizedContentDamage
                {
                    accumulator.addRect(localized)
                } else {
                    if let old { accumulator.addRect(old.rect) }
                    if let new { accumulator.addRect(new.rect) }
                }
            }
        }
        if structural {
            for snapshot in previous.values { accumulator.addRect(snapshot.rect) }
            for snapshot in plan.layerSnapshots.values { accumulator.addRect(snapshot.rect) }
        }
        let blurRegions: [PhysicalRect] = plan.ops.compactMap {
            guard case .backdrop(let spec) = $0 else { return nil }
            let rect = spec.region
            return PhysicalRect(
                x: Int32(rect.x.rounded(.down)), y: Int32(rect.y.rounded(.down)),
                width: UInt32(max(0, (rect.x + rect.w).rounded(.up) - rect.x.rounded(.down))),
                height: UInt32(max(0, (rect.y + rect.h).rounded(.up) - rect.y.rounded(.down))))
        }
        reconcileBackdropBlurDamage(accumulator, blurRegions)
        let rects = accumulator.rects.compactMap { clampDamageRectToTarget($0, width, height) }
        let bounds = DamageAccumulatorBounds.bounds(rects)
        let full = bounds.map { damageBoundsCoverTarget($0, width, height) } ?? false
        return FrameDamage(rects: full ? [fullRect] : rects, bounds: full ? fullRect : bounds, full: full)
    }
}

private enum DamageAccumulatorBounds {
    static func bounds(_ rects: [PhysicalRect]) -> PhysicalRect? {
        guard let first = rects.first else { return nil }
        var left = Int64(first.x), top = Int64(first.y)
        var right = left + Int64(first.width), bottom = top + Int64(first.height)
        for rect in rects.dropFirst() {
            left = min(left, Int64(rect.x)); top = min(top, Int64(rect.y))
            right = max(right, Int64(rect.x) + Int64(rect.width))
            bottom = max(bottom, Int64(rect.y) + Int64(rect.height))
        }
        return PhysicalRect(x: Int32(left), y: Int32(top),
                            width: UInt32(right - left), height: UInt32(bottom - top))
    }
}
