import Testing
@testable import NucleusRenderServerRuntime

@MainActor
@Suite struct OwnerControlTests {
    @Test func refreshIntervalPreservesFractionalMillihertz() {
        #expect(
            CompositorRuntime.millihertz(
                fromIntervalNs: 1_000_000_000_000 / 59_940)
                == 59_940)
        #expect(CompositorRuntime.millihertz(fromIntervalNs: 0) == 0)
    }
}
