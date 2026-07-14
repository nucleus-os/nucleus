// Parity fixture for the smaller shell-adjacent protocols on the router:
//   - xdg-output: get_xdg_output → logical position/size from the WlOutput model.
//   - cursor-shape: get_pointer → device → set_shape (valid applies; invalid errors).
//   - xdg-decoration: get_toplevel_decoration → configure(mode); set_mode re-configures.
//   - xdg-activation: token commit → done(token); activate(token, surface) → delegate.
//   - xdg-foreign v2: export_toplevel → handle; import_toplevel + set_parent_of → delegate.
//
// One delegate stubs every policy seam (#12 wires these to WindowManager / cursor
// renderer). The invalid-shape error is sent last (it disconnects the client).

import Glibc
import WaylandServerC

private func fail(_ msg: String) -> Never {
    print("FAIL: \(msg)")
    exit(1)
}

private final class AuxDelegate:
    CursorShapeDelegate, DecorationDelegate, XdgActivationDelegate, XdgForeignDelegate
{
    var appliedShape: UInt32?
    var activatedToken: String?
    var activatedSurfaceId: UInt32?
    var foreignChildId: UInt32?
    var foreignParentId: UInt32?

    func applyCursorShape(_ shape: UInt32) -> Bool {
        guard shape >= 1, shape <= 36 else { return false }
        appliedShape = shape
        return true
    }

    func activateSurface(_ surface: WlSurface?, token: String) {
        activatedToken = token
        activatedSurfaceId = surface?.objectId
    }

    func setForeignParent(child: WlSurface, parent: WlSurface?) {
        foreignChildId = child.objectId
        foreignParentId = parent?.objectId
    }
}

