import Testing
import Glibc
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

    @Test func cancelledPreparedReadLeavesConnectionReusable() throws {
        var sockets: [Int32] = [0, 0]
        try #require(socketpair(
            AF_UNIX,
            Int32(SOCK_STREAM.rawValue),
            0,
            &sockets) == 0)
        defer { close(sockets[0]) }
        let connection = try #require(WaylandConnection(fd: sockets[1]))

        let first = try #require(connection.prepareRead())
        first.read.cancel()

        let second = try #require(connection.prepareRead())
        #expect(second.dispatchedEventCount == 0)
        #expect(second.read.complete(readable: false) == 0)
    }
}
