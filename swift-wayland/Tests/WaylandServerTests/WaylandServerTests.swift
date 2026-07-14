import Testing
import WaylandServer

// Exercises the ergonomic server layer under C++ interop: a wl_display + event loop + SHM is
// created, the loop fd is read, and dispatch/flush run with no clients — proving the public API
// imports, links libwayland-server, and the wl_* lifecycle wrappers work.
@Suite struct WaylandServerTests {
    @Test func displayLifecycle() {
        guard let display = WaylandDisplay() else {
            Issue.record("WaylandDisplay() returned nil — wl_display_create/init_shm failed")
            return
        }
        #expect(display.eventLoopFd >= 0)
        // No clients connected: dispatch + flush must be safe no-ops.
        display.dispatch()
        display.flushClients()
    }
}
