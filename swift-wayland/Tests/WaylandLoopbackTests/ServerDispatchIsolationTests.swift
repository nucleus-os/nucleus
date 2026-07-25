import Glibc
import Testing
import WaylandServer
import WaylandServerC
import WaylandServerDispatch
import WaylandProtocolTypes

@MainActor
private final class DispatchTracker {
    var createCount = 0
    var createdVersion: Int32?
    var defaultOwnerDeinitCount = 0
    var overrideReleaseCount = 0
    var overrideOwnerDeinitCount = 0
    var destroyOnlyFallbackDeinitCount = 0
    var destroyOnlyOverrideCount = 0
    var destroyOnlyOverrideDeinitCount = 0
}

@MainActor
private final class DestroyOnlyFallbackOwner {
    private let tracker: DispatchTracker

    init(tracker: DispatchTracker) {
        self.tracker = tracker
    }

    isolated deinit {
        tracker.destroyOnlyFallbackDeinitCount += 1
    }
}

@MainActor
private final class DestroyOnlyOverrideOwner: WlBufferRequests {
    private let tracker: DispatchTracker

    init(tracker: DispatchTracker) {
        self.tracker = tracker
    }

    func destroy(_ request: WaylandRequest<WlBufferServer>) {
        let resource = unsafe request.resource
        MainActor.preconditionIsolated()
        tracker.destroyOnlyOverrideCount += 1
        unsafe wl_resource_destroy(resource)
    }

    isolated deinit {
        tracker.destroyOnlyOverrideDeinitCount += 1
    }
}

@MainActor
private final class TestSurfaceOwner: WlSurfaceRequests {
    var attachedBufferWasNil: [Bool] = []
    var expectedBufferOwner: AnyObject?
    var attachedExpectedBufferOwner = false

    func attach(
        _ request: WaylandRequest<WlSurfaceServer>,
        buffer: WaylandBorrowedObject<WlBufferServer>?,
        x: Int32,
        y: Int32
    ) {
        attachedBufferWasNil.append(buffer == nil)
        if let expectedBufferOwner {
            attachedExpectedBufferOwner =
                buffer?.owner(as: AnyObject.self) === expectedBufferOwner
        }
    }

    func damage(
        _ request: WaylandRequest<WlSurfaceServer>,
        x: Int32,
        y: Int32,
        width: Int32,
        height: Int32
    ) {}

    func frame(
        _ request: WaylandRequest<WlSurfaceServer>,
        callback: WlNewId<WlCallbackServer>
    ) {}

    func setOpaqueRegion(
        _ request: WaylandRequest<WlSurfaceServer>,
        region: WaylandBorrowedObject<WlRegionServer>?
    ) {}

    func setInputRegion(
        _ request: WaylandRequest<WlSurfaceServer>,
        region: WaylandBorrowedObject<WlRegionServer>?
    ) {}

    func commit(_ request: WaylandRequest<WlSurfaceServer>) {}

    func setBufferTransform(
        _ request: WaylandRequest<WlSurfaceServer>,
        transform: WlOutputTransform
    ) {}

    func setBufferScale(
        _ request: WaylandRequest<WlSurfaceServer>,
        scale: Int32
    ) {}

    func damageBuffer(
        _ request: WaylandRequest<WlSurfaceServer>,
        x: Int32,
        y: Int32,
        width: Int32,
        height: Int32
    ) {}

    func offset(
        _ request: WaylandRequest<WlSurfaceServer>,
        x: Int32,
        y: Int32
    ) {}

    func getRelease(
        _ request: WaylandRequest<WlSurfaceServer>,
        callback: WlNewId<WlCallbackServer>
    ) {}
}

@MainActor
private final class TypedDataOfferOwner: WlDataOfferRequests {
    var acceptedMimeTypes: [String?] = []
    var receivedMimeType: String?
    var receivedDescriptorWasOpen = false
    var actionRawValues: (UInt32, UInt32)?

