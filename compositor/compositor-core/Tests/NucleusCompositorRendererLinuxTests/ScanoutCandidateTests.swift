import Testing
@testable import NucleusCompositorRendererLinux

// M2 Phase 1 — the per-output `ScanoutCandidate` bundle: it runs the output-level
// block-reason gate first, then the per-surface eligibility check, against the
// output's primary-plane format set. The raw evaluators are exhaustively covered by
// DrmScanoutTests; this asserts the bundle wires the three inputs together and
// reports the combined `ScanoutEligibility` correctly. Hardware-independent.
@Suite struct ScanoutCandidateTests {
    // A 1920×1080 output at (0,0), scale 1, with a fullscreen root filling it exactly
    // and an opaque XRGB8888 dmabuf at the output's pixel size.
    static let modifier: UInt64 = 0x0100_0000_0000_0001  // an arbitrary explicit modifier

    static func candidate(
        inputs: ScanoutInputs = ScanoutInputs(),
        surface: ScanoutSurfaceInfo? = defaultSurface()
    ) -> ScanoutCandidate {
        ScanoutCandidate(
            inputs: inputs,
            candidate: FullscreenCandidate(
                outputLogicalX: 0, outputLogicalY: 0,
                outputLogicalWidth: 1920, outputLogicalHeight: 1080,
                outputWidth: 1920, outputHeight: 1080,
                layoutX: 0, layoutY: 0, layoutWidth: 1920, layoutHeight: 1080,
                animatedX: 0, animatedY: 0),
            surface: surface,
            rootIOSurfaceID: 42)
    }

    static func defaultSurface() -> ScanoutSurfaceInfo {
        ScanoutSurfaceInfo(
            hasViewportTransform: false, currentWidth: 1920, currentHeight: 1080,
            dmabuf: ScanoutDmabufInfo(
                format: drmFormatXRGB8888, modifier: modifier, width: 1920, height: 1080))
    }

    // A format set whose primary plane advertises the candidate's format + modifier.
    static func planeFormats() -> FormatSet {
        var formats = FormatSet()
        formats.add(drmFormatXRGB8888, modifier)
        return formats
    }

    @Test func eligibleWhenUnblockedAndMatching() {
        let decision = Self.candidate().evaluate(primaryPlaneFormats: Self.planeFormats())
        #expect(decision == .eligible(rootIOSurfaceID: 42))
        #expect(decision.isEligible)
        #expect(decision.reason == "eligible")
    }

    @Test func outputGateWinsOverSurfaceCheck() {
        // Session locked AND no surface: the output gate must fire first, so the
        // reason is the output block, not the missing dmabuf.
        var inputs = ScanoutInputs()
        inputs.sessionLocked = true
        let decision = Self.candidate(inputs: inputs, surface: nil)
            .evaluate(primaryPlaneFormats: Self.planeFormats())
        #expect(decision == .blockedOutput(.sessionLocked))
        #expect(!decision.isEligible)
    }

    @Test func layerShellBlocksOutput() {
        var inputs = ScanoutInputs()
        inputs.layerShellActiveOnOutput = true
        let decision = Self.candidate(inputs: inputs).evaluate(primaryPlaneFormats: Self.planeFormats())
        #expect(decision == .blockedOutput(.layerShell))
    }

    @Test func missingDmabufBlocksSurface() {
        let decision = Self.candidate(surface: nil).evaluate(primaryPlaneFormats: Self.planeFormats())
        #expect(decision == .blockedSurface(.missingDmabuf))
    }

    @Test func viewportTransformBlocksSurface() {
        var surface = Self.defaultSurface()
        surface.hasViewportTransform = true
        let decision = Self.candidate(surface: surface).evaluate(primaryPlaneFormats: Self.planeFormats())
        #expect(decision == .blockedSurface(.viewportTransform))
    }

    @Test func unsupportedModifierBlocksSurface() {
        // The plane advertises the format but not this buffer's modifier.
        var formats = FormatSet()
        formats.add(drmFormatXRGB8888, 0xDEAD_BEEF)
        let decision = Self.candidate().evaluate(primaryPlaneFormats: formats)
        #expect(decision == .blockedSurface(.modifierUnsupported))
    }

    @Test func sizeMismatchBlocksSurface() {
        var surface = Self.defaultSurface()
        surface.currentWidth = 1280
        surface.currentHeight = 720
        let decision = Self.candidate(surface: surface).evaluate(primaryPlaneFormats: Self.planeFormats())
        #expect(decision == .blockedSurface(.surfaceSizeMismatch))
    }
}
