import Testing
@testable import NucleusRenderer
import VulkanC
import Vulkan
import NucleusSkiaGraphiteBridge
import NucleusRenderModel

// FramePlan op-vocabulary assembly is hardware-independent and asserts directly;
// rendering a FramePlan through NucleusRenderer into an offscreen Graphite target
// runs best-effort over a real device and asserts nothing hardware-conditional.
@Suite struct RendererModuleTests {
    @Test func framePlanAssembly() {
        // masked fill, a textured quad, and a shadow quad.
        let plan = FramePlan()
        plan.appendFillQuad(FillQuad(dst: PlanRect(x: 0, y: 0, w: 256, h: 128), color: (0.1, 0.1, 0.1, 1)))
        plan.appendFillQuad(FillQuad(
            dst: PlanRect(x: 20, y: 20, w: 80, h: 80),
            color: (1, 0, 0, 1),
            maskRRect: RRectMask(rect: PlanRect(x: 20, y: 20, w: 80, h: 80), radii: (16, 16, 16, 16))))
        plan.appendTextureQuad(TextureQuad(
            texture: TextureHandle(raw: 1),
            dst: PlanRect(x: 120, y: 20, w: 64, h: 64),
            src: PlanRect(x: 0, y: 0, w: 16, h: 16),
            alpha: 1))
        plan.appendShadowQuad(ShadowQuad(
            dst: PlanRect(x: 120, y: 90, w: 100, h: 24),
            src: PlanRect(x: 0, y: 0, w: 1, h: 1),
            alpha: 0.8))
        #expect(plan.ops.count == 4, "plan-op-count")

    }

    // Best-effort GPU: render FramePlans through the real Graphite path. Asserts
    // nothing hardware-conditional; verifies compile + link and headless safety.
    @Test(.disabled("requires a live GPU/Vulkan device")) func renderOffscreenBestEffort() {
        let plan = FramePlan()
        plan.appendFillQuad(FillQuad(dst: PlanRect(x: 0, y: 0, w: 256, h: 128), color: (0.1, 0.1, 0.1, 1)))
        plan.appendFillQuad(FillQuad(
            dst: PlanRect(x: 20, y: 20, w: 80, h: 80),
            color: (1, 0, 0, 1),
            maskRRect: RRectMask(rect: PlanRect(x: 20, y: 20, w: 80, h: 80), radii: (16, 16, 16, 16))))
        plan.appendTextureQuad(TextureQuad(
            texture: TextureHandle(raw: 1),
            dst: PlanRect(x: 120, y: 20, w: 64, h: 64),
            src: PlanRect(x: 0, y: 0, w: 16, h: 16),
            alpha: 1))
        plan.appendShadowQuad(ShadowQuad(
            dst: PlanRect(x: 120, y: 90, w: 100, h: 24),
            src: PlanRect(x: 0, y: 0, w: 1, h: 1),
            alpha: 0.8))

        let base = VK.loadBaseDispatch()
        let contract = VkRequirements.contract()
        guard let instance = InstanceOwner.create(
            base: base, applicationName: "NucleusCompositorRendererLinuxTests",
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

            // A 16×16 solid-green source image for the textured quad.
            var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
            for i in 0..<(16 * 16) {
                pixels[i * 4 + 0] = 0
                pixels[i * 4 + 1] = 255
                pixels[i * 4 + 2] = 0
                pixels[i * 4 + 3] = 255
            }
            let sourceImage = pixels.withUnsafeBufferPointer { buf in
                nucleus.skia.makeRasterImageRGBA(16, 16, buf.baseAddress, buf.count)
            }

            _ = NucleusRenderer.renderOffscreen(
                context: context, plan: plan, width: 256, height: 128,
                submissionSerial: 1,
                resolveTexture: { handle in handle.raw == 1 ? sourceImage : nil })

            // The richer composite: src-blend fill, a masked textured quad with a
            // source rect and a shadow with a resolvable texture. Each op type
            // lowers through the real path.
            let rich = FramePlan()
            rich.appendFillQuad(FillQuad(
                dst: PlanRect(x: 0, y: 0, w: 256, h: 128), color: (0.05, 0.05, 0.05, 1),
                blendMode: .src))
            rich.appendTextureQuad(TextureQuad(
                texture: TextureHandle(raw: 1),
                dst: PlanRect(x: 10, y: 10, w: 80, h: 80),
                src: PlanRect(x: 2, y: 2, w: 12, h: 12),
                alpha: 0.9, blendMode: .srcOver,
                maskRRect: RRectMask(rect: PlanRect(x: 10, y: 10, w: 80, h: 80), radii: (12, 12, 12, 12))))
            rich.appendShadowQuad(ShadowQuad(
                texture: TextureHandle(raw: 1),
                dst: PlanRect(x: 110, y: 20, w: 90, h: 30),
                src: PlanRect(x: 0, y: 0, w: 16, h: 16),
                alpha: 0.7))
            _ = NucleusRenderer.renderOffscreen(
                context: context, plan: rich, width: 256, height: 128,
                submissionSerial: 2,
                resolveTexture: { handle in handle.raw == 1 ? sourceImage : nil })
        }
    }
}
