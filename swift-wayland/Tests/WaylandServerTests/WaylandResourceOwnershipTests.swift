import Glibc
import Testing
import WaylandServerC
@testable import WaylandServer

private enum TestCallbackServer: WaylandServerInterface {
    nonisolated(unsafe) static let interface =
        unsafe swift_wayland_iface_wl_callback()
    nonisolated static let maximumVersion: Int32 = 1
    nonisolated static func requestVtable() -> UnsafeRawPointer? { nil }
}

@MainActor
@Suite
struct WaylandResourceOwnershipTests {
    private final class Owner {}
    private final class TypedOwner {
        let resource: WaylandResourceHandle<TestCallbackServer>

        init(resource: WaylandResourceHandle<TestCallbackServer>) {
            self.resource = resource
        }
    }

    @Test
    func failedNativeCreationDoesNotConsumeTheSwiftOwner() throws {
        var owner: Owner? = Owner()
        weak let observedOwner = owner

        let resourceWasCreated = unsafe WaylandResource.create(
            client: OpaquePointer(bitPattern: 1)!,
            interface: nil,
            version: 1,
            id: 1,
            vtable: nil,
            owner: owner!,
            using: { _, _, _, _ in nil }) != nil

        #expect(!resourceWasCreated)
        #expect(observedOwner === owner)
        owner = nil
        #expect(observedOwner == nil)
    }

    @Test
    func typedNativeFailureDoesNotConstructOrInstallOwner() {
        var constructed = false
        var installed = false

        let owner: TypedOwner? = unsafe WaylandResource.create(
            client: OpaquePointer(bitPattern: 1)!,
            interface: TestCallbackServer.self,
            version: 1,
            id: 1,
            vtable: nil,
            owner: { handle in
                constructed = true
                return TypedOwner(resource: handle)
            },
            installed: { _ in installed = true },
            using: { _, _, _, _ in nil })

        #expect(owner == nil)
        #expect(!constructed)
        #expect(!installed)
    }

    @Test
    func typedOwnerFailureDestroysNativeResourceWithoutInstalling() throws {
        let display = try #require(WaylandDisplay(), "wl_display_create")
        var sockets: [Int32] = [0, 0]
        try #require(
            unsafe socketpair(
                AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &sockets) == 0,
            "socketpair")
        defer { _ = close(sockets[1]) }
        let createdClient = unsafe display.createClient(fd: sockets[0])
        try #require(unsafe createdClient != nil, "wl_client_create")
        let client = unsafe createdClient!
        var observedHandle:
            WaylandResourceHandle<TestCallbackServer>?
        var installed = false

        let owner: TypedOwner? = unsafe WaylandResource.create(
            client: client,
            interface: TestCallbackServer.self,
            version: 1,
            id: 2,
            vtable: nil,
            owner: { handle in
                observedHandle = handle
                return nil
            },
            installed: { _ in installed = true },
            using: wl_resource_create)

        #expect(owner == nil)
        #expect(!installed)
        #expect(unsafe observedHandle?.resource == nil)
    }

    @Test
    func nativeDestructionClearsTypedHandleAndReleasesOwner() throws {
        let display = try #require(WaylandDisplay(), "wl_display_create")
        var sockets: [Int32] = [0, 0]
        try #require(
            unsafe socketpair(
                AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &sockets) == 0,
            "socketpair")
        defer { _ = close(sockets[1]) }
        let createdClient = unsafe display.createClient(fd: sockets[0])
        try #require(unsafe createdClient != nil, "wl_client_create")
        let client = unsafe createdClient!
        var installed = false
        var handle: WaylandResourceHandle<TestCallbackServer>?
        var owner: TypedOwner? = unsafe WaylandResource.create(
            client: client,
            interface: TestCallbackServer.self,
            version: 1,
            id: 2,
            vtable: nil,
            owner: { resource in
                handle = resource
                return TypedOwner(resource: resource)
            },
            installed: { _ in installed = true },
            using: wl_resource_create)
        weak let observedOwner = owner
        let createdResource = unsafe handle?.resource
        try #require(unsafe createdResource != nil, "wl_resource_create")
        let resource = unsafe createdResource!

        #expect(installed)
        owner = nil
        #expect(observedOwner != nil)

        unsafe wl_resource_destroy(resource)

        #expect(unsafe handle?.resource == nil)
        #expect(observedOwner == nil)
    }
}