    func accept(
        _ request: WaylandRequest<WlDataOfferServer>,
        serial: UInt32,
        mime_type: String?
    ) {
        acceptedMimeTypes.append(mime_type)
    }

    func receive(
        _ request: WaylandRequest<WlDataOfferServer>,
        mime_type: String,
        fd: consuming WaylandOwnedFileDescriptor
    ) {
        receivedMimeType = mime_type
        receivedDescriptorWasOpen = fcntl(fd.rawValue, F_GETFD) >= 0
    }

    func finish(_ request: WaylandRequest<WlDataOfferServer>) {}

    func setActions(
        _ request: WaylandRequest<WlDataOfferServer>,
        dnd_actions: WlDataDeviceManagerDndAction,
        preferred_action: WlDataDeviceManagerDndAction
    ) {
        actionRawValues = (dnd_actions.rawValue, preferred_action.rawValue)
    }
}

@MainActor
private final class TypedViewportOwner: WpViewportRequests {
    var source: (Double, Double, Double, Double)?

    func setSource(
        _ request: WaylandRequest<WpViewportServer>,
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) {
        source = (x, y, width, height)
    }

    func setDestination(
        _ request: WaylandRequest<WpViewportServer>,
        width: Int32,
        height: Int32
    ) {}
}

@MainActor
private final class TypedSubcompositorOwner: WlSubcompositorRequests {
    let expectedSurface: AnyObject
    let expectedParent: AnyObject
    var receivedExpectedObjects = false

    init(expectedSurface: AnyObject, expectedParent: AnyObject) {
        self.expectedSurface = expectedSurface
        self.expectedParent = expectedParent
    }

    func getSubsurface(
        _ request: WaylandRequest<WlSubcompositorServer>,
        id: WlNewId<WlSubsurfaceServer>,
        surface: WaylandBorrowedObject<WlSurfaceServer>,
        parent: WaylandBorrowedObject<WlSurfaceServer>
    ) {
        receivedExpectedObjects =
            surface.owner(as: AnyObject.self) === expectedSurface
            && parent.owner(as: AnyObject.self) === expectedParent
    }
}

@MainActor
private final class TestRegionOwner: WlRegionRequests {
    func add(
        _ request: WaylandRequest<WlRegionServer>,
        x: Int32,
        y: Int32,
        width: Int32,
        height: Int32
    ) {}

    func subtract(
        _ request: WaylandRequest<WlRegionServer>,
        x: Int32,
        y: Int32,
        width: Int32,
        height: Int32
    ) {}
}

@MainActor
private final class DefaultReleaseCompositor: WlCompositorRequests {
    private let tracker: DispatchTracker

    init(tracker: DispatchTracker) {
        self.tracker = tracker
    }

    isolated deinit {
        tracker.defaultOwnerDeinitCount += 1
    }

    func createSurface(
        _ request: WaylandRequest<WlCompositorServer>,
        id: WlNewId<WlSurfaceServer>
    ) {
        MainActor.preconditionIsolated()
        tracker.createCount += 1
        tracker.createdVersion = unsafe id.version
        _ = unsafe id.create { _ in TestSurfaceOwner() }
    }

    func createRegion(
        _ request: WaylandRequest<WlCompositorServer>,
        id: WlNewId<WlRegionServer>
    ) {
        _ = unsafe id.create { _ in TestRegionOwner() }
    }
}

@MainActor
private final class OverrideReleaseCompositor: WlCompositorRequests {
    private let tracker: DispatchTracker

    init(tracker: DispatchTracker) {
        self.tracker = tracker
    }

    isolated deinit {
        tracker.overrideOwnerDeinitCount += 1
    }

    func createSurface(
        _ request: WaylandRequest<WlCompositorServer>,
        id: WlNewId<WlSurfaceServer>
    ) {
        _ = unsafe id.create { _ in TestSurfaceOwner() }
    }

    func createRegion(
        _ request: WaylandRequest<WlCompositorServer>,
        id: WlNewId<WlRegionServer>
    ) {
        _ = unsafe id.create { _ in TestRegionOwner() }
    }

