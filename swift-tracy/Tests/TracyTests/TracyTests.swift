import Testing
import Tracy

// Exercises the Trace surface end-to-end. Assertions hold in both build modes: no receiver is
// connected in a unit test, so `connected` is false whether or not TRACY_ENABLE is set, and the
// inert (default) build turns every call into a no-op.
@Suite struct TracyTests {
    @Test func apiRunsWithoutCrashing() {
        Trace.setThreadName("swift-tracy-test")
        Trace.message("hello")
        Trace.message("colored", color: Trace.Color.green)
        Trace.plot("metric", 1.5)
        Trace.plot("count", Int64(3))
        Trace.frameMarkStart("output-frame")
        Trace.frameMarkEnd("output-frame")
        let z = Trace.beginZone("manual", color: Trace.Color.blue)
        z.text("detail")
        z.value(7)
        z.end()
        #expect(Trace.connected == false)
    }

    @Test func zoneScopeReturnsBodyValue() {
        #expect(Trace.zone("work") { 40 + 2 } == 42)
    }
}
