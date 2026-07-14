// Parity fixture for zwp_pointer_constraints_v1 on the router: lock_pointer binds
// a constraint to a surface, which stays inactive until that surface gains pointer
// focus; notifyPointerFocus (the focus mechanism's call at #12) then emits locked,
// and emits unlocked on focus loss. A second constraint on the same (surface,
// pointer) raises already_constrained.

import Glibc
import WaylandServerC

private func fail(_ msg: String) -> Never {
    print("FAIL: \(msg)")
    exit(1)
}

@main
enum WaylandPointerConstraintsFixture {
    static func main() {
        guard let router = NucleusWaylandRouter() else { fail("router") }
        let seat = WlSeat()
        seat.register(in: router)
        let compositor = WlCompositor()
        compositor.register(in: router)
        let constraints = PointerConstraintsManager()
        constraints.register(in: router)

        guard let client = WaylandTestClient(display: router.display) else { fail("client") }
        let globals = client.globals()
        func name(_ iface: String) -> (name: UInt32, version: UInt32) {
            guard let g = globals.first(where: { $0.interface == iface }) else { fail("no \(iface)") }
            return (g.name, g.version)
        }
        let seatG = name("wl_seat")
        let compG = name("wl_compositor")
        let pcG = name("zwp_pointer_constraints_v1")

        // ids: seat 3, compositor 4, pointer 5, surface 6, constraints-mgr 7, locked 8.
        let seatId: UInt32 = 3, compId: UInt32 = 4, ptrId: UInt32 = 5
        let surfId: UInt32 = 6, mgrId: UInt32 = 7, lockId: UInt32 = 8

        var a = WireBuilder()
        a.message(object: 2, opcode: 0) {  // bind wl_seat
            $0.uint(seatG.name); $0.string("wl_seat"); $0.uint(seatG.version); $0.newId(seatId)
        }
        a.message(object: 2, opcode: 0) {  // bind wl_compositor
            $0.uint(compG.name); $0.string("wl_compositor"); $0.uint(compG.version); $0.newId(compId)
        }
        a.message(object: seatId, opcode: 0) { $0.newId(ptrId) }   // get_pointer
        a.message(object: compId, opcode: 0) { $0.newId(surfId) }  // create_surface
        a.message(object: 2, opcode: 0) {  // bind pointer-constraints manager
            $0.uint(pcG.name); $0.string("zwp_pointer_constraints_v1"); $0.uint(pcG.version); $0.newId(mgrId)
        }
        // lock_pointer(id, surface, pointer, region=null, lifetime=persistent(2)).
        a.message(object: mgrId, opcode: 1) {
            $0.newId(lockId); $0.object(surfId); $0.object(ptrId); $0.object(0); $0.uint(2)
        }
        guard client.send(a) else { fail("send a") }
        client.pump()
        let setup = client.drainEvents()

        // Not focused yet: no locked event.
        guard WireMessage.first(setup, object: lockId, opcode: 0) == nil else {
            fail("locked before focus")
        }

        guard let surface = compositor.surface(id: surfId) else { fail("surface model") }

        // Focus enters → locked.
        constraints.notifyPointerFocus(old: nil, new: surface)
        let afterFocus = client.drainEvents()
        guard WireMessage.first(afterFocus, object: lockId, opcode: 0) != nil else { fail("missing locked") }

        // Focus leaves → unlocked.
        constraints.notifyPointerFocus(old: surface, new: nil)
        let afterBlur = client.drainEvents()
        guard WireMessage.first(afterBlur, object: lockId, opcode: 1) != nil else { fail("missing unlocked") }

        // The confined kind on a second surface: confine_pointer → confined on focus,
        // unconfined on blur. ids: surface2 9, confined 10.
        let surf2Id: UInt32 = 9, confineId: UInt32 = 10
        var b = WireBuilder()
        b.message(object: compId, opcode: 0) { $0.newId(surf2Id) }  // create_surface
        b.message(object: mgrId, opcode: 2) {  // confine_pointer(id, surface, pointer, region=null, lifetime=persistent)
            $0.newId(confineId); $0.object(surf2Id); $0.object(ptrId); $0.object(0); $0.uint(2)
        }
        guard client.send(b) else { fail("send b") }
        client.pump()
        guard let surface2 = compositor.surface(id: surf2Id) else { fail("surface2 model") }

        constraints.notifyPointerFocus(old: nil, new: surface2)
        let afterFocus2 = client.drainEvents()
        guard WireMessage.first(afterFocus2, object: confineId, opcode: 0) != nil else { fail("missing confined") }
        constraints.notifyPointerFocus(old: surface2, new: nil)
        let afterBlur2 = client.drainEvents()
        guard WireMessage.first(afterBlur2, object: confineId, opcode: 1) != nil else { fail("missing unconfined") }

        // already_constrained: a second constraint on the same (surface, pointer) is a
        // fatal protocol error (code 1) on the manager. (Last — it kills the client.)
        var c = WireBuilder()
        c.message(object: mgrId, opcode: 1) {
            $0.newId(11); $0.object(surfId); $0.object(ptrId); $0.object(0); $0.uint(2)
        }
        guard client.send(c) else { fail("send c") }
        client.pump()
        let errs = client.drainEvents()
        guard let err = WireMessage.first(errs, object: 1, opcode: 0),
            err.u32(0) == mgrId, err.u32(4) == 1 else {
            fail("missing already_constrained protocol error")
        }

        print("OK wayland pointer-constraints locked=1 unlocked=1 confined=1 unconfined=1 already_constrained=1")
    }
}
