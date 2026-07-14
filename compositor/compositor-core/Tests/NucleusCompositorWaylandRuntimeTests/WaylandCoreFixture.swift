// Parity fixture for the router's core globals that emit on bind: wl_shm (owned
// by libwayland via wl_display_init_shm) and wl_output (the Swift WlOutput).
// Discovers globals through the registry, binds each, and asserts the advertised
// events decode correctly at the wire level. Surface/region/subsurface semantics
// are exercised by their own fixtures.

import Glibc
import WaylandServerC

private func fail(_ msg: String) -> Never {
    print("FAIL: \(msg)")
    exit(1)
}

private let syntheticOutput = OutputInfo(
    physicalWidthMm: 600, physicalHeightMm: 340,
    pixelWidth: 2560, pixelHeight: 1440, refreshMhz: 60_000, scale: 2,
    name: "nucleus-0", description: "Nucleus Virtual Output 0"
)

@main
enum WaylandCoreFixture {
    static func main() {
        guard let router = NucleusWaylandRouter() else { fail("router") }
        let output = WlOutput(info: syntheticOutput)
        output.register(in: router)

        guard let client = WaylandTestClient(display: router.display) else { fail("client") }

        // Discover the advertised globals by interface name. wl_shm is registered
        // inside wl_display_init_shm; wl_output is the WlOutput we just registered.
        let globals = client.globals()
        func global(_ iface: String) -> (name: UInt32, version: UInt32) {
            guard let g = globals.first(where: { $0.interface == iface }) else {
                fail("global \(iface) not advertised; saw \(globals.map(\.interface))")
            }
            return (g.name, g.version)
        }
        let shm = global("wl_shm")
        let out = global("wl_output")

        // Bind both in one batch. libwayland requires client object ids to be
        // allocated sequentially, so after the registry (id 2) the next ids are
        // 3 (wl_shm) and 4 (wl_output).
        let shmId: UInt32 = 3
        let outId: UInt32 = 4
        var req = WireBuilder()
        req.message(object: 2, opcode: 0) {  // wl_registry.bind(wl_shm)
            $0.uint(shm.name); $0.string("wl_shm"); $0.uint(shm.version); $0.newId(shmId)
        }
        req.message(object: 2, opcode: 0) {  // wl_registry.bind(wl_output)
            $0.uint(out.name); $0.string("wl_output"); $0.uint(out.version); $0.newId(outId)
        }
        guard client.send(req) else { fail("send") }
        client.pump()
        let events = client.drainEvents()

        // wl_shm.format (opcode 0) — one per advertised format. wl_display_init_shm
        // advertises ARGB8888 (0) and XRGB8888 (1).
        let formats = events
            .filter { $0.objectId == shmId && $0.opcode == 0 }
            .map { $0.u32(0) }
        guard formats.contains(0), formats.contains(1) else {
            fail("shm formats missing argb/xrgb; got \(formats)")
        }

        // wl_output.mode (opcode 1): flags, width, height, refresh.
        guard let mode = WireMessage.first(events, object: outId, opcode: 1) else {
            fail("output mode event missing")
        }
        guard mode.i32(4) == syntheticOutput.pixelWidth,
            mode.i32(8) == syntheticOutput.pixelHeight,
            mode.i32(12) == syntheticOutput.refreshMhz
        else {
            fail("output mode \(mode.i32(4))x\(mode.i32(8))@\(mode.i32(12))")
        }
        // wl_output.scale (opcode 3): factor.
        guard let scale = WireMessage.first(events, object: outId, opcode: 3) else {
            fail("output scale event missing")
        }
        guard scale.i32(0) == syntheticOutput.scale else { fail("output scale \(scale.i32(0))") }

        print("OK wayland core shm_formats=\(formats.count) "
            + "output_mode=\(mode.i32(4))x\(mode.i32(8))@\(mode.i32(12)) "
            + "output_scale=\(scale.i32(0))")
    }
}
