import Testing
import FoundationEssentials
import Glibc
import NucleusCompositorDrmC
import VulkanC
import Vulkan
import NucleusSkiaGraphiteBridge
@testable import NucleusRenderer
@testable import NucleusCompositorRendererLinux

// scanout-usage constraint is wired into the descriptor and that the plane-layout
// packing behaves. The mandatory GPU+GBM lane opens a DRM render node, creates
// a GBM device, allocates a renderable BO, imports it as a Vulkan image over the
// SAME Vulkan device, wraps it as a Graphite render-target surface, clears + draws
// a known color, reads it back, then assembles the `OutputBufferOwner` and lets it
// deinit — proving the full GBM → Vulkan → Skia round-trip and the reverse-order
// teardown.
@Suite struct GbmScanoutBufferTests {
    @Test func scanoutUsageAndPlanePacking() {
        #expect(DrmFramebuffer.explicitModifierFlags == UInt32(DRM_MODE_FB_MODIFIERS),
                "explicit framebuffer modifiers must opt in through the addfb2 flag")
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

    @Test func gpuDRM_gbmRoundTrip() throws {
        try Self.runRoundTrip()
    }

    /// Open a render node + GBM device, bring up the Vulkan device + Graphite
    /// context, allocate a renderable BO, import it, wrap it as a surface, draw +
    /// read back, then assemble + deinit the `OutputBufferOwner`.
    static func runRoundTrip() throws {
        let renderPath = try requireProvisionedDrmRenderNode()
        guard let drmFd = DrmDeviceFd(openingNode: renderPath) else {
            throw VulkanLaneTestFailure.requirement(
                "could not open required DRM render node \(renderPath)")
        }
        try requireTrue(drmFd.isValid, "DRM render-node descriptor is invalid")
        guard let gbm = GbmDevice(borrowingFd: drmFd.fd) else {
            throw VulkanLaneTestFailure.requirement(
                "GBM rejected required render node \(renderPath)")
        }
        let gbmHandle = try unsafe requireValue(
            gbm.handle, "GBM returned a null device")
        let renderIdentity = try Self.renderNodeIdentity(drmFd.fd)

        // Bring up the Vulkan device the Graphite context will use. The GBM
        // allocation and this device are required to be the same physical GPU.
        try unsafe withRequiredVulkanGraphite(
            presentation: .platformDefault,
            applicationName: "GbmScanoutBufferTests",
            queueFamilyQualification: { instance, physicalDevice, _ in
                unsafe Self.physicalDevice(
                    physicalDevice,
                    belongsToRenderNode: renderIdentity,
                    instance: instance)
            }
        ) { device, selection, context, recorder in
            try unsafe runGbmImport(
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
    ) throws {
        let width: UInt32 = 64
        let height: UInt32 = 64

        // Allocate the scanout buffer. A render node has no DRM master, so use the
        // renderable-only fallback (no GBM_BO_USE_SCANOUT) and no negotiated
        // modifier (LINEAR). The GPU half is fully exercised without KMS master.
        guard let buffer = unsafe GbmScanoutBuffer.allocate(
            gbmDevice: gbmHandle,
            drmFormat: DrmFourcc.xrgb8888,
            width: width, height: height,
            modifiers: [],
            usage: .renderableOnly,
            device: device.handle, dispatch: device.dispatch
        ) else {
            throw VulkanLaneTestFailure.requirement(
                "GBM allocation or DMA-BUF Vulkan import failed")
        }

        // Wrap the imported image as a Graphite render-target surface, draw a known
        // color, submit, and read it back. The surface lives in this `do` so it is
        // destroyed strictly before the OutputBufferOwner is assembled below.
        do {
            let params = unsafe ScanoutImageParams(
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

            let surface = unsafe ScanoutSurface.wrap(recorder: recorder, params: params)
            let surfaceIsValid = unsafe surface.isValid()
            try requireTrue(
                surfaceIsValid,
                "Graphite rejected the imported GBM image")

            let canvas = unsafe surface.getCanvas()
            var color = nucleus.skia.Color()
            color.r = 0.25; color.g = 0.5; color.b = 0.75; color.a = 1
            unsafe canvas.clear(color)
            var paint = nucleus.skia.Paint()
            paint.color = color
            paint.alpha = 1
            unsafe canvas.drawRect(
                nucleus.skia.RectF(x: 8, y: 8, width: 16, height: 16), paint)

            let recording = unsafe recorder.snapRecording()
            let submissionCompleted = unsafe submitGraphiteAndWait(
                context: context, recording: recording, serial: 1)
            try requireTrue(
                submissionCompleted,
                "GBM image submission did not complete")
            let pixels = try requireValue(
                unsafe readGraphiteSurfaceRGBA(
                    context: context, surface: surface),
                "GBM image readback failed")
            #expect(pixels.count == Int(width * height * 4))
            #expect(pixels[0] >= 60 && pixels[0] <= 68)
            #expect(pixels[1] >= 124 && pixels[1] <= 132)
            #expect(pixels[2] >= 188 && pixels[2] <= 196)
            #expect(pixels[3] >= 250)
        }
        // `surface` destroyed here, before the owner is assembled.

        // Assemble the OutputBufferOwner (no KMS fb — render node has no master)
        // and let it deinit at the end of this scope: destroyImage (drops the
        // imported VkImage + memory) then destroyBuffer (gbm_bo_destroy). This runs
        // before the Graphite context is torn down (the caller's closure).
        let owner = unsafe buffer.makeOwner()
        _ = owner
        // `owner` deinits here.
    }

    static func renderNodeIdentity(_ fd: Int32) throws -> (major: Int64, minor: Int64) {
        var deviceStat = stat()
        let statSucceeded = unsafe fstat(fd, &deviceStat) == 0
        try requireTrue(statSucceeded, "fstat failed for DRM render node")
        let deviceID = UInt64(deviceStat.st_rdev)
        return (
            Int64(((deviceID >> 8) & 0xfff) | ((deviceID >> 32) & ~0xfff)),
            Int64((deviceID & 0xff) | ((deviceID >> 12) & ~0xff)))
    }

    static func physicalDevice(
        _ physicalDevice: VkPhysicalDevice,
        belongsToRenderNode identity: (major: Int64, minor: Int64),
        instance: VkInstance
    ) -> Bool {
        guard let raw = unsafe vkGetInstanceProcAddr(
            instance, "vkGetPhysicalDeviceProperties2")
        else { return false }
        let getProperties = unsafe unsafeBitCast(
            raw, to: PFN_vkGetPhysicalDeviceProperties2.self)
        var drm = unsafe VkPhysicalDeviceDrmPropertiesEXT()
        unsafe drm.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRM_PROPERTIES_EXT
        var properties = unsafe VkPhysicalDeviceProperties2()
        unsafe properties.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2
        withUnsafeMutablePointer(to: &drm) { pointer in
            unsafe properties.pNext = UnsafeMutableRawPointer(pointer)
            unsafe getProperties(physicalDevice, &properties)
        }
        return unsafe drm.hasRender != 0
            && drm.renderMajor == identity.major
            && drm.renderMinor == identity.minor
    }
}