    func release(_ request: WaylandRequest<WlCompositorServer>) {
        let resource = unsafe request.resource
        MainActor.preconditionIsolated()
        tracker.overrideReleaseCount += 1
        unsafe wl_resource_destroy(resource)
    }
}

@MainActor
@Suite
struct ServerDispatchIsolationTests {
    @Test
    func generatedRequestTrampolinesMarshalTypedValues() throws {
        let display = try #require(WaylandDisplay(), "wl_display_create")
        var sockets: [Int32] = [0, 0]
        try #require(
            unsafe socketpair(
                AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &sockets) == 0,
            "socketpair")
        defer { _ = close(sockets[1]) }

        let createdClient = unsafe display.createClient(fd: sockets[0])
        let hasClient = unsafe createdClient != nil
        try #require(hasClient, "wl_client_create")
        let client = unsafe createdClient!

        let offerOwner = TypedDataOfferOwner()
        let createdOfferResource = unsafe WaylandResource.create(
                client: client,
                interface: WlDataOfferServer.interface,
                version: WlDataOfferServer.maximumVersion,
                id: 2,
                vtable: WlDataOfferServer.vtable,
                owner: offerOwner)
        let hasOfferResource = unsafe createdOfferResource != nil
        try #require(hasOfferResource)
        let offerResource = unsafe createdOfferResource!
        let offerVtable = unsafe WlDataOfferServer.vtable.assumingMemoryBound(
            to: swift_wayland_wl_data_offer_requests.self).pointee

        unsafe offerVtable.accept!(client, offerResource, 1, nil)
        "".withCString { empty in
            unsafe offerVtable.accept!(client, offerResource, 2, empty)
        }
        #expect(offerOwner.acceptedMimeTypes.count == 2)
        #expect(offerOwner.acceptedMimeTypes[0] == nil)
        #expect(offerOwner.acceptedMimeTypes[1] == "")

        let descriptor = dup(STDIN_FILENO)
        try #require(descriptor >= 0)
        "text/plain".withCString { mimeType in
            unsafe offerVtable.receive!(
                client, offerResource, mimeType, descriptor)
        }
        #expect(offerOwner.receivedMimeType == "text/plain")
        #expect(offerOwner.receivedDescriptorWasOpen)
        #expect(fcntl(descriptor, F_GETFD) == -1)
        #expect(errno == EBADF)

        unsafe offerVtable.set_actions!(
            client, offerResource, 0x8000_0001, 0x4000_0000)
        #expect(offerOwner.actionRawValues?.0 == 0x8000_0001)
        #expect(offerOwner.actionRawValues?.1 == 0x4000_0000)

        let viewportOwner = TypedViewportOwner()
        let createdViewportResource = unsafe WaylandResource.create(
                client: client,
                interface: WpViewportServer.interface,
                version: WpViewportServer.maximumVersion,
                id: 3,
                vtable: WpViewportServer.vtable,
                owner: viewportOwner)
        let hasViewportResource = unsafe createdViewportResource != nil
        try #require(hasViewportResource)
        let viewportResource = unsafe createdViewportResource!
        let viewportVtable = unsafe WpViewportServer.vtable
            .assumingMemoryBound(
                to: swift_wayland_wp_viewport_requests.self).pointee
        unsafe viewportVtable.set_source!(
            client,
            viewportResource,
            swift_wayland_fixed_from_double(1.25),
            swift_wayland_fixed_from_double(-2.5),
            swift_wayland_fixed_from_double(640.5),
            swift_wayland_fixed_from_double(480.75))
        #expect(viewportOwner.source?.0 == 1.25)
        #expect(viewportOwner.source?.1 == -2.5)
        #expect(viewportOwner.source?.2 == 640.5)
        #expect(viewportOwner.source?.3 == 480.75)

