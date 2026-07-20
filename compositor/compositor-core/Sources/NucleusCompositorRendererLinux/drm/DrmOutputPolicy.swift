// Swift DrmOutput policy state machines: VRR, recovery, telemetry.
//
// These are the self-contained per-output policy/state cores for VRR, recovery,
// and telemetry. DrmOutput owns them while RendererRuntime drives their live
// transitions around atomic commits, pause/resume, and modesets.

// `DRM_MODE_ATOMIC_ALLOW_MODESET` (drm_mode.h) — mirrored so this stays pure Swift.
let drmModeAtomicAllowModeset: UInt32 = 1 << 10
// `DRM_MODE_ATOMIC_NONBLOCK`: return after validation/queueing rather than sleeping
// until hardware applies the update at vblank. Live page flips must set this so
// the compositor's main thread remains available for input and client dispatch.
let drmModeAtomicNonblock: UInt32 = 1 << 9

// MARK: - VRR policy

/// Per-output Variable Refresh Rate policy. `disabled` is valid even on capable
/// hardware.
enum VrrPolicy: Sendable, Equatable {
    case disabled
    case fullscreenDirectScanoutOnly
    case fullscreen

    var name: String {
        switch self {
        case .disabled: return "disabled"
        case .fullscreenDirectScanoutOnly: return "fullscreen direct scanout only"
        case .fullscreen: return "fullscreen"
        }
    }
}

/// VRR capability + policy + last-committed enable state for one output.
struct VrrState: Sendable, Equatable {
    /// Connector advertises `vrr_capable` and the CRTC has `VRR_ENABLED`.
    var capable: Bool
    var policy: VrrPolicy
    /// Cached last-committed `VRR_ENABLED`; drives whether toggling needs a
    /// modeset on the next commit.
    var enabled: Bool

    init(capable: Bool) {
        self.capable = capable
        self.policy = capable ? .fullscreenDirectScanoutOnly : .disabled
        self.enabled = false
    }

    /// Whether this frame should request VRR, given the per-frame
    /// direct-scanout-eligibility the commit builder computes elsewhere.
    func requestedFor(directScanoutEligible: Bool) -> Bool {
        guard capable else { return false }
        switch policy {
        case .disabled: return false
        case .fullscreenDirectScanoutOnly, .fullscreen: return directScanoutEligible
        }
    }

    /// The VRR portion of the atomic-commit flags: a modeset is forced only when
    /// the requested state differs from the committed one (toggling VRR_ENABLED).
    func flagsForCommit(requestedVrr: Bool) -> UInt32 {
        requestedVrr != enabled ? drmModeAtomicAllowModeset : 0
    }

    mutating func applyAfterCommit(requestedVrr: Bool) {
        enabled = requestedVrr
    }
}

// MARK: - Recovery state

/// KMS commit recovery counters/timers for one output. The runtime's
/// pause/resume/force-modeset verbs coordinate across owners using this persistent
/// state and backoff schedule.
struct RecoveryState: Sendable, Equatable {
    /// Consecutive EBUSY commits; reset on any success.
    var busyRetryCount: UInt8 = 0
    /// Sticky degraded flag; normal frame prep is skipped until cleared.
    var degraded: Bool = false
    var recoveryAttemptCount: UInt8 = 0
    var nextRecoveryNs: UInt64 = 0

    mutating func resetBusy() { busyRetryCount = 0 }

    mutating func clear() {
        degraded = false
        busyRetryCount = 0
        recoveryAttemptCount = 0
        nextRecoveryNs = 0
    }

    var isClear: Bool {
        !degraded && busyRetryCount == 0 && recoveryAttemptCount == 0 && nextRecoveryNs == 0
    }

    /// Exponential backoff for the Nth attempt: 250ms × 2^min(attempt, 3),
    /// capped at the 3rd doubling (2000ms). Matches `enterDegradedRecovery`.
    static func backoffDelayMs(forAttempt attempt: UInt8) -> UInt64 {
        let shift = min(attempt, 3)
        return 250 &* (UInt64(1) << shift)
    }

