import Glibc
import Testing
import WaylandServerC

@testable import WaylandServer

private enum TestCallbackServer: WaylandServerInterface {
    typealias Requests = AnyObject

    nonisolated(unsafe) static let nativeRequestVtable: UnsafeRawPointer = {
        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        unsafe storage.initialize(to: 0)
        return UnsafeRawPointer(storage)
    }()
    nonisolated static let descriptor = unsafe WaylandServerInterfaceDescriptor(
        nativeInterface: swift_wayland_iface_wl_callback(),
        nativeRequestVtable: nativeRequestVtable)
    nonisolated static let maximumVersion: Int32 = 1
}

private protocol TestRequestHandler: AnyObject {}

private enum TestDispatchingCallbackServer: WaylandServerInterface {
    typealias Requests = any TestRequestHandler

    nonisolated(unsafe) static let nativeRequestVtable: UnsafeRawPointer = {
        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        unsafe storage.initialize(to: 0)
        return UnsafeRawPointer(storage)
    }()
    nonisolated static let descriptor = unsafe WaylandServerInterfaceDescriptor(
        nativeInterface: swift_wayland_iface_wl_callback(),
        nativeRequestVtable: nativeRequestVtable)
    nonisolated static let maximumVersion: Int32 = 1
}

private enum TestSurfaceServer: WaylandServerInterface {
    typealias Requests = AnyObject

    nonisolated(unsafe) static let nativeRequestVtable: UnsafeRawPointer = {
        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        unsafe storage.initialize(to: 0)
        return UnsafeRawPointer(storage)
    }()
    nonisolated static let descriptor = unsafe WaylandServerInterfaceDescriptor(
        nativeInterface: swift_wayland_iface_wl_surface(),
        nativeRequestVtable: nativeRequestVtable)
    nonisolated static let maximumVersion: Int32 = 1
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
    func nonconformingOwnerFailsBeforeNativeAllocation() {
        let resourceWasCreated =
            unsafe WaylandResource.create(
                client: OpaquePointer(bitPattern: 1)!,
                interface: TestDispatchingCallbackServer.self,
                version: 1,
                id: 1,
                owner: Owner()) != nil

        #expect(!resourceWasCreated)
    }

    @Test
    func ownerRecoveryRequiresExactInterfaceAndImplementationIdentity() throws {
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

        let owner = Owner()
        let createdOwnedResource = unsafe WaylandResource.create(
            client: client,
            interface: TestCallbackServer.self,
            version: 1,
            id: 2,
            owner: owner)
        try #require(
            unsafe createdOwnedResource != nil,
            "WaylandResource.create")
        let ownedResource = unsafe createdOwnedResource!
        let ownedObject = unsafe WaylandBorrowedObject<TestCallbackServer>(
            ownedResource)
        #expect(ownedObject.owner(as: Owner.self) === owner)

        let wrongInterfaceObject = unsafe WaylandBorrowedObject<TestSurfaceServer>(
            ownedResource)
        #expect(wrongInterfaceObject.owner(as: Owner.self) == nil)

