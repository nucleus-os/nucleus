import Testing
import VulkanC
import Vulkan
import NucleusSkiaGraphiteBridge
@testable import NucleusRenderer

// Converted from SnapshotCaptureFixture (Phase 10b.4h): the world→device
// capture sizing (hardware-independent), plus the device-rect capture → register
// → resolve lifecycle over a real Graphite recorder (best-effort, asserts nothing
// hardware-conditional).
@Suite struct SnapshotCaptureTests {
    @Test func worldToDeviceSizing() {
        let s1 = SnapshotCapture.deviceSize(localWidth: 100, localHeight: 50, scale: 2)
        #expect(s1.width == 200 && s1.height == 100, "device-size-scale-2")
        let s2 = SnapshotCapture.deviceSize(localWidth: 33, localHeight: 33, scale: 1.5)
        #expect(s2.width == 50 && s2.height == 50, "device-size-rounds")
        let s3 = SnapshotCapture.deviceSize(localWidth: -5, localHeight: 10, scale: 2)
        #expect(s3.width == 0 && s3.height == 20, "device-size-clamps-negative")
    }

    // Best-effort GPU: capture lifecycle. Hardware-gated, so it asserts nothing.
    @Test(.disabled("requires a live GPU/Vulkan device")) func captureLifecycleBestEffort() {
        let base = VK.loadBaseDispatch()
        let contract = VkRequirements.contract()
        guard let instance = InstanceOwner.create(
            base: base, applicationName: "SnapshotCaptureTests",
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

            let registry = TextureRegistry()

            // A 32×32 source to capture a 16×16 sub-rect from.
            var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
            for i in 0..<(32 * 32) {
                pixels[i * 4 + 1] = 255  // green
                pixels[i * 4 + 3] = 255
            }
            let source = pixels.withUnsafeBufferPointer {
                nucleus.skia.makeRasterImageRGBA(32, 32, $0.baseAddress, $0.count)
            }

            // begin() allocates a render texture of the requested size.
            guard let target = SnapshotCapture.begin(recorder: recorder, width: 16, height: 16) else {
                registry.clear(); return
            }
            _ = target

            // captureDeviceRect captures + registers the sub-rect.
            guard let handle = SnapshotCapture.captureDeviceRect(
                recorder: recorder, source: source, srcX: 8, srcY: 8, width: 16, height: 16,
                into: registry, contentRevision: 1)
            else { registry.clear(); return }
            _ = registry.resolve(handle)
            _ = registry.size(handle)

            // captureWorldRect maps through scale then captures.
            let worldHandle = SnapshotCapture.captureWorldRect(
                recorder: recorder, source: source, originX: 0, originY: 0, scale: 0.5,
                localWidth: 32, localHeight: 32, into: registry, contentRevision: 1)
            _ = registry.size(worldHandle ?? 0)

            let recording = recorder.snapRecording()
            if recording.isValid() { _ = context.submit(recording) }
            registry.clear()
        }
    }
}