        let childSurfaceOwner = TestSurfaceOwner()
        let parentSurfaceOwner = TestSurfaceOwner()
        let createdChildSurface = unsafe WaylandResource.create(
                client: client,
                interface: WlSurfaceServer.interface,
                version: WlSurfaceServer.maximumVersion,
                id: 4,
                vtable: WlSurfaceServer.vtable,
                owner: childSurfaceOwner)
        let hasChildSurface = unsafe createdChildSurface != nil
        try #require(hasChildSurface)
        let childSurface = unsafe createdChildSurface!
        let createdParentSurface = unsafe WaylandResource.create(
                client: client,
                interface: WlSurfaceServer.interface,
                version: WlSurfaceServer.maximumVersion,
                id: 5,
                vtable: WlSurfaceServer.vtable,
                owner: parentSurfaceOwner)
        let hasParentSurface = unsafe createdParentSurface != nil
        try #require(hasParentSurface)
        let parentSurface = unsafe createdParentSurface!

        let bufferOwner = DestroyOnlyFallbackOwner(
            tracker: DispatchTracker())
        let createdBufferResource = unsafe WaylandResource.create(
                client: client,
                interface: WlBufferServer.interface,
                version: WlBufferServer.maximumVersion,
                id: 6,
                vtable: WlBufferServer.vtable,
                owner: bufferOwner)
        let hasBufferResource = unsafe createdBufferResource != nil
        try #require(hasBufferResource)
        let bufferResource = unsafe createdBufferResource!
        childSurfaceOwner.expectedBufferOwner = bufferOwner
        let surfaceVtable = unsafe WlSurfaceServer.vtable
            .assumingMemoryBound(
                to: swift_wayland_wl_surface_requests.self).pointee
        unsafe surfaceVtable.attach!(
            client, childSurface, nil, 0, 0)
        unsafe surfaceVtable.attach!(
            client, childSurface, bufferResource, 0, 0)
        #expect(childSurfaceOwner.attachedBufferWasNil == [true, false])
        #expect(childSurfaceOwner.attachedExpectedBufferOwner)

