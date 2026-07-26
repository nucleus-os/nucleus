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
    private final class ChildOwner {
        let resource: WaylandResourceHandle<TestCallbackServer>

        init(resource: WaylandResourceHandle<TestCallbackServer>) {
            self.resource = resource
        }
    }
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

    @Test
    func typedReferenceDestructionIsIdempotent() throws {
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
        let createdResource = unsafe wl_resource_create(
            client, TestCallbackServer.interface, 1, 2)
        try #require(unsafe createdResource != nil, "wl_resource_create")
        let resource = unsafe createdResource!
        let reference = try #require(
            unsafe WaylandResourceReference<TestCallbackServer>(resource),
            "WaylandResourceReference")

        #expect(reference.isLive)
        #expect(reference.version == 1)
        #expect(reference.objectID == 2)
        #expect(reference.clientID != nil)
        #expect(reference.destroy())
        #expect(!reference.destroy())
        #expect(!reference.isLive)
        #expect(reference.version == nil)
        #expect(reference.objectID == nil)
        #expect(reference.clientID == nil)
    }

    @Test
    func semanticOwnerSurvivesWireDestructionUntilReferenceRelease() throws {
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
        let createdResource = unsafe wl_resource_create(
            client, TestCallbackServer.interface, 1, 2)
        try #require(unsafe createdResource != nil, "wl_resource_create")
        let resource = unsafe createdResource!
        var owner: Owner? = Owner()
        weak let observedOwner = owner
        var reference:
            WaylandResourceReference<TestCallbackServer>? =
                unsafe WaylandResourceReference(
                    resource, retaining: owner)
        try #require(reference != nil, "WaylandResourceReference")

        owner = nil
        #expect(observedOwner != nil)
        #expect(
            reference?.retainedSemanticOwner(as: Owner.self)
                === observedOwner)

        unsafe wl_client_destroy(client)
        #expect(reference?.isLive == false)
        #expect(observedOwner != nil)

        reference = nil
        #expect(observedOwner == nil)
    }

    @Test
    func shmMetadataRejectsInvalidNativeLayouts() {
        #expect(
            WaylandShmMetadata(
                format: 0, width: 0, height: 1, stride: 4) == nil)
        #expect(
            WaylandShmMetadata(
                format: 0, width: -1, height: 1, stride: 4) == nil)
        #expect(
            WaylandShmMetadata(
                format: 0, width: 1, height: 0, stride: 4) == nil)
        #expect(
            WaylandShmMetadata(
                format: 0, width: 1, height: -1, stride: 4) == nil)
        #expect(
            WaylandShmMetadata(
                format: 0, width: 1, height: 1, stride: -1) == nil)
        #expect(
            WaylandShmMetadata(
                format: 0, width: 2, height: 2, stride: 8)?.byteCount
                == 16)
    }

    @Test
    func parentScopedChildCreationIsTransactional() throws {
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
        let createdParent = unsafe wl_resource_create(
            client, TestCallbackServer.interface, 1, 2)
        try #require(unsafe createdParent != nil, "wl_resource_create")
        let parent = try #require(
            unsafe WaylandResourceHandle<TestCallbackServer>(
                createdParent))

        var order: [String] = []
        let child: ChildOwner? = unsafe WaylandResource.createChild(
            parent: parent,
            interface: TestCallbackServer.self,
            version: 99,
            owner: {
                order.append("owner")
                return ChildOwner(resource: $0)
            },
            installed: { _ in order.append("installed") },
            publish: {
                order.append("publish")
                #expect($0.clientID == parent.clientID)
                return true
            },
            using: wl_resource_create)
        let liveChild = try #require(child)
        #expect(order == ["owner", "publish", "installed"])
        #expect(liveChild.resource.version == 1)
        #expect(liveChild.resource.clientID == parent.clientID)
        #expect(liveChild.resource.objectID != nil)
        #expect(liveChild.resource.destroy())

        var ownerFailureHandle:
            WaylandResourceHandle<TestCallbackServer>?
        let ownerFailure: ChildOwner? =
            unsafe WaylandResource.createChild(
                parent: parent,
                interface: TestCallbackServer.self,
                version: 1,
                owner: {
                    ownerFailureHandle = $0
                    return nil
                },
                installed: { _ in
                    Issue.record("owner failure installed a child")
                },
                publish: { _ in
                    Issue.record("owner failure published a child")
                    return true
                },
                using: wl_resource_create)
        #expect(ownerFailure == nil)
        #expect(ownerFailureHandle?.isLive == false)

        var publicationFailureHandle:
            WaylandResourceHandle<TestCallbackServer>?
        weak var publicationFailureOwner: ChildOwner?
        var publicationFailureInstalled = false
        let publicationFailure: ChildOwner? =
            unsafe WaylandResource.createChild(
                parent: parent,
                interface: TestCallbackServer.self,
                version: 1,
                owner: {
                    publicationFailureHandle = $0
                    let owner = ChildOwner(resource: $0)
                    publicationFailureOwner = owner
                    return owner
                },
                installed: { _ in
                    publicationFailureInstalled = true
                },
                publish: { _ in false },
                using: wl_resource_create)
        #expect(publicationFailure == nil)
        #expect(publicationFailureHandle?.isLive == false)
        #expect(publicationFailureOwner == nil)
        #expect(!publicationFailureInstalled)

        var allocationConstructedOwner = false
        let allocationFailure: ChildOwner? =
            unsafe WaylandResource.createChild(
                parent: parent,
                interface: TestCallbackServer.self,
                version: 1,
                owner: {
                    allocationConstructedOwner = true
                    return ChildOwner(resource: $0)
                },
                installed: { _ in },
                publish: { _ in true },
                using: { _, _, _, _ in nil })
        #expect(allocationFailure == nil)
        #expect(!allocationConstructedOwner)

        #expect(parent.destroy())
        var calledFactoryAfterParentDestruction = false
        let afterParentDestruction: ChildOwner? =
            unsafe WaylandResource.createChild(
                parent: parent,
                interface: TestCallbackServer.self,
                version: 1,
                owner: { ChildOwner(resource: $0) },
                installed: { _ in },
                publish: { _ in true },
                using: { _, _, _, _ in
                    calledFactoryAfterParentDestruction = true
                    return nil
                })
        #expect(afterParentDestruction == nil)
        #expect(!calledFactoryAfterParentDestruction)
    }
}
