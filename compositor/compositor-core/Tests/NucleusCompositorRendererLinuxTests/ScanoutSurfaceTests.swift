import Testing
import VulkanC
import Vulkan
import NucleusSkiaGraphiteBridge
@testable import NucleusRenderer

// scanout-surface bridge. The descriptor marshaling is hardware-independent and
// asserted field-by-field; the live wrap creates a borrowed color-attachment
// VkImage, wraps it as a Graphite render-target Surface, clears + draws into it,
// submits, and reads it back — over the mandatory Graphite capability lane (every
// GPU stage guards on loader/device/context availability and asserts nothing
// hardware-conditional).
@Suite struct ScanoutSurfaceTests {
    @Test func descriptorMarshaling() {
        // A dummy non-null borrowed image handle: the descriptor never derefs it,
        // it only marshals the address into the façade's void* field.
        let dummyImage = unsafe VkImage(bitPattern: 0xDEAD_BEEF)
        let usage: VK.ImageUsageFlags = [.colorAttachmentBit, .transferSrcBit]
        let params = unsafe ScanoutImageParams(
            image: dummyImage,
            memory: nil,
            allocSize: 64 * 64 * 4,
            width: 64,
            height: 64,
            format: VK_FORMAT_B8G8R8A8_UNORM,
            tiling: VK_IMAGE_TILING_OPTIMAL,
            initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
            usageFlags: usage,
            queueFamilyIndex: 3,
            hasAlpha: false)
        let desc = unsafe ScanoutSurface.descriptor(params)
        let imageIsNonNull = unsafe desc.image != nil
        let memoryIsNull = unsafe desc.memory == nil
        let allocSize = unsafe desc.allocSize
        let width = unsafe desc.width
        let height = unsafe desc.height
        let format = unsafe desc.format
        let imageTiling = unsafe desc.imageTiling
        let imageLayout = unsafe desc.imageLayout
        let imageUsageFlags = unsafe desc.imageUsageFlags
        let sampleCount = unsafe desc.sampleCount
        let queueFamilyIndex = unsafe desc.queueFamilyIndex
        let hasAlpha = unsafe desc.hasAlpha
        #expect(imageIsNonNull, "desc-image-nonnull")
        #expect(memoryIsNull, "desc-memory-null")
        #expect(allocSize == 64 * 64 * 4, "desc-allocsize")
        #expect(width == 64 && height == 64, "desc-extent")
        #expect(format == VK_FORMAT_B8G8R8A8_UNORM.rawValue, "desc-format")
        #expect(imageTiling == VK_IMAGE_TILING_OPTIMAL.rawValue, "desc-tiling")
        #expect(imageLayout == VK_IMAGE_LAYOUT_UNDEFINED.rawValue, "desc-layout")
        #expect(imageUsageFlags == usage.rawValue, "desc-usage")
        #expect(imageUsageFlags & VK.ImageUsageFlags.colorAttachmentBit.rawValue != 0, "desc-usage-color-attachment")
        #expect(sampleCount == 1, "desc-samplecount")
        #expect(queueFamilyIndex == 3, "desc-queuefamily")
        #expect(hasAlpha == false, "desc-hasalpha")

        // A descriptor built from a nil image marshals a null void* (fail-closed
        // input).
        let nullParams = unsafe ScanoutImageParams(
            image: nil, memory: nil, allocSize: 0, width: 64, height: 64,
            format: VK_FORMAT_B8G8R8A8_UNORM, tiling: VK_IMAGE_TILING_OPTIMAL,
            initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
            usageFlags: [.colorAttachmentBit], queueFamilyIndex: 0, hasAlpha: false)
        let nullImageIsNull =
            unsafe ScanoutSurface.descriptor(nullParams).image == nil
        #expect(nullImageIsNull, "desc-null-image")
    }

    @Test func gpuHeadless_scanoutWrap() throws {
        try unsafe withRequiredVulkanGraphite(
            presentation: .headless,
            applicationName: "ScanoutSurfaceTests"
        ) { device, selection, context, recorder in
            // A descriptor with a null image wraps to an invalid Surface
            // (fail-closed) — mirrors the registry's wrap-null check.
            var nullDesc = unsafe nucleus.skia.VulkanImageDescriptor()
            unsafe nullDesc.width = 64
            unsafe nullDesc.height = 64
            unsafe nullDesc.imageUsageFlags =
                VK.ImageUsageFlags.colorAttachmentBit.rawValue
            let nullSurface = unsafe recorder.wrapBackendSurface(nullDesc)
            let nullSurfaceIsValid = unsafe nullSurface.isValid()
            #expect(!nullSurfaceIsValid)

            try unsafe Self.runScanoutGPU(
                device: device, dispatch: device.dispatch,
                graphicsFamily: selection.graphicsQueueFamily,
                context: context, recorder: recorder)
        }
    }

