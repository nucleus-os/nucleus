import Testing
import VulkanC
import Vulkan
import NucleusSkiaGraphiteBridge
import NucleusRenderModel
@testable import NucleusRenderer

struct RendererTestWakeSink: AsyncRenderWakeSink {
    nonisolated func signalRenderWork() {}
}

@MainActor
final class TestFrameResourceResolver: FrameResourceResolver {
    var paintContents: [PaintContentHandle: PaintContentStore.Content] = [:]
    var paintImages: [UInt64: nucleus.skia.Image] = [:]
    var textures: [PlanTextureReference: nucleus.skia.Image] = [:]
    var paintImageCalls: [UInt64] = []
    var textureCalls: [PlanTextureReference] = []

    func acquireWaitSemaphore(
        forClientSurfaceID surfaceID: UInt64
    ) -> VkSemaphore? {
        nil
    }

    func paintContent(
        for handle: PaintContentHandle
    ) -> PaintContentStore.Content? {
        paintContents[handle]
    }

    func paintImage(
        for handle: UInt64,
        outputID: UInt64
    ) -> nucleus.skia.Image? {
        paintImageCalls.append(handle)
        return paintImages[handle]
    }

    func texture(
        for reference: PlanTextureReference
    ) -> nucleus.skia.Image? {
        textureCalls.append(reference)
        return textures[reference]
    }
}

// predicate (hardware-independent) + the end-to-end top-level frame — walk →
// pre-resolve → composite → backdrop → present → submit — over a real Graphite
// context in the mandatory headless Graphite lane.
@Suite struct FrameDriverTests {
    @Test func frameDemandPredicate() {
        #expect(!FrameDemand().shouldRenderThisVblank, "demand-idle-false")
        #expect(FrameDemand(continuousActive: true).shouldRenderThisVblank, "demand-continuous")
        #expect(FrameDemand(frameDue: true).shouldRenderThisVblank, "demand-frame-due")
        #expect(FrameDemand(workPlausible: true).shouldRenderThisVblank, "demand-work-plausible")
    }

