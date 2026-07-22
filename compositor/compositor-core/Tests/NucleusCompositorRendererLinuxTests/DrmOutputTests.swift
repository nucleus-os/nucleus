import Testing
@testable import NucleusRenderer
@testable import NucleusCompositorRendererLinux
import NucleusCompositorDrmC
import Glibc

// commit assembly (property set, flags, VRR latch, lifecycle drain) is checked
// against synthetic props — hardware-independent. The fixture's best-effort real
// discover + KMS test-only commit (which asserted nothing) is dropped.
@Suite struct DrmOutputTests {
    /// Synthetic props with every required id present (distinct non-zero ids).
    static func syntheticProps() -> AtomicProps {
        AtomicProps(
            connCrtcId: 1, connBroadcastRgb: 2,
            crtcActive: 10, crtcModeId: 11, crtcVrrEnabled: 12, crtcOutFencePtr: 13,
            crtcGammaLut: 14, crtcDegammaLut: 15, crtcCtm: 16,
            planeFbId: 20, planeCrtcId: 21, planeSrcX: 22, planeSrcY: 23, planeSrcW: 24, planeSrcH: 25,
            planeCrtcX: 26, planeCrtcY: 27, planeCrtcW: 28, planeCrtcH: 29,
            planeInFenceFd: 30, planeColorRange: 31)
    }

    static func makeOutput(vrrCapable: Bool = false) -> DrmOutput {
        DrmOutput(
            deviceFd: -1, connectorId: 100, crtcId: 200, planeId: 300,
            modeBlobId: 0xabc, width: 1920, height: 1080, props: syntheticProps(),
            vrrCapable: vrrCapable)
    }

