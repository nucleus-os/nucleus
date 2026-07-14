// Validates the parity-fixture harness (WaylandTestClient / WireBuilder /
// WireMessage) against a libwayland-backed server: it builds a real request
// stream, pumps the loop, and decodes the event the server flushes back — the
// exact shape every protocol-port parity fixture will take.

import Glibc
import WaylandServerC
import WaylandServer

private final class Empty {}

nonisolated(unsafe) var g_bind = 0
nonisolated(unsafe) var g_surface = 0
nonisolated(unsafe) var g_vtable: UnsafeMutableRawPointer? = nil

private let createSurface: @convention(c) (
    OpaquePointer?, UnsafeMutablePointer<wl_resource>?, UInt32
) -> Void = { client, _, id in
    guard let client else { return }
    g_surface += 1
    guard let surface = WaylandResource.create(
        client: client, interface: swift_wayland_iface_wl_surface(),
        version: 6, id: id, vtable: nil, owner: Empty()
    ) else { return }
    wl_surface_send_preferred_buffer_scale(surface, 2)
}

private let createRegion: @convention(c) (
    OpaquePointer?, UnsafeMutablePointer<wl_resource>?, UInt32
) -> Void = { _, _, _ in }

private let compositorBind: @convention(c) (
    OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
) -> Void = { client, _, version, id in
    g_bind += 1
    guard let client else { return }
    _ = WaylandResource.create(
        client: client, interface: swift_wayland_iface_wl_compositor(),
        version: Int32(version), id: id, vtable: g_vtable.map(UnsafeRawPointer.init),
        owner: Empty()
    )
}

private func fail(_ msg: String) -> Never {
    print("FAIL: \(msg)")
    exit(1)
}

@main
enum WaylandHarnessFixture {
    static func main() {
        let vtSize = MemoryLayout<swift_wayland_wl_compositor_requests>.stride
        let vtRaw = UnsafeMutableRawPointer.allocate(
            byteCount: vtSize, alignment: MemoryLayout<swift_wayland_wl_compositor_requests>.alignment
        )
        vtRaw.initializeMemory(as: UInt8.self, repeating: 0, count: vtSize)
        let vt = vtRaw.bindMemory(to: swift_wayland_wl_compositor_requests.self, capacity: 1)
        vt.pointee.create_surface = createSurface
        vt.pointee.create_region = createRegion
        g_vtable = vtRaw

        guard let display = WaylandDisplay() else { fail("WaylandDisplay") }
        guard let global = WaylandGlobal(
            display: display, interface: swift_wayland_iface_wl_compositor(),
            version: 6, bind: compositorBind
        ) else { fail("WaylandGlobal") }
        defer { withExtendedLifetime(global) {} }

        guard let client = WaylandTestClient(display: display) else { fail("WaylandTestClient") }

        // Discover wl_compositor's name (libwayland-owned wl_shm also appears now).
        let globals = client.globals()
        guard let comp = globals.first(where: { $0.interface == "wl_compositor" }) else {
            fail("wl_compositor not advertised")
        }

        var req = WireBuilder()
        req.message(object: 2, opcode: 0) {                // wl_registry.bind(wl_compositor)
            $0.uint(comp.name); $0.string("wl_compositor"); $0.uint(comp.version); $0.newId(3)
        }
        req.message(object: 3, opcode: 0) { $0.newId(4) }  // wl_compositor.create_surface
        guard client.send(req) else { fail("send") }

        client.pump(until: { g_surface > 0 })

        guard g_bind == 1 else { fail("bind=\(g_bind)") }
        guard g_surface == 1 else { fail("surface=\(g_surface)") }

        let events = client.drainEvents()
        guard let scale = WireMessage.first(events, object: 4, opcode: 2) else {
            fail("preferred_buffer_scale not decoded; got \(events.count) events")
        }
        guard scale.i32(0) == 2 else { fail("scale=\(scale.i32(0))") }

        print("OK wayland harness bind=\(g_bind) surface=\(g_surface) "
            + "events=\(events.count) scale=\(scale.i32(0))")
    }
}
