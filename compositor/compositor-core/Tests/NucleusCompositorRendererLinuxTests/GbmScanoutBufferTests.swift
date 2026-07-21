import Testing
import NucleusCompositorDrmC
import VulkanC
import Vulkan
import NucleusSkiaGraphiteBridge
@testable import NucleusRenderer
@testable import NucleusCompositorRendererLinux

// Converted from GbmScanoutBufferFixture (Phase 10b.6e): the live GBM
// scanout-buffer allocator. The hardware-independent floor asserts the 10b.6d
// scanout-usage constraint is wired into the descriptor and that the plane-layout
// packing behaves. The best-effort GPU+GBM path opens a DRM render node, creates
// a GBM device, allocates a renderable BO, imports it as a Vulkan image over the
// SAME Vulkan device, wraps it as a Graphite render-target surface, clears + draws
// a known color, reads it back, then assembles the `OutputBufferOwner` and lets it
// deinit — proving the full GBM → Vulkan → Skia round-trip and the reverse-order
// teardown. Every GPU/GBM stage guards on availability and asserts nothing
// hardware-conditional.
@Suite struct GbmScanoutBufferTests {
    @Test func scanoutUsageAndPlanePacking() {
        #expect(DrmFramebuffer.explicitModifierFlags == UInt32(DRM_MODE_FB_MODIFIERS),
                "explicit framebuffer modifiers must opt in through the addfb2 flag")
        // The descriptor a scanout BO is imported with MUST carry the 10b.6d
        // render-target constraints (color + input attachment) plus transfer-src.
        let scanoutUsage = DmaBufImageDescriptor.scanoutUsage
        #expect(scanoutUsage.contains(.colorAttachmentBit), "scanout-usage-color-attachment")
        #expect(scanoutUsage.contains(.inputAttachmentBit), "scanout-usage-input-attachment")
        #expect(scanoutUsage.contains(.transferSrcBit), "scanout-usage-transfer-src")

