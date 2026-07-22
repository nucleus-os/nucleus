import Testing
@testable import NucleusRenderer
@testable import NucleusCompositorRendererLinux

// the compositor block-reason gate (ordering, shell-output gating) and the
// per-surface eligibility checks (viewport, geometry, dmabuf, opaque format,
// modifier) — against the behavior of ScanoutPlanner.zig / Scanout.zig. Fully
// hardware-independent.
@Suite struct DrmScanoutTests {
    static func candidate() -> FullscreenCandidate {
        // A 1920×1080 output at (0,0), scale 1, layout filling it exactly.
        FullscreenCandidate(
            outputLogicalX: 0, outputLogicalY: 0, outputLogicalWidth: 1920, outputLogicalHeight: 1080,
            outputWidth: 1920, outputHeight: 1080,
            layoutX: 0, layoutY: 0, layoutWidth: 1920, layoutHeight: 1080,
            animatedX: 0, animatedY: 0)
    }

    static func surface() -> ScanoutSurfaceInfo {
        ScanoutSurfaceInfo(
            hasViewportTransform: false, currentWidth: 1920, currentHeight: 1080,
            dmabuf: ScanoutDmabufInfo(format: drmFormatXRGB8888, modifier: 0x100, width: 1920, height: 1080))
    }

    static func planeFormats() -> FormatSet {
        var s = FormatSet()
        s.add(drmFormatXRGB8888, 0x100)
        return s
    }

    @Test func blockReasonGate() {
        #expect(scanoutBlockReason(ScanoutInputs()) == nil, "gate-unblocked")
        // Ordering: lock wins over everything.
        var locked = ScanoutInputs()
        locked.sessionLocked = true
        locked.screenshotCaptureActive = true
        #expect(scanoutBlockReason(locked) == .sessionLocked, "gate-lock-first")
        // Capture before notifications.
        var capture = ScanoutInputs()
        capture.screenshotCaptureActive = true
        #expect(scanoutBlockReason(capture) == .screenshotCapture, "gate-capture")
        // Notifications only block the shell output.
        var notif = ScanoutInputs()
        notif.notificationCount = 1
        #expect(scanoutBlockReason(notif) == nil, "gate-notif-non-shell")
        notif.isShellOutput = true
        #expect(scanoutBlockReason(notif) == .nativeOverlay, "gate-notif-shell")
        // Hotkey content, shell output → native overlay.
        var hotkey = ScanoutInputs()
        hotkey.hotkeyHasContent = true
        hotkey.isShellOutput = true
        #expect(scanoutBlockReason(hotkey) == .nativeOverlay, "gate-hotkey-shell")
        // Layer-shell and animation block any output.
        var layer = ScanoutInputs(); layer.layerShellActiveOnOutput = true
        #expect(scanoutBlockReason(layer) == .layerShell, "gate-layer-shell")
        var anim = ScanoutInputs(); anim.toplevelAnimationActiveOnOutput = true
        #expect(scanoutBlockReason(anim) == .toplevelAnimation && scanoutBlocked(anim), "gate-animation")
    }

    @Test func perSurfaceEligibility() {
        #expect(evaluateDirectScanout(candidate: Self.candidate(), surface: Self.surface(),
                                      primaryPlaneFormats: Self.planeFormats()) == .eligible, "eligible")

        // nil surface → missing dmabuf.
        #expect(evaluateDirectScanout(candidate: Self.candidate(), surface: nil,
                                      primaryPlaneFormats: Self.planeFormats()) == .blocked(.missingDmabuf),
                "block-nil-surface")

        // Viewport transform blocks.
        var vp = Self.surface(); vp.hasViewportTransform = true
        #expect(evaluateDirectScanout(candidate: Self.candidate(), surface: vp,
                                      primaryPlaneFormats: Self.planeFormats()) == .blocked(.viewportTransform),
                "block-viewport")

        // Layout not filling the output (logical mismatch).
        var layoutMismatch = Self.candidate(); layoutMismatch.layoutWidth = 1280
        #expect(evaluateDirectScanout(candidate: layoutMismatch, surface: Self.surface(),
                                      primaryPlaneFormats: Self.planeFormats()) == .blocked(.layoutRectMismatch),
                "block-layout")

        // Animated origin offset → origin mismatch.
        var animated = Self.candidate(); animated.animatedX = 5
        #expect(evaluateDirectScanout(candidate: animated, surface: Self.surface(),
                                      primaryPlaneFormats: Self.planeFormats()) == .blocked(.surfaceOriginMismatch),
                "block-origin")

        // Surface logical size mismatch.
        var smallSurface = Self.surface(); smallSurface.currentWidth = 1280
        #expect(evaluateDirectScanout(candidate: Self.candidate(), surface: smallSurface,
                                      primaryPlaneFormats: Self.planeFormats()) == .blocked(.surfaceSizeMismatch),
                "block-surface-size")

        // dmabuf pixel size mismatch (logical ok, buffer wrong).
        var bufMismatch = Self.surface()
        bufMismatch.dmabuf = ScanoutDmabufInfo(format: drmFormatXRGB8888, modifier: 0x100, width: 1280, height: 1080)
        #expect(evaluateDirectScanout(candidate: Self.candidate(), surface: bufMismatch,
                                      primaryPlaneFormats: Self.planeFormats()) == .blocked(.surfaceSizeMismatch),
                "block-dmabuf-size")

        // Non-opaque format (ARGB) blocks.
        var argb = Self.surface()
        argb.dmabuf = ScanoutDmabufInfo(format: drmFormatABGR2101010, modifier: 0x100, width: 1920, height: 1080)
        #expect(evaluateDirectScanout(candidate: Self.candidate(), surface: argb,
                                      primaryPlaneFormats: Self.planeFormats()) == .blocked(.formatNotOpaque),
                "block-not-opaque")
        // The 2101010 X-variants are opaque.
        #expect(isOpaqueScanoutFormat(drmFormatXRGB2101010) && isOpaqueScanoutFormat(drmFormatXBGR2101010) &&
                !isOpaqueScanoutFormat(drmFormatABGR2101010), "opaque-format-set")

        // Modifier unsupported by the primary plane.
        var unsupported = Self.surface()
        unsupported.dmabuf = ScanoutDmabufInfo(format: drmFormatXRGB8888, modifier: 0x999, width: 1920, height: 1080)
        #expect(evaluateDirectScanout(candidate: Self.candidate(), surface: unsupported,
                                      primaryPlaneFormats: Self.planeFormats()) == .blocked(.modifierUnsupported),
                "block-modifier")
    }
}