        let subcompositorOwner = TypedSubcompositorOwner(
            expectedSurface: childSurfaceOwner,
            expectedParent: parentSurfaceOwner)
        let createdSubcompositorResource = unsafe WaylandResource.create(
                client: client,
                interface: WlSubcompositorServer.interface,
                version: WlSubcompositorServer.maximumVersion,
                id: 7,
                vtable: WlSubcompositorServer.vtable,
                owner: subcompositorOwner)
        let hasSubcompositorResource =
            unsafe createdSubcompositorResource != nil
        try #require(hasSubcompositorResource)
        let subcompositorResource = unsafe createdSubcompositorResource!
        let subcompositorVtable = unsafe WlSubcompositorServer.vtable
            .assumingMemoryBound(
                to: swift_wayland_wl_subcompositor_requests.self).pointee
        unsafe subcompositorVtable.get_subsurface!(
            client, subcompositorResource, 8,
            childSurface, parentSurface)
        #expect(subcompositorOwner.receivedExpectedObjects)
    }

    @Test
    func generatedServerTrampolineIsolatesNewIDAndDestructorRequests()
        throws
    {
        let display = try #require(WaylandDisplay(), "wl_display_create")
        var sockets: [Int32] = [0, 0]
        let socketResult = unsafe socketpair(
            AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &sockets)
        try #require(socketResult == 0, "socketpair")
        defer { _ = close(sockets[1]) }

        let createdClient = unsafe display.createClient(fd: sockets[0])
        let hasClient = unsafe createdClient != nil
        try #require(hasClient, "wl_client_create")
        let client = unsafe createdClient!
        let tracker = DispatchTracker()
        let compositorInterface = unsafe swift_wayland_iface_wl_compositor()
        let requestTable = unsafe WlCompositorServer.vtable
            .assumingMemoryBound(
                to: swift_wayland_wl_compositor_requests.self
            ).pointee
        let createSurfaceEntry = unsafe requestTable.create_surface
        let hasCreateSurface = unsafe createSurfaceEntry != nil
        try #require(
            hasCreateSurface,
            "generated create_surface trampoline")
        let createSurface = unsafe createSurfaceEntry!
        let releaseEntry = unsafe requestTable.release
        let hasRelease = unsafe releaseEntry != nil
        try #require(hasRelease, "generated release trampoline")
        let release = unsafe releaseEntry!

        var defaultOwner: DefaultReleaseCompositor? =
            DefaultReleaseCompositor(tracker: tracker)
        let createdDefaultResource = unsafe WaylandResource.create(
            client: client,
            interface: compositorInterface,
            version: 6,
            id: 2,
            vtable: WlCompositorServer.vtable,
            owner: defaultOwner!)
        let hasDefaultResource = unsafe createdDefaultResource != nil
        try #require(
            hasDefaultResource,
            "default compositor resource")
        let defaultResource = unsafe createdDefaultResource!
        defaultOwner = nil

        unsafe createSurface(client, defaultResource, 3)
        #expect(tracker.createCount == 1)
        #expect(tracker.createdVersion == 6)

        unsafe release(client, defaultResource)
        #expect(tracker.defaultOwnerDeinitCount == 1)

        var overrideOwner: OverrideReleaseCompositor? =
            OverrideReleaseCompositor(tracker: tracker)
        let createdOverrideResource = unsafe WaylandResource.create(
            client: client,
            interface: compositorInterface,
            version: 6,
            id: 4,
            vtable: WlCompositorServer.vtable,
            owner: overrideOwner!)
        let hasOverrideResource = unsafe createdOverrideResource != nil
        try #require(
            hasOverrideResource,
            "override compositor resource")
        let overrideResource = unsafe createdOverrideResource!
        overrideOwner = nil

        unsafe release(client, overrideResource)
        #expect(tracker.overrideReleaseCount == 1)
        #expect(tracker.overrideOwnerDeinitCount == 1)

        let bufferRequestTable = unsafe WlBufferServer.vtable
            .assumingMemoryBound(
                to: swift_wayland_wl_buffer_requests.self
            ).pointee
        let destroyBufferEntry = unsafe bufferRequestTable.destroy
        let hasDestroyBuffer = unsafe destroyBufferEntry != nil
        try #require(hasDestroyBuffer, "generated destroy-only trampoline")
        let destroyBuffer = unsafe destroyBufferEntry!

        var fallbackOwner: DestroyOnlyFallbackOwner? =
            DestroyOnlyFallbackOwner(tracker: tracker)
        let createdFallbackResource = unsafe WaylandResource.create(
                client: client,
                interface: WlBufferServer.interface,
                version: WlBufferServer.maximumVersion,
                id: 5,
                vtable: WlBufferServer.vtable,
                owner: fallbackOwner!)
        let hasFallbackResource = unsafe createdFallbackResource != nil
        try #require(hasFallbackResource, "destroy-only fallback resource")
        let fallbackResource = unsafe createdFallbackResource!
        let fallbackHandle = try #require(
            unsafe WaylandResourceHandle<WlBufferServer>(fallbackResource))
        fallbackOwner = nil

        unsafe destroyBuffer(client, fallbackResource)
        #expect(tracker.destroyOnlyFallbackDeinitCount == 1)
        #expect(!fallbackHandle.sendRelease())

        var destroyOverrideOwner: DestroyOnlyOverrideOwner? =
            DestroyOnlyOverrideOwner(tracker: tracker)
        let createdDestroyOverrideResource = unsafe WaylandResource.create(
                client: client,
                interface: WlBufferServer.interface,
                version: WlBufferServer.maximumVersion,
                id: 6,
                vtable: WlBufferServer.vtable,
                owner: destroyOverrideOwner!)
        let hasDestroyOverrideResource =
            unsafe createdDestroyOverrideResource != nil
        try #require(
            hasDestroyOverrideResource,
            "destroy-only override resource")
        let destroyOverrideResource = unsafe createdDestroyOverrideResource!
        destroyOverrideOwner = nil

        unsafe destroyBuffer(client, destroyOverrideResource)
        #expect(tracker.destroyOnlyOverrideCount == 1)
        #expect(tracker.destroyOnlyOverrideDeinitCount == 1)
    }
}
