// A conformance loopback: a real libwayland SERVER and a real libwayland CLIENT talking over a
// socketpair, in one process, driven by the ergonomic layers and the GENERATED dispatch on both
// sides. The server advertises a wl_output global and, on bind, sends its geometry/mode/scale/name
// through libwayland's own event senders; the client binds it via WaylandRegistry and receives those
// events through the generated WlOutputClient listener. This is the only test that exercises the
// client-side trampolines + arg marshalling on the wire — the mirror of the compositor's server-side
// wire fixtures.

import Glibc
import Testing
import WaylandClient
import WaylandClientC
import WaylandClientDispatch
import WaylandProtocolTypes
import WaylandServer
import WaylandServerC
import WaylandServerDispatch

// SOCK_NONBLOCK: reads never block, so the pump can advance both peers without deadlocking.
private let sockNonblock: Int32 = 0o4000

@discardableResult
@MainActor
private func pumpClient(_ client: WaylandConnection) -> Int32 {
    guard let preparation = client.prepareRead() else { return -1 }
    let flushResult = client.flush()
    if flushResult < 0, errno != EAGAIN {
        preparation.read.cancel()
        return -1
    }
    var descriptor = pollfd(
        fd: client.fd,
        events: Int16(POLLIN),
        revents: 0)
    let pollResult = unsafe poll(&descriptor, 1, 0)
    let readable =
        pollResult > 0
        && descriptor.revents & Int16(POLLIN) != 0
    return preparation.read.complete(readable: readable)
}

// The values the server's bind callback sends; the client must decode exactly these.
private enum Sent {
    static let modeWidth: Int32 = 1920, modeHeight: Int32 = 1080, refresh: Int32 = 60000
    static let scale: Int32 = 2
    static let name = "TEST-OUT"
    static let version: Int32 = 4  // scale is v2+, name is v4+
}

@MainActor
private final class OutputGlobalImplementation {}

@MainActor
private final class GlobalBindingTracker {
    var ownerIDs: [ObjectIdentifier] = []
    var versions: [Int32] = []
}

@MainActor
private final class TrackedOutputOwner {
    let resource: WaylandResourceHandle<WlOutputServer>

    init(resource: WaylandResourceHandle<WlOutputServer>) {
        self.resource = resource
    }
}

/// Receives wl_output events through the generated client dispatch. A plain (nonisolated) class —
/// the WlOutputClient trampolines call it directly from the client's dispatch.
private final class OutputReceiver: WlOutputEvents {
    var mode: (width: Int32, height: Int32, refresh: Int32)?
    var modeFlags: WlOutputMode?
    var subpixel: WlOutputSubpixel?
    var transform: WlOutputTransform?
    var make: String?
    var model: String?
    var scale: Int32?
    var name: String?
    var doneCount = 0

    func geometry(
        _ proxy: WaylandBorrowedProxy<WlOutputClient>,
        x: Int32, y: Int32,
        physical_width: Int32, physical_height: Int32,
        subpixel: WlOutputSubpixel,
        make: String, model: String,
        transform: WlOutputTransform
    ) {
        self.subpixel = subpixel
        self.transform = transform
        self.make = make
        self.model = model
    }
    func mode(
        _ proxy: WaylandBorrowedProxy<WlOutputClient>,
        flags: WlOutputMode,
        width: Int32, height: Int32, refresh: Int32
    ) {
        modeFlags = flags
        mode = (width, height, refresh)
    }
    func scale(
        _ proxy: WaylandBorrowedProxy<WlOutputClient>,
        factor: Int32
    ) {
        scale = factor
    }
    func name(
        _ proxy: WaylandBorrowedProxy<WlOutputClient>, name: String
    ) {
        self.name = name
    }
    func description(
        _ proxy: WaylandBorrowedProxy<WlOutputClient>,
        description: String
    ) {}
    func done(_ proxy: WaylandBorrowedProxy<WlOutputClient>) {
        doneCount += 1
    }
}

@MainActor
private final class ForeignToplevelChildOwner:
    ZwlrForeignToplevelHandleV1Requests
{
    let resource: WaylandResourceHandle<ZwlrForeignToplevelHandleV1Server>

    init(
        resource:
            WaylandResourceHandle<ZwlrForeignToplevelHandleV1Server>
    ) {
        self.resource = resource
    }

    func setMaximized(
        _ request: WaylandRequest<ZwlrForeignToplevelHandleV1Server>
    ) {}
    func unsetMaximized(
        _ request: WaylandRequest<ZwlrForeignToplevelHandleV1Server>
    ) {}
    func setMinimized(
        _ request: WaylandRequest<ZwlrForeignToplevelHandleV1Server>
    ) {}
    func unsetMinimized(
        _ request: WaylandRequest<ZwlrForeignToplevelHandleV1Server>
    ) {}
    func activate(
        _ request: WaylandRequest<ZwlrForeignToplevelHandleV1Server>,
        seat: WaylandBorrowedObject<WlSeatServer>
    ) {}
    func close(
        _ request: WaylandRequest<ZwlrForeignToplevelHandleV1Server>
    ) {}
    func setRectangle(
        _ request: WaylandRequest<ZwlrForeignToplevelHandleV1Server>,
        surface: WaylandBorrowedObject<WlSurfaceServer>,
        x: Int32,
        y: Int32,
        width: Int32,
        height: Int32
    ) {}
    func setFullscreen(
        _ request: WaylandRequest<ZwlrForeignToplevelHandleV1Server>,
        output: WaylandBorrowedObject<WlOutputServer>?
    ) {}
    func unsetFullscreen(
        _ request: WaylandRequest<ZwlrForeignToplevelHandleV1Server>
    ) {}
}

