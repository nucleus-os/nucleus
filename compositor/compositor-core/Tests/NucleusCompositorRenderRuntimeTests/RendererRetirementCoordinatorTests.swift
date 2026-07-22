import Glibc
import Testing
@testable import NucleusCompositorRendererLinux
@testable import NucleusCompositorRenderRuntime

@MainActor
@Suite
struct RendererRetirementCoordinatorTests {
    private final class ScanoutOwner {}

    private func makeOutput(id: UInt32) -> DrmOutput {
        DrmOutput(
            device: DrmDeviceLifetime(fileDescriptor: -1),
            connectorId: id,
            crtcId: id + 100,
            planeId: id + 200,
            modeBlobId: 0,
            width: 1_920,
            height: 1_080,
            props: AtomicProps(
                connCrtcId: 1,
                crtcActive: 2,
                crtcModeId: 3,
                planeFbId: 4,
                planeCrtcId: 5,
                planeSrcX: 6,
                planeSrcY: 7,
                planeSrcW: 8,
                planeSrcH: 9,
                planeCrtcX: 10,
                planeCrtcY: 11,
                planeCrtcW: 12,
                planeCrtcH: 13))
    }

    @Test
    func pauseWaitsForEveryFlipAndKernelBusyBeforeAcknowledging() {
        let first = makeOutput(id: 1)
        let second = makeOutput(id: 2)
        var firstOwner: ScanoutOwner? = ScanoutOwner()
        var secondOwner: ScanoutOwner? = ScanoutOwner()
        weak let observedFirst = firstOwner
        weak let observedSecond = secondOwner
        first.noteScanoutCommitAccepted(retaining: firstOwner!)
        second.noteScanoutCommitAccepted(retaining: secondOwner!)
        firstOwner = nil
        secondOwner = nil

        var coordinator = RendererRetirementCoordinator(
            retryDelayNanoseconds: 5,
            shutdownGraceNanoseconds: 100)
        var disableCalls = 0
        var result = retireDrmOutputs([first, second]) { _ in
            disableCalls += 1
            return .accepted
        }
        #expect(result == .draining)
        #expect(coordinator.applyPauseResult(
            result, nowNanoseconds: 10) == .waiting(
                retryAtNanoseconds: 15))
        #expect(disableCalls == 0)
        #expect(observedFirst != nil)
        #expect(observedSecond != nil)

        #expect(first.notePageFlipComplete())
        #expect(second.notePageFlipComplete())
        result = retireDrmOutputs([first, second]) { _ in
            disableCalls += 1
            return .rejected(errno: EBUSY)
        }
        #expect(result == .draining)
        #expect(coordinator.applyPauseResult(
            result, nowNanoseconds: 15) == .waiting(
                retryAtNanoseconds: 20))
        #expect(disableCalls == 1)
        #expect(observedFirst != nil)
        #expect(observedSecond != nil)

        result = retireDrmOutputs([first, second]) { _ in
            disableCalls += 1
            return .accepted
        }
        #expect(coordinator.applyPauseResult(
            result, nowNanoseconds: 20) == .acknowledge(
                cleanlyRetired: true))
        #expect(disableCalls == 2)
        #expect(observedFirst == nil)
        #expect(observedSecond == nil)
        #expect(coordinator.phase == .paused)
    }

    @Test
    func headlessSessionLifecycleHandlesHotplugDeviceLossAndLateCallbacks() {
        let removed = makeOutput(id: 1)
        let replaced = makeOutput(id: 2)
        var removedOwner: ScanoutOwner? = ScanoutOwner()
        var replacedOwner: ScanoutOwner? = ScanoutOwner()
        weak let observedRemoved = removedOwner
        weak let observedReplaced = replacedOwner
        removed.noteScanoutCommitAccepted(retaining: removedOwner!)
        replaced.noteScanoutCommitAccepted(retaining: replacedOwner!)
        removedOwner = nil
        replacedOwner = nil

        var coordinator = RendererRetirementCoordinator(
            retryDelayNanoseconds: 5,
            shutdownGraceNanoseconds: 100)
        var acknowledgementCount = 0
        var disableAttempts = 0
        var disabledConnectorIDs: [[UInt32]] = []

        func applyPause(_ result: RendererRetirementResult, at now: UInt64) {
            if case .acknowledge = coordinator.applyPauseResult(
                result, nowNanoseconds: now)
            {
                acknowledgementCount += 1
            }
        }

        // A hotplug inventory change can arrive while retirement is blocked. The
        // live topology remains intact until the old generation is retired; the
        // replacement is attached only after resume rediscovers the inventory.
        var pendingReplacementID: UInt32? = 3
        var result = retireDrmOutputs([removed, replaced]) { disabling in
            disableAttempts += 1
            disabledConnectorIDs.append(disabling.map(\.connectorId))
            return .accepted
        }
        applyPause(result, at: 10)
        #expect(acknowledgementCount == 0)
        #expect(disableAttempts == 0)
        #expect(observedRemoved != nil)
        #expect(observedReplaced != nil)
        #expect(pendingReplacementID == 3)

        #expect(removed.notePageFlipComplete())
        #expect(!removed.notePageFlipComplete(), "late duplicate flip is inert")
        #expect(replaced.notePageFlipComplete())
        result = retireDrmOutputs([removed, replaced]) { disabling in
            disableAttempts += 1
            disabledConnectorIDs.append(disabling.map(\.connectorId))
            return .rejected(errno: EBUSY)
        }
        applyPause(result, at: 15)
        #expect(acknowledgementCount == 0)
        #expect(disableAttempts == 1)

        // Device loss releases that output's owner and removes it from the next
        // atomic disable. The still-live output remains retained through retry.
        removed.noteDeviceLost()
        #expect(observedRemoved == nil)
        #expect(observedReplaced != nil)
        result = retireDrmOutputs([removed, replaced]) { disabling in
            disableAttempts += 1
            disabledConnectorIDs.append(disabling.map(\.connectorId))
            return .accepted
        }
        applyPause(result, at: 20)
        #expect(acknowledgementCount == 1)
        #expect(disableAttempts == 2)
        #expect(disabledConnectorIDs == [[1, 2], [2]])
        #expect(observedReplaced == nil)

        coordinator.noteResume(succeeded: true)
        let replacement = makeOutput(id: pendingReplacementID!)
        pendingReplacementID = nil
        #expect(replacement.lifecycleState == .disabled)
        #expect(coordinator.phase == .active)
        #expect(acknowledgementCount == 1)
    }

    @Test
    func shutdownDeadlineRequiresDeviceCloseBeforeOwnerTeardown() {
        var coordinator = RendererRetirementCoordinator(
            retryDelayNanoseconds: 5,
            shutdownGraceNanoseconds: 12)

        #expect(coordinator.applyShutdownResult(
            .draining, nowNanoseconds: 100) == .waiting(
                retryAtNanoseconds: 105,
                deadlineNanoseconds: 112))
        #expect(coordinator.applyShutdownResult(
            .draining, nowNanoseconds: 105) == .waiting(
                retryAtNanoseconds: 110,
                deadlineNanoseconds: 112))
        #expect(coordinator.applyShutdownResult(
            .draining, nowNanoseconds: 112) == .readyToExit(
                .drmDeviceCloseRequired))
        #expect(coordinator.phase == .finished(
            .drmDeviceCloseRequired))
    }

    @Test
    func successfulShutdownUsesCleanOutputRetirementDisposition() {
        var coordinator = RendererRetirementCoordinator(
            retryDelayNanoseconds: 5,
            shutdownGraceNanoseconds: 12)

        #expect(coordinator.applyShutdownResult(
            .complete, nowNanoseconds: 100) == .readyToExit(
                .outputsDisabled))
        #expect(coordinator.phase == .finished(.outputsDisabled))
        #expect(coordinator.applyShutdownResult(
            .failed, nowNanoseconds: 101) == .readyToExit(
                .outputsDisabled))
    }

    @Test
    func terminalRetirementFailureRequiresDeviceClose() {
        var coordinator = RendererRetirementCoordinator(
            retryDelayNanoseconds: 5,
            shutdownGraceNanoseconds: 12)

        #expect(coordinator.applyShutdownResult(
            .failed, nowNanoseconds: 100) == .readyToExit(
                .drmDeviceCloseRequired))
        #expect(coordinator.phase == .finished(.drmDeviceCloseRequired))
    }

    @Test
    func successfulResumeStartsANewRetirementEpoch() {
        var coordinator = RendererRetirementCoordinator(
            retryDelayNanoseconds: 5,
            shutdownGraceNanoseconds: 100)
        #expect(coordinator.applyPauseResult(
            .complete, nowNanoseconds: 0) == .acknowledge(
                cleanlyRetired: true))
        coordinator.noteResume(succeeded: false)
        #expect(coordinator.phase == .paused)
        coordinator.noteResume(succeeded: true)
        #expect(coordinator.phase == .active)
        #expect(coordinator.applyPauseResult(
            .failed, nowNanoseconds: .max) == .acknowledge(
                cleanlyRetired: false))
    }
}
