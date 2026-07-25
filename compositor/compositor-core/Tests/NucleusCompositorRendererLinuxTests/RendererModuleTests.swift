import Testing
@testable import NucleusRenderer
import VulkanC
import Vulkan
import NucleusSkiaGraphiteBridge
import NucleusRenderModel

// FramePlan op-vocabulary assembly is hardware-independent and asserts directly;
// rendering a FramePlan through NucleusRenderer into an offscreen Graphite target
// runs in the mandatory headless Graphite lane.
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

    @Test func gpuHeadless_renderOffscreen() throws {
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

        try withRequiredVulkanGraphite(
            presentation: .headless,
            applicationName: "NucleusCompositorRendererLinuxTests"
        ) { _, _, context, recorder in
            // A 16×16 solid-green source image for the textured quad.
            var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
            for i in 0..<(16 * 16) {
                pixels[i * 4 + 0] = 0
                pixels[i * 4 + 1] = 255
                pixels[i * 4 + 2] = 0
                pixels[i * 4 + 3] = 255
            }
            let decodedSource = pixels.withUnsafeBufferPointer { buf in
                nucleus.skia.makeRasterImageRGBA(16, 16, buf.baseAddress, buf.count)
            }
            let sourceImage = recorder.makeTextureImage(decodedSource)
            try requireTrue(sourceImage.isValid(), "texture upload image is invalid")
            try requireTrue(
                submitGraphiteAndWait(
                    context: context,
                    recording: recorder.snapRecording(),
                    serial: 1),
                "texture upload submission did not complete")

            let basic = try requireValue(
                FramePlanRenderer.renderOffscreen(
                    context: context, plan: plan, width: 256, height: 128,
                    submissionSerial: 2,
                    resolveTexture: {
                        $0.handle.raw == 1 ? sourceImage : nil
                    }),
                "basic offscreen render failed")
            #expect(basic.imageWidth == 256)
            #expect(basic.imageHeight == 128)
            #expect(basic.opsDrawn == 3)
            #expect(basic.submitOk)

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
            let result = try requireValue(
                FramePlanRenderer.renderOffscreen(
                    context: context, plan: rich, width: 256, height: 128,
                    submissionSerial: 3,
                    resolveTexture: {
                        $0.handle.raw == 1 ? sourceImage : nil
                    }),
                "rich offscreen render failed")
            #expect(result.opsDrawn == 3)
            #expect(result.submitOk)
            try requireTrue(
                waitForGraphiteSerial(context: context, serial: 3),
                "offscreen submissions did not complete")
        }
    }
}