@MainActor
private final class ForeignManagerOwner:
    ZwlrForeignToplevelManagerV1Requests
{
    let resource: WaylandResourceHandle<ZwlrForeignToplevelManagerV1Server>
    var child: WaylandResourceHandle<ZwlrForeignToplevelHandleV1Server>?
    var childOwner: ForeignToplevelChildOwner?

    init(
        resource:
            WaylandResourceHandle<ZwlrForeignToplevelManagerV1Server>
    ) {
        self.resource = resource
    }

    func publishToplevel() {
        _ = resource.createToplevel(
            owner: { ForeignToplevelChildOwner(resource: $0) },
            installed: {
                self.childOwner = $0
                self.child = $0.resource
            })
    }

    func stop(
        _ request:
            WaylandRequest<ZwlrForeignToplevelManagerV1Server>
    ) {}
}

private final class ForeignToplevelReceiver:
    ZwlrForeignToplevelManagerV1Events
{
    var handle: WaylandProxy<ZwlrForeignToplevelHandleV1Client>?

    func toplevel(
        _ proxy:
            WaylandBorrowedProxy<
                ZwlrForeignToplevelManagerV1Client
            >,
        toplevel:
            WaylandProxy<ZwlrForeignToplevelHandleV1Client>
    ) {
        handle = toplevel
    }

    func finished(
        _ proxy:
            WaylandBorrowedProxy<
                ZwlrForeignToplevelManagerV1Client
            >
    ) {}
}

@MainActor
private final class GeneratedClientRequestTracker {
    var createdSurfaceCount = 0
    var compositorReleaseCount = 0
}

@MainActor
private final class RawTestResourceOwner {}

@MainActor
private final class CompositorRequestOwner: WlCompositorRequests {
    let tracker: GeneratedClientRequestTracker

    init(tracker: GeneratedClientRequestTracker) {
        self.tracker = tracker
    }

    func createSurface(
        _ request: WaylandRequest<WlCompositorServer>,
        id: WlNewId<WlSurfaceServer>
    ) {
        guard
            unsafe WaylandResource.create(
                client: id.client,
                interface: WlSurfaceServer.self,
                version: id.version,
                id: id.id,
                owner: RawTestResourceOwner(),
                handler: nil) != nil
        else {
            return
        }
        tracker.createdSurfaceCount += 1
    }

    func createRegion(
        _ request: WaylandRequest<WlCompositorServer>,
        id: WlNewId<WlRegionServer>
    ) {
        _ = unsafe WaylandResource.create(
            client: id.client,
            interface: WlRegionServer.self,
            version: id.version,
            id: id.id,
            owner: RawTestResourceOwner(),
            handler: nil)
    }

    func release(
        _ request: WaylandRequest<WlCompositorServer>
    ) {
        tracker.compositorReleaseCount += 1
        unsafe wl_resource_destroy(request.resource)
    }
}

@MainActor
private final class ClientFamilyGlobalOwner:
    XdgWmBaseRequests,
    ZwlrLayerShellV1Requests,
    ExtSessionLockManagerV1Requests,
    ZwpTextInputManagerV3Requests,
    WlDataDeviceManagerRequests,
    ZwpLinuxDmabufV1Requests,
    WpLinuxDrmSyncobjManagerV1Requests,
    WpPresentationRequests,
    WlSeatRequests,
    WlOutputRequests
{
    func createPositioner(
        _ request: WaylandRequest<XdgWmBaseServer>,
        id: WlNewId<XdgPositionerServer>
    ) {}

    func getXdgSurface(
        _ request: WaylandRequest<XdgWmBaseServer>,
        id: WlNewId<XdgSurfaceServer>,
        surface: WaylandBorrowedObject<WlSurfaceServer>
    ) {}

    func pong(
        _ request: WaylandRequest<XdgWmBaseServer>,
        serial: UInt32
    ) {}

    func getLayerSurface(
        _ request: WaylandRequest<ZwlrLayerShellV1Server>,
        id: WlNewId<ZwlrLayerSurfaceV1Server>,
        surface: WaylandBorrowedObject<WlSurfaceServer>,
        output: WaylandBorrowedObject<WlOutputServer>?,
        layer: ZwlrLayerShellV1Layer,
        namespace: String
    ) {}

    func lock(
        _ request: WaylandRequest<ExtSessionLockManagerV1Server>,
        id: WlNewId<ExtSessionLockV1Server>
    ) {}

    func getTextInput(
        _ request: WaylandRequest<ZwpTextInputManagerV3Server>,
        id: WlNewId<ZwpTextInputV3Server>,
        seat: WaylandBorrowedObject<WlSeatServer>
    ) {}

    func createDataSource(
        _ request: WaylandRequest<WlDataDeviceManagerServer>,
        id: WlNewId<WlDataSourceServer>
    ) {}

    func getDataDevice(
        _ request: WaylandRequest<WlDataDeviceManagerServer>,
        id: WlNewId<WlDataDeviceServer>,
        seat: WaylandBorrowedObject<WlSeatServer>
    ) {}

    func createParams(
        _ request: WaylandRequest<ZwpLinuxDmabufV1Server>,
        params_id: WlNewId<ZwpLinuxBufferParamsV1Server>
    ) {}

    func getDefaultFeedback(
        _ request: WaylandRequest<ZwpLinuxDmabufV1Server>,
        id: WlNewId<ZwpLinuxDmabufFeedbackV1Server>
    ) {}

    func getSurfaceFeedback(
        _ request: WaylandRequest<ZwpLinuxDmabufV1Server>,
        id: WlNewId<ZwpLinuxDmabufFeedbackV1Server>,
        surface: WaylandBorrowedObject<WlSurfaceServer>
    ) {}

    func getSurface(
        _ request: WaylandRequest<WpLinuxDrmSyncobjManagerV1Server>,
        id: WlNewId<WpLinuxDrmSyncobjSurfaceV1Server>,
        surface: WaylandBorrowedObject<WlSurfaceServer>
    ) {}

    func importTimeline(
        _ request: WaylandRequest<WpLinuxDrmSyncobjManagerV1Server>,
        id: WlNewId<WpLinuxDrmSyncobjTimelineV1Server>,
        fd: consuming WaylandOwnedFileDescriptor
    ) {}

    func feedback(
        _ request: WaylandRequest<WpPresentationServer>,
        surface: WaylandBorrowedObject<WlSurfaceServer>,
        callback: WlNewId<WpPresentationFeedbackServer>
    ) {}

    func getPointer(
        _ request: WaylandRequest<WlSeatServer>,
        id: WlNewId<WlPointerServer>
    ) {}

    func getKeyboard(
        _ request: WaylandRequest<WlSeatServer>,
        id: WlNewId<WlKeyboardServer>
    ) {}

    func getTouch(
        _ request: WaylandRequest<WlSeatServer>,
        id: WlNewId<WlTouchServer>
    ) {}
}

