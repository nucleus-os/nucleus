import Testing
import VulkanC
import Vulkan
import NucleusSkiaGraphiteBridge
@testable import NucleusRenderer

// pixel-format conversion (hardware-independent), plus the GPU surface readback
// round-trip — clear a surface to a known color, submit, read it back, and verify
// the pixel — over the mandatory headless Graphite lane.
@Suite struct ScreenshotTests {
    @Test func pixelFormatConversion() {
        let rgba: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255]
        #expect(Screenshot.convert(rgba: rgba, to: .rgba8888) == rgba, "convert-rgba-identity")
        let bgra = Screenshot.convert(rgba: rgba, to: .bgra8888)
        // R↔B swap: (255,0,0,255) → (0,0,255,255); (0,255,0,255) unchanged.
        #expect(bgra == [0, 0, 255, 255, 0, 255, 0, 255], "convert-bgra-swaps-rb")
    }

    @Test func gpuHeadless_readbackRoundTrip() throws {
        try unsafe withRequiredVulkanGraphite(
            presentation: .headless,
            applicationName: "ScreenshotTests"
        ) { _, _, context, recorder in
            let surface = unsafe recorder.makeOffscreenSurface(8, 8)
            let surfaceIsValid = unsafe surface.isValid()
            try requireTrue(surfaceIsValid, "could not create the screenshot surface")

            // Clear to opaque red, submit, then read back.
            let canvas = unsafe surface.getCanvas()
            var red = nucleus.skia.Color()
            red.r = 1; red.g = 0; red.b = 0; red.a = 1
            unsafe canvas.clear(red)
            let recording = unsafe recorder.snapRecording()
            let submissionCompleted = unsafe submitGraphiteAndWait(
                context: context, recording: recording, serial: 1)
            try requireTrue(
                submissionCompleted,
                "screenshot submission did not complete")

            let pixels = try requireValue(
                unsafe readGraphiteSurfaceRGBA(context: context, surface: surface),
                "screenshot readback failed")
            #expect(pixels.count == 8 * 8 * 4)
            #expect(pixels[0] >= 250)
            #expect(pixels[1] <= 5)
            #expect(pixels[2] <= 5)
            #expect(pixels[3] >= 250)
            // Exercise the BGRA conversion of the read frame.
            let bgra = Screenshot.convert(rgba: pixels, to: .bgra8888)
            #expect(bgra[0] <= 5)
            #expect(bgra[2] >= 250)
        }
    }
}
