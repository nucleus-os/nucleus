import Testing
@testable import NucleusCompositorRendererLinux

// M2 Phase 4 — the scanned-surface state machine that drives deferred client-buffer
// release. The bug this fixes: treating a surface as scanned at commit-*submit* time
// lied about the plane during the in-flight-flip window, so a buffer could be released
// while the kernel still scanned it (tearing). The correct rule: a surface is scanned
// from submit (pending) until the flip that replaces it completes (front rotates).
@Suite struct ScanoutSurfaceTrackerTests {
    let outputA: UInt64 = 1
    let outputB: UInt64 = 2

    @Test func pendingBufferCountsAsScannedBeforeItsFlip() {
        var t = ScanoutSurfaceTracker()
        t.submitScanout(output: outputA, iosurfaceID: 100)
        #expect(t.isScannedOut(100), "an in-flight (pending) buffer is on the plane")
    }

    @Test func scanoutToCompositeKeepsOldBufferScannedUntilItsFlip() {
        // The reviewer's headline scenario: A is scanned on the plane; the output
        // switches to composite; A must stay "scanned" until the composite flip lands,
        // or a mid-flight commit would release A while it is still displayed.
        var t = ScanoutSurfaceTracker()
        t.submitScanout(output: outputA, iosurfaceID: 100)
        t.flipCompleted(output: outputA)  // A now latched (front)
        #expect(t.isScannedOut(100))

        t.submitComposite(output: outputA)  // composite submitted; A still on plane
        #expect(t.isScannedOut(100), "A stays scanned until the composite flip replaces it")

        t.flipCompleted(output: outputA)  // composite now latched; A gone
        #expect(!t.isScannedOut(100), "A released only after the flip that replaced it")
    }

    @Test func surfaceHandoffKeepsPriorSurfaceScannedUntilFlip() {
        var t = ScanoutSurfaceTracker()
        t.submitScanout(output: outputA, iosurfaceID: 100)
        t.flipCompleted(output: outputA)  // S1 (100) latched

        t.submitScanout(output: outputA, iosurfaceID: 200)  // S2 (200) submitted
        #expect(t.isScannedOut(100), "S1 still latched until S2's flip")
        #expect(t.isScannedOut(200), "S2 in-flight is also on the plane")

        t.flipCompleted(output: outputA)  // S2 latched, S1 gone
        #expect(!t.isScannedOut(100))
        #expect(t.isScannedOut(200))
    }

    @Test func independentPerOutput() {
        var t = ScanoutSurfaceTracker()
        t.submitScanout(output: outputA, iosurfaceID: 100)
        t.submitScanout(output: outputB, iosurfaceID: 200)
        t.flipCompleted(output: outputA)
        #expect(t.isScannedOut(100))
        #expect(t.isScannedOut(200))
        t.removeOutput(outputB)
        #expect(!t.isScannedOut(200), "removing an output forgets its scanned surface")
        #expect(t.isScannedOut(100))
    }

    @Test func resetForgetsEverything() {
        var t = ScanoutSurfaceTracker()
        t.submitScanout(output: outputA, iosurfaceID: 100)
        t.flipCompleted(output: outputA)
        t.reset()
        #expect(!t.isScannedOut(100))
    }
}