@MainActor
private func proxyID<Interface: WaylandClientInterface>(
    _ proxy: WaylandProxy<Interface>
) throws -> UInt32 {
    try unsafe proxy.withUnsafeNativeProxy {
        unsafe wl_proxy_get_id($0)
    }
}

private func drainWaylandMessages(
    from descriptor: Int32
) -> [(object: UInt32, opcode: UInt16)] {
    var bytes: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 65_536)
    while true {
        let count = unsafe recv(
            descriptor,
            &chunk,
            chunk.count,
            Int32(MSG_DONTWAIT))
        if count <= 0 {
            break
        }
        bytes.append(contentsOf: chunk.prefix(Int(count)))
    }
    var messages: [(UInt32, UInt16)] = []
    var offset = 0
    while offset + 8 <= bytes.count {
        let object =
            UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
        let sizeAndOpcode =
            UInt32(bytes[offset + 4])
            | UInt32(bytes[offset + 5]) << 8
            | UInt32(bytes[offset + 6]) << 16
            | UInt32(bytes[offset + 7]) << 24
        let size = Int(sizeAndOpcode >> 16)
        guard size >= 8, offset + size <= bytes.count else {
            break
        }
        messages.append((object, UInt16(truncatingIfNeeded: sizeAndOpcode)))
        offset += size
    }
    return messages
}

