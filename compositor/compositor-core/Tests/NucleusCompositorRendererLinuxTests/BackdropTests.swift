import NucleusRenderModel
import NucleusSkiaGraphiteBridge
import Testing
import Vulkan
import VulkanC

@testable import NucleusRenderer

// Converted from BackdropFixture: blur-sigma + vibrancy-strength
// derivation and the chroma-preserving vibrancy runtime shader (hardware-
// independent via a raster content image) assert directly; backdrop-band
// execution (capture → blur+saturate → tint, .behindWindow vs .withinWindow
// source) runs in the mandatory headless Graphite lane.
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
        #expect(
            Backdrop.blurSigma(Self.spec(blending: .behindWindow, shape: .rect((10, 10, 80, 60))))
                == 12,
            "blur-sigma-offset-x-passes")
        var zeroPass = Self.spec(blending: .behindWindow, shape: .rect((0, 0, 1, 1)))
        zeroPass.passes = 0
        #expect(Backdrop.blurSigma(zeroPass) == 4, "blur-sigma-min-one-pass")
        #expect(
            Backdrop.vibrancyStrength(.light) < Backdrop.vibrancyStrength(.dark),
            "vibrancy-light-lt-dark")

        // --- Vibrancy shader compiles over a raster content image ---
        let contentSurface = unsafe nucleus.skia.makeRasterSurface(2, 2)
        var contentColor = nucleus.skia.Color()
        contentColor.r = 0.2
        contentColor.g = 0.4
        contentColor.b = 0.6
        contentColor.a = 1
        unsafe contentSurface.getCanvas().clear(contentColor)
        let content = unsafe contentSurface.snapshotImage()
        let contentIsValid = unsafe content.isValid()
        #expect(contentIsValid, "vibrancy-content-image")
        let lightShaderExists =
            unsafe Backdrop.makeVibrancyShader(
                variant: .light, content: content) != nil
        let darkShaderExists =
            unsafe Backdrop.makeVibrancyShader(
                variant: .dark, content: content) != nil
        #expect(lightShaderExists, "vibrancy-shader-light")
        #expect(darkShaderExists, "vibrancy-shader-dark")
        // A child-less SkSL fails the with-image binding (needs exactly one child).
        let emptyUniforms: [Float] = []
        let source = Array("half4 main(float2 c) { return half4(1,0,0,1); }".utf8)
        let bad = unsafe nucleus.skia.makeRuntimeShaderWithImage(
            source.span,
            emptyUniforms.span,
            content)
        let badIsValid = unsafe bad.isValid()
        #expect(!badIsValid, "vibrancy-no-child-fails")
    }

    @Test func gpuHeadless_bandExecution() throws {
        try unsafe withRequiredVulkanGraphite(
            presentation: .headless,
            applicationName: "BackdropTests"
        ) { _, _, context, recorder in
            let surface = unsafe recorder.makeOffscreenSurface(200, 120)
            let surfaceIsValid = unsafe surface.isValid()
            try requireTrue(
                surfaceIsValid,
                "could not create the backdrop output surface")

            // Compose a background, snapshot the prefix (the .behindWindow source).
            let canvas = unsafe surface.getCanvas()
            var bg = nucleus.skia.Color()
            bg.r = 0.3
            bg.g = 0.5
            bg.b = 0.7
            bg.a = 1
            unsafe canvas.clear(bg)
            let prefix = unsafe surface.snapshotImage()
            let live = unsafe surface.snapshotImage()

            // A .behindWindow rrect command draws once.
            let command1 = Self.spec(
                blending: .behindWindow,
                shape: .rrect(rect: (10, 10, 80, 60), radii: (8, 8, 8, 8)))
            let behindDraws = unsafe Backdrop.execute(
                command1, liveSnapshot: live, prefix: prefix, onto: canvas)

            // A .withinWindow rect command samples the live accumulator.
            let command2 = Self.spec(
                blending: .withinWindow, shape: .rect((100, 40, 60, 60)))
            let withinDraws = unsafe Backdrop.execute(
                command2, liveSnapshot: live, prefix: nil, onto: canvas)

            // A disabled draw is skipped.
            var disabled = Self.spec(blending: .behindWindow, shape: .rect((0, 0, 10, 10)))
            disabled.enabled = false
            let disabledDraws = unsafe Backdrop.execute(
                disabled, liveSnapshot: live, prefix: prefix, onto: canvas)

            let recording = unsafe recorder.snapRecording()
            let submissionCompleted = unsafe submitGraphiteAndWait(
                context: context, recording: recording, serial: 1)
            try requireTrue(
                submissionCompleted,
                "backdrop Graphite submission did not complete")
            #expect(behindDraws == 1)
            #expect(withinDraws == 1)
            #expect(disabledDraws == 0)
        }
    }
}