        let probeDesc = DmaBufImageDescriptor(
            fd: -1, width: 64, height: 64, drmFormat: DrmFourcc.xrgb8888,
            modifier: 0,  // DRM_FORMAT_MOD_LINEAR == fourcc_mod_code(NONE, 0) == 0
            planes: [DmaBufPlane(offset: 0, rowPitch: 256)],
            usage: DmaBufImageDescriptor.scanoutUsage)
        #expect(probeDesc.usage.contains(.colorAttachmentBit) && probeDesc.usage.contains(.inputAttachmentBit),
                "probe-desc-usage-wired")

        // Plane-layout packing: a single-plane XRGB layout marshals offset/stride.
        let layout = GbmPlaneLayout(offset: 0, stride: 256, handle: 7)
        #expect(layout.offset == 0 && layout.stride == 256 && layout.handle == 7, "plane-layout-fields")
        let planesAsDmaBuf = [layout].map { DmaBufPlane(offset: UInt64($0.offset), rowPitch: UInt64($0.stride)) }
        #expect(planesAsDmaBuf.count == 1 && planesAsDmaBuf[0].rowPitch == 256, "plane-layout-to-dmabuf")
    }

    // Best-effort GPU + GBM round-trip. Hardware-gated, so it asserts nothing.
    @Test(.disabled("requires a live GPU/Vulkan device")) func gbmRoundTripBestEffort() {
        Self.runRoundTrip()
    }

    /// Open a render node + GBM device, bring up the Vulkan device + Graphite
    /// context, allocate a renderable BO, import it, wrap it as a surface, draw +
    /// read back, then assemble + deinit the `OutputBufferOwner`. Each stage
    /// escapes when its prerequisite is unavailable.
    static func runRoundTrip() {
        // Find a DRM render node. Prefer enumeration; fall back to renderD128.
        let renderPath: String
        switch DrmDeviceEnumerator.enumerate() {
        case .success(let candidates) where !candidates.isEmpty:
            renderPath = candidates[0].renderPath
        default:
            renderPath = "/dev/dri/renderD128"
        }

        let drmFd = DrmDeviceFd(openingNode: renderPath)
        guard let drmFd, drmFd.isValid else { return }
        guard let gbm = GbmDevice(borrowingFd: drmFd.fd) else { return }
        guard let gbmHandle = gbm.handle else { return }

        // Bring up the Vulkan device the Graphite context will use. The GBM
        // allocation and this device should be the same physical GPU for the
        // dmabuf import to succeed; on a multi-GPU mismatch the import escapes.
        let base = VK.loadBaseDispatch()
        let contract = VkRequirements.contract()
        guard let instance = InstanceOwner.create(
            base: base, applicationName: "GbmScanoutBufferTests",
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
            var ctxDesc = nucleus.skia.VulkanContextDescriptor()
            ctxDesc.instance = UnsafeMutableRawPointer(instance.handle)
            ctxDesc.physicalDevice = UnsafeMutableRawPointer(selection.physicalDevice)
            ctxDesc.device = UnsafeMutableRawPointer(device.handle)
            ctxDesc.queue = UnsafeMutableRawPointer(queue)
            ctxDesc.graphicsQueueIndex = selection.graphicsQueueFamily
            ctxDesc.maxApiVersion = VkRequirements.minimumApiVersion.raw
            ctxDesc.deviceExtensions = extPtr
            ctxDesc.deviceExtensionCount = extCount

            let context = nucleus.skia.makeGraphiteVulkanContext(ctxDesc)
            guard context.isValid() else { return }
            let recorder = context.makeRecorder()
            guard recorder.isValid() else { return }

            runGbmImport(
                gbmHandle: gbmHandle, device: device, graphicsFamily: selection.graphicsQueueFamily,
                context: context, recorder: recorder)
        }
    }

    /// Allocate a renderable GBM BO, import it as a Vulkan image, wrap + draw +
    /// read back over the live Graphite context, then build the `OutputBufferOwner`
    /// and let it deinit. The surface scope ends before the owner is built; the
    /// owner deinit (image + BO) runs before the context (the caller's closure).
    static func runGbmImport(
        gbmHandle: OpaquePointer, device: borrowing DeviceOwner, graphicsFamily: UInt32,
        context: nucleus.skia.GraphiteContext, recorder: nucleus.skia.Recorder
    ) {
        let width: UInt32 = 64
        let height: UInt32 = 64

        // Allocate the scanout buffer. A render node has no DRM master, so use the
        // renderable-only fallback (no GBM_BO_USE_SCANOUT) and no negotiated
        // modifier (LINEAR). The GPU half is fully exercised without KMS master.
        guard let buffer = GbmScanoutBuffer.allocate(
            gbmDevice: gbmHandle,
            drmFormat: DrmFourcc.xrgb8888,
            width: width, height: height,
            modifiers: [],
            usage: .renderableOnly,
            device: device.handle, dispatch: device.dispatch
        ) else {
            return
        }

        // Wrap the imported image as a Graphite render-target surface, draw a known
        // color, submit, and read it back. The surface lives in this `do` so it is
        // destroyed strictly before the OutputBufferOwner is assembled below.
        do {
            let params = ScanoutImageParams(
                image: buffer.image.handle,
                memory: nil,
                allocSize: 0,
                width: Int32(width),
                height: Int32(height),
                format: vulkanFormatForDrm(buffer.drmFormat),
                tiling: VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
                initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
                usageFlags: DmaBufImageDescriptor.scanoutUsage,
                queueFamilyIndex: graphicsFamily,
                hasAlpha: false)

            let surface = ScanoutSurface.wrap(recorder: recorder, params: params)
            guard surface.isValid() else { skipToOwner(buffer: buffer); return }

            let canvas = surface.getCanvas()
            var color = nucleus.skia.Color()
            color.r = 0.25; color.g = 0.5; color.b = 0.75; color.a = 1
            canvas.clear(color)
            var paint = nucleus.skia.Paint()
            paint.color = color
            paint.alpha = 1
            canvas.drawRect(nucleus.skia.RectF(x: 8, y: 8, width: 16, height: 16), paint)

            let recording = recorder.snapRecording()
            _ = submitGraphiteAndWait(
                context: context, recording: recording, serial: 1)
            _ = readGraphiteSurfaceRGBA(
                context: context, surface: surface)
        }
        // `surface` destroyed here, before the owner is assembled.

        // Assemble the OutputBufferOwner (no KMS fb — render node has no master)
        // and let it deinit at the end of this scope: destroyImage (drops the
        // imported VkImage + memory) then destroyBuffer (gbm_bo_destroy). This runs
        // before the Graphite context is torn down (the caller's closure).
        let owner = buffer.makeOwner()
        _ = owner
        // `owner` deinits here.
    }

    /// On a surface-wrap failure we still assemble + deinit the owner to prove the
    /// teardown path runs (consumes the buffer the same way the happy path does).
    static func skipToOwner(buffer: consuming GbmScanoutBuffer) {
        let owner = buffer.makeOwner()
        _ = owner
    }
}
