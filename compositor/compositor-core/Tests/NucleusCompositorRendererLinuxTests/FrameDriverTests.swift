import Testing
import VulkanC
import Vulkan
import NucleusSkiaGraphiteBridge
import NucleusRenderModel
@testable import NucleusRenderer

struct RendererTestWakeSink: AsyncRenderWakeSink {
    nonisolated func signalRenderWork() {}
}

// Converted from FrameDriverFixture (Phase 10b.4k): the FrameDemand render
// predicate (hardware-independent) + the end-to-end top-level frame — walk →
// pre-resolve → composite → backdrop → present → submit — over a real Graphite
// context (best-effort GPU, asserts nothing hardware-conditional).
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

        ledger.acknowledge(1, treeRevision: 7, lockGeneration: 3)
        #expect(!ledger.needsTreeRevision(7, outputID: 1))
        #expect(ledger.needsTreeRevision(7, outputID: 2))
        #expect(!ledger.allPresented([1, 2], treeRevision: 7))
        #expect(!ledger.needsLockGeneration(3, outputID: 1))
        #expect(ledger.needsLockGeneration(3, outputID: 2))

        ledger.acknowledge(2, treeRevision: 7, lockGeneration: 3)
        #expect(ledger.allPresented([1, 2], treeRevision: 7))
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
        #expect(FrameDriver.referencedClientSurfaceIDs(plan) == [41])
    }

    static func layer(_ id: UInt64, kind: LayerKind = .container,
                      x: Float, y: Float, w: Float, h: Float) -> Layer {
        var l = Layer(id: id, kind: kind)
        l.model.properties.position = Point2D(x: x, y: y)
        l.model.properties.bounds = Bounds(w: w, h: h)
        l.model.properties.anchorPoint = Point2D(x: 0, y: 0)
        return l
    }

    // Best-effort GPU: end-to-end frame. Hardware-gated, so it asserts nothing
    // hardware-conditional.
    @Test(.disabled("requires a live GPU/Vulkan device")) func endToEndFrameBestEffort() {
        // Build a tree: a backdrop root with an external-content child + a paint
        // content layer.
        var tree = LayerTree()
        var backdropRoot = Self.layer(1, x: 0, y: 0, w: 200, h: 200)
        backdropRoot.backdropAttachment = BackdropAttachment(
            materialRole: .default, blendingMode: .behindWindow, state: .active,
            appearance: .auto, emphasized: false, mask: .none, shape: .rect((0, 0, 200, 200)))
        backdropRoot.children = [2]
        tree.insertLayer(backdropRoot)
        var contentChild = Self.layer(2, x: 10, y: 10, w: 100, h: 100)
        contentChild.presentation.content = .external(IOSurfaceID(raw: 5))
        tree.insertLayer(contentChild)
        var painted = Self.layer(3, x: 120, y: 20, w: 80, h: 80)
        painted.presentation.content = .paint(PaintContentHandle(raw: 9))
        tree.insertLayer(painted)
        tree.contextRoots[compositorContextId] = [1, 3]

        let target = RenderTarget(
            outputId: 1,
            logicalRect: LogicalRect(x: 0, y: 0, width: 200, height: 200),
            pixelSize: PixelSize(width: 400, height: 400),
            scale: 1, fractionalScale: 2, overlayUsableArea: UsableArea())

        let base = VK.loadBaseDispatch()
        let contract = VkRequirements.contract()
        guard let instance = InstanceOwner.create(
            base: base, applicationName: "FrameDriverTests",
            contract: contract, enableValidation: false
        ) else { return }
        guard let selection = DeviceOwner.selectPhysicalDevice(
            instance: instance.handle, dispatch: instance.dispatch, contract: contract
        ) else { return }
        guard let device = DeviceOwner.create(
            selection: selection, instanceDispatch: instance.dispatch,
            contract: contract
        ) else { return }
        guard let queue = device.queue(family: selection.graphicsQueueFamily) else { return }

        withCStringArray(contract.deviceExtensions) { extPtr, extCount in
            var desc = nucleus.skia.VulkanContextDescriptor()
            desc.instance = UnsafeMutableRawPointer(instance.handle)
            desc.physicalDevice = UnsafeMutableRawPointer(selection.physicalDevice)
            desc.device = UnsafeMutableRawPointer(device.handle)
            desc.queue = UnsafeMutableRawPointer(queue)
            desc.graphicsQueueIndex = selection.graphicsQueueFamily
            desc.maxApiVersion = VkRequirements.minimumApiVersion.raw
            desc.deviceExtensions = extPtr
            desc.deviceExtensionCount = extCount

            let context = nucleus.skia.makeGraphiteVulkanContext(desc)
            guard context.isValid() else { return }
            guard let driver = FrameDriver(
                context: context,
                resourceHost: SwiftResourceHost(),
                wakeSink: RendererTestWakeSink())
            else { return }

            // A small green source image stands in for resolved content.
            var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
            for i in 0..<(16 * 16) { pixels[i * 4 + 1] = 255; pixels[i * 4 + 3] = 255 }
            let source = pixels.withUnsafeBufferPointer {
                nucleus.skia.makeRasterImageRGBA(16, 16, $0.baseAddress, $0.count)
            }

            let scanout = driver.recorder.makeOffscreenSurface(400, 400)

            var resolveCalls = 0
            let result = driver.renderFrame(
                tree: tree, target: target, frame: FrameInfo(outputId: 1), scanout: scanout,
                submissionMode: .offscreen,
                resolvePaintContent: { handle in
                    handle.raw == 9
                        ? PaintContentStore.Content(commands: [
                            PaintDrawCommand(
                                kind: .rect, x: 0, y: 0, w: 80, h: 80,
                                color: (0.8, 0.1, 0.1, 1)),
                            PaintDrawCommand(
                                kind: .image, x: 8, y: 8, w: 16, h: 16,
                                imageHandle: 88),
                        ], width: 80, height: 80)
                        : nil
                },
                resolvePaintImage: { handle in
                    handle == 88 ? source : nil
                }
            ) { _ in
                resolveCalls += 1
                return source
            }
            guard result != nil else { driver.shutdown(); return }
            _ = driver.producer.drainStats()

            // A second frame reuses the persistent accumulator (no re-create).
            _ = driver.renderFrame(
                tree: tree, target: target, frame: FrameInfo(outputId: 1), scanout: scanout,
                submissionMode: .offscreen,
                resolvePaintContent: { _ in
                    PaintContentStore.Content(commands: [
                        PaintDrawCommand(
                            kind: .rect, x: 0, y: 0, w: 80, h: 80,
                            color: (0.8, 0.1, 0.1, 1)),
                        PaintDrawCommand(kind: .image, x: 8, y: 8, w: 16, h: 16, imageHandle: 88),
                    ], width: 80, height: 80)
                },
                resolvePaintImage: { handle in
                    handle == 88 ? source : nil
                }
            ) { _ in source }
            _ = driver.producer.drainStats()

            driver.shutdown()
        }
    }
}
