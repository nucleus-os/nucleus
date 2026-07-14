import Testing
@testable import NucleusRenderer
@testable import NucleusCompositorRendererLinux

// Converted from DrmOutputPolicyFixture (Phase 10a.7): the DrmOutput policy state
// machines (VRR, recovery backoff, telemetry) against the behavior of the Zig
// VrrState / RecoveryState / FrameTelemetry. Fully hardware-independent.
@Suite struct DrmOutputPolicyTests {
    @Test func vrr() {
        #expect(VrrState(capable: false).policy == .disabled, "vrr-incapable-disabled")
        #expect(VrrState(capable: true).policy == .fullscreenDirectScanoutOnly, "vrr-capable-default")

        // Incapable hardware never requests VRR, even under fullscreen policy.
        var vrrIncapable = VrrState(capable: false)
        vrrIncapable.policy = .fullscreen
        #expect(!vrrIncapable.requestedFor(directScanoutEligible: true), "vrr-incapable-never-requests")

        // fullscreen_direct_scanout_only honors the per-frame eligibility.
        var vrr = VrrState(capable: true)
        #expect(vrr.requestedFor(directScanoutEligible: true), "vrr-eligible-true")
        #expect(!vrr.requestedFor(directScanoutEligible: false), "vrr-eligible-false")

        // ALLOW_MODESET forced only when toggling the committed state. flagsForCommit
        // mutates (latches), so it is hoisted out of #expect (which binds immutably).
        let toggleOn = vrr.flagsForCommit(requestedVrr: true)
        #expect(toggleOn == drmModeAtomicAllowModeset, "vrr-flags-toggle-on")
        let noChange = vrr.flagsForCommit(requestedVrr: false)
        #expect(noChange == 0, "vrr-flags-no-change")
        vrr.applyAfterCommit(requestedVrr: true)
        let latched = vrr.flagsForCommit(requestedVrr: true)
        #expect(vrr.enabled && latched == 0, "vrr-latch-after-commit")
        let toggleOff = vrr.flagsForCommit(requestedVrr: false)
        #expect(toggleOff == drmModeAtomicAllowModeset, "vrr-flags-toggle-off")
    }

    @Test func recovery() {
        var rec = RecoveryState()
        #expect(rec.isClear, "rec-fresh-clear")
        rec.busyRetryCount = 3
        rec.resetBusy()
        #expect(rec.busyRetryCount == 0, "rec-reset-busy")

        // Backoff schedule: 250 × 2^min(attempt,3) → 250,500,1000,2000,2000…
        #expect(RecoveryState.backoffDelayMs(forAttempt: 0) == 250, "rec-backoff-0")
        #expect(RecoveryState.backoffDelayMs(forAttempt: 1) == 500, "rec-backoff-1")
        #expect(RecoveryState.backoffDelayMs(forAttempt: 2) == 1000, "rec-backoff-2")
        #expect(RecoveryState.backoffDelayMs(forAttempt: 3) == 2000, "rec-backoff-3")
        #expect(RecoveryState.backoffDelayMs(forAttempt: 9) == 2000, "rec-backoff-capped")

        // enterDegraded latches degraded, bumps the attempt, schedules next.
        rec.enterDegraded(nowNs: 10_000_000_000)
        #expect(rec.degraded && rec.recoveryAttemptCount == 1, "rec-enter-degraded")
        #expect(rec.nextRecoveryNs == 10_000_000_000 + 250 * 1_000_000, "rec-next-scheduled")
        #expect(!rec.isRecoveryDue(nowNs: 10_100_000_000), "rec-not-due-yet")
        #expect(rec.isRecoveryDue(nowNs: 10_300_000_000), "rec-due-after-delay")
        // Second entry uses the next backoff bracket (500ms).
        rec.enterDegraded(nowNs: 20_000_000_000)
        #expect(rec.recoveryAttemptCount == 2 && rec.nextRecoveryNs == 20_000_000_000 + 500 * 1_000_000,
                "rec-second-bracket")
        rec.clear()
        #expect(rec.isClear, "rec-clear")
    }

    @Test func telemetry() {
        var tel = FrameTelemetry()
        tel.noteRenderedFrame(); tel.noteRenderedFrame()
        tel.noteGpuCompletedFrame()
        tel.noteDroppedRenderedFrame()
        tel.noteComposedFrameFailure(.atomicCommitRejected)
        tel.noteComposedFrameFailure(.queueOverflow)
        #expect(tel.renderedFrameCount == 2 && tel.gpuCompletedFrameCount == 1 &&
                tel.droppedRenderedFrameCount == 1 && tel.composedFrameFailureCount == 2,
                "tel-counters")

        // Timing aggregate: count/sum/max/mean.
        #expect(tel.meanComposedFrameNs == nil, "tel-mean-empty")
        tel.recordComposedFrameTiming(totalNs: 1000)
        tel.recordComposedFrameTiming(totalNs: 3000)
        #expect(tel.composedFrameTimingCount == 2 && tel.composedFrameTimingTotalNs == 4000 &&
                tel.composedFrameTimingMaxNs == 3000 && tel.meanComposedFrameNs == 2000,
                "tel-timing-aggregate")

        // One-shot color-diag gates, independent per kind.
        #expect(tel.shouldLogColorDiag(.composed) && tel.shouldLogColorDiag(.direct), "tel-diag-initial")
        tel.markColorDiagLogged(.composed)
        #expect(!tel.shouldLogColorDiag(.composed) && tel.shouldLogColorDiag(.direct), "tel-diag-one-shot")

        // First-page-flip fires exactly once. shouldLogFirstPageFlip mutates, so
        // hoist out of #expect (which binds immutably).
        let firstFlip = tel.shouldLogFirstPageFlip()
        #expect(firstFlip, "tel-first-flip")
        let secondFlip = tel.shouldLogFirstPageFlip()
        #expect(!secondFlip, "tel-first-flip-once")
    }
}