    @Test func outputRenderGateTreatsCursorAndInitialFrameAsIndependentDemand() {
        #expect(!RenderCore.shouldRenderOutput(
            hasPendingDamage: false, forced: false,
            wantsPresent: false, needsInitialFrame: false))
        #expect(RenderCore.shouldRenderOutput(
            hasPendingDamage: false, forced: false,
            wantsPresent: true, needsInitialFrame: false))
        #expect(RenderCore.shouldRenderOutput(
            hasPendingDamage: false, forced: false,
            wantsPresent: false, needsInitialFrame: true))
    }

    @Test func presentationRevisionsAreAcknowledgedPerOutput() {
        var ledger = OutputPresentationLedger()
        ledger.attach(1)
        ledger.attach(2)
        #expect(ledger.needsTreeRevision(7, outputID: 1))
        #expect(ledger.needsTreeRevision(7, outputID: 2))
        #expect(ledger.needsResourceGeneration(5, outputID: 1))
        #expect(ledger.needsResourceGeneration(5, outputID: 2))

        ledger.acknowledge(1, treeRevision: 7, lockGeneration: 3, resourceGeneration: 5)
        #expect(!ledger.needsTreeRevision(7, outputID: 1))
        #expect(ledger.needsTreeRevision(7, outputID: 2))
        #expect(!ledger.allPresented([1, 2], treeRevision: 7))
        #expect(!ledger.needsLockGeneration(3, outputID: 1))
        #expect(ledger.needsLockGeneration(3, outputID: 2))
        #expect(!ledger.needsResourceGeneration(5, outputID: 1))
        #expect(ledger.needsResourceGeneration(5, outputID: 2))

        ledger.acknowledge(2, treeRevision: 7, lockGeneration: 3, resourceGeneration: 5)
        #expect(ledger.allPresented([1, 2], treeRevision: 7))
        #expect(!ledger.needsResourceGeneration(5, outputID: 2))
    }

    @Test func retainedDamageTracksOldAndNewPerOutputFootprints() {
        let old = LayerFrameSnapshot(
            rect: PhysicalRect(x: 10, y: 10, width: 20, height: 20),
            visualSignature: 1, structural: false)
        let moved = LayerFrameSnapshot(
            rect: PhysicalRect(x: 30, y: 10, width: 20, height: 20),
            visualSignature: 2, structural: false)

        let initialPlan = FramePlan()
        initialPlan.recordLayerSnapshot(7, old)
        let initial = FrameDriver.planFrameDamage(
            plan: initialPlan, previous: nil, forceFull: false, width: 100, height: 100)
        #expect(initial.full && initial.bounds == PhysicalRect(x: 0, y: 0, width: 100, height: 100))

        let unchanged = FrameDriver.planFrameDamage(
            plan: initialPlan, previous: [7: old], forceFull: false, width: 100, height: 100)
        #expect(!unchanged.full && unchanged.bounds == nil)

        let movedPlan = FramePlan()
        movedPlan.recordLayerSnapshot(7, moved)
        let changed = FrameDriver.planFrameDamage(
            plan: movedPlan, previous: [7: old], forceFull: false, width: 100, height: 100)
        #expect(!changed.full)
        #expect(changed.bounds == PhysicalRect(x: 10, y: 10, width: 40, height: 20))

        let otherOutput = FrameDriver.planFrameDamage(
            plan: initialPlan, previous: [7: old], forceFull: false, width: 200, height: 100)
        #expect(otherOutput.bounds == nil, "another output's unchanged snapshot remains independent")
    }

    @Test func acquireWaitsIncludeOnlyClientSurfacesSampledByThePlan() {
        let plan = FramePlan()
        plan.appendTextureQuad(TextureQuad(
            role: .content, texture: TextureHandle(raw: 41),
            dst: PlanRect(x: 0, y: 0, w: 10, h: 10),
            src: PlanRect(x: 0, y: 0, w: 10, h: 10), alpha: 1))
        plan.appendTextureQuad(TextureQuad(
            role: .paint, texture: TextureHandle(raw: 99),
            dst: PlanRect(x: 0, y: 0, w: 10, h: 10),
            src: PlanRect(x: 0, y: 0, w: 10, h: 10), alpha: 1))
        plan.appendTextureQuad(TextureQuad(
            role: .content, texture: TextureHandle(raw: 7),
            dst: PlanRect(x: 0, y: 0, w: 10, h: 10),
            src: PlanRect(x: 0, y: 0, w: 10, h: 10), alpha: 1))
        plan.appendTextureQuad(TextureQuad(
            role: .content, texture: TextureHandle(raw: 41),
            dst: PlanRect(x: 0, y: 0, w: 10, h: 10),
            src: PlanRect(x: 0, y: 0, w: 10, h: 10), alpha: 1))
        #expect(plan.resourceSummary.clientSurfaceIDs == [41, 7])
    }

    @Test func textureResolutionKeepsEqualRawHandlesDistinctByRole() {
        let plan = FramePlan()
        plan.appendTextureQuad(TextureQuad(
            role: .content, texture: TextureHandle(raw: 1),
            dst: PlanRect(x: 0, y: 0, w: 10, h: 10),
            src: PlanRect(x: 0, y: 0, w: 10, h: 10), alpha: 1))
        plan.appendTextureQuad(TextureQuad(
            role: .paint, texture: TextureHandle(raw: 1),
            dst: PlanRect(x: 0, y: 0, w: 10, h: 10),
            src: PlanRect(x: 0, y: 0, w: 10, h: 10), alpha: 1))

        let references = plan.resourceSummary.textureReferences
        #expect(references.count == 2)
        #expect(Set(references) == [
            PlanTextureReference(
                role: .content, handle: TextureHandle(raw: 1)),
            PlanTextureReference(
                role: .paint, handle: TextureHandle(raw: 1)),
        ])
    }

    @Test @MainActor
    func missingTextureIsResolvedOncePerFrame() {
        let plan = FramePlan()
        let reference = PlanTextureReference(
            role: .content,
            handle: TextureHandle(raw: 7))
        for layerID in 1...3 {
            plan.appendTextureQuad(TextureQuad(
                layerId: UInt64(layerID),
                role: reference.role,
                texture: reference.handle,
                dst: PlanRect(x: 0, y: 0, w: 10, h: 10),
                src: PlanRect(x: 0, y: 0, w: 10, h: 10),
                alpha: 1))
        }
        let resolver = TestFrameResourceResolver()
        var resolved: [PlanTextureReference: nucleus.skia.Image] = [:]

        FrameDriver.resolveGenericTextures(
            summary: plan.resourceSummary,
            resolver: resolver,
            into: &resolved)

        #expect(resolver.textureCalls == [reference])
        #expect(resolved.isEmpty)
    }

    @Test @MainActor
    func missingPaintImageIsResolvedOnceAcrossPaintRequests() {
        let resolver = TestFrameResourceResolver()
        var attempted: Set<UInt64> = []
        var resolved: [UInt64: nucleus.skia.Image] = [:]

        _ = FrameDriver.resolvePaintImages(
            [88, 99],
            outputID: 1,
            resolver: resolver,
            attempted: &attempted,
            resolved: &resolved)
        _ = FrameDriver.resolvePaintImages(
            [88],
            outputID: 1,
            resolver: resolver,
            attempted: &attempted,
            resolved: &resolved)

        #expect(resolver.paintImageCalls == [88, 99])
        #expect(resolved.isEmpty)
    }

    @Test
    func backdropDamageUsesTheFinalResourceSummary() {
        let old = LayerFrameSnapshot(
            rect: PhysicalRect(x: 45, y: 45, width: 2, height: 2),
            visualSignature: 1,
            structural: false)
        let changed = LayerFrameSnapshot(
            rect: old.rect,
            visualSignature: 2,
            structural: false)
        let plan = FramePlan()
        plan.recordLayerSnapshot(1, changed)
        plan.appendBackdropExecSpec(ExecSpec(
            layerId: 2,
            groupId: 2,
            region: PlanRect(x: 40, y: 40, w: 20, h: 20),
            shape: .rect((0, 0, 20, 20)),
            mask: .none))

        let damage = FrameDriver.planFrameDamage(
            plan: plan,
            previous: [1: old],
            forceFull: false,
            width: 100,
            height: 100)

        #expect(damage.bounds == PhysicalRect(
            x: 40,
            y: 40,
            width: 20,
            height: 20))
    }

    static func layer(_ id: UInt64, kind: LayerKind = .container,
                      x: Float, y: Float, w: Float, h: Float) -> LayerCreated {
        LayerCreated(
            nodeId: id,
            kind: kind,
            position: Point2D(x: x, y: y),
            anchorPoint: Point2D(x: 0, y: 0),
            bounds: Bounds(w: w, h: h))
    }

    @Test @MainActor
    func gpuHeadless_endToEndFrame() throws {
        // Build a tree: a backdrop root with an external-content child + a paint
        // content layer.
        var tree = LayerTree()
        var backdropRoot = Self.layer(1, x: 0, y: 0, w: 200, h: 200)
        backdropRoot.backdropAttachment = BackdropAttachment(
            materialRole: .default, blendingMode: .behindWindow, state: .active,
            appearance: .auto, emphasized: false, mask: .none, shape: .rect((0, 0, 200, 200)))
        var contentChild = Self.layer(2, x: 10, y: 10, w: 100, h: 100)
        contentChild.initialContent = .external(IOSurfaceID(raw: 5))
        var painted = Self.layer(3, x: 120, y: 20, w: 80, h: 80)
        painted.initialContent = .paint(PaintContentHandle(raw: 9))
        var transaction = Transaction(contextId: compositorContextId)
        transaction.created = [backdropRoot, contentChild, painted]
        transaction.inserted = [
            LayerInserted(nodeId: 1, parentId: 0, index: 0),
            LayerInserted(nodeId: 2, parentId: 1, index: 0),
            LayerInserted(nodeId: 3, parentId: 0, index: 1),
        ]
        guard case .success = TransactionApplier.apply(
            transaction,
            to: &tree)
        else {
            Issue.record("end-to-end frame tree setup was rejected")
            return
        }

        let target = RenderTarget(
            outputId: 1,
            logicalRect: LogicalRect(x: 0, y: 0, width: 200, height: 200),
            pixelSize: PixelSize(width: 400, height: 400),
            scale: 1, fractionalScale: 2, overlayUsableArea: UsableArea())

        try withRequiredVulkanGraphite(
            presentation: .headless,
            applicationName: "FrameDriverTests"
        ) { _, _, context, _ in
            let driver = try requireValue(
                FrameDriver(
                    context: context,
                    resourceHost: SwiftResourceHost(),
                    wakeSink: RendererTestWakeSink()),
                "could not create the frame driver")
            defer { driver.shutdown() }

            // A small green source image stands in for resolved content.
            var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
            for i in 0..<(16 * 16) { pixels[i * 4 + 1] = 255; pixels[i * 4 + 3] = 255 }
            let decodedSource = pixels.withUnsafeBufferPointer {
                nucleus.skia.makeRasterImageRGBA(16, 16, $0.baseAddress, $0.count)
            }
            let source = driver.recorder.makeTextureImage(decodedSource)

            let scanout = driver.recorder.makeOffscreenSurface(400, 400)

            let resolver = TestFrameResourceResolver()
            resolver.paintContents[PaintContentHandle(raw: 9)] =
                PaintContentStore.Content(commands: [
                    PaintDrawCommand(
                        kind: .rect, x: 0, y: 0, w: 80, h: 80,
                        color: (0.8, 0.1, 0.1, 1)),
                    PaintDrawCommand(
                        kind: .image, x: 8, y: 8, w: 16, h: 16,
                        imageHandle: 88),
                ], width: 80, height: 80)
            resolver.paintImages[88] = source
            resolver.textures[PlanTextureReference(
                role: .content,
                handle: TextureHandle(raw: 5))] = source

            var resolveCalls = 0
            let firstRequest = FrameDriver.FrameRenderRequest(
                tree: tree,
                target: target,
                frame: FrameInfo(outputId: 1, frameSerial: 1),
                scanout: scanout,
                submissionMode: .offscreen)
            let result = try requireValue(
                driver.renderFrame(
                    firstRequest,
                    resolver: resolver),
                "first end-to-end frame failed")
            resolveCalls += resolver.textureCalls.count
            #expect(result.presented)
            #expect(result.submitted)
            _ = driver.producer.drainStats()

            // A second frame reuses the persistent accumulator (no re-create).
            resolver.textureCalls.removeAll()
            let secondRequest = FrameDriver.FrameRenderRequest(
                tree: tree,
                target: target,
                frame: FrameInfo(outputId: 1, frameSerial: 2),
                scanout: scanout,
                submissionMode: .offscreen)
            let second = try requireValue(
                driver.renderFrame(
                    secondRequest,
                    resolver: resolver),
                "second end-to-end frame failed")
            resolveCalls += resolver.textureCalls.count
            _ = driver.producer.drainStats()

            #expect(resolveCalls == 2)
            #expect(second.presented)
            #expect(second.submitted)
            try requireTrue(
                waitForGraphiteSerial(
                    context: context,
                    serial: secondRequest.frame.frameSerial),
                "frame driver submissions did not complete")
        }
    }

    @Test @MainActor
    func gpuHeadless_abandonedUploadPreservesResidentPixels() throws {
        try withRequiredVulkanGraphite(
            presentation: .headless,
            applicationName: "FrameDriver upload rollback"
        ) { _, _, context, _ in
            let driver = try requireValue(
                FrameDriver(
                    context: context,
                    resourceHost: SwiftResourceHost(),
                    wakeSink: RendererTestWakeSink()),
                "could not create the frame driver")
            defer { driver.shutdown() }

            let green: [UInt8] = [UInt8](repeating: 0, count: 16).enumerated().map {
                switch $0.offset % 4 {
                case 1, 3: 255
                default: 0
                }
            }
            let texture = try requireValue(
                driver.stageClientUpload(
                    replacing: nil,
                    pixels: green,
                    width: 2,
                    height: 2),
                "initial upload failed")
            let image = texture.image()
            let initialTarget = driver.recorder.makeOffscreenSurface(2, 2)
            var rect = nucleus.skia.RectF()
            rect.width = 2
            rect.height = 2
            initialTarget.getCanvas().drawImage(image, rect, 1)
            let initialResult = driver.submitImmediate(
                driver.recorder.snapRecording(),
                waitSemaphores: [],
                submissionSerial: 1)
            try requireTrue(initialResult.isOk(), "initial upload submission failed")
            try requireTrue(
                waitForGraphiteSerial(context: context, serial: 1),
                "initial upload did not complete")

            var red = [UInt8](repeating: 0, count: 16)
            for index in stride(from: 0, to: red.count, by: 4) {
                red[index] = 255
                red[index + 3] = 255
            }
            _ = try requireValue(
                driver.stageClientUpload(
                    replacing: texture,
                    pixels: red,
                    width: 2,
                    height: 2),
                "replacement upload failed")
            driver.abandonSubmissionScope()

            let verificationTarget =
                driver.recorder.makeOffscreenSurface(2, 2)
            verificationTarget.getCanvas().drawImage(image, rect, 1)
            let verificationResult = driver.submitImmediate(
                driver.recorder.snapRecording(),
                waitSemaphores: [],
                submissionSerial: 2)
            try requireTrue(
                verificationResult.isOk(),
                "verification submission failed")
            try requireTrue(
                waitForGraphiteSerial(context: context, serial: 2),
                "verification submission did not complete")
            let pixels = try requireValue(
                readGraphiteSurfaceRGBA(
                    context: context,
                    surface: verificationTarget),
                "verification readback failed")
            #expect(Array(pixels.prefix(4)) == [0, 255, 0, 255])
            #expect(context.completedSubmissionTimingCount() == 0)
        }
    }
}
