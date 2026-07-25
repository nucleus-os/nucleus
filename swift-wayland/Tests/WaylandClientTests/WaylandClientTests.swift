import Testing
import Glibc
import WaylandClientC
import WaylandClient
import WaylandClientDispatch

// Proves the ergonomic client layer imports under C++ interop and its lifecycle is sound. No
// compositor runs in the test env, so a connection to a bogus socket must fail cleanly (nil), and a
// DesiredGlobal must expose the interface's wire name for registry matching.
@Suite struct WaylandClientTests {
    @Test func connectToMissingCompositorFailsCleanly() {
        // A socket name that cannot exist → wl_display_connect fails → init? returns nil.
        #expect(WaylandConnection(socket: "swift-wayland-nonexistent-socket") == nil)
    }

    @Test func desiredGlobalExposesInterfaceName() {
        let want = unsafe DesiredGlobal(swift_wayland_iface_wl_compositor(), maxVersion: 6)
        #expect(want.interfaceName == "wl_compositor")
        #expect(want.allowsMultiple == false)
    }

    @Test func cancelledPreparedReadLeavesConnectionReusable() throws {
        var sockets: [Int32] = [0, 0]
        let socketResult = unsafe socketpair(
            AF_UNIX,
            Int32(SOCK_STREAM.rawValue),
            0,
            &sockets)
        try #require(socketResult == 0)
        defer { close(sockets[0]) }
        let connection = try #require(WaylandConnection(fd: sockets[1]))

        let first = try #require(connection.prepareRead())
        first.read.cancel()

        let second = try #require(connection.prepareRead())
        #expect(second.dispatchedEventCount == 0)
        #expect(second.read.complete(readable: false) == 0)
    }

    @Test func typedEventArrayViewCopiesAlignedValues() {
        var array = unsafe wl_array()
        unsafe wl_array_init(&array)
        defer { unsafe wl_array_release(&array) }
        let storage = unsafe wl_array_add(
            &array, 2 * MemoryLayout<UInt16>.stride)
        #expect(unsafe storage != nil)
        unsafe storage?.storeBytes(of: UInt16(7), as: UInt16.self)
        unsafe storage?.advanced(by: MemoryLayout<UInt16>.stride)
            .storeBytes(of: UInt16(11), as: UInt16.self)

        let view = unsafe WaylandClientArrayView(&array)
        #expect(view.byteCount == 2 * MemoryLayout<UInt16>.stride)
        #expect(view.copiedElements(of: UInt16.self) == [7, 11])
    }

    @Test func typedEventDescriptorClosesUnlessTaken() throws {
        var descriptors: [Int32] = [0, 0]
        try #require(unsafe pipe(&descriptors) == 0)
        defer { _ = close(descriptors[1]) }
        let raw = descriptors[0]

        consumeWithoutTaking(raw)

        #expect(fcntl(raw, F_GETFD) == -1)
        #expect(errno == EBADF)
    }

    private func consumeWithoutTaking(_ descriptor: Int32) {
        let owned = WaylandClientOwnedFileDescriptor(descriptor)
        #expect(fcntl(owned.rawValue, F_GETFD) >= 0)
    }
}