        let createdForeignResource = unsafe wl_resource_create(
            client,
            TestCallbackServer.descriptor.nativeInterface,
            1,
            3)
        try #require(
            unsafe createdForeignResource != nil,
            "wl_resource_create")
        let foreignResource = unsafe createdForeignResource!
        unsafe wl_resource_set_user_data(
            foreignResource,
            UnsafeMutableRawPointer(bitPattern: 1))
        let foreignObject = unsafe WaylandBorrowedObject<TestCallbackServer>(
            foreignResource)
        #expect(foreignObject.owner(as: Owner.self) == nil)

        unsafe wl_resource_destroy(foreignResource)
        unsafe wl_resource_destroy(ownedResource)
    }

    @Test
    func failedNativeCreationDoesNotConsumeTheSwiftOwner() throws {
        var owner: Owner? = Owner()
        weak let observedOwner = owner

        let resourceWasCreated =
            unsafe WaylandResource.installCreatedResource(
                nil,
                interface: TestCallbackServer.self,
                owner: owner!,
                handler: owner!) != nil

        #expect(!resourceWasCreated)
        #expect(observedOwner === owner)
        owner = nil
        #expect(observedOwner == nil)
    }

    @Test
    func typedNativeFailureDoesNotConstructOrInstallOwner() {
        var constructed = false
        var installed = false

        let owner: TypedOwner? = unsafe WaylandResource.installCreatedResource(
            nil,
            owner: { handle in
                constructed = true
                return TypedOwner(resource: handle)
            },
            handler: { $0 },
            installed: { _ in installed = true })

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
        var observedHandle: WaylandResourceHandle<TestCallbackServer>?
        var installed = false

        let owner: TypedOwner? = unsafe WaylandResource.create(
            client: client,
            interface: TestCallbackServer.self,
            version: 1,
            id: 2,
            owner: { handle in
                observedHandle = handle
                return nil
            },
            handler: { $0 },
            installed: { _ in installed = true })

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
            owner: { resource in
                handle = resource
                return TypedOwner(resource: resource)
            },
            handler: { $0 },
            installed: { _ in installed = true })
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
            client, TestCallbackServer.descriptor.nativeInterface, 1, 2)
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
            client, TestCallbackServer.descriptor.nativeInterface, 1, 2)
        try #require(unsafe createdResource != nil, "wl_resource_create")
        let resource = unsafe createdResource!
        var owner: Owner? = Owner()
        weak let observedOwner = owner
        var reference: WaylandResourceReference<TestCallbackServer>? =
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
            client, TestCallbackServer.descriptor.nativeInterface, 1, 2)
        try #require(unsafe createdParent != nil, "wl_resource_create")
        let parent = try #require(
            unsafe WaylandResourceHandle<TestCallbackServer>(
                createdParent))

        var order: [String] = []
        let child: ChildOwner? = WaylandResource.createChild(
            parent: parent,
            interface: TestCallbackServer.self,
            version: 99,
            owner: {
                order.append("owner")
                return ChildOwner(resource: $0)
            },
            handler: { $0 },
            installed: { _ in order.append("installed") },
            publish: {
                order.append("publish")
                #expect($0.clientID == parent.clientID)
                return true
            })
        let liveChild = try #require(child)
        #expect(order == ["owner", "publish", "installed"])
        #expect(liveChild.resource.version == 1)
        #expect(liveChild.resource.clientID == parent.clientID)
        #expect(liveChild.resource.objectID != nil)
        #expect(liveChild.resource.destroy())

        var ownerFailureHandle: WaylandResourceHandle<TestCallbackServer>?
        let ownerFailure: ChildOwner? =
            WaylandResource.createChild(
                parent: parent,
                interface: TestCallbackServer.self,
                version: 1,
                owner: {
                    ownerFailureHandle = $0
                    return nil
                },
                handler: { $0 },
                installed: { _ in
                    Issue.record("owner failure installed a child")
                },
                publish: { _ in
                    Issue.record("owner failure published a child")
                    return true
                })
        #expect(ownerFailure == nil)
        #expect(ownerFailureHandle?.isLive == false)

        var publicationFailureHandle: WaylandResourceHandle<TestCallbackServer>?
        weak var publicationFailureOwner: ChildOwner?
        var publicationFailureInstalled = false
        let publicationFailure: ChildOwner? =
            WaylandResource.createChild(
                parent: parent,
                interface: TestCallbackServer.self,
                version: 1,
                owner: {
                    publicationFailureHandle = $0
                    let owner = ChildOwner(resource: $0)
                    publicationFailureOwner = owner
                    return owner
                },
                handler: { $0 },
                installed: { _ in
                    publicationFailureInstalled = true
                },
                publish: { _ in false })
        #expect(publicationFailure == nil)
        #expect(publicationFailureHandle?.isLive == false)
        #expect(publicationFailureOwner == nil)
        #expect(!publicationFailureInstalled)

        var allocationConstructedOwner = false
        let allocationFailure: ChildOwner? =
            unsafe WaylandResource.installCreatedChild(
                nil,
                parent: parent,
                interface: TestCallbackServer.self,
                owner: {
                    allocationConstructedOwner = true
                    return ChildOwner(resource: $0)
                },
                handler: { $0 },
                installed: { _ in },
                publish: { _ in true })
        #expect(allocationFailure == nil)
        #expect(!allocationConstructedOwner)

        #expect(parent.destroy())
        let afterParentDestruction: ChildOwner? =
            WaylandResource.createChild(
                parent: parent,
                interface: TestCallbackServer.self,
                version: 1,
                owner: { ChildOwner(resource: $0) },
                handler: { $0 },
                installed: { _ in },
                publish: { _ in true })
        #expect(afterParentDestruction == nil)
    }
}
