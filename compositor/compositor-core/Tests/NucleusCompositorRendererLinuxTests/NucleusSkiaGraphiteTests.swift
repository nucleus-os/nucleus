import Testing
@testable import NucleusRenderer
import VulkanC
import Vulkan
import NucleusSkiaGraphiteBridge

// Converted from NucleusSkiaGraphiteFixture: the C++ Swift-interop façade value
// vocabulary, runtime-shader compilation, and raster readback are hardware-
// independent and assert directly; the live Graphite context round-trip
// (offscreen surface → canvas draw → image snapshot → recording → submit) runs
// best-effort over a real device and asserts nothing hardware-conditional.
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

    // Best-effort GPU: live Graphite round-trip + draw vocabulary. Asserts
    // nothing hardware-conditional; verifies compile + link and headless safety.
    @Test func graphiteRoundTripBestEffort() {
        let srcPixels: [UInt8] = [
            255, 0, 0, 255, 0, 255, 0, 255,
            0, 0, 255, 255, 255, 255, 255, 255,
        ]
        let rasterImage = srcPixels.withUnsafeBufferPointer {
            nucleus.skia.makeRasterImageRGBA(2, 2, $0.baseAddress, $0.count)
        }
        var radii = nucleus.skia.RRectRadii()
        radii.topLeft = 4; radii.bottomRight = 8

        let base = VK.loadBaseDispatch()
        let contract = VkRequirements.contract()
        guard let instance = InstanceOwner.create(
            base: base, applicationName: "NucleusSkiaGraphiteTests",
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

            let surface = recorder.makeOffscreenSurface(256, 128)
            guard surface.isValid() else { return }

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
            canvas.drawImageRect(rasterImage, srcRect, dstRect, blurred)
            canvas.restore()

            "half4 main(float2 c) { return half4(0.2, 0.4, 0.6, 1.0); }".withCString { src in
                let shader = nucleus.skia.makeRuntimeShader(src, nil, 0)
                if shader.isValid() {
                    var shaderPaint = nucleus.skia.Paint()
                    shaderPaint.alpha = 0.9
                    canvas.drawShaderRect(rect, shader, shaderPaint)
                }
            }

            let image = surface.snapshotImage()
            _ = image.isValid()

            let recording = recorder.snapRecording()
            _ = submitGraphiteAndWait(
                context: context, recording: recording, serial: 1)

            // Dedicated mutable-upload recorder: two consecutive updates must
            // submit ahead of frames without converting a raster image during draw
            // or wedging the context on the second generation.
            let uploadRecorder = context.makeRecorder()
            guard uploadRecorder.isValid() else { return }
            let texture = uploadRecorder.makeUploadTextureRGBA(2, 2)
            #expect(texture.isValid(), "upload-texture-created")
            var uploadPixels = srcPixels
            for generation in 1...2 {
                if generation == 2 { uploadPixels[0] = 32 }
                let updated = uploadPixels.withUnsafeBufferPointer {
                    texture.updateRGBA($0.baseAddress, $0.count)
                }
                #expect(updated, "upload-texture-updated-\(generation)")
                let upload = uploadRecorder.snapRecording()
                let target = recorder.makeOffscreenSurface(8, 8)
                let image = texture.image()
                #expect(upload.isValid() && target.isValid() && image.isValid(),
                        "upload-generation-valid-\(generation)")
                var uploadDst = nucleus.skia.RectF()
                uploadDst.width = 8; uploadDst.height = 8
                target.getCanvas().drawImage(image, uploadDst, 1)
                let frame = recorder.snapRecording()
                #expect(submitGraphiteWithUploadAndWait(
                    context: context, upload: upload, frame: frame,
                    serial: UInt64(generation + 1)),
                        "upload-generation-submit-\(generation)")
            }
        }
    }
}
