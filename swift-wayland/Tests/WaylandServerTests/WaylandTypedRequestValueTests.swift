import Glibc
import Testing
import WaylandProtocolTypes
@testable import WaylandServer
import WaylandServerC

@MainActor
@Suite
struct WaylandTypedRequestValueTests {
    @Test
    func protocolValuesPreserveUnknownEnumValuesAndOptionBits() {
        let unknownMode = XdgToplevelState(rawValue: 0xFFFF_FFFE)
        #expect(unknownMode.rawValue == 0xFFFF_FFFE)

        let unknownActions = WlDataDeviceManagerDndAction(rawValue: 1 << 31)
        #expect(unknownActions.rawValue == 1 << 31)
        #expect(!unknownActions.contains(.copy))
        #expect(unknownActions.union(.copy).rawValue == (1 << 31) | 1)
    }

    @Test
    func arrayViewHandlesEmptyAlignedAndMalformedStorage() {
        var empty = unsafe wl_array()
        unsafe wl_array_init(&empty)
        defer { unsafe wl_array_release(&empty) }

        let emptyView = unsafe WaylandArrayView(&empty)
        let emptyIsEmpty = emptyView.isEmpty
        let emptyElements = emptyView.copiedElements(of: UInt32.self)
        #expect(emptyIsEmpty)
        #expect(emptyElements == [])

        var aligned = unsafe wl_array()
        unsafe wl_array_init(&aligned)
        defer { unsafe wl_array_release(&aligned) }
        let alignedStorage = unsafe wl_array_add(
            &aligned, 2 * MemoryLayout<UInt32>.stride)
        let hasAlignedStorage = unsafe alignedStorage != nil
        #expect(hasAlignedStorage)
        unsafe alignedStorage?.storeBytes(
            of: UInt32(0x1020_3040), as: UInt32.self)
        unsafe alignedStorage?
            .advanced(by: MemoryLayout<UInt32>.stride)
            .storeBytes(of: UInt32(0x5060_7080), as: UInt32.self)

        let alignedView = unsafe WaylandArrayView(&aligned)
        let alignedElements =
            alignedView.copiedElements(of: UInt32.self)
        #expect(alignedElements == [0x1020_3040, 0x5060_7080])

        var malformed = unsafe wl_array()
        unsafe wl_array_init(&malformed)
        defer { unsafe wl_array_release(&malformed) }
        #expect(unsafe wl_array_add(&malformed, 3) != nil)

        let malformedView = unsafe WaylandArrayView(&malformed)
        let malformedByteCount = malformedView.byteCount
        let malformedElements =
            malformedView.copiedElements(of: UInt32.self)
        #expect(malformedByteCount == 3)
        #expect(malformedElements == nil)
    }

    @Test
    func ownedFileDescriptorClosesUnlessConsumed() throws {
        let automatic = dup(STDIN_FILENO)
        try #require(automatic >= 0)
        do {
            let owned = WaylandOwnedFileDescriptor(automatic)
            #expect(owned.rawValue == automatic)
        }
        #expect(fcntl(automatic, F_GETFD) == -1)
        #expect(errno == EBADF)

        let transferred = dup(STDIN_FILENO)
        try #require(transferred >= 0)
        let taken: Int32
        do {
            let owned = WaylandOwnedFileDescriptor(transferred)
            taken = owned.take()
        }
        #expect(taken == transferred)
        #expect(fcntl(taken, F_GETFD) >= 0)
        _ = close(taken)
    }
}
