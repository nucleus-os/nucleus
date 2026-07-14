import Testing
import WaylandClientC
import WaylandClient

// Proves the ergonomic client layer imports under C++ interop and its lifecycle is sound. No
// compositor runs in the test env, so a connection to a bogus socket must fail cleanly (nil), and a
// DesiredGlobal must expose the interface's wire name for registry matching.
@Suite struct WaylandClientTests {
    @Test func connectToMissingCompositorFailsCleanly() {
        // A socket name that cannot exist → wl_display_connect fails → init? returns nil.
        #expect(WaylandConnection(socket: "swift-wayland-nonexistent-socket") == nil)
    }

    @Test func desiredGlobalExposesInterfaceName() {
        let want = DesiredGlobal(swift_wayland_iface_wl_compositor(), maxVersion: 6)
        #expect(want.interfaceName == "wl_compositor")
        #expect(want.allowsMultiple == false)
    }
}
