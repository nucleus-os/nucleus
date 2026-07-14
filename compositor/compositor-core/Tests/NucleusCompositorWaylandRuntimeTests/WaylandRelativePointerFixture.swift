// Parity fixture for zwp_relative_pointer_v1 on the router: the manager hands out
// a relative-pointer bound to a client's wl_pointer, and emitRelativeMotion (the
// call the seat's motion path makes at #12) delivers a relative_motion event with
// the timestamp split into hi/lo words and the four fixed-point deltas.

import Glibc
import WaylandServerC

private func fail(_ msg: String) -> Never {
    print("FAIL: \(msg)")
    exit(1)
}

@main
enum WaylandRelativePointerFixture {
    static func main() {
        guard let router = NucleusWaylandRouter() else { fail("router") }
        let seat = WlSeat()
        seat.register(in: router)
        let relative = RelativePointerManager()
        relative.register(in: router)

        guard let client = WaylandTestClient(display: router.display) else { fail("client") }
        let globals = client.globals()
        func name(_ iface: String) -> (name: UInt32, version: UInt32) {
            guard let g = globals.first(where: { $0.interface == iface }) else { fail("no \(iface)") }
            return (g.name, g.version)
        }
        let seatG = name("wl_seat")
        let relG = name("zwp_relative_pointer_manager_v1")

        // ids: seat 3, pointer 4, relative-mgr 5, relative-pointer 6.
        let seatId: UInt32 = 3, ptrId: UInt32 = 4, mgrId: UInt32 = 5, relId: UInt32 = 6

        var a = WireBuilder()
        a.message(object: 2, opcode: 0) {  // bind wl_seat
            $0.uint(seatG.name); $0.string("wl_seat"); $0.uint(seatG.version); $0.newId(seatId)
        }
        a.message(object: seatId, opcode: 0) { $0.newId(ptrId) }  // get_pointer
        a.message(object: 2, opcode: 0) {  // bind relative-pointer manager
            $0.uint(relG.name); $0.string("zwp_relative_pointer_manager_v1")
            $0.uint(relG.version); $0.newId(mgrId)
        }
        a.message(object: mgrId, opcode: 1) {  // get_relative_pointer(id, pointer)
            $0.newId(relId); $0.object(ptrId)
        }
        guard client.send(a) else { fail("send a") }
        client.pump()
        _ = client.drainEvents()  // discard caps/name

        // The seat motion path's call: timestamp 0x1_00000002 µs, deltas 1/2 (3/4 unaccel).
        let key = WlSeat.clientKey(client.client)
        relative.emitRelativeMotion(
            clientKey: key, timestampUs: (UInt64(1) << 32) | 2,
            dx: 1.0, dy: 2.0, dxUnaccel: 3.0, dyUnaccel: 4.0)

        let evts = client.drainEvents()
        guard let m = WireMessage.first(evts, object: relId, opcode: 0) else {
            fail("missing relative_motion")
        }
        // utime_hi, utime_lo, dx, dy, dx_unaccel, dy_unaccel (fixed = value * 256).
        guard m.u32(0) == 1, m.u32(4) == 2 else { fail("relative_motion timestamp") }
        guard m.i32(8) == 256, m.i32(12) == 512 else { fail("relative_motion dx/dy") }
        guard m.i32(16) == 768, m.i32(20) == 1024 else { fail("relative_motion unaccel") }

        print("OK wayland relative-pointer time=1,2 dx=256 dy=512 unaccel=768,1024")
    }
}
