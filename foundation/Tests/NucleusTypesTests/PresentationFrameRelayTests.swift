import NucleusAppHostProtocols
import Testing

@MainActor
@Suite struct PresentationFrameRelayTests {
    @Test func startAndStopOwnExactlyOneRequest() throws {
        let source = NucleusPresentationFrameRelay()
        source.attachSurface()

        #expect(throws: NucleusPresentationFrameRelay.RequestError.inactive) {
            try source.requestPresentationFrame { _ in }
        }

        source.start()
        try source.requestPresentationFrame { _ in }
        #expect(source.hasOutstandingRequest)
        #expect(throws: NucleusPresentationFrameRelay.RequestError.requestOutstanding) {
            try source.requestPresentationFrame { _ in }
        }

        source.stop()
        #expect(!source.hasOutstandingRequest)
        #expect(throws: NucleusPresentationFrameRelay.RequestError.inactive) {
            try source.requestPresentationFrame { _ in }
        }
    }

    @Test func surfaceReplacementCancelsBeforeRearming() throws {
        let source = NucleusPresentationFrameRelay()
        source.start()
        source.attachSurface()
        try source.requestPresentationFrame { _ in }

        source.attachSurface()
        #expect(!source.hasOutstandingRequest)

        try source.requestPresentationFrame { _ in }
        #expect(source.hasOutstandingRequest)
        source.detachSurface()
        #expect(!source.hasOutstandingRequest)
        #expect(throws: NucleusPresentationFrameRelay.RequestError.surfaceUnavailable) {
            try source.requestPresentationFrame { _ in }
        }
    }

    @Test func deliveryIsOneShotAndUsesPlatformNanoseconds() throws {
        let source = NucleusPresentationFrameRelay()
        var timestamps: [UInt64] = []
        source.start()
        source.attachSurface()
        try source.requestPresentationFrame { timestamps.append($0) }

        source.deliver(frameTimeNanoseconds: 16_666_667)
        source.deliver(frameTimeNanoseconds: 33_333_334)

        #expect(timestamps == [16_666_667])
        #expect(!source.hasOutstandingRequest)
    }

    @Test func negativePlatformTimestampClampsToMonotonicOrigin() throws {
        let source = NucleusPresentationFrameRelay()
        var timestamp: UInt64?
        source.start()
        source.attachSurface()
        try source.requestPresentationFrame { timestamp = $0 }

        source.deliver(frameTimeNanoseconds: -1)

        #expect(timestamp == 0)
    }
}
