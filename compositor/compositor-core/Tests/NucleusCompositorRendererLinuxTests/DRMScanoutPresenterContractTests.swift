import NucleusPresentationBackendContractTestSupport
import Testing
@testable import NucleusCompositorRendererLinux

private struct DRMScanoutContractAdapter:
    PresentationBackendContractState
{
    private let outputID: UInt64 = 1
    private let surfaceID: UInt64 = 42
    private var tracker = ScanoutSurfaceTracker()
    private var acquired = false
    private var framePending = false
    private var paused = false
    private var removed = false

    var exposesOutput: Bool {
        !paused && !removed
    }

    var acceptsFrame: Bool {
        exposesOutput && !acquired && !framePending
    }

    var resourceIsReusable: Bool {
        !acquired && !tracker.isScannedOut(surfaceID)
    }

    mutating func acquire() {
        acquired = true
    }

    mutating func submit() {
        framePending = true
        tracker.submitScanout(
            output: outputID,
            iosurfaceID: surfaceID)
    }

    mutating func completePresentation() {
        tracker.flipCompleted(output: outputID)
        framePending = false
        acquired = false
    }

    mutating func replacePresentedResource() {
        framePending = true
        tracker.submitComposite(output: outputID)
    }

    mutating func pause() {
        paused = true
    }

    mutating func resume() {
        guard !removed else { return }
        paused = false
    }

    mutating func removeOutput() {
        removed = true
        paused = true
        framePending = false
        tracker.removeOutput(outputID)
    }
}

@Suite
struct DRMScanoutPresenterContractTests {
    @Test
    func satisfiesSharedPresentationBackendContract() {
        #expect(validatePresentationBackendContract(
            DRMScanoutContractAdapter()).isEmpty)
    }
}