@main
enum WaylandShellAuxFixture {
    static func main() {
        guard let router = NucleusWaylandRouter() else { fail("router") }
        let delegate = AuxDelegate()

        let compositor = WlCompositor(); compositor.register(in: router)
        let seat = WlSeat(); seat.register(in: router)
        let output = WlOutput(info: OutputInfo(
            x: 100, y: 50, physicalWidthMm: 600, physicalHeightMm: 340,
            pixelWidth: 2560, pixelHeight: 1440, refreshMhz: 60000, scale: 2,
            name: "DP-2", description: "Aux Output"))
        output.register(in: router)
        let xdg = XdgShell(); xdg.register(in: router)
        let xdgOutput = XdgOutputManager(); xdgOutput.register(in: router)
        let cursor = CursorShapeManager(); cursor.delegate = delegate; cursor.register(in: router)
        let deco = XdgDecorationManager(); deco.delegate = delegate; deco.register(in: router)
        let activation = XdgActivationManager(); activation.delegate = delegate; activation.register(in: router)
        let foreign = XdgForeign(); foreign.delegate = delegate; foreign.register(in: router)

        guard let client = WaylandTestClient(display: router.display) else { fail("client") }
        let globals = client.globals()
        func g(_ iface: String) -> (name: UInt32, version: UInt32) {
            guard let v = globals.first(where: { $0.interface == iface }) else { fail("no \(iface)") }
            return (v.name, v.version)
        }
        func bind(_ b: inout WireBuilder, _ iface: String, _ id: UInt32) {
            let info = g(iface)
            b.message(object: 2, opcode: 0) {
                $0.uint(info.name); $0.string(iface); $0.uint(info.version); $0.newId(id)
            }
        }

        // Bind ids 3..12; objects 13..23.
        let compId: UInt32 = 3, seatId: UInt32 = 4, outId: UInt32 = 5, wmId: UInt32 = 6
        let xoMgr: UInt32 = 7, curMgr: UInt32 = 8, decoMgr: UInt32 = 9, actMgr: UInt32 = 10
        let expMgr: UInt32 = 11, impMgr: UInt32 = 12
        // libwayland requires client object ids to be allocated strictly in
        // sequence with no gaps, so the ids below run in creation order: 13..20 are
        // minted in batch A, then 21/22/23 in the later batches.
        let xoId: UInt32 = 13, ptrId: UInt32 = 14, curDev: UInt32 = 15
        let surfId: UInt32 = 16, xdgId: UInt32 = 17, topId: UInt32 = 18, decoId: UInt32 = 19
        let childId: UInt32 = 20, tokId: UInt32 = 21, expId: UInt32 = 22, impId: UInt32 = 23

        var a = WireBuilder()
        bind(&a, "wl_compositor", compId)
        bind(&a, "wl_seat", seatId)
        bind(&a, "wl_output", outId)
        bind(&a, "xdg_wm_base", wmId)
        bind(&a, "zxdg_output_manager_v1", xoMgr)
        bind(&a, "wp_cursor_shape_manager_v1", curMgr)
        bind(&a, "zxdg_decoration_manager_v1", decoMgr)
        bind(&a, "xdg_activation_v1", actMgr)
        bind(&a, "zxdg_exporter_v2", expMgr)
        bind(&a, "zxdg_importer_v2", impMgr)
        a.message(object: xoMgr, opcode: 1) { $0.newId(xoId); $0.object(outId) }   // get_xdg_output
        a.message(object: seatId, opcode: 0) { $0.newId(ptrId) }                   // wl_seat.get_pointer
        a.message(object: curMgr, opcode: 1) { $0.newId(curDev); $0.object(ptrId) }  // get_pointer
        a.message(object: compId, opcode: 0) { $0.newId(surfId) }                  // create_surface
        a.message(object: wmId, opcode: 2) { $0.newId(xdgId); $0.object(surfId) }  // get_xdg_surface
        a.message(object: xdgId, opcode: 1) { $0.newId(topId) }                    // get_toplevel
        a.message(object: decoMgr, opcode: 1) { $0.newId(decoId); $0.object(topId) }  // get_toplevel_decoration
        a.message(object: compId, opcode: 0) { $0.newId(childId) }                 // create_surface (foreign child)
        guard client.send(a) else { fail("send a") }
        client.pump()
        let r1 = client.drainEvents()

        // xdg-output: logical position/size from the output (2560×1440 ÷ scale 2).
        guard let lp = WireMessage.first(r1, object: xoId, opcode: 0),
            lp.i32(0) == 100, lp.i32(4) == 50 else { fail("xdg_output logical_position") }
        guard let ls = WireMessage.first(r1, object: xoId, opcode: 1),
            ls.i32(0) == 1280, ls.i32(4) == 720 else { fail("xdg_output logical_size") }
        guard WireMessage.first(r1, object: xoId, opcode: 2) != nil else { fail("xdg_output done") }

        // decoration: initial configure is server_side (2).
        guard let dc = WireMessage.first(r1, object: decoId, opcode: 0), dc.u32(0) == 2 else {
            fail("decoration initial configure != server_side")
        }

        // decoration: set_mode(client_side) re-configures to mode 1.
        var b = WireBuilder()
        b.message(object: decoId, opcode: 1) { $0.uint(1) }  // set_mode client_side
        guard client.send(b) else { fail("send b") }
        client.pump()
        let r2 = client.drainEvents()
        guard let dc2 = WireMessage.first(r2, object: decoId, opcode: 0), dc2.u32(0) == 1 else {
            fail("decoration set_mode configure != client_side")
        }

        // cursor-shape: a valid shape applies to the global cursor (delegate records).
        var c = WireBuilder()
        c.message(object: curDev, opcode: 1) { $0.uint(1); $0.uint(4) }  // set_shape(serial, pointer)
        guard client.send(c) else { fail("send c") }
        client.pump()
        _ = client.drainEvents()
        guard delegate.appliedShape == 4 else { fail("cursor shape not applied") }

        // activation: commit → done(token); activate(token, surface) → delegate.
        var d = WireBuilder()
        d.message(object: actMgr, opcode: 1) { $0.newId(tokId) }  // get_activation_token
        d.message(object: tokId, opcode: 3) { _ in }             // token.commit
        guard client.send(d) else { fail("send d") }
        client.pump()
        let r3 = client.drainEvents()
        guard let done = WireMessage.first(r3, object: tokId, opcode: 0),
            let token = done.string(0), !token.isEmpty else { fail("activation done token") }

        var e = WireBuilder()
        e.message(object: actMgr, opcode: 2) { $0.string(token); $0.object(surfId) }  // activate
        guard client.send(e) else { fail("send e") }
        client.pump()
        _ = client.drainEvents()
        guard delegate.activatedToken == token, delegate.activatedSurfaceId == surfId else {
            fail("activate not delivered")
        }

        // foreign v2: export → handle; import + set_parent_of → delegate parent link.
        var f = WireBuilder()
        f.message(object: expMgr, opcode: 1) { $0.newId(expId); $0.object(surfId) }  // export_toplevel
        guard client.send(f) else { fail("send f") }
        client.pump()
        let r4 = client.drainEvents()
        guard let h = WireMessage.first(r4, object: expId, opcode: 0),
            let handle = h.string(0), !handle.isEmpty else { fail("foreign handle") }

        var gmsg = WireBuilder()
        gmsg.message(object: impMgr, opcode: 1) { $0.newId(impId); $0.string(handle) }  // import_toplevel
        gmsg.message(object: impId, opcode: 1) { $0.object(childId) }                   // set_parent_of
        guard client.send(gmsg) else { fail("send g") }
        client.pump()
        _ = client.drainEvents()
        guard delegate.foreignChildId == childId, delegate.foreignParentId == surfId else {
            fail("foreign set_parent_of: child=\(String(describing: delegate.foreignChildId)) parent=\(String(describing: delegate.foreignParentId))")
        }

        // cursor-shape invalid shape → invalid_shape protocol error (disconnects). Last.
        var h2 = WireBuilder()
        h2.message(object: curDev, opcode: 1) { $0.uint(2); $0.uint(0) }  // set_shape(serial, 0=invalid)
        guard client.send(h2) else { fail("send h") }
        client.pump()
        let r5 = client.drainEvents()
        guard let err = WireMessage.first(r5, object: 1, opcode: 0),
            err.u32(0) == curDev, err.u32(4) == 1 else { fail("missing invalid_shape error") }

        print("OK wayland shell-aux xdg_output=100,50,1280,720 deco=2,1 cursor=4 token=ok activate=16 foreign_parent=16 invalid_shape=1")
    }
}
