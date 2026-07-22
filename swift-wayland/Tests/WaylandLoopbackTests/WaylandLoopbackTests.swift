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
    let pollResult = poll(&descriptor, 1, 0)
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

// wl_output global bind: create the resource and push a full initial burst. @convention(c) can't
// capture, so the geometry is baked in (this is a fixture server, not policy).
private let outputBind: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32) -> Void = {
    client, _, version, id in
    guard let client,
          let res = wl_resource_create(client, swift_wayland_iface_wl_output(), Int32(version), id)
    else { return }
    wl_output_send_geometry(res, 100, 200, 600, 340, 0, "TestMake", "TestModel", 0)
    wl_output_send_mode(res, 1 /* current */, Sent.modeWidth, Sent.modeHeight, Sent.refresh)
    wl_output_send_scale(res, Sent.scale)
    wl_output_send_name(res, Sent.name)
    wl_output_send_done(res)
}

/// Receives wl_output events through the generated client dispatch. A plain (nonisolated) class —
/// the WlOutputClient trampolines call it directly from the client's dispatch.
private final class OutputReceiver: WlOutputEvents {
    var mode: (width: Int32, height: Int32, refresh: Int32)?
    var scale: Int32?
    var name: String?
    var doneCount = 0

    func geometry(_ proxy: OpaquePointer, x: Int32, y: Int32, physical_width: Int32, physical_height: Int32, subpixel: Int32, make: UnsafePointer<CChar>?, model: UnsafePointer<CChar>?, transform: Int32) {}
    func mode(_ proxy: OpaquePointer, flags: UInt32, width: Int32, height: Int32, refresh: Int32) {
        mode = (width, height, refresh)
    }
    func scale(_ proxy: OpaquePointer, factor: Int32) { scale = factor }
    func name(_ proxy: OpaquePointer, name: UnsafePointer<CChar>?) {
        self.name = name.map { String(cString: $0) }
    }
    func description(_ proxy: OpaquePointer, description: UnsafePointer<CChar>?) {}
    func done(_ proxy: OpaquePointer) { doneCount += 1 }
}

@MainActor
@Suite struct WaylandLoopbackTests {
    @Test func outputEventsRoundTripThroughGeneratedDispatch() throws {
        // ── Server: a display + one wl_output global. ──
        let server = try #require(WaylandDisplay(), "wl_display_create")
        let global = try #require(
            WaylandGlobal(display: server, interface: swift_wayland_iface_wl_output(),
                          version: Sent.version, bind: outputBind),
            "wl_global_create")
        _ = global  // retained for the test's duration

        // ── Wire the two peers together with a socketpair. ──
        var sv: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue) | sockNonblock, 0, &sv) == 0,
                     "socketpair")
        try #require(server.createClient(fd: sv[0]) != nil, "createClient")  // server adopts sv[0]
        let client = try #require(WaylandConnection(fd: sv[1]), "connect_to_fd")  // client owns sv[1]

        // ── Client: bind wl_output via the ergonomic registry; attach the generated listener. ──
        let receiver = OutputReceiver()
        var boundInterface: String?
        var boundVersion: UInt32?
        let registry = try #require(
            WaylandRegistry(client, wanting: [DesiredGlobal(swift_wayland_iface_wl_output(), maxVersion: 6)]),
            "get_registry")
        registry.onBind = { bound in
            boundInterface = DesiredGlobal(bound.interface, maxVersion: 0).interfaceName
            boundVersion = bound.version
            WlOutputClient.addListener(bound.proxy, owner: receiver)
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
        #expect(registry.singleton(swift_wayland_iface_wl_output()) != nil)
        #expect(receiver.mode?.width == Sent.modeWidth)
        #expect(receiver.mode?.height == Sent.modeHeight)
        #expect(receiver.mode?.refresh == Sent.refresh)
        #expect(receiver.scale == Sent.scale)
        #expect(receiver.name == Sent.name)
        #expect(receiver.doneCount >= 1)
    }
}
