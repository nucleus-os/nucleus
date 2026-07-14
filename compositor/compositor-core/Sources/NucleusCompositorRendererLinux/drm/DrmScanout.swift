// Swift direct-scanout policy: the output block-reason gate +
// the per-surface direct-scanout eligibility checks.
//
// Two pieces: the compositor-level block-reason classification consumed by
// fullscreen-VRR eligibility, and the single-surface fullscreen-candidate checks
// (viewport, geometry, dmabuf, opaque-format, modifier). The live Wayland scene
// supplies these value inputs and RendererRuntime consumes the result before
// substituting an eligible client framebuffer onto the primary plane.

// MARK: - fourcc (2101010 opaque variants; 8-bit ones live in DrmFormats.swift)

private func scanoutFourcc(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> UInt32 {
    UInt32(a) | (UInt32(b) << 8) | (UInt32(c) << 16) | (UInt32(d) << 24)
}

let drmFormatXRGB2101010 = scanoutFourcc(0x58, 0x52, 0x33, 0x30)  // 'X','R','3','0'
let drmFormatXBGR2101010 = scanoutFourcc(0x58, 0x42, 0x33, 0x30)  // 'X','B','3','0'

/// Opaque scanout formats (alpha-free), eligible for direct scanout. Mirrors
/// `isOpaqueScanoutFormat`.
func isOpaqueScanoutFormat(_ format: UInt32) -> Bool {
    format == drmFormatXRGB8888 || format == drmFormatXBGR8888 ||
        format == drmFormatXRGB2101010 || format == drmFormatXBGR2101010
}

// MARK: - Compositor block-reason gate

/// Why an output cannot direct-scanout this frame (compositor-level, distinct
/// from the per-plane `DirectScanoutBlock`). Mirrors `ScanoutBlockReason`.
enum ScanoutBlockReason: Sendable, Equatable {
    case sessionLocked
    case screenshotCapture
    case nativeOverlay
    case layerShell
    case toplevelAnimation
    case operationInFlight
    case remoteHost

    var name: String {
        switch self {
        case .sessionLocked: return "session locked"
        case .screenshotCapture: return "screenshot capture"
        case .nativeOverlay: return "native overlay"
        case .layerShell: return "layer-shell surface"
        case .toplevelAnimation: return "toplevel animation"
        case .operationInFlight: return "operation in flight"
        case .remoteHost: return "remote host"
        }
    }
}

/// The compositor-state inputs the block-reason gate classifies. Value-typed;
/// the composition root feeds these from the live shell/session/runtime state
/// each frame (public: constructed across the module boundary).
public struct ScanoutInputs: Sendable, Equatable {
    public var sessionLocked = false
    public var screenshotCaptureActive = false
    public var notificationCount = 0
    public var hotkeyHasContent = false
    public var layerShellActiveOnOutput = false
    public var toplevelAnimationActiveOnOutput = false
    /// Whether the output being classified is the shell output (notifications /
    /// hotkey overlays render only there).
    public var isShellOutput = false

    public init(
        sessionLocked: Bool = false,
        screenshotCaptureActive: Bool = false,
        notificationCount: Int = 0,
        hotkeyHasContent: Bool = false,
        layerShellActiveOnOutput: Bool = false,
        toplevelAnimationActiveOnOutput: Bool = false,
        isShellOutput: Bool = false
    ) {
        self.sessionLocked = sessionLocked
        self.screenshotCaptureActive = screenshotCaptureActive
        self.notificationCount = notificationCount
        self.hotkeyHasContent = hotkeyHasContent
        self.layerShellActiveOnOutput = layerShellActiveOnOutput
        self.toplevelAnimationActiveOnOutput = toplevelAnimationActiveOnOutput
        self.isShellOutput = isShellOutput
    }
}

/// Classify why `inputs`' output can't direct-scanout, or nil if unblocked.
/// Mirrors `blockReasonForOutput`'s ordering exactly: lock → capture →
/// notifications → hotkey → layer-shell → animation.
func scanoutBlockReason(_ inputs: ScanoutInputs) -> ScanoutBlockReason? {
    if inputs.sessionLocked { return .sessionLocked }
    if inputs.screenshotCaptureActive { return .screenshotCapture }
    if inputs.notificationCount > 0 { return inputs.isShellOutput ? .nativeOverlay : nil }
    if inputs.hotkeyHasContent { return inputs.isShellOutput ? .nativeOverlay : nil }
    if inputs.layerShellActiveOnOutput { return .layerShell }
    if inputs.toplevelAnimationActiveOnOutput { return .toplevelAnimation }
    return nil
}

/// Whether the output is blocked from direct scanout this frame.
func scanoutBlocked(_ inputs: ScanoutInputs) -> Bool {
    scanoutBlockReason(inputs) != nil
}

// MARK: - Per-surface direct-scanout eligibility

/// The per-plane reason a surface can't direct-scanout. Mirrors
/// `DirectScanoutBlock` (the subset the single-surface evaluation produces).
enum DirectScanoutBlock: Sendable, Equatable {
    case viewportTransform
    case layoutRectMismatch
    case surfaceOriginMismatch
    case surfaceSizeMismatch
    case missingDmabuf
    case formatNotOpaque
    case modifierUnsupported
}

public struct ScanoutDmabufInfo: Sendable, Equatable {
    public var format: UInt32
    public var modifier: UInt64
    public var width: UInt32
    public var height: UInt32

    public init(format: UInt32, modifier: UInt64, width: UInt32, height: UInt32) {
        self.format = format
        self.modifier = modifier
        self.width = width
        self.height = height
    }
}

/// The root surface's scanout-relevant attributes (the live Wayland surface state
/// feeds these each frame).
public struct ScanoutSurfaceInfo: Sendable, Equatable {
    public var hasViewportTransform = false
    public var currentWidth: UInt32 = 0
    public var currentHeight: UInt32 = 0
    public var dmabuf: ScanoutDmabufInfo?

    public init(
        hasViewportTransform: Bool = false,
        currentWidth: UInt32 = 0,
        currentHeight: UInt32 = 0,
        dmabuf: ScanoutDmabufInfo? = nil
    ) {
        self.hasViewportTransform = hasViewportTransform
        self.currentWidth = currentWidth
        self.currentHeight = currentHeight
        self.dmabuf = dmabuf
    }
}

/// The fullscreen candidate's output + layout geometry. Mirrors
/// `FullscreenCandidate` (minus the scene-tree handles the promotion builder
/// needs).
public struct FullscreenCandidate: Sendable, Equatable {
    public var outputLogicalX: Double
    public var outputLogicalY: Double
    public var outputLogicalWidth: Double
    public var outputLogicalHeight: Double
    public var outputWidth: UInt32
    public var outputHeight: UInt32
    public var layoutX: Double
    public var layoutY: Double
    public var layoutWidth: UInt32
    public var layoutHeight: UInt32
    public var animatedX: Double
    public var animatedY: Double

    public init(
        outputLogicalX: Double, outputLogicalY: Double,
        outputLogicalWidth: Double, outputLogicalHeight: Double,
        outputWidth: UInt32, outputHeight: UInt32,
        layoutX: Double, layoutY: Double,
        layoutWidth: UInt32, layoutHeight: UInt32,
        animatedX: Double, animatedY: Double
    ) {
        self.outputLogicalX = outputLogicalX
        self.outputLogicalY = outputLogicalY
        self.outputLogicalWidth = outputLogicalWidth
        self.outputLogicalHeight = outputLogicalHeight
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.layoutX = layoutX
        self.layoutY = layoutY
        self.layoutWidth = layoutWidth
        self.layoutHeight = layoutHeight
        self.animatedX = animatedX
        self.animatedY = animatedY
    }
}

/// Direct-scanout eligibility outcome. `.eligible` means the root surface passes
/// every single-surface check and can scan out the primary plane; overlay
/// plane-promotion (the multi-surface plan) is the graphics phase.
enum DirectScanoutResult: Sendable, Equatable {
    case eligible
    case blocked(DirectScanoutBlock)
}

private func approxEqual(_ a: Double, _ b: Double) -> Bool {
    abs(a - b) <= 0.01
}

/// Evaluate whether the fullscreen candidate's root surface can direct-scanout
/// onto the primary plane. Mirrors `evaluateFullscreenCandidate`'s single-surface
/// checks, in order; a nil surface (inspect failed) blocks on missing dmabuf.
func evaluateDirectScanout(
    candidate: FullscreenCandidate,
    surface: ScanoutSurfaceInfo?,
    primaryPlaneFormats: FormatSet
) -> DirectScanoutResult {
    guard let surface else { return .blocked(.missingDmabuf) }

    if surface.hasViewportTransform { return .blocked(.viewportTransform) }

    if !approxEqual(candidate.layoutX, candidate.outputLogicalX) ||
        !approxEqual(candidate.layoutY, candidate.outputLogicalY) ||
        !approxEqual(Double(candidate.layoutWidth), candidate.outputLogicalWidth) ||
        !approxEqual(Double(candidate.layoutHeight), candidate.outputLogicalHeight) {
        return .blocked(.layoutRectMismatch)
    }

    if !approxEqual(candidate.animatedX, candidate.outputLogicalX) ||
        !approxEqual(candidate.animatedY, candidate.outputLogicalY) {
        return .blocked(.surfaceOriginMismatch)
    }

    if !approxEqual(Double(surface.currentWidth), candidate.outputLogicalWidth) ||
        !approxEqual(Double(surface.currentHeight), candidate.outputLogicalHeight) {
        return .blocked(.surfaceSizeMismatch)
    }

    guard let attrs = surface.dmabuf else { return .blocked(.missingDmabuf) }

    if attrs.width != candidate.outputWidth || attrs.height != candidate.outputHeight {
        return .blocked(.surfaceSizeMismatch)
    }

    if !isOpaqueScanoutFormat(attrs.format) { return .blocked(.formatNotOpaque) }

    if !primaryPlaneFormats.supportsFormatModifier(attrs.format, attrs.modifier) {
        return .blocked(.modifierUnsupported)
    }

    return .eligible
}

// MARK: - Per-output candidate (the composition root pushes one of these per frame)

/// Everything the backend needs to decide one output's direct-scanout eligibility:
/// the output-level block-reason inputs, the fullscreen candidate's geometry, the
/// root surface's scanout attributes (nil when there is no single fullscreen root),
/// and that root surface's IOSurface id (the buffer that would scan out). Public:
/// the composition root builds it from the live window model and hands it down
/// through `RendererRuntime.setScanoutCandidates`, mirroring the lock-composition
/// push. The backend runs `evaluate` against the output's cached primary-plane
/// formats.
public struct ScanoutCandidate: Sendable, Equatable {
    public var inputs: ScanoutInputs
    public var candidate: FullscreenCandidate
    public var surface: ScanoutSurfaceInfo?
    public var rootIOSurfaceID: UInt64

    public init(
        inputs: ScanoutInputs,
        candidate: FullscreenCandidate,
        surface: ScanoutSurfaceInfo?,
        rootIOSurfaceID: UInt64
    ) {
        self.inputs = inputs
        self.candidate = candidate
        self.surface = surface
        self.rootIOSurfaceID = rootIOSurfaceID
    }
}

/// One output's combined direct-scanout decision: the output-level gate first,
/// then the per-surface check. Internal — the backend logs decision transitions,
/// promotes eligible buffers, and `@testable` tests assert it.
enum ScanoutEligibility: Sendable, Equatable {
    /// The root surface can scan out the primary plane; carries the buffer id.
    case eligible(rootIOSurfaceID: UInt64)
    /// The output is blocked by compositor state (lock, capture, overlay, …).
    case blockedOutput(ScanoutBlockReason)
    /// The output is unblocked but the root surface can't scan out (geometry,
    /// format, modifier, …).
    case blockedSurface(DirectScanoutBlock)

    var isEligible: Bool { if case .eligible = self { return true }; return false }

    /// A short reason string for the per-frame throttled log.
    var reason: String {
        switch self {
        case .eligible: return "eligible"
        case .blockedOutput(let r): return "output:\(r.name)"
        case .blockedSurface(let b): return "surface:\(b)"
        }
    }
}

extension ScanoutCandidate {
    /// Run the output gate then the per-surface eligibility check against the
    /// output's primary-plane format set.
    func evaluate(primaryPlaneFormats: FormatSet) -> ScanoutEligibility {
        if let blocked = scanoutBlockReason(inputs) { return .blockedOutput(blocked) }
        switch evaluateDirectScanout(
            candidate: candidate, surface: surface, primaryPlaneFormats: primaryPlaneFormats) {
        case .eligible: return .eligible(rootIOSurfaceID: rootIOSurfaceID)
        case .blocked(let block): return .blockedSurface(block)
        }
    }
}
