import Testing

@testable import NucleusWindowClientWayland

@Suite struct PresentationFrameTimestampTests {
    @Test func firstFrameAnchorsTheProtocolClockToMonotonicTime() {
        var timestamp = NucleusPresentationFrameTimestamp()

        #expect(
            timestamp.resolve(
                protocolMilliseconds: 7,
                observedMonotonicNanoseconds: 5_000_000_000)
                == 5_000_000_000)
    }

    @Test func subsequentFramesUseProtocolDeltasAcrossWraparound() {
        var timestamp = NucleusPresentationFrameTimestamp()
        _ = timestamp.resolve(
            protocolMilliseconds: UInt32.max - 5,
            observedMonotonicNanoseconds: 8_000_000_000)

        #expect(
            timestamp.resolve(
                protocolMilliseconds: 10,
                observedMonotonicNanoseconds: 9_000_000_000)
                == 8_016_000_000)
    }

    @Test func regressingProtocolTimeDoesNotRegressTheRuntimeClock() {
        var timestamp = NucleusPresentationFrameTimestamp()
        _ = timestamp.resolve(
            protocolMilliseconds: 1_000,
            observedMonotonicNanoseconds: 12_000_000_000)

        #expect(
            timestamp.resolve(
                protocolMilliseconds: 900,
                observedMonotonicNanoseconds: 13_000_000_000)
                == 12_000_000_000)
    }
}
