import Testing
@testable import NucleusRenderer
import VulkanC
import Vulkan
import NucleusSkiaGraphiteBridge

// Converted from NucleusSkiaGraphiteFixture: the C++ Swift-interop façade value
// vocabulary, runtime-shader compilation, and raster readback are hardware-
// independent and assert directly; the live Graphite context round-trip
// (offscreen surface → canvas draw → image snapshot → recording → submit) runs
// mandatory over the Collider-provisioned headless device.
@Suite struct NucleusSkiaGraphiteTests {
    @Test func facadeValueVocabulary() {
        #expect(nucleus.skia.Status.ok.rawValue == 0, "status-ok-raw")
        var probe = nucleus.skia.Color()
        probe.r = 0.5
        probe.a = 1
        #expect(probe.r == 0.5 && probe.a == 1, "color-fields")

        // Paint defaults + blend-mode raws + rrect radii.
        let defaultPaint = nucleus.skia.Paint()
        #expect(defaultPaint.alpha == 1 && defaultPaint.saturation == 1 && defaultPaint.blurSigma == 0,
                "paint-defaults")
        #expect(nucleus.skia.BlendMode.srcOver.rawValue == 0
            && nucleus.skia.BlendMode.dstOut.rawValue == 7, "blend-mode-raws")
        var radii = nucleus.skia.RRectRadii()
        radii.topLeft = 4; radii.bottomRight = 8
        #expect(radii.topLeft == 4 && radii.bottomRight == 8, "rrect-radii-fields")
    }

    @Test func runtimeEffectCompilation() {
        // Runtime-effect compilation is GPU-independent (SkSL → shader).
        "half4 main(float2 c) { return half4(1.0, 0.0, 0.0, 1.0); }".withCString { src in
            let shader = nucleus.skia.makeRuntimeShader(src, nil, 0)
            #expect(shader.isValid(), "runtime-shader-no-uniform")
        }
        "uniform half intensity; half4 main(float2 c) { return half4(intensity, 0, 0, 1); }".withCString { src in
            let uniforms: [Float] = [0.5]
            let shader = uniforms.withUnsafeBufferPointer {
                nucleus.skia.makeRuntimeShader(src, $0.baseAddress, 1)
            }
            #expect(shader.isValid(), "runtime-shader-with-uniform")
            // Wrong uniform count fails closed (byte-size mismatch).
            let bad = nucleus.skia.makeRuntimeShader(src, nil, 0)
            #expect(!bad.isValid(), "runtime-shader-uniform-mismatch")
        }
        "this is not valid sksl {{{".withCString { src in
            #expect(!nucleus.skia.makeRuntimeShader(src, nil, 0).isValid(), "runtime-shader-compile-fail")
        }
    }

    @Test func rasterReadbackRoundTrip() {
        let srcPixels: [UInt8] = [
            255, 0, 0, 255, 0, 255, 0, 255,
            0, 0, 255, 255, 255, 255, 255, 255,
        ]
        let rasterImage = srcPixels.withUnsafeBufferPointer {
            nucleus.skia.makeRasterImageRGBA(2, 2, $0.baseAddress, $0.count)
        }
        #expect(rasterImage.isValid(), "raster-image")
        var readback = [UInt8](repeating: 0, count: 16)
        let readOk = readback.withUnsafeMutableBufferPointer {
            rasterImage.readPixelsRGBA($0.baseAddress, $0.count, 8)
        }
        #expect(readOk && readback == srcPixels, "raster-readback-roundtrip")
    }

    @Test func gpuHeadless_graphiteRoundTrip() throws {
        let srcPixels: [UInt8] = [
            255, 0, 0, 255, 0, 255, 0, 255,
            0, 0, 255, 255, 255, 255, 255, 255,
        ]
        let rasterImage = srcPixels.withUnsafeBufferPointer {
            nucleus.skia.makeRasterImageRGBA(2, 2, $0.baseAddress, $0.count)
        }
        var radii = nucleus.skia.RRectRadii()
        radii.topLeft = 4; radii.bottomRight = 8

        try withRequiredVulkanGraphite(
            presentation: .headless,
            applicationName: "NucleusSkiaGraphiteTests"
        ) { _, _, context, recorder in
            // CPU decode results cross onto the Graphite recorder before draw;
            // Graphite's default image provider deliberately drops raster images.
            let textureImage = recorder.makeTextureImage(rasterImage)
            #expect(textureImage.isValid(), "raster-image-promoted-to-graphite")

            let imageProbe = recorder.makeOffscreenSurface(2, 2)
            #expect(imageProbe.isValid(), "texture-image-probe-surface")
            var imageProbeRect = nucleus.skia.RectF()
            imageProbeRect.width = 2
            imageProbeRect.height = 2
            imageProbe.getCanvas().drawImage(textureImage, imageProbeRect, 1)
            #expect(submitGraphiteAndWait(
                context: context,
                recording: recorder.snapRecording(),
                serial: 1), "texture-image-upload-and-draw-submit")
            #expect(context.completedSubmissionTimingCount() == 0)
            let pixels = try requireValue(
                readGraphiteSurfaceRGBA(
                    context: context,
                    surface: imageProbe),
                "promoted image readback failed")
            #expect(
                Array(pixels.prefix(4)) == Array(srcPixels.prefix(4)),
                "promoted-image-draws-decoded-pixels")

            let surface = recorder.makeOffscreenSurface(256, 128)
            try requireTrue(surface.isValid(), "could not create Graphite draw surface")

            let canvas = surface.getCanvas()
            var clearColor = nucleus.skia.Color()
            clearColor.r = 0.1; clearColor.g = 0.2; clearColor.b = 0.3; clearColor.a = 1
            canvas.clear(clearColor)
            var rect = nucleus.skia.RectF()
            rect.x = 10; rect.y = 10; rect.width = 100; rect.height = 50
            var rectColor = nucleus.skia.Color()
            rectColor.r = 1; rectColor.a = 1
            canvas.drawRect(rect, rectColor)

            // Draw vocabulary: save/clip stack + Paint-carrying draws + shader fill.
            canvas.save()
            canvas.clipRRect(rect, radii, true)
            var paint = nucleus.skia.Paint()
            paint.color = rectColor
            paint.alpha = 0.8
            paint.blend = nucleus.skia.BlendMode.srcOver
            paint.saturation = 1.4
            canvas.drawRRect(rect, radii, paint)
            canvas.restore()

            canvas.saveLayerAlpha(rect, 0.5)
            var blurred = nucleus.skia.Paint()
            blurred.alpha = 1
            blurred.blurSigma = 3
            var srcRect = nucleus.skia.RectF()
            srcRect.x = 0; srcRect.y = 0; srcRect.width = 2; srcRect.height = 2
            var dstRect = nucleus.skia.RectF()
            dstRect.x = 20; dstRect.y = 20; dstRect.width = 64; dstRect.height = 64
            canvas.drawImageRect(textureImage, srcRect, dstRect, blurred)
            canvas.restore()

            "half4 main(float2 c) { return half4(0.2, 0.4, 0.6, 1.0); }".withCString { src in
                let shader = nucleus.skia.makeRuntimeShader(src, nil, 0)
                #expect(shader.isValid())
                if shader.isValid() {
                    var shaderPaint = nucleus.skia.Paint()
                    shaderPaint.alpha = 0.9
                    canvas.drawShaderRect(rect, shader, shaderPaint)
                }
            }

            let image = surface.snapshotImage()
            #expect(image.isValid())

            let recording = recorder.snapRecording()
            try requireTrue(
                submitGraphiteAndWait(
                    context: context, recording: recording, serial: 2),
                "Graphite draw-vocabulary submission did not complete")

            // Upload and draw share one recorder and become one insertion for
            // each generation.
            let texture = recorder.makeUploadTextureRGBA(2, 2)
            #expect(texture.isValid(), "upload-texture-created")
            var uploadPixels = srcPixels
            for generation in 1...2 {
                if generation == 2 { uploadPixels[0] = 32 }
                let updated = uploadPixels.withUnsafeBufferPointer {
                    texture.updateRGBA($0.baseAddress, $0.count)
                }
                #expect(updated, "upload-texture-updated-\(generation)")
                let target = recorder.makeOffscreenSurface(8, 8)
                let image = texture.image()
                #expect(target.isValid() && image.isValid(),
                        "upload-generation-valid-\(generation)")
                var uploadDst = nucleus.skia.RectF()
                uploadDst.width = 8; uploadDst.height = 8
                target.getCanvas().drawImage(image, uploadDst, 1)
                let submission = recorder.snapRecording()
                #expect(submitGraphiteAndWait(
                    context: context, recording: submission,
                    serial: UInt64(generation + 2)),
                        "upload-generation-submit-\(generation)")
            }
        }
    }

    @Test func gpuHeadless_exactInsertStatusesAndCallbacks() throws {
        let cases: [(
            nucleus.skia.RecordingInsertStatus,
            Bool
        )] = [
            (.success, true),
            (.invalidRecording, true),
            (.promiseImageInstantiationFailed, true),
            (.addCommandsFailed, false),
            (.asyncShaderCompilesFailed, false),
            (.outOfOrderRecording, false),
        ]

        for (simulated, expectedUsable) in cases {
            try withRequiredVulkanGraphite(
                presentation: .headless,
                applicationName: "Nucleus insert-status \(simulated.rawValue)"
            ) { _, _, context, recorder in
                let surface = recorder.makeOffscreenSurface(2, 2)
                try requireTrue(
                    surface.isValid(),
                    "could not create insert-status surface")
                var color = nucleus.skia.Color()
                color.a = 1
                surface.getCanvas().clear(color)
                let recording = recorder.snapRecording()
                let result = context.submitAsyncSimulatingInsertStatus(
                    recording, 1, simulated)
                if simulated == .success {
                    try requireTrue(
                        waitForGraphiteSerial(
                            context: context,
                            serial: 1),
                        "successful simulated insertion did not complete")
                } else {
                    _ = context.pollCompletedSubmissionSerial()
                }

                #expect(result.insertStatus == simulated)
                #expect(result.contextUsable == expectedUsable)
                #expect(result.isOk() == (simulated == .success))
                #expect(context.submissionCallbackCount() == 1)
                if simulated == .success {
                    #expect(
                        context.successfulSubmissionCallbackCount() == 1)
                    #expect(context.failedSubmissionCallbackCount() == 0)
                    #expect(String(result.diagnostic).isEmpty)
                } else {
                    #expect(
                        context.successfulSubmissionCallbackCount() == 0)
                    #expect(context.failedSubmissionCallbackCount() == 1)
                    #expect(!String(result.diagnostic).isEmpty)
                }
            }
        }
    }

    @Test func gpuHeadless_presentationTimingRingIsBounded() throws {
        try withRequiredVulkanGraphite(
            presentation: .headless,
            applicationName: "Nucleus timing-ring"
        ) { _, _, context, recorder in
            for serial in 1...257 {
                let surface = recorder.makeOffscreenSurface(1, 1)
                try requireTrue(
                    surface.isValid(),
                    "could not create timing sample surface")
                var color = nucleus.skia.Color()
                color.r = Float(serial % 2)
                color.a = 1
                surface.getCanvas().clear(color)
                let result = context.submitWithSemaphores(
                    recorder.snapRecording(),
                    nil, 0, nil,
                    UInt64(serial),
                    true)
                try requireTrue(
                    result.isOk(),
                    "timed submission \(serial) failed")
            }
            try requireTrue(
                waitForGraphiteSerial(context: context, serial: 257),
                "timed submissions did not complete")
            #expect(context.completedSubmissionTimingCount() == 256)
            #expect(context.droppedSubmissionTimingCount() == 1)
            #expect(context.submissionCallbackCount() == 257)
            #expect(
                context.takeCompletedSubmissionGpuElapsedNs(1) == 0,
                "the oldest unconsumed timing was overwritten")
        }
    }
}