    /// Create a borrowed color-attachment VkImage, wrap it as a render-target
    /// Surface, draw + submit + read back, then tear down in the correct order:
    /// the Surface's scope ends before the image/memory `VkOwned`, which in turn
    /// are destroyed before the Graphite context (the enclosing closure).
    static func runScanoutGPU(
        device: borrowing DeviceOwner, dispatch: VK.DeviceDispatch, graphicsFamily: UInt32,
        context: nucleus.skia.GraphiteContext, recorder: nucleus.skia.Recorder
    ) throws {
        let width: Int32 = 64
        let height: Int32 = 64

        // Create the borrowed scanout-style image: a color attachment we can also
        // copy out of (TRANSFER_SRC) so the readback path is valid.
        var imageInfo = unsafe VkImageCreateInfo()
        unsafe imageInfo.imageType = VK_IMAGE_TYPE_2D
        unsafe imageInfo.format = VK_FORMAT_B8G8R8A8_UNORM
        unsafe imageInfo.extent =
            VkExtent3D(width: UInt32(width), height: UInt32(height), depth: 1)
        unsafe imageInfo.mipLevels = 1
        unsafe imageInfo.arrayLayers = 1
        unsafe imageInfo.samples = VK_SAMPLE_COUNT_1_BIT
        unsafe imageInfo.tiling = VK_IMAGE_TILING_OPTIMAL
        // A color-renderable Graphite Vulkan texture must carry both
        // COLOR_ATTACHMENT and INPUT_ATTACHMENT (Skia binds the dst as an input
        // attachment for blending); TRANSFER_SRC makes the readback path valid.
        let renderUsage: VK.ImageUsageFlags = [.colorAttachmentBit, .inputAttachmentBit, .transferSrcBit]
        unsafe imageInfo.usage = renderUsage.rawValue
        unsafe imageInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE
        unsafe imageInfo.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED

        guard let imageOwned = unsafe dispatch.createImage(
            device.handle, info: imageInfo)
        else {
            throw VulkanLaneTestFailure.requirement(
                "could not create the borrowed scanout test image")
        }

        let getReqs = try unsafe requireValue(
            dispatch.vkGetImageMemoryRequirements,
            "vkGetImageMemoryRequirements is unavailable")
        let bindImage = try unsafe requireValue(
            dispatch.vkBindImageMemory,
            "vkBindImageMemory is unavailable")

        var requirements = VkMemoryRequirements()
        unsafe getReqs(device.handle, imageOwned.handle, &requirements)
        let memoryTypeBits = requirements.memoryTypeBits
        try requireTrue(
            memoryTypeBits != 0,
            "scanout test image has no compatible memory type")
        // Lowest set bit, mirroring the DmaBuf import's selection.
        let memoryTypeIndex = UInt32(memoryTypeBits.trailingZeroBitCount)

        var allocInfo = unsafe VkMemoryAllocateInfo()
        unsafe allocInfo.allocationSize = requirements.size
        unsafe allocInfo.memoryTypeIndex = memoryTypeIndex
        guard let memoryOwned = unsafe dispatch.allocateMemory(
            device.handle, info: allocInfo)
        else {
            throw VulkanLaneTestFailure.requirement(
                "could not allocate scanout test image memory")
        }
        let bindSucceeded = unsafe bindImage(
                device.handle, imageOwned.handle,
                memoryOwned.handle, 0) == VK_SUCCESS
        try requireTrue(
            bindSucceeded,
            "could not bind scanout test image memory")

        let params = unsafe ScanoutImageParams(
            image: imageOwned.handle,
            memory: memoryOwned.handle,
            allocSize: requirements.size,
            width: width,
            height: height,
            format: VK_FORMAT_B8G8R8A8_UNORM,
            tiling: VK_IMAGE_TILING_OPTIMAL,
            initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
            usageFlags: renderUsage,
            queueFamilyIndex: graphicsFamily,
            hasAlpha: false)

        // The Surface (and its readback) live inside this `do` so the Surface
        // value is destroyed at the block's end — strictly before `memoryOwned`
        // and `imageOwned` are destroyed at the enclosing function's return, which
        // is itself before the Graphite context (the caller's closure). Skia
        // surfaces backed by a backend texture must not outlive their backing.
        do {
            let surface = unsafe ScanoutSurface.wrap(recorder: recorder, params: params)
            let surfaceIsValid = unsafe surface.isValid()
            try requireTrue(surfaceIsValid, "Graphite rejected the borrowed image")

            // Clear to an opaque known color, then draw a rect in the same color
            // over a sub-region (exercises the Paint/drawRect path on a wrapped RT).
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
                "borrowed-image submission did not complete")

            let pixels = try requireValue(
                unsafe readGraphiteSurfaceRGBA(
                    context: context, surface: surface),
                "borrowed-image readback failed")
            #expect(pixels.count == Int(width * height * 4))
            #expect(pixels[0] >= 60 && pixels[0] <= 68)
            #expect(pixels[1] >= 124 && pixels[1] <= 132)
            #expect(pixels[2] >= 188 && pixels[2] <= 196)
            #expect(pixels[3] >= 250)
        }
        // `surface` destroyed here; `memoryOwned`/`imageOwned` destroyed on return.
    }
}
