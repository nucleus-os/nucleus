import Testing
@testable import NucleusCompositorRendererLinux

@Suite struct DrmPresentationClockTests {
    @Test func realtimeConversionHandlesBothClockOffsets() {
        #expect(DrmPresentationClock.convertRealtimeToMonotonic(
            1_000, monotonicNowNs: 5_000, realtimeNowNs: 4_000) == 2_000)
        #expect(DrmPresentationClock.convertRealtimeToMonotonic(
            5_000, monotonicNowNs: 4_000, realtimeNowNs: 5_000) == 4_000)
        #expect(DrmPresentationClock.convertRealtimeToMonotonic(
            500, monotonicNowNs: 4_000, realtimeNowNs: 5_000) == nil)
    }

    @Test func sequenceExtendsAcrossUInt32Wrap() {
        var extender = DrmSequenceExtender()
        #expect(extender.extend(UInt32.max - 1) == UInt64(UInt32.max - 1))
        #expect(extender.extend(UInt32.max) == UInt64(UInt32.max))
        #expect(extender.extend(0) == UInt64(UInt32.max) + 1)
        #expect(extender.extend(1) == UInt64(UInt32.max) + 2)
    }

    @Test func duplicateAndBackwardSequencesAreRejectedWithoutPoisoningState() {
        var extender = DrmSequenceExtender()
        #expect(extender.extend(100) == 100)
        #expect(extender.extend(100) == nil)
        #expect(extender.extend(99) == nil)
        #expect(extender.extend(101) == 101)
    }

    @Test func eventStateRejectsBackwardTimeAndPreservesLastGoodSample() {
        var state = DrmPresentationEventState()
        let clock = DrmPresentationClock(kernelUsesMonotonic: true)
        #expect(state.accept(
            DrmPageFlipEvent(timestampNs: 1_000, sequence: 10, crtcId: 2),
            clock: clock)?.sequence == 10)
        #expect(state.accept(
            DrmPageFlipEvent(timestampNs: 999, sequence: 11, crtcId: 2),
            clock: clock) == nil)
        let accepted = state.accept(
            DrmPageFlipEvent(timestampNs: 1_001, sequence: 11, crtcId: 2),
            clock: clock)
        #expect(accepted?.sequence == 11)
        #expect(accepted?.timestampNs == 1_001)
    }
}
