import Testing
@testable import NucleusRenderer
import VulkanC
import Vulkan
import NucleusSkiaGraphiteBridge
import NucleusRenderModel

// Converted from BackdropFixture: blur-sigma + vibrancy-strength
// derivation and the chroma-preserving vibrancy runtime shader (hardware-
// independent via a raster content image) assert directly; backdrop-band
// execution (capture → blur+saturate → tint, .behindWindow vs .withinWindow
// source) over a real Graphite context runs best-effort and asserts nothing
// hardware-conditional.
@Suite struct BackdropTests {
    static func spec(blending: BackdropBlendingMode, shape: EffectShape) -> ExecSpec {
        ExecSpec(
            layerId: 1, groupId: 7,
            blendingMode: blending,
            region: PlanRect(x: 10, y: 10, w: 80, h: 60),
            shape: shape, mask: .none,
            tintRgba: (0.2, 0.2, 0.3, 1), tintBlend: 0.25,
            alpha: 1, enabled: true, passes: 3, offset: 4, saturation: 1.5, noise: 0.02)
    }

    @Test func pureDerivationsAndVibrancyShader() {
        // --- Pure derivations ---
        #expect(Backdrop.blurSigma(Self.spec(blending: .behindWindow, shape: .rect((10, 10, 80, 60)))) == 12,
                "blur-sigma-offset-x-passes")
        var zeroPass = Self.spec(blending: .behindWindow, shape: .rect((0, 0, 1, 1)))
        zeroPass.passes = 0
        #expect(Backdrop.blurSigma(zeroPass) == 4, "blur-sigma-min-one-pass")
        #expect(Backdrop.vibrancyStrength(.light) < Backdrop.vibrancyStrength(.dark),
                "vibrancy-light-lt-dark")

        // --- Vibrancy shader compiles over a raster content image ---
        let contentSurface = nucleus.skia.makeRasterSurface(2, 2)
        var contentColor = nucleus.skia.Color()
        contentColor.r = 0.2
        contentColor.g = 0.4
        contentColor.b = 0.6
        contentColor.a = 1
        contentSurface.getCanvas().clear(contentColor)
        let content = contentSurface.snapshotImage()
        #expect(content.isValid(), "vibrancy-content-image")
        #expect(Backdrop.makeVibrancyShader(variant: .light, content: content) != nil,
                "vibrancy-shader-light")
        #expect(Backdrop.makeVibrancyShader(variant: .dark, content: content) != nil,
                "vibrancy-shader-dark")
        // A child-less SkSL fails the with-image binding (needs exactly one child).
        "half4 main(float2 c) { return half4(1,0,0,1); }".withCString { src in
            let bad = nucleus.skia.makeRuntimeShaderWithImage(src, nil, 0, content)
            #expect(!bad.isValid(), "vibrancy-no-child-fails")
        }
    }

    // Best-effort GPU: band execution over a real Graphite context. Asserts
    // nothing hardware-conditional; verifies compile + link and headless safety.
    @Test(.disabled("requires a live GPU/Vulkan device")) func bandExecutionBestEffort() {
        let base = VK.loadBaseDispatch()
        let contract = VkRequirements.contract()
        guard let instance = InstanceOwner.create(
            base: base, applicationName: "BackdropTests",
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

            guard let accumulator = OutputAccumulator.create(
                recorder: recorder, outputId: 1, width: 200, height: 120
            ) else { return }

            // Compose a background, snapshot the prefix (the .behindWindow source).
            let canvas = accumulator.canvas
            var bg = nucleus.skia.Color()
            bg.r = 0.3; bg.g = 0.5; bg.b = 0.7; bg.a = 1
            canvas.clear(bg)
            accumulator.snapshotPrefix()
            let live = accumulator.snapshotImage()

            // A .behindWindow rrect command draws once.
            let command1 = Self.spec(
                blending: .behindWindow,
                shape: .rrect(rect: (10, 10, 80, 60), radii: (8, 8, 8, 8)))
            _ = Backdrop.execute(
                command1, liveSnapshot: live, prefix: accumulator.prefix, onto: canvas)

            // A .withinWindow rect command samples the live accumulator.
            let command2 = Self.spec(
                blending: .withinWindow, shape: .rect((100, 40, 60, 60)))
            _ = Backdrop.execute(command2, liveSnapshot: live, prefix: nil, onto: canvas)

            // A disabled draw is skipped.
            var disabled = Self.spec(blending: .behindWindow, shape: .rect((0, 0, 10, 10)))
            disabled.enabled = false
            _ = Backdrop.execute(
                disabled, liveSnapshot: live, prefix: accumulator.prefix, onto: canvas)

            let recording = recorder.snapRecording()
            _ = submitGraphiteAndWait(
                context: context, recording: recording, serial: 1)
        }
    }
}
