import Testing
@_spi(NucleusPlatform) import NucleusRenderer
@_spi(NucleusPlatform) import NucleusCompositorRendererLinux
@testable import NucleusCompositorRenderRuntime

private func frame(outputID: UInt64, serial: UInt64) -> RenderFrameTelemetry {
    var value = RenderFrameTelemetry()
    value.outputID = outputID
    value.frameSerial = serial
    return value
}

@Test func submissionMayArriveBeforeFrameTelemetry() {
    var correlator = PresentationTelemetryCorrelator()

    #expect(correlator.noteSubmission(
        outputID: 7, frameSerial: 42, atomicCommitAcceptedNs: 1_000) == nil)
    let accepted = correlator.noteFrame(frame(outputID: 7, serial: 42))

    #expect(accepted?.frame.frameSerial == 42)
    #expect(accepted?.atomicCommitAcceptedNs == 1_000)
    var fences = CompositeFenceTelemetry()
    fences.clientAcquireFenceCount = 2
    fences.latestClientAcquireSignalNs = 1_400
    fences.renderCompleteNs = 1_600
    let presented = correlator.notePageflip(
        outputID: 7, frameSerial: 42, pageflipNs: 2_000,
        fenceTelemetry: fences)
    #expect(presented?.frame.outputID == 7)
    #expect(presented?.pageflipNs == 2_000)
    #expect(presented?.fenceTelemetry == fences)
}

@Test func serialMatchingIsIndependentAcrossOutputs() {
    var correlator = PresentationTelemetryCorrelator()
    _ = correlator.noteFrame(frame(outputID: 10, serial: 1))
    _ = correlator.noteFrame(frame(outputID: 20, serial: 2))

    let second = correlator.noteSubmission(
        outputID: 20, frameSerial: 2, atomicCommitAcceptedNs: 200)
    let first = correlator.noteSubmission(
        outputID: 10, frameSerial: 1, atomicCommitAcceptedNs: 100)

    #expect(second?.frame.outputID == 20)
    #expect(first?.frame.outputID == 10)
    #expect(correlator.notePageflip(
        outputID: 10, frameSerial: 1, pageflipNs: 300)?.frame.frameSerial == 1)
    #expect(correlator.notePageflip(
        outputID: 20, frameSerial: 2, pageflipNs: 400)?.frame.frameSerial == 2)
}

@Test func directScanoutSerialZeroCannotShiftCompositeTelemetry() {
    var correlator = PresentationTelemetryCorrelator()
    _ = correlator.noteFrame(frame(outputID: 5, serial: 9))
    let composite = correlator.noteSubmission(
        outputID: 5, frameSerial: 9, atomicCommitAcceptedNs: 900)
    #expect(composite != nil)

    #expect(correlator.noteSubmission(
        outputID: 5, frameSerial: 0, atomicCommitAcceptedNs: 950) == nil)
    #expect(correlator.notePageflip(
        outputID: 5, frameSerial: 0, pageflipNs: 1_000) == nil)
    #expect(correlator.notePageflip(
        outputID: 5, frameSerial: 9, pageflipNs: 1_100)?.frame.frameSerial == 9)
}

@Test func staleAndUnknownPageflipsAreDiscardedByExactKey() {
    var correlator = PresentationTelemetryCorrelator()
    _ = correlator.noteFrame(frame(outputID: 1, serial: 11))
    _ = correlator.noteSubmission(
        outputID: 1, frameSerial: 11, atomicCommitAcceptedNs: 100)

    #expect(correlator.notePageflip(
        outputID: 1, frameSerial: 10, pageflipNs: 150) == nil)
    #expect(correlator.notePageflip(
        outputID: 2, frameSerial: 11, pageflipNs: 175) == nil)
    #expect(correlator.notePageflip(
        outputID: 1, frameSerial: 11, pageflipNs: 200)?.frame.frameSerial == 11)
    #expect(correlator.notePageflip(
        outputID: 1, frameSerial: 11, pageflipNs: 250) == nil)

    #expect(correlator.noteFrame(frame(outputID: 1, serial: 10)) == nil)
    #expect(correlator.noteSubmission(
        outputID: 1, frameSerial: 10, atomicCommitAcceptedNs: 300) == nil)
}
