import Testing
import VulkanC
import Vulkan
import NucleusSkiaGraphiteBridge
@testable import NucleusRenderer

// capture sizing (hardware-independent), plus the device-rect capture → register
// → resolve lifecycle over the mandatory headless Graphite lane.
@Suite struct SnapshotCaptureTests {
    @Test func worldToDeviceSizing() {
        let s1 = SnapshotCapture.deviceSize(localWidth: 100, localHeight: 50, scale: 2)
        #expect(s1.width == 200 && s1.height == 100, "device-size-scale-2")
        let s2 = SnapshotCapture.deviceSize(localWidth: 33, localHeight: 33, scale: 1.5)
        #expect(s2.width == 50 && s2.height == 50, "device-size-rounds")
        let s3 = SnapshotCapture.deviceSize(localWidth: -5, localHeight: 10, scale: 2)
        #expect(s3.width == 0 && s3.height == 20, "device-size-clamps-negative")
    }

    @Test func gpuHeadless_captureLifecycle() throws {
        try unsafe withRequiredVulkanGraphite(
            presentation: .headless,
            applicationName: "SnapshotCaptureTests"
        ) { _, _, context, recorder in
            let registry = TextureRegistry()

            // A 32×32 source to capture a 16×16 sub-rect from.
            var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
            for i in 0..<(32 * 32) {
                pixels[i * 4 + 1] = 255  // green
                pixels[i * 4 + 3] = 255
            }
            let decodedSource = pixels.withUnsafeBufferPointer {
                unsafe nucleus.skia.makeRasterImageRGBA(32, 32, $0.baseAddress, $0.count)
            }
            let source = unsafe recorder.makeTextureImage(decodedSource)

            // begin() allocates a render texture of the requested size.
            let target = try requireValue(
                unsafe SnapshotCapture.begin(
                    recorder: recorder, width: 16, height: 16),
                "could not allocate the snapshot target")
            #expect(target.width == 16)
            #expect(target.height == 16)

            // captureDeviceRect captures + registers the sub-rect.
            let handle = try requireValue(
                unsafe SnapshotCapture.captureDeviceRect(
                    recorder: recorder, source: source,
                    srcX: 8, srcY: 8, width: 16, height: 16,
                    into: registry, contentRevision: 1),
                "device-rect snapshot capture failed")
            let capturedImage = try unsafe requireValue(
                unsafe registry.resolve(.renderer(handle)),
                "captured snapshot was not registered")
            let capturedImageIsValid = unsafe capturedImage.isValid()
            #expect(capturedImageIsValid)
            #expect(registry.size(.renderer(handle))?.width == 16)
            #expect(registry.size(.renderer(handle))?.height == 16)

            // captureWorldRect maps through scale then captures.
            let worldHandle = try requireValue(
                unsafe SnapshotCapture.captureWorldRect(
                    recorder: recorder, source: source,
                    originX: 0, originY: 0, scale: 0.5,
                    localWidth: 32, localHeight: 32,
                    into: registry, contentRevision: 1),
                "world-rect snapshot capture failed")
            #expect(registry.size(.renderer(worldHandle))?.width == 16)
            #expect(registry.size(.renderer(worldHandle))?.height == 16)

            let recording = unsafe recorder.snapRecording()
            let submissionCompleted = unsafe submitGraphiteAndWait(
                context: context, recording: recording, serial: 1)
            try requireTrue(
                submissionCompleted,
                "snapshot submission did not complete")
            let completedSubmissionTimingCount =
                unsafe context.completedSubmissionTimingCount()
            #expect(completedSubmissionTimingCount == 0)
            registry.clear()
        }
    }
}
