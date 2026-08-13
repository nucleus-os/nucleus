import NucleusSkiaGraphiteBridge
import Testing
import Vulkan
import VulkanC

@testable import NucleusRenderer

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
        #expect(
            defaultPaint.alpha == 1 && defaultPaint.saturation == 1 && defaultPaint.blurSigma == 0,
            "paint-defaults")
        #expect(
            nucleus.skia.BlendMode.srcOver.rawValue == 0
                && nucleus.skia.BlendMode.dstOut.rawValue == 7, "blend-mode-raws")
        var radii = nucleus.skia.RRectRadii()
        radii.topLeft = 4
        radii.bottomRight = 8
        #expect(radii.topLeft == 4 && radii.bottomRight == 8, "rrect-radii-fields")
    }

    @Test func runtimeEffectCompilation() {
        // Runtime-effect compilation is GPU-independent (SkSL → shader).
        "half4 main(float2 c) { return half4(1.0, 0.0, 0.0, 1.0); }".withCString { src in
            let shader = unsafe nucleus.skia.makeRuntimeShader(src, nil, 0)
            let shaderIsValid = unsafe shader.isValid()
            #expect(shaderIsValid, "runtime-shader-no-uniform")
        }
        "uniform half intensity; half4 main(float2 c) { return half4(intensity, 0, 0, 1); }"
            .withCString { src in
                let uniforms: [Float] = [0.5]
                let shader = uniforms.withUnsafeBufferPointer {
                    unsafe nucleus.skia.makeRuntimeShader(src, $0.baseAddress, 1)
                }
                let shaderIsValid = unsafe shader.isValid()
                #expect(shaderIsValid, "runtime-shader-with-uniform")
                // Wrong uniform count fails closed (byte-size mismatch).
                let bad = unsafe nucleus.skia.makeRuntimeShader(src, nil, 0)
                let badIsValid = unsafe bad.isValid()
                #expect(!badIsValid, "runtime-shader-uniform-mismatch")
            }
        "this is not valid sksl {{{".withCString { src in
            let shader = unsafe nucleus.skia.makeRuntimeShader(src, nil, 0)
            let shaderIsValid = unsafe shader.isValid()
            #expect(!shaderIsValid, "runtime-shader-compile-fail")
        }
    }

    @Test func rasterReadbackRoundTrip() {
        let srcPixels: [UInt8] = [
            255, 0, 0, 255, 0, 255, 0, 255,
            0, 0, 255, 255, 255, 255, 255, 255,
        ]
        let rasterImage = srcPixels.withUnsafeBufferPointer {
            unsafe nucleus.skia.makeRasterImageRGBA(
                2, 2, $0.baseAddress, $0.count)
        }
        let rasterImageIsValid = rasterImage.isValid()
        #expect(rasterImageIsValid, "raster-image")
        var readback = [UInt8](repeating: 0, count: 16)
        let readOk = readback.withUnsafeMutableBufferPointer {
            unsafe rasterImage.readPixelsRGBA($0.baseAddress, $0.count, 8)
        }
        #expect(readOk && readback == srcPixels, "raster-readback-roundtrip")
    }

    @Test func gpuHeadless_graphiteRoundTrip() throws {
        let srcPixels: [UInt8] = [
            255, 0, 0, 255, 0, 255, 0, 255,
            0, 0, 255, 255, 255, 255, 255, 255,
        ]
        let rasterImage = srcPixels.withUnsafeBufferPointer {
            unsafe nucleus.skia.makeRasterImageRGBA(
                2, 2, $0.baseAddress, $0.count)
        }
        var radii = nucleus.skia.RRectRadii()
        radii.topLeft = 4
        radii.bottomRight = 8

        try unsafe withRequiredVulkanGraphite(
            presentation: .headless,
            applicationName: "NucleusSkiaGraphiteTests"
        ) { _, _, context, recorder in
            // CPU decode results cross onto the Graphite recorder before draw;
            // Graphite's default image provider deliberately drops raster images.
            let textureImage = unsafe recorder.makeTextureImage(rasterImage)
            let textureImageIsValid = unsafe textureImage.isValid()
            #expect(textureImageIsValid, "raster-image-promoted-to-graphite")

            let imageProbe = unsafe recorder.makeOffscreenSurface(2, 2)
            let imageProbeIsValid = unsafe imageProbe.isValid()
            #expect(imageProbeIsValid, "texture-image-probe-surface")
            var imageProbeRect = nucleus.skia.RectF()
            imageProbeRect.width = 2
            imageProbeRect.height = 2
            unsafe imageProbe.getCanvas().drawImage(
                textureImage, imageProbeRect, 1)
            let imageProbeSubmitted = unsafe submitGraphiteAndWait(
                context: context,
                recording: recorder.snapRecording(),
                serial: 1)
            #expect(imageProbeSubmitted, "texture-image-upload-and-draw-submit")
            let initialTimingCount =
                unsafe context.completedSubmissionTimingCount()
            #expect(initialTimingCount == 0)
            let pixels = try requireValue(
                unsafe readGraphiteSurfaceRGBA(
                    context: context,
                    surface: imageProbe),
                "promoted image readback failed")
            #expect(
                Array(pixels.prefix(4)) == Array(srcPixels.prefix(4)),
                "promoted-image-draws-decoded-pixels")

            let surface = unsafe recorder.makeOffscreenSurface(256, 128)
            let surfaceIsValid = unsafe surface.isValid()
            try requireTrue(surfaceIsValid, "could not create Graphite draw surface")

            let canvas = unsafe surface.getCanvas()
            var clearColor = nucleus.skia.Color()
            clearColor.r = 0.1
            clearColor.g = 0.2
            clearColor.b = 0.3
            clearColor.a = 1
            unsafe canvas.clear(clearColor)
            var rect = nucleus.skia.RectF()
            rect.x = 10
            rect.y = 10
            rect.width = 100
            rect.height = 50
            var rectColor = nucleus.skia.Color()
            rectColor.r = 1
            rectColor.a = 1
            unsafe canvas.drawRect(rect, rectColor)

            // Draw vocabulary: save/clip stack + Paint-carrying draws + shader fill.
            unsafe canvas.save()
            unsafe canvas.clipRRect(rect, radii, true)
            var paint = nucleus.skia.Paint()
            paint.color = rectColor
            paint.alpha = 0.8
            paint.blend = nucleus.skia.BlendMode.srcOver
            paint.saturation = 1.4
            unsafe canvas.drawRRect(rect, radii, paint)
            unsafe canvas.restore()

            unsafe canvas.saveLayerAlpha(rect, 0.5)
            var blurred = nucleus.skia.Paint()
            blurred.alpha = 1
            blurred.blurSigma = 3
            var srcRect = nucleus.skia.RectF()
            srcRect.x = 0
            srcRect.y = 0
            srcRect.width = 2
            srcRect.height = 2
            var dstRect = nucleus.skia.RectF()
            dstRect.x = 20
            dstRect.y = 20
            dstRect.width = 64
            dstRect.height = 64
            unsafe canvas.drawImageRect(textureImage, srcRect, dstRect, blurred)
            unsafe canvas.restore()

            "half4 main(float2 c) { return half4(0.2, 0.4, 0.6, 1.0); }".withCString { src in
                let shader = unsafe nucleus.skia.makeRuntimeShader(src, nil, 0)
                let shaderIsValid = unsafe shader.isValid()
                #expect(shaderIsValid)
                if shaderIsValid {
                    var shaderPaint = nucleus.skia.Paint()
                    shaderPaint.alpha = 0.9
                    unsafe canvas.drawShaderRect(rect, shader, shaderPaint)
                }
            }

            let image = unsafe surface.snapshotImage()
            let imageIsValid = unsafe image.isValid()
            #expect(imageIsValid)

            let recording = unsafe recorder.snapRecording()
            let vocabularySubmitted = unsafe submitGraphiteAndWait(
                context: context, recording: recording, serial: 2)
            try requireTrue(
                vocabularySubmitted,
                "Graphite draw-vocabulary submission did not complete")

            // Upload and draw share one recorder and become one insertion for
            // each generation.
            let texture = unsafe recorder.makeUploadTextureRGBA(2, 2)
            let textureIsValid = unsafe texture.isValid()
            #expect(textureIsValid, "upload-texture-created")
            var uploadPixels = srcPixels
            for generation in 1...2 {
                if generation == 2 { uploadPixels[0] = 32 }
                let updated = uploadPixels.withUnsafeBufferPointer {
                    unsafe texture.updateRGBA($0.baseAddress, $0.count)
                }
                #expect(updated, "upload-texture-updated-\(generation)")
                let target = unsafe recorder.makeOffscreenSurface(8, 8)
                let image = unsafe texture.image()
                let targetIsValid = unsafe target.isValid()
                let imageIsValid = unsafe image.isValid()
                #expect(
                    targetIsValid && imageIsValid,
                    "upload-generation-valid-\(generation)")
                var uploadDst = nucleus.skia.RectF()
                uploadDst.width = 8
                uploadDst.height = 8
                unsafe target.getCanvas().drawImage(image, uploadDst, 1)
                let submission = unsafe recorder.snapRecording()
                let generationSubmitted = unsafe submitGraphiteAndWait(
                    context: context, recording: submission,
                    serial: UInt64(generation + 2))
                #expect(
                    generationSubmitted,
                    "upload-generation-submit-\(generation)")
            }
        }
    }

    @Test func gpuHeadless_exactInsertStatusesAndCallbacks() throws {
        let cases:
            [(
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
            try unsafe withRequiredVulkanGraphite(
                presentation: .headless,
                applicationName: "Nucleus insert-status \(simulated.rawValue)"
            ) { _, _, context, recorder in
                let surface = unsafe recorder.makeOffscreenSurface(2, 2)
                let surfaceIsValid = unsafe surface.isValid()
                try requireTrue(
                    surfaceIsValid,
                    "could not create insert-status surface")
                var color = nucleus.skia.Color()
                color.a = 1
                unsafe surface.getCanvas().clear(color)
                let recording = unsafe recorder.snapRecording()
                let result = unsafe context.submitAsyncSimulatingInsertStatus(
                    recording, 1, simulated)
                if simulated == .success {
                    let submissionCompleted = unsafe waitForGraphiteSerial(
                        context: context,
                        serial: 1)
                    try requireTrue(
                        submissionCompleted,
                        "successful simulated insertion did not complete")
                } else {
                    _ = unsafe context.pollCompletedSubmissionSerial()
                }

                let insertStatus = result.insertStatus
                let contextUsable = result.contextUsable
                let resultIsOk = result.isOk()
                let callbackCount = unsafe context.submissionCallbackCount()
                #expect(insertStatus == simulated)
                #expect(contextUsable == expectedUsable)
                #expect(resultIsOk == (simulated == .success))
                #expect(callbackCount == 1)
                if simulated == .success {
                    let successfulCallbackCount =
                        unsafe context.successfulSubmissionCallbackCount()
                    let failedCallbackCount =
                        unsafe context.failedSubmissionCallbackCount()
                    let diagnosticIsEmpty = String(result.diagnostic).isEmpty
                    #expect(successfulCallbackCount == 1)
                    #expect(failedCallbackCount == 0)
                    #expect(diagnosticIsEmpty)
                } else {
                    let successfulCallbackCount =
                        unsafe context.successfulSubmissionCallbackCount()
                    let failedCallbackCount =
                        unsafe context.failedSubmissionCallbackCount()
                    let diagnosticIsEmpty = String(result.diagnostic).isEmpty
                    #expect(successfulCallbackCount == 0)
                    #expect(failedCallbackCount == 1)
                    #expect(!diagnosticIsEmpty)
                }
            }
        }
    }

    @Test func gpuHeadless_presentationTimingRingIsBounded() throws {
        try unsafe withRequiredVulkanGraphite(
            presentation: .headless,
            applicationName: "Nucleus timing-ring"
        ) { _, _, context, recorder in
            for serial in 1...257 {
                let surface = unsafe recorder.makeOffscreenSurface(1, 1)
                let surfaceIsValid = unsafe surface.isValid()
                try requireTrue(
                    surfaceIsValid,
                    "could not create timing sample surface")
                var color = nucleus.skia.Color()
                color.r = Float(serial % 2)
                color.a = 1
                unsafe surface.getCanvas().clear(color)
                let result = unsafe context.submitWithSemaphores(
                    recorder.snapRecording(),
                    nil, 0, nil,
                    UInt64(serial),
                    true)
                let resultIsOk = result.isOk()
                try requireTrue(
                    resultIsOk,
                    "timed submission \(serial) failed")
            }
            let submissionsCompleted =
                unsafe waitForGraphiteSerial(context: context, serial: 257)
            try requireTrue(
                submissionsCompleted,
                "timed submissions did not complete")
            let completedTimingCount =
                unsafe context.completedSubmissionTimingCount()
            let droppedTimingCount =
                unsafe context.droppedSubmissionTimingCount()
            let callbackCount = unsafe context.submissionCallbackCount()
            let oldestElapsed =
                unsafe context.takeCompletedSubmissionGpuElapsedNs(1)
            #expect(completedTimingCount == 256)
            #expect(droppedTimingCount == 1)
            #expect(callbackCount == 257)
            #expect(
                oldestElapsed == 0,
                "the oldest unconsumed timing was overwritten")
        }
    }
}
