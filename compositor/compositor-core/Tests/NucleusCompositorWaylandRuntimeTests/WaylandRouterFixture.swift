// Validates the NucleusWaylandRouter registry path: build a router, plug in
// wl_compositor, and drive a real client through the parity harness — bind,
// create_surface, and the surface event must round-trip through the router with
// no test-only globals (assertions are purely on decoded wire events).

import Glibc
import WaylandServerC

private func fail(_ msg: String) -> Never {
    print("FAIL: \(msg)")
    exit(1)
}

@main
enum WaylandRouterFixture {
    static func main() {
        guard let router = NucleusWaylandRouter() else { fail("router") }
        let compositor = WlCompositor()
        compositor.preferredBufferScale = 2  // probed by the wire assertion below
        compositor.register(in: router)

        guard let client = WaylandTestClient(display: router.display) else { fail("client") }

        // Discover wl_compositor's registry name (libwayland-owned wl_shm now also
        // appears, so names are not positional).
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

        client.pump()
        let events = client.drainEvents()
        guard let scale = WireMessage.first(events, object: 4, opcode: 2) else {
            fail("surface event not routed through router; got \(events.count) events")
        }
        guard scale.i32(0) == 2 else { fail("scale=\(scale.i32(0))") }

        // The router must keep the global alive for the whole session.
        withExtendedLifetime(compositor) {}
        print("OK wayland router globals=registered events=\(events.count) "
            + "surface_event_scale=\(scale.i32(0))")
    }
}