    /// Enter degraded recovery: latch the flag, bump the attempt counter
    /// (wrapping), and schedule the next attempt after the backoff delay.
    mutating func enterDegraded(nowNs: UInt64) {
        let delayMs = RecoveryState.backoffDelayMs(forAttempt: recoveryAttemptCount)
        degraded = true
        recoveryAttemptCount = recoveryAttemptCount &+ 1
        nextRecoveryNs = nowNs &+ delayMs &* 1_000_000
    }

    /// Whether the degraded output is due for another recovery attempt (the
    /// timer portion; the full gate also requires no in-flight frames — checked
    /// against the other owners at integration).
    func isRecoveryDue(nowNs: UInt64) -> Bool {
        degraded && nowNs >= nextRecoveryNs
    }
}

// MARK: - Telemetry

enum ColorDiagKind: Sendable { case composed, direct, promoted }

enum FrameFailureReason: UInt32, Sendable {
    case atomicCommitRejected
    case gpuNotReady
    case renderIntoTextureFailed
    case syncExportMissing
    case queueOverflow
    case other
}

/// Per-output frame counters, one-shot diagnostic gates, and composed-frame
/// timing aggregates. Bookkeeping only — nothing here affects frame correctness.
struct FrameTelemetry: Sendable, Equatable {
    var renderedFrameCount: UInt64 = 0
    var gpuCompletedFrameCount: UInt64 = 0
    var droppedRenderedFrameCount: UInt64 = 0
    var composedFrameFailureCount: UInt64 = 0

    var composedFrameTimingCount: UInt32 = 0
    var composedFrameTimingTotalNs: UInt64 = 0
    var composedFrameTimingMaxNs: UInt64 = 0

    var composedColorDiagnosticsLogged = false
    var directColorDiagnosticsLogged = false
    var promotedColorDiagnosticsLogged = false
    var firstPageFlipLogged = false

    mutating func noteRenderedFrame() { renderedFrameCount &+= 1 }
    mutating func noteGpuCompletedFrame() { gpuCompletedFrameCount &+= 1 }
    mutating func noteDroppedRenderedFrame() { droppedRenderedFrameCount &+= 1 }
    mutating func noteComposedFrameFailure(_ reason: FrameFailureReason) { composedFrameFailureCount &+= 1 }

    /// Accumulate one composed-frame total-time sample (count + sum + max).
    mutating func recordComposedFrameTiming(totalNs: UInt64) {
        composedFrameTimingCount &+= 1
        composedFrameTimingTotalNs &+= totalNs
        if totalNs > composedFrameTimingMaxNs { composedFrameTimingMaxNs = totalNs }
    }

    /// Mean composed-frame time, or nil before any sample.
    var meanComposedFrameNs: UInt64? {
        composedFrameTimingCount == 0 ? nil : composedFrameTimingTotalNs / UInt64(composedFrameTimingCount)
    }

    /// One-shot color-diagnostics gate (true the first time per kind).
    func shouldLogColorDiag(_ kind: ColorDiagKind) -> Bool {
        switch kind {
        case .composed: return !composedColorDiagnosticsLogged
        case .direct: return !directColorDiagnosticsLogged
        case .promoted: return !promotedColorDiagnosticsLogged
        }
    }

    mutating func markColorDiagLogged(_ kind: ColorDiagKind) {
        switch kind {
        case .composed: composedColorDiagnosticsLogged = true
        case .direct: directColorDiagnosticsLogged = true
        case .promoted: promotedColorDiagnosticsLogged = true
        }
    }

    /// Fires true exactly once (the first page flip).
    mutating func shouldLogFirstPageFlip() -> Bool {
        if firstPageFlipLogged { return false }
        firstPageFlipLogged = true
        return true
    }
}
