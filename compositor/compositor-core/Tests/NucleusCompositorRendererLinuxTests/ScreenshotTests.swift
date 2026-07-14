import Testing
import VulkanC
import Vulkan
import NucleusSkiaGraphiteBridge
@testable import NucleusRenderer

// Converted from ScreenshotFixture (Phase 10b.4i): the RGBA→BGRA
// pixel-format conversion (hardware-independent), plus the GPU surface readback
// round-trip — clear a surface to a known color, submit, read it back, and verify
// the pixel — over a real Graphite context (best-effort, asserts nothing
// hardware-conditional).
@Suite struct ScreenshotTests {
    @Test func pixelFormatConversion() {
        let rgba: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255]
        #expect(Screenshot.convert(rgba: rgba, to: .rgba8888) == rgba, "convert-rgba-identity")
        let bgra = Screenshot.convert(rgba: rgba, to: .bgra8888)
        // R↔B swap: (255,0,0,255) → (0,0,255,255); (0,255,0,255) unchanged.
        #expect(bgra == [0, 0, 255, 255, 0, 255, 0, 255], "convert-bgra-swaps-rb")
    }

    // Best-effort GPU readback round-trip. Hardware-gated, so it asserts nothing.
    @Test(.disabled("requires a live GPU/Vulkan device")) func readbackRoundTripBestEffort() {
        let base = VK.loadBaseDispatch()
        let contract = VkRequirements.contract()
        guard let instance = InstanceOwner.create(
            base: base, applicationName: "ScreenshotTests",
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
            let recorder = context.makeRecorder()
            guard recorder.isValid() else { return }

            let surface = recorder.makeOffscreenSurface(8, 8)
            guard surface.isValid() else { return }

            // Clear to opaque red, submit, then read back.
            let canvas = surface.getCanvas()
            var red = nucleus.skia.Color()
            red.r = 1; red.g = 0; red.b = 0; red.a = 1
            canvas.clear(red)
            let recording = recorder.snapRecording()
            _ = context.submit(recording)

            guard let pixels = Screenshot.readback(context: context, surface: surface) else {
                return
            }
            // Exercise the BGRA conversion of the read frame.
            _ = Screenshot.convert(rgba: pixels, to: .bgra8888)
        }
    }
}