    @Test func scanoutCommitAssembly() {
        let output = Self.makeOutput()

        // Assemble a scanout commit into a builder and inspect the recorded set.
        guard var builder = AtomicRequestBuilder() else {
            Issue.record("builder-alloc")
            return
        }
        let assembled = output.assembleScanoutCommit(
            into: &builder, fbId: 0xfb, requestedVrr: false, inFenceFd: 42)
        #expect(assembled, "assemble-ok")

        func value(_ label: String) -> UInt64? { builder.entries.first { $0.label == label }?.value }
        // Connector routing + CRTC active/mode.
        #expect(value("connector.CRTC_ID") == 200, "assemble-connector-crtc")
        #expect(value("crtc.ACTIVE") == 1, "assemble-active")
        #expect(value("crtc.MODE_ID") == 0xabc, "assemble-mode")
        // Primary plane: fb id, 16.16 source size, full-output CRTC rect.
        #expect(value("plane.FB_ID") == 0xfb, "assemble-fb")
        #expect(value("plane.SRC_W") == UInt64(1920) << 16 && value("plane.SRC_H") == UInt64(1080) << 16,
                "assemble-src-fixed-point")
        #expect(value("plane.CRTC_W") == 1920 && value("plane.CRTC_H") == 1080, "assemble-crtc-rect")
        #expect(value("plane.IN_FENCE_FD") == 42, "assemble-in-fence")
        #expect(output.supportsInFence, "reports-in-fence-support")
        // Gamma/color pipeline present; COLOR_RANGE added once (by plane state).
        #expect(value("connector.Broadcast RGB") == 1 && value("crtc.GAMMA_LUT") != nil, "assemble-color-pipeline")
        let colorRangeCount = builder.entries.filter { $0.label == "plane.COLOR_RANGE" }.count
        #expect(colorRangeCount == 1, "assemble-color-range-once")
        // VRR_ENABLED is added (value 0) whenever the prop exists — matching the
        // Zig, which writes the requested state regardless of capability.
        #expect(value("crtc.VRR_ENABLED") == 0, "assemble-vrr-disabled-value")
    }

    @Test func scanoutCommitOmitsUnavailableFence() {
        var props = Self.syntheticProps()
        props.planeInFenceFd = 0
        let output = DrmOutput(
            deviceFd: -1, connectorId: 100, crtcId: 200, planeId: 300,
            modeBlobId: 1, width: 640, height: 480, props: props)
        var builder = AtomicRequestBuilder()!
        #expect(output.assembleScanoutCommit(
            into: &builder, fbId: 1, requestedVrr: false, inFenceFd: 42))
        #expect(!output.supportsInFence)
        #expect(!builder.entries.contains { $0.label == "plane.IN_FENCE_FD" })
    }

    @Test func vrrCommit() {
        // VRR-capable output adds VRR_ENABLED and the toggle forces a modeset.
        let vrrOut = Self.makeOutput(vrrCapable: true)
        var vb = AtomicRequestBuilder()!
        vrrOut.assembleScanoutCommit(into: &vb, fbId: 1, requestedVrr: true)
        #expect(vb.entries.contains { $0.label == "crtc.VRR_ENABLED" && $0.value == 1 }, "assemble-vrr-enabled")
        #expect(vrrOut.requestedVrr(directScanoutEligible: true), "vrr-requested-when-eligible")
        #expect(!vrrOut.requestedVrr(directScanoutEligible: false), "vrr-not-requested-otherwise")
        let flags = vrrOut.commitFlags(requestedVrr: true, pageFlipEvent: true, modeset: false)
        #expect(flags & drmModeAtomicAllowModeset != 0, "flags-vrr-toggle-modeset")
        #expect(flags & UInt32(DRM_MODE_PAGE_FLIP_EVENT) != 0, "flags-page-flip-event")
        #expect(flags & drmModeAtomicNonblock != 0, "live page flips must not block until vblank")
        let teardownStyle = vrrOut.commitFlags(
            requestedVrr: false, pageFlipEvent: false, modeset: true)
        #expect(teardownStyle & drmModeAtomicNonblock == 0, "eventless modesets remain blocking")
    }

    @Test func hasRequiredGating() {
        // hasRequired gating: drop a required plane prop → assembly refuses.
        var incomplete = Self.syntheticProps(); incomplete.planeFbId = 0
        let badOutput = DrmOutput(
            deviceFd: -1, connectorId: 1, crtcId: 2, planeId: 3, modeBlobId: 0,
            width: 100, height: 100, props: incomplete)
        var bb = AtomicRequestBuilder()!
        #expect(!badOutput.assembleScanoutCommit(into: &bb, fbId: 1, requestedVrr: false), "assemble-refuses-incomplete")
    }

    @Test func retirementWaitsForFlipAndRetriesKernelBusyWithoutReleasingOwner() {
        let output = Self.makeOutput()
        final class Owner {}
        var owner: Owner? = Owner()
        weak let retainedOwner = owner
        output.noteScanoutCommitAccepted(retaining: owner!)
        owner = nil

        #expect(output.lifecycleState == .pageFlipPending)
        #expect(retainedOwner != nil)
        var commitCalls = 0
        let waiting = retireDrmOutputs([output]) { _ in
            commitCalls += 1
            return .accepted
        }
        #expect(waiting == .draining)
        #expect(commitCalls == 0)
        #expect(output.lifecycleState == .drainingPageFlip)
        #expect(retainedOwner != nil)

        #expect(output.notePageFlipComplete())
        #expect(!output.notePageFlipComplete(), "duplicate completion is inert")
        #expect(output.lifecycleState == .drainingReady)
        #expect(retainedOwner != nil)

        let busy = retireDrmOutputs([output]) { _ in
            commitCalls += 1
            return .rejected(errno: EBUSY)
        }
        #expect(busy == .draining)
        #expect(commitCalls == 1)
        #expect(output.lifecycleState == .drainingReady)
        #expect(!output.lifecycleState.admitsScanoutCommit)
        #expect(output.active, "EBUSY keeps kernel scanout ownership live")
        #expect(retainedOwner != nil)

        let complete = retireDrmOutputs([output]) { _ in
            commitCalls += 1
            return .accepted
        }
        #expect(complete == .complete)
        #expect(commitCalls == 2)
        #expect(output.lifecycleState == .disabled)
        #expect(!output.active)
        #expect(retainedOwner == nil)
    }

    @Test func deviceLossIsTheOnlyNonDisablePathThatReleasesKernelOwners() {
        let output = Self.makeOutput()
        final class Owner {}
        var owner: Owner? = Owner()
        weak let retainedOwner = owner
        output.noteScanoutCommitAccepted(retaining: owner!)
        owner = nil
        #expect(!output.beginRetirement())
        #expect(retainedOwner != nil)

        output.noteDeviceLost()
        #expect(output.lifecycleState == .deviceLost)
        #expect(retainedOwner == nil)
        #expect(!output.notePageFlipComplete(), "late completion after device loss is inert")

        var commits = 0
        #expect(retireDrmOutputs([output]) { _ in
            commits += 1
            return .accepted
        } == .complete)
        #expect(commits == 0, "a lost device must not receive an atomic disable")
        #expect(output.lifecycleState == .deviceLost)
    }

    @Test func deviceWideRetirementExcludesLostOutputsFromTheDisableCommit() {
        final class Owner {}
        let lost = Self.makeOutput()
        let live = Self.makeOutput()
        lost.noteScanoutCommitAccepted(retaining: Owner())
        live.noteScanoutCommitAccepted(retaining: Owner())
        #expect(lost.notePageFlipComplete())
        #expect(live.notePageFlipComplete())
        lost.noteDeviceLost()

        var disabled: [DrmOutput] = []
        #expect(retireDrmOutputs([lost, live]) {
            disabled = $0
            return .accepted
        } == .complete)
        #expect(disabled.count == 1)
        #expect(disabled.first === live)
        #expect(lost.lifecycleState == .deviceLost)
        #expect(live.lifecycleState == .disabled)
    }

    @Test func deviceWideRetirementWaitsForEveryOutputBeforeOneCommit() {
        final class Owner {}
        let first = Self.makeOutput()
        let second = Self.makeOutput()
        first.noteScanoutCommitAccepted(retaining: Owner())
        second.noteScanoutCommitAccepted(retaining: Owner())
        #expect(second.notePageFlipComplete())

        var commits = 0
        #expect(retireDrmOutputs([first, second]) { _ in
            commits += 1
            return .accepted
        } == .draining)
        #expect(commits == 0)
        #expect(first.lifecycleState == .drainingPageFlip)
        #expect(second.lifecycleState == .drainingReady)

        #expect(first.notePageFlipComplete())
        #expect(retireDrmOutputs([first, second]) { _ in
            commits += 1
            return .accepted
        } == .complete)
        #expect(commits == 1)
        #expect(first.lifecycleState == .disabled)
        #expect(second.lifecycleState == .disabled)
    }

    @Test func recoveryGating() {
        let output = Self.makeOutput()
        output.enterDegradedRecovery(nowNs: 1_000_000_000)
        #expect(!output.shouldAttemptRecovery(nowNs: 1_000_000_000), "recovery-not-due-yet")
        #expect(output.shouldAttemptRecovery(nowNs: 2_000_000_000), "recovery-due-when-idle")
        output.clearRecovery()
        #expect(output.recovery.isClear, "recovery-clear")
    }

    @MainActor @Test func pageFlipCompletion() {
        let output = Self.makeOutput()
        // Page-flip completion clears the in-flight slot (via the token path).
        output.flipToken.onFlip(DrmPageFlipEvent(timestampNs: 1, sequence: 1, crtcId: 200))
        output.notePageFlipComplete()
        #expect(!output.pageFlipPending, "page-flip-complete-clears")
    }
}
