import Testing
import NucleusPresentationBackendContractTestSupport
@testable import NucleusWindowClientRender

private struct WaylandBackingStoreContractAdapter:
    PresentationBackendContractState
{
    var slot = WaylandBackingStoreSlotLifecycle()
    var pacing = WaylandBackingStorePacingState()
    var acquired = false
    var timelineValue: UInt64 = 0

    var exposesOutput: Bool {
        !pacing.paused && !pacing.removed
    }

    var acceptsFrame: Bool {
        pacing.canAcquire(
            hasReusableSlot: !acquired)
    }

    var resourceIsReusable: Bool {
        !acquired && slot.isReusable(
            timelineValue: timelineValue)
    }

    mutating func acquire() {
        acquired = true
    }

    mutating func submit() {
        slot.committed(releasePoint: 2)
        pacing.committedFrame()
    }

    mutating func completePresentation() {
        pacing.frameCallbackCompleted()
        acquired = false
    }

    mutating func replacePresentedResource() {
        timelineValue = 2
        slot.compositorReleased()
    }

    mutating func pause() {
        pacing.pause()
    }

    mutating func resume() {
        pacing.resume()
    }

    mutating func removeOutput() {
        pacing.remove()
    }
}

@Suite
struct WaylandBackingStoreLifecycleTests {
    @Test
    func satisfiesSharedPresentationBackendContract() {
        #expect(validatePresentationBackendContract(
            WaylandBackingStoreContractAdapter()).isEmpty)
    }

    @Test
    func reuseRequiresBothWaylandReleaseAndTimelineRelease() {
        var slot = WaylandBackingStoreSlotLifecycle()
        #expect(slot.isReusable(timelineValue: 0))

        slot.committed(releasePoint: 2)
        #expect(!slot.isReusable(timelineValue: 2))
        slot.compositorReleased()
        #expect(!slot.isReusable(timelineValue: 1))
        #expect(slot.isReusable(timelineValue: 2))
    }

    @Test
    func resizeRetiresGenerationUntilEveryReleaseCompletes() {
        var slot = WaylandBackingStoreSlotLifecycle()
        slot.committed(releasePoint: 8)
        slot.retire()
        #expect(!slot.isReusable(timelineValue: 8))
        #expect(!slot.isReclaimable(timelineValue: 8))

        slot.compositorReleased()
        #expect(!slot.isReclaimable(timelineValue: 7))
        #expect(slot.isReclaimable(timelineValue: 8))
    }

    @Test
    func frameCallbackPacesCommitsAndPauseModelsOcclusion() {
        var pacing = WaylandBackingStorePacingState()
        #expect(pacing.canAcquire(hasReusableSlot: true))
        pacing.committedFrame()
        #expect(!pacing.canAcquire(hasReusableSlot: true))

        pacing.frameCallbackCompleted()
        #expect(pacing.canAcquire(hasReusableSlot: true))
        pacing.pause()
        #expect(!pacing.canAcquire(hasReusableSlot: true))
        pacing.resume()
        #expect(pacing.canAcquire(hasReusableSlot: true))
    }

    @Test
    func outputRemovalPermanentlyClosesPresentation() {
        var pacing = WaylandBackingStorePacingState()
        pacing.committedFrame()
        pacing.remove()
        #expect(!pacing.frameCallbackPending)
        #expect(!pacing.canAcquire(hasReusableSlot: true))
        pacing.resume()
        #expect(!pacing.canAcquire(hasReusableSlot: true))
    }
}
