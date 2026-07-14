import Testing
import VulkanC
import Vulkan
import NucleusSkiaGraphiteBridge
@testable import NucleusRenderer

// Converted from ScanoutSurfaceFixture (Phase 10b.6d): the GBM↔Vulkan↔Skia
// scanout-surface bridge. The descriptor marshaling is hardware-independent and
// asserted field-by-field; the live wrap creates a borrowed color-attachment
// VkImage, wraps it as a Graphite render-target Surface, clears + draws into it,
// submits, and reads it back — over a real Graphite context, best-effort (every
// GPU stage guards on loader/device/context availability and asserts nothing
// hardware-conditional).
@Suite struct ScanoutSurfaceTests {
    @Test func descriptorMarshaling() {
        // A dummy non-null borrowed image handle: the descriptor never derefs it,
        // it only marshals the address into the façade's void* field.
        let dummyImage = VkImage(bitPattern: 0xDEAD_BEEF)
        let usage: VK.ImageUsageFlags = [.colorAttachmentBit, .transferSrcBit]
        let params = ScanoutImageParams(
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
        let desc = ScanoutSurface.descriptor(params)
        #expect(desc.image != nil, "desc-image-nonnull")
        #expect(desc.memory == nil, "desc-memory-null")
        #expect(desc.allocSize == 64 * 64 * 4, "desc-allocsize")
        #expect(desc.width == 64 && desc.height == 64, "desc-extent")
        #expect(desc.format == VK_FORMAT_B8G8R8A8_UNORM.rawValue, "desc-format")
        #expect(desc.imageTiling == VK_IMAGE_TILING_OPTIMAL.rawValue, "desc-tiling")
        #expect(desc.imageLayout == VK_IMAGE_LAYOUT_UNDEFINED.rawValue, "desc-layout")
        #expect(desc.imageUsageFlags == usage.rawValue, "desc-usage")
        #expect(desc.imageUsageFlags & VK.ImageUsageFlags.colorAttachmentBit.rawValue != 0, "desc-usage-color-attachment")
        #expect(desc.sampleCount == 1, "desc-samplecount")
        #expect(desc.queueFamilyIndex == 3, "desc-queuefamily")
        #expect(desc.hasAlpha == false, "desc-hasalpha")

        // A descriptor built from a nil image marshals a null void* (fail-closed
        // input).
        let nullParams = ScanoutImageParams(
            image: nil, memory: nil, allocSize: 0, width: 64, height: 64,
            format: VK_FORMAT_B8G8R8A8_UNORM, tiling: VK_IMAGE_TILING_OPTIMAL,
            initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
            usageFlags: [.colorAttachmentBit], queueFamilyIndex: 0, hasAlpha: false)
        #expect(ScanoutSurface.descriptor(nullParams).image == nil, "desc-null-image")
    }

    // Best-effort GPU: borrowed VkImage → Graphite render-target Surface. Every
    // stage is hardware-gated, so it asserts nothing hardware-conditional.
    @Test(.disabled("requires a live GPU/Vulkan device")) func scanoutWrapBestEffort() {
        let base = VK.loadBaseDispatch()
        let contract = VkRequirements.contract()
        guard let instance = InstanceOwner.create(
            base: base, applicationName: "ScanoutSurfaceTests",
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

            // A descriptor with a null image wraps to an invalid Surface
            // (fail-closed) — mirrors the registry's wrap-null check.
            var nullDesc = nucleus.skia.VulkanImageDescriptor()
            nullDesc.width = 64
            nullDesc.height = 64
            nullDesc.imageUsageFlags = VK.ImageUsageFlags.colorAttachmentBit.rawValue
            _ = recorder.wrapBackendSurface(nullDesc)

            Self.runScanoutGPU(
                device: device, dispatch: device.dispatch,
                graphicsFamily: selection.graphicsQueueFamily,
                context: context, recorder: recorder)
        }
    }

    /// Create a borrowed color-attachment VkImage, wrap it as a render-target
    /// Surface, draw + submit + read back, then tear down in the correct order:
    /// the Surface's scope ends before the image/memory `VkOwned`, which in turn
    /// are destroyed before the Graphite context (the enclosing closure).
    /// Best-effort: every stage escapes when its prerequisite is unavailable and
    /// asserts nothing hardware-conditional.
    static func runScanoutGPU(
        device: borrowing DeviceOwner, dispatch: VK.DeviceDispatch, graphicsFamily: UInt32,
        context: nucleus.skia.GraphiteContext, recorder: nucleus.skia.Recorder
    ) {
        let width: Int32 = 64
        let height: Int32 = 64

        // Create the borrowed scanout-style image: a color attachment we can also
        // copy out of (TRANSFER_SRC) so the readback path is valid.
        var imageInfo = VkImageCreateInfo()
        imageInfo.imageType = VK_IMAGE_TYPE_2D
        imageInfo.format = VK_FORMAT_B8G8R8A8_UNORM
        imageInfo.extent = VkExtent3D(width: UInt32(width), height: UInt32(height), depth: 1)
        imageInfo.mipLevels = 1
        imageInfo.arrayLayers = 1
        imageInfo.samples = VK_SAMPLE_COUNT_1_BIT
        imageInfo.tiling = VK_IMAGE_TILING_OPTIMAL
        // A color-renderable Graphite Vulkan texture must carry both
        // COLOR_ATTACHMENT and INPUT_ATTACHMENT (Skia binds the dst as an input
        // attachment for blending); TRANSFER_SRC makes the readback path valid.
        let renderUsage: VK.ImageUsageFlags = [.colorAttachmentBit, .inputAttachmentBit, .transferSrcBit]
        imageInfo.usage = renderUsage.rawValue
        imageInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE
        imageInfo.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED

        guard let imageOwned = dispatch.createImage(device.handle, info: imageInfo) else { return }

        guard let getReqs = dispatch.vkGetImageMemoryRequirements,
              let bindImage = dispatch.vkBindImageMemory
        else { return }

        var requirements = VkMemoryRequirements()
        getReqs(device.handle, imageOwned.handle, &requirements)
        guard requirements.memoryTypeBits != 0 else { return }
        // Lowest set bit, mirroring the DmaBuf import's selection.
        let memoryTypeIndex = UInt32(requirements.memoryTypeBits.trailingZeroBitCount)

        var allocInfo = VkMemoryAllocateInfo()
        allocInfo.allocationSize = requirements.size
        allocInfo.memoryTypeIndex = memoryTypeIndex
        guard let memoryOwned = dispatch.allocateMemory(device.handle, info: allocInfo) else { return }
        guard bindImage(device.handle, imageOwned.handle, memoryOwned.handle, 0) == VK_SUCCESS else { return }

        let params = ScanoutImageParams(
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
            let surface = ScanoutSurface.wrap(recorder: recorder, params: params)
            guard surface.isValid() else { return }

            // Clear to an opaque known color, then draw a rect in the same color
            // over a sub-region (exercises the Paint/drawRect path on a wrapped RT).
            let canvas = surface.getCanvas()
            var color = nucleus.skia.Color()
            color.r = 0.25; color.g = 0.5; color.b = 0.75; color.a = 1
            canvas.clear(color)
            var paint = nucleus.skia.Paint()
            paint.color = color
            paint.alpha = 1
            canvas.drawRect(nucleus.skia.RectF(x: 8, y: 8, width: 16, height: 16), paint)

            let recording = recorder.snapRecording()
            _ = context.submit(recording)

            // Read back to exercise the path; the values are not asserted because
            // the round-trip only runs on real GPU hardware.
            let stride = Int(width) * 4
            var buf = [UInt8](repeating: 0, count: stride * Int(height))
            _ = buf.withUnsafeMutableBufferPointer {
                context.readSurfaceRGBA(surface, $0.baseAddress, $0.count, Int32(stride))
            }
        }
        // `surface` destroyed here; `memoryOwned`/`imageOwned` destroyed on return.
    }
}
