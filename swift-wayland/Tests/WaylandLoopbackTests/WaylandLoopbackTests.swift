// A conformance loopback: a real libwayland SERVER and a real libwayland CLIENT talking over a
// socketpair, in one process, driven by the ergonomic layers and the GENERATED dispatch on both
// sides. The server advertises a wl_output global and, on bind, sends its geometry/mode/scale/name
// through libwayland's own event senders; the client binds it via WaylandRegistry and receives those
// events through the generated WlOutputClient listener. This is the only test that exercises the
// client-side trampolines + arg marshalling on the wire — the mirror of the compositor's server-side
// wire fixtures.

import Testing
import Glibc
import WaylandServerC
import WaylandServer
import WaylandServerDispatch
import WaylandProtocolTypes
import WaylandClientC
import WaylandClient
import WaylandClientDispatch

// SOCK_NONBLOCK: reads never block, so the pump can advance both peers without deadlocking.
private let sockNonblock: Int32 = 0o4000

@discardableResult
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
    let readable = pollResult > 0
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
@Suite struct WaylandLoopbackTests {
    @Test func outputEventsRoundTripThroughGeneratedDispatch() throws {
        // ── Server: a display + one wl_output global. ──
        let server = try #require(WaylandDisplay(), "wl_display_create")
        let implementation = OutputGlobalImplementation()
        let specification = WlOutputServer.global(
            implementation: implementation,
            advertisedVersion: Sent.version,
            owner: { implementation, _ in implementation },
            installed: { _, _, handle in
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
        let desired = unsafe DesiredGlobal(
            swift_wayland_iface_wl_output(), maxVersion: 6)
        let registry = try #require(
            WaylandRegistry(client, wanting: [desired]), "get_registry")
        registry.onBind = { bound in
            boundInterface = unsafe DesiredGlobal(
                bound.interface, maxVersion: 0).interfaceName
            boundVersion = bound.version
            unsafe WlOutputClient.addListener(bound.proxy, owner: receiver)
        }

        // ── Pump both peers until the output burst has arrived (or give up). ──
        for _ in 0..<50 {
            pumpClient(client)                // flush client requests, read+dispatch client events
            server.dispatch()                 // process client requests (get_registry, bind)
            server.flushClients()             // push server events to the socket
            if receiver.doneCount > 0 { break }
        }

        // ── The registry bound the global, and every event decoded through generated dispatch. ──
        #expect(boundInterface == "wl_output")
        #expect(boundVersion == UInt32(Sent.version))          // min(advertised 4, maxVersion 6)
        let foundSingleton = unsafe registry.singleton(
            swift_wayland_iface_wl_output()) != nil
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
            let desired = unsafe DesiredGlobal(
                swift_wayland_iface_wl_output(),
                maxVersion: 6,
                allowsMultiple: true)
            let registry = try #require(
                WaylandRegistry(connection, wanting: [desired]),
                "get_registry")
            registry.onRemove = { _ in removedCount += 1 }
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
            let instances = unsafe registry.instances(
                swift_wayland_iface_wl_output())
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
            let instances = unsafe registry.instances(
                swift_wayland_iface_wl_output())
            #expect(instances.count == 1)
        }
        _ = second
    }
}