@MainActor
@Suite struct WaylandLoopbackTests {
    @Test
    func managedClientObservesPeerDisconnectBeforeExplicitTeardown()
        throws
    {
        let server = try #require(WaylandDisplay(), "wl_display_create")
        var sockets: [Int32] = [0, 0]
        try #require(
            unsafe socketpair(
                AF_UNIX,
                Int32(SOCK_STREAM.rawValue) | sockNonblock,
                0,
                &sockets) == 0)
        let managed = try #require(
            server.createManagedClient(fd: sockets[0]))
        var peer = WaylandConnection(fd: sockets[1])
        #expect(peer != nil)

        peer = nil
        server.dispatch()
        managed.destroy()
        #expect(peer == nil)
    }

    @Test
    func globalFilterRestrictsAStandardGlobalToTheManagedClient()
        throws
    {
        let server = try #require(WaylandDisplay(), "wl_display_create")
        let output = try #require(
            WaylandGlobalRegistration(
                display: server,
                specification: WlOutputServer.global(
                    implementation: OutputGlobalImplementation(),
                    advertisedVersion: 4)))
        let compositorTracker = GeneratedClientRequestTracker()
        let compositor = try #require(
            WaylandGlobalRegistration(
                display: server,
                specification: WlCompositorServer.global(
                    implementation: compositorTracker,
                    advertisedVersion: 1,
                    owner: { tracker, _ in
                        CompositorRequestOwner(tracker: tracker)
                    })))
        var privilegedClientID: WaylandClientID?
        server.setGlobalFilter { client, interfaceName in
            interfaceName != WlOutputClient.descriptor.wireName
                || client == privilegedClientID
        }

        var privilegedSockets: [Int32] = [0, 0]
        try #require(
            unsafe socketpair(
                AF_UNIX,
                Int32(SOCK_STREAM.rawValue) | sockNonblock,
                0,
                &privilegedSockets) == 0)
        let managed = try #require(
            server.createManagedClient(fd: privilegedSockets[0]))
        privilegedClientID = managed.identity
        let privileged = try #require(
            WaylandConnection(fd: privilegedSockets[1]))
        let privilegedRegistry = try #require(
            WaylandRegistry(
                privileged,
                wanting: [
                    DesiredGlobal<WlOutputClient>(),
                    DesiredGlobal<WlCompositorClient>(),
                ]))

        var ordinarySockets: [Int32] = [0, 0]
        try #require(
            unsafe socketpair(
                AF_UNIX,
                Int32(SOCK_STREAM.rawValue) | sockNonblock,
                0,
                &ordinarySockets) == 0)
        try #require(
            unsafe server.createClient(fd: ordinarySockets[0]) != nil)
        let ordinary = try #require(
            WaylandConnection(fd: ordinarySockets[1]))
        let ordinaryRegistry = try #require(
            WaylandRegistry(
                ordinary,
                wanting: [
                    DesiredGlobal<WlOutputClient>(),
                    DesiredGlobal<WlCompositorClient>(),
                ]))

        for _ in 0..<50 {
            _ = pumpClient(privileged)
            _ = pumpClient(ordinary)
            server.dispatch()
            server.flushClients()
            if privilegedRegistry.singleton(WlOutputClient.self) != nil,
                ordinaryRegistry.singleton(WlCompositorClient.self) != nil
            {
                break
            }
        }

        #expect(
            privilegedRegistry.singleton(WlOutputClient.self) != nil)
        #expect(
            privilegedRegistry.singleton(WlCompositorClient.self) != nil)
        #expect(ordinaryRegistry.singleton(WlOutputClient.self) == nil)
        let ordinaryCompositor = try #require(
            ordinaryRegistry.singleton(WlCompositorClient.self))

        privilegedClientID = nil
        managed.destroy()
        let ordinarySurface = try ordinaryCompositor.createSurface()
        for _ in 0..<50 where compositorTracker.createdSurfaceCount == 0 {
            _ = pumpClient(ordinary)
            server.dispatch()
            server.flushClients()
        }
        #expect(compositorTracker.createdSurfaceCount == 1)
        #expect(ordinaryCompositor.isLive)
        try ordinarySurface.destroyLocally()
        _ = output
        _ = compositor
    }

    @Test func outputEventsRoundTripThroughGeneratedDispatch() throws {
        // ── Server: a display + one wl_output global. ──
        let server = try #require(WaylandDisplay(), "wl_display_create")
        let implementation = OutputGlobalImplementation()
        let specification = WlOutputServer.global(
            implementation: implementation,
            advertisedVersion: Sent.version,
            installed: { _, handle in
                handle.sendGeometry(
                    x: 100, y: 200,
                    physical_width: 600, physical_height: 340,
                    subpixel: .unknown,
                    make: "TestMake", model: "TestModel",
                    transform: .normal)
                handle.sendMode(
                    flags: .current,
                    width: Sent.modeWidth,
                    height: Sent.modeHeight,
                    refresh: Sent.refresh)
                if handle.supportsScale {
                    handle.sendScale(factor: Sent.scale)
                }
                if handle.supportsName {
                    handle.sendName(name: Sent.name)
                }
                if handle.supportsDone {
                    handle.sendDone()
                }
            })
        let createdGlobal = WaylandGlobalRegistration(
            display: server,
            specification: specification)
        let global = try #require(createdGlobal, "wl_global_create")
        _ = global  // retained for the test's duration

        // ── Wire the two peers together with a socketpair. ──
        var sv: [Int32] = [0, 0]
        let socketResult = unsafe socketpair(
            AF_UNIX, Int32(SOCK_STREAM.rawValue) | sockNonblock, 0, &sv)
        try #require(socketResult == 0, "socketpair")
        let createdClient = unsafe server.createClient(fd: sv[0])
        let didCreateClient = unsafe createdClient != nil
        try #require(didCreateClient, "createClient")  // server adopts sv[0]
        let client = try #require(WaylandConnection(fd: sv[1]), "connect_to_fd")  // client owns sv[1]

        // ── Client: bind wl_output via the ergonomic registry; attach the generated listener. ──
        let receiver = OutputReceiver()
        var boundInterface: String?
        var boundVersion: UInt32?
        var outputProxy: WaylandProxy<WlOutputClient>?
        let desired = DesiredGlobal<WlOutputClient>(
            maximumVersion: 4,
            onBind: { bound in
                boundInterface = "wl_output"
                boundVersion = bound.version
                outputProxy = bound.proxy
                try? bound.proxy.installListener(receiver)
            })
        let registry = try #require(
            WaylandRegistry(client, wanting: [desired]), "get_registry")

        // ── Pump both peers until the output burst has arrived (or give up). ──
        for _ in 0..<50 {
            pumpClient(client)  // flush client requests, read+dispatch client events
            server.dispatch()  // process client requests (get_registry, bind)
            server.flushClients()  // push server events to the socket
            if receiver.doneCount > 0 { break }
        }

        // ── The registry bound the global, and every event decoded through generated dispatch. ──
        #expect(boundInterface == "wl_output")
        #expect(boundVersion == UInt32(Sent.version))  // min(advertised 4, maxVersion 6)
        #expect(outputProxy?.isLive == true)
        let foundSingleton =
            registry.singleton(WlOutputClient.self) != nil
        #expect(foundSingleton)
        #expect(receiver.mode?.width == Sent.modeWidth)
        #expect(receiver.mode?.height == Sent.modeHeight)
        #expect(receiver.mode?.refresh == Sent.refresh)
        #expect(receiver.modeFlags == .current)
        #expect(receiver.subpixel == .unknown)
        #expect(receiver.transform == .normal)
        #expect(receiver.make == "TestMake")
        #expect(receiver.model == "TestModel")
        #expect(receiver.scale == Sent.scale)
        #expect(receiver.name == Sent.name)
        #expect(receiver.doneCount >= 1)
    }

    @Test
    func generatedGlobalRegistrationSupportsSharedImplementationsAndClients()
        throws
    {
        let server = try #require(WaylandDisplay(), "wl_display_create")
        let tracker = GlobalBindingTracker()
        let specification = WlOutputServer.global(
            implementation: tracker,
            advertisedVersion: 3,
            owner: { _, handle in
                TrackedOutputOwner(resource: handle)
            },
            installed: { tracker, owner, handle in
                tracker.ownerIDs.append(ObjectIdentifier(owner))
                tracker.versions.append(handle.version ?? 0)
            })
        let first = try #require(
            WaylandGlobalRegistration(
                display: server, specification: specification),
            "first wl_global_create")
        let second = try #require(
            WaylandGlobalRegistration(
                display: server, specification: specification),
            "second wl_global_create")

        var connections: [WaylandConnection] = []
        var registries: [WaylandRegistry] = []
        var removedCount = 0
        for _ in 0..<2 {
            var sockets: [Int32] = [0, 0]
            let socketResult = unsafe socketpair(
                AF_UNIX,
                Int32(SOCK_STREAM.rawValue) | sockNonblock,
                0,
                &sockets)
            try #require(socketResult == 0, "socketpair")
            let serverClient = unsafe server.createClient(fd: sockets[0])
            try #require(
                unsafe serverClient != nil,
                "wl_client_create")
            let connection = try #require(
                WaylandConnection(fd: sockets[1]),
                "connect_to_fd")
            let desired = DesiredGlobal<WlOutputClient>(
                maximumVersion: 4,
                allowsMultiple: true,
                onRemove: { _ in removedCount += 1 })
            let registry = try #require(
                WaylandRegistry(connection, wanting: [desired]),
                "get_registry")
            connections.append(connection)
            registries.append(registry)
        }

        for _ in 0..<50 {
            for connection in connections {
                _ = pumpClient(connection)
            }
            server.dispatch()
            server.flushClients()
            if tracker.ownerIDs.count == 4 { break }
        }

        #expect(tracker.ownerIDs.count == 4)
        #expect(Set(tracker.ownerIDs).count == 4)
        #expect(tracker.versions == [3, 3, 3, 3])
        for registry in registries {
            let instances = registry.instances(WlOutputClient.self)
            #expect(instances.count == 2)
        }

        first.remove()
        for _ in 0..<50 {
            server.flushClients()
            for connection in connections {
                _ = pumpClient(connection)
            }
            if removedCount == 2 { break }
        }

        #expect(removedCount == 2)
        for registry in registries {
            let instances = registry.instances(WlOutputClient.self)
            #expect(instances.count == 1)
        }
        _ = second
    }

    @Test
    func eventNewIDTransfersEscapableOwnedProxy() throws {
        let server = try #require(WaylandDisplay(), "wl_display_create")
        let implementation = OutputGlobalImplementation()
        let specification =
            ZwlrForeignToplevelManagerV1Server.global(
                implementation: implementation,
                advertisedVersion: 3,
                owner: { _, handle in
                    ForeignManagerOwner(resource: handle)
                },
                installed: { _, owner, _ in
                    owner.publishToplevel()
                })
        let global = try #require(
            WaylandGlobalRegistration(
                display: server,
                specification: specification),
            "wl_global_create")
        _ = global

        var sockets: [Int32] = [0, 0]
        try #require(
            unsafe socketpair(
                AF_UNIX,
                Int32(SOCK_STREAM.rawValue) | sockNonblock,
                0,
                &sockets) == 0)
        try #require(
            unsafe server.createClient(fd: sockets[0]) != nil,
            "wl_client_create")
        let client = try #require(
            WaylandConnection(fd: sockets[1]),
            "connect_to_fd")
        let receiver = ForeignToplevelReceiver()
        var manager: WaylandProxy<ZwlrForeignToplevelManagerV1Client>?
        let desired =
            DesiredGlobal<ZwlrForeignToplevelManagerV1Client>(
                maximumVersion: 3,
                onBind: { bound in
                    manager = bound.proxy
                    try? bound.proxy.installListener(receiver)
                })
        let registry = try #require(
            WaylandRegistry(client, wanting: [desired]),
            "get_registry")
        _ = registry

        for _ in 0..<50 {
            pumpClient(client)
            server.dispatch()
            server.flushClients()
            if receiver.handle != nil { break }
        }

        #expect(manager?.isLive == true)
        #expect(receiver.handle?.isLive == true)
        #expect(receiver.handle?.version == 3)
    }

    @Test
    func generatedClientRequestCreatesTypedProxyAndGatesVersion()
        throws
    {
        let server = try #require(WaylandDisplay(), "wl_display_create")
        let tracker = GeneratedClientRequestTracker()
        let specification = WlCompositorServer.global(
            implementation: tracker,
            advertisedVersion: 1,
            owner: { tracker, _ in
                CompositorRequestOwner(tracker: tracker)
            })
        let global = try #require(
            WaylandGlobalRegistration(
                display: server,
                specification: specification),
            "wl_global_create")
        _ = global

        var sockets: [Int32] = [0, 0]
        try #require(
            unsafe socketpair(
                AF_UNIX,
                Int32(SOCK_STREAM.rawValue) | sockNonblock,
                0,
                &sockets) == 0)
        try #require(
            unsafe server.createClient(fd: sockets[0]) != nil,
            "wl_client_create")
        let client = try #require(
            WaylandConnection(fd: sockets[1]),
            "connect_to_fd")
        var compositor: WaylandProxy<WlCompositorClient>?
        let desired = DesiredGlobal<WlCompositorClient>(
            maximumVersion: 1,
            onBind: { compositor = $0.proxy })
        let registry = try #require(
            WaylandRegistry(client, wanting: [desired]),
            "get_registry")
        _ = registry

        for _ in 0..<50 where compositor == nil {
            pumpClient(client)
            server.dispatch()
            server.flushClients()
        }
        let liveCompositor = try #require(compositor)
        let surface = try liveCompositor.createSurface()
        #expect(surface.version == 1)
        #expect(
            throws: WaylandProxyError.unsupportedVersion(
                required: 4,
                actual: 1)
        ) {
            try surface.damageBuffer(
                x: 0,
                y: 0,
                width: 1,
                height: 1)
        }

        for _ in 0..<50 where tracker.createdSurfaceCount == 0 {
            pumpClient(client)
            server.dispatch()
            server.flushClients()
        }
        #expect(tracker.createdSurfaceCount == 1)
        try surface.destroyLocally()
    }

    @Test
    func selectedProtocolFamiliesMarshalGeneratedClientRequests()
        throws
    {
        let server = try #require(WaylandDisplay(), "wl_display_create")
        let owner = ClientFamilyGlobalOwner()
        let compositorTracker = GeneratedClientRequestTracker()
        let compositorOwner = CompositorRequestOwner(
            tracker: compositorTracker)
        let globals: [WaylandGlobalRegistration] = [
            try #require(
                WaylandGlobalRegistration(
                    display: server,
                    specification: WlCompositorServer.global(
                        implementation: compositorOwner,
                        advertisedVersion: 6,
                        owner: { owner, _ in owner }))),
            try #require(
                WaylandGlobalRegistration(
                    display: server,
                    specification: WlOutputServer.global(
                        implementation: owner,
                        advertisedVersion: 4,
                        owner: { owner, _ in owner }))),
            try #require(
                WaylandGlobalRegistration(
                    display: server,
                    specification: WlSeatServer.global(
                        implementation: owner,
                        advertisedVersion: 9,
                        owner: { owner, _ in owner }))),
            try #require(
                WaylandGlobalRegistration(
                    display: server,
                    specification: XdgWmBaseServer.global(
                        implementation: owner,
                        advertisedVersion: 6,
                        owner: { owner, _ in owner }))),
            try #require(
                WaylandGlobalRegistration(
                    display: server,
                    specification: ZwlrLayerShellV1Server.global(
                        implementation: owner,
                        advertisedVersion: 4,
                        owner: { owner, _ in owner }))),
            try #require(
                WaylandGlobalRegistration(
                    display: server,
                    specification: ExtSessionLockManagerV1Server.global(
                        implementation: owner,
                        advertisedVersion: 1,
                        owner: { owner, _ in owner }))),
            try #require(
                WaylandGlobalRegistration(
                    display: server,
                    specification: ZwpTextInputManagerV3Server.global(
                        implementation: owner,
                        advertisedVersion: 1,
                        owner: { owner, _ in owner }))),
            try #require(
                WaylandGlobalRegistration(
                    display: server,
                    specification: WlDataDeviceManagerServer.global(
                        implementation: owner,
                        advertisedVersion: 3,
                        owner: { owner, _ in owner }))),
            try #require(
                WaylandGlobalRegistration(
                    display: server,
                    specification: ZwpLinuxDmabufV1Server.global(
                        implementation: owner,
                        advertisedVersion: 5,
                        owner: { owner, _ in owner }))),
            try #require(
                WaylandGlobalRegistration(
                    display: server,
                    specification: WpLinuxDrmSyncobjManagerV1Server.global(
                        implementation: owner,
                        advertisedVersion: 1,
                        owner: { owner, _ in owner }))),
            try #require(
                WaylandGlobalRegistration(
                    display: server,
                    specification: WpPresentationServer.global(
                        implementation: owner,
                        advertisedVersion: 1,
                        owner: { owner, _ in owner }))),
        ]
        _ = globals

        var sockets: [Int32] = [0, 0]
        try #require(
            unsafe socketpair(
                AF_UNIX,
                Int32(SOCK_STREAM.rawValue) | sockNonblock,
                0,
                &sockets) == 0)
        let observer = dup(sockets[0])
        try #require(observer >= 0)
        defer { _ = close(observer) }
        try #require(
            unsafe server.createClient(fd: sockets[0]) != nil,
            "wl_client_create")
        let client = try #require(
            WaylandConnection(fd: sockets[1]),
            "connect_to_fd")
        let registry = try #require(
            WaylandRegistry(
                client,
                wanting: [
                    DesiredGlobal<WlCompositorClient>(maximumVersion: 6),
                    DesiredGlobal<WlOutputClient>(maximumVersion: 4),
                    DesiredGlobal<WlSeatClient>(maximumVersion: 9),
                    DesiredGlobal<XdgWmBaseClient>(maximumVersion: 6),
                    DesiredGlobal<ZwlrLayerShellV1Client>(maximumVersion: 4),
                    DesiredGlobal<ExtSessionLockManagerV1Client>(
                        maximumVersion: 1),
                    DesiredGlobal<ZwpTextInputManagerV3Client>(
                        maximumVersion: 1),
                    DesiredGlobal<WlDataDeviceManagerClient>(
                        maximumVersion: 3),
                    DesiredGlobal<ZwpLinuxDmabufV1Client>(
                        maximumVersion: 5),
                    DesiredGlobal<WpLinuxDrmSyncobjManagerV1Client>(
                        maximumVersion: 1),
                    DesiredGlobal<WpPresentationClient>(
                        maximumVersion: 1),
                ]))

        for _ in 0..<100 {
            _ = pumpClient(client)
            server.dispatch()
            server.flushClients()
            if registry.singleton(WpPresentationClient.self) != nil {
                break
            }
        }

        let compositor = try #require(
            registry.singleton(WlCompositorClient.self))
        let output = try #require(
            registry.singleton(WlOutputClient.self))
        let seat = try #require(
            registry.singleton(WlSeatClient.self))
        let wmBase = try #require(
            registry.singleton(XdgWmBaseClient.self))
        let layerShell = try #require(
            registry.singleton(ZwlrLayerShellV1Client.self))
        let lockManager = try #require(
            registry.singleton(ExtSessionLockManagerV1Client.self))
        let textManager = try #require(
            registry.singleton(ZwpTextInputManagerV3Client.self))
        let dataManager = try #require(
            registry.singleton(WlDataDeviceManagerClient.self))
        let dmabuf = try #require(
            registry.singleton(ZwpLinuxDmabufV1Client.self))
        let syncManager = try #require(
            registry.singleton(WpLinuxDrmSyncobjManagerV1Client.self))
        let presentation = try #require(
            registry.singleton(WpPresentationClient.self))

        let surface = try compositor.createSurface()
        let xdgSurface = try wmBase.getXdgSurface(surface: surface)
        let toplevel = try xdgSurface.getToplevel()
        try toplevel.setTitle(title: "typed-loopback")
        try surface.commit()

        let layerBacking = try compositor.createSurface()
        let layerSurface = try layerShell.getLayerSurface(
            surface: layerBacking,
            output: output,
            layer: .top,
            namespace: "typed-loopback")
        try layerSurface.setSize(width: 800, height: 32)

        let lockBacking = try compositor.createSurface()
        let lock = try lockManager.lock()
        let lockSurface = try lock.getLockSurface(
            surface: lockBacking,
            output: output)
        try lockSurface.ackConfigure(serial: 17)

        let textInput = try textManager.getTextInput(seat: seat)
        try textInput.enable()
        try textInput.commit()

        let source = try dataManager.createDataSource()
        try source.offer(mime_type: "text/plain")
        let dataDevice = try dataManager.getDataDevice(seat: seat)
        try dataDevice.startDrag(
            source: source,
            origin: surface,
            icon: nil,
            serial: 23)

        let params = try dmabuf.createParams()
        let planeFD = unsafe memfd_create("swift-wayland-dmabuf", 0)
        try #require(planeFD >= 0)
        try params.add(
            fd: WaylandClientOwnedFileDescriptor(planeFD),
            plane_idx: 0,
            offset: 0,
            stride: 256,
            modifier_hi: 0,
            modifier_lo: 0)
        _ = try params.createImmed(
            width: 64,
            height: 64,
            format: 0x3432_5258,
            flags: ZwpLinuxBufferParamsV1Flags(rawValue: 0))

        let timelineFD = unsafe memfd_create(
            "swift-wayland-syncobj",
            0)
        try #require(timelineFD >= 0)
        let timeline = try syncManager.importTimeline(
            fd: WaylandClientOwnedFileDescriptor(timelineFD))
        let syncSurface = try syncManager.getSurface(surface: surface)
        try syncSurface.setAcquirePoint(
            timeline: timeline,
            point_hi: 0,
            point_lo: 5)
        try syncSurface.setReleasePoint(
            timeline: timeline,
            point_hi: 0,
            point_lo: 9)

        _ = try presentation.feedback(surface: surface)
        let flushResult = client.flush()
        #expect(flushResult >= 0 || errno == EAGAIN)

        let messages = drainWaylandMessages(from: observer)
        let pairs = Set(
            messages.map {
                (UInt64($0.object) << 16) | UInt64($0.opcode)
            })
        func contains<Interface>(
            _ proxy: WaylandProxy<Interface>,
            opcode: UInt16
        ) throws -> Bool {
            let id = try proxyID(proxy)
            return pairs.contains((UInt64(id) << 16) | UInt64(opcode))
        }

        #expect(try contains(compositor, opcode: 0))
        #expect(try contains(wmBase, opcode: 2))
        #expect(try contains(xdgSurface, opcode: 1))
        #expect(try contains(toplevel, opcode: 2))
        #expect(try contains(layerShell, opcode: 0))
        #expect(try contains(layerSurface, opcode: 0))
        #expect(try contains(lockManager, opcode: 1))
        #expect(try contains(lock, opcode: 1))
        #expect(try contains(textManager, opcode: 1))
        #expect(try contains(textInput, opcode: 1))
        #expect(try contains(dataManager, opcode: 0))
        #expect(try contains(dataManager, opcode: 1))
        #expect(try contains(dataDevice, opcode: 0))
        #expect(try contains(dmabuf, opcode: 1))
        #expect(try contains(params, opcode: 1))
        #expect(try contains(params, opcode: 3))
        #expect(try contains(syncManager, opcode: 1))
        #expect(try contains(syncManager, opcode: 2))
        #expect(try contains(syncSurface, opcode: 1))
        #expect(try contains(syncSurface, opcode: 2))
        #expect(try contains(presentation, opcode: 1))
    }

    @Test
    func generatedDestructorRequestInvalidatesProxyExactlyOnce()
        throws
    {
        let server = try #require(WaylandDisplay(), "wl_display_create")
        let tracker = GeneratedClientRequestTracker()
        let specification = WlCompositorServer.global(
            implementation: tracker,
            advertisedVersion: 7,
            owner: { tracker, _ in
                CompositorRequestOwner(tracker: tracker)
            })
        let global = try #require(
            WaylandGlobalRegistration(
                display: server,
                specification: specification),
            "wl_global_create")
        _ = global

        var sockets: [Int32] = [0, 0]
        try #require(
            unsafe socketpair(
                AF_UNIX,
                Int32(SOCK_STREAM.rawValue) | sockNonblock,
                0,
                &sockets) == 0)
        try #require(
            unsafe server.createClient(fd: sockets[0]) != nil,
            "wl_client_create")
        let client = try #require(
            WaylandConnection(fd: sockets[1]),
            "connect_to_fd")
        var compositor: WaylandProxy<WlCompositorClient>?
        let desired = DesiredGlobal<WlCompositorClient>(
            maximumVersion: 7,
            onBind: { compositor = $0.proxy })
        let registry = try #require(
            WaylandRegistry(client, wanting: [desired]),
            "get_registry")
        _ = registry

        for _ in 0..<50 where compositor == nil {
            pumpClient(client)
            server.dispatch()
            server.flushClients()
        }
        let liveCompositor = try #require(compositor)
        try liveCompositor.release()
        #expect(liveCompositor.isLive == false)
        #expect(throws: WaylandProxyError.destroyed) {
            try liveCompositor.release()
        }

        for _ in 0..<50 where tracker.compositorReleaseCount == 0 {
            pumpClient(client)
            server.dispatch()
            server.flushClients()
        }
        #expect(tracker.compositorReleaseCount == 1)
    }

    @Test
    func scopedShmAccessValidatesMetadataAndBalancesThrowingAccess()
        throws
    {
        let server = try #require(WaylandDisplay(), "wl_display_create")
        var sockets: [Int32] = [0, 0]
        try #require(
            unsafe socketpair(
                AF_UNIX,
                Int32(SOCK_STREAM.rawValue) | sockNonblock,
                0,
                &sockets) == 0)
        let createdServerClient =
            unsafe server.createClient(fd: sockets[0])
        try #require(
            unsafe createdServerClient != nil,
            "wl_client_create")
        let serverClient = unsafe createdServerClient!
        let client = try #require(
            WaylandConnection(fd: sockets[1]),
            "connect_to_fd")
        var shm: WaylandProxy<WlShmClient>?
        let desired = DesiredGlobal<WlShmClient>(
            maximumVersion: 2,
            onBind: { shm = $0.proxy })
        let registry = try #require(
            WaylandRegistry(client, wanting: [desired]),
            "get_registry")
        _ = registry

        for _ in 0..<50 where shm == nil {
            pumpClient(client)
            server.dispatch()
            server.flushClients()
        }
        let liveShm = try #require(shm)

        let fd = unsafe memfd_create("swift-wayland-shm-test", UInt32(MFD_CLOEXEC))
        try #require(fd >= 0, "memfd_create")
        try #require(ftruncate(fd, 32) == 0, "ftruncate")
        let initial = Array(UInt8(0)..<UInt8(32))
        let wrote = initial.withUnsafeBytes {
            unsafe write(fd, $0.baseAddress, $0.count)
        }
        try #require(wrote == initial.count, "write")

        let pool = try liveShm.createPool(
            fd: WaylandClientOwnedFileDescriptor(fd),
            size: 32)
        let argb = try pool.createBuffer(
            offset: 0,
            width: 2,
            height: 2,
            stride: 8,
            format: .argb8888)
        let xrgb = try pool.createBuffer(
            offset: 16,
            width: 2,
            height: 2,
            stride: 8,
            format: .xrgb8888)
        let argbID = try unsafe argb.withUnsafeNativeProxy {
            unsafe wl_proxy_get_id($0)
        }
        let xrgbID = try unsafe xrgb.withUnsafeNativeProxy {
            unsafe wl_proxy_get_id($0)
        }

        for _ in 0..<10 {
            pumpClient(client)
            server.dispatch()
            server.flushClients()
        }
        let argbNative =
            unsafe wl_client_get_object(serverClient, argbID)
        let xrgbNative =
            unsafe wl_client_get_object(serverClient, xrgbID)
        let argbReference = try #require(
            unsafe WaylandResourceReference<WlBufferServer>(argbNative))
        let xrgbReference = try #require(
            unsafe WaylandResourceReference<WlBufferServer>(xrgbNative))

        #expect(
            argbReference.shmMetadata
                == WaylandShmMetadata(
                    format: WlShmFormat.argb8888.rawValue,
                    width: 2,
                    height: 2,
                    stride: 8,
                    byteCount: 16))
        #expect(
            xrgbReference.shmMetadata?.format
                == WlShmFormat.xrgb8888.rawValue)

        var copied: [UInt8] = []
        try argbReference.withShmBytes { _, bytes in
            copied = bytes.copiedBytes()
        }
        #expect(copied == Array(initial[0..<16]))

        try xrgbReference.withMutableShmBytes { _, bytes in
            bytes[0] = 0xA5
        }
        var firstWrittenByte: UInt8?
        try xrgbReference.withShmBytes { _, bytes in
            firstWrittenByte = bytes[0]
        }
        #expect(firstWrittenByte == 0xA5)
    }
}
