// Parity fixture for xdg-shell on the router. Drives the full windowing
// handshake at the wire level: bind xdg_wm_base, get an xdg_surface + xdg_toplevel,
// elicit the initial configure on the first (bufferless) commit, ack it, commit
// again to map, re-plan on set_maximized, set_title, and close. Then a popup:
// positioner setup → get_popup → assert the resolved parent-local placement.
//
// The XdgShellDelegate (the #12 policy seam) is stubbed here: it returns the
// configure plans and records the requests the window policy would act on.

import Glibc
import WaylandServerC

private func fail(_ msg: String) -> Never {
    print("FAIL: \(msg)")
    exit(1)
}

/// Stub policy: returns fixed configure plans and records observable requests.
private final class StubDelegate: XdgShellDelegate {
    var mappedSerial: UInt32?
    var lastTitle: String?
    var maximizeRequested: Bool?
    /// The serial reported by the new toplevelConfigureSent seam for the initial
    /// pending configure under exactly this serial).
    var initialConfigureSentSerial: UInt32?
    var configureSentCount = 0

    func configure(for toplevel: XdgToplevel, initial: Bool) -> XdgToplevelConfigure {
        if initial {
            // Rectangular initial configure: 0×0 (client self-sizes) + tiled states.
            return XdgToplevelConfigure(width: 0, height: 0, states: [5, 6, 7, 8])
        }
        // A re-plan after a state request: maximized + activated at a fixed size.
        let states: [UInt32] = (maximizeRequested == true) ? [1, 4] : [4]
        return XdgToplevelConfigure(width: 800, height: 600, states: states)
    }

    func toplevelConfigureSent(_ toplevel: XdgToplevel, serial: UInt32, initial: Bool) {
        configureSentCount += 1
        if initial { initialConfigureSentSerial = serial }
    }

    func toplevelDidCommit(_ toplevel: XdgToplevel, ackedSerial: UInt32) {
        mappedSerial = ackedSerial
    }

    func toplevelDidRequest(_ toplevel: XdgToplevel, _ request: XdgToplevelRequest) {
        switch request {
        case .setTitle(let t): lastTitle = t
        case .setMaximized(let v): maximizeRequested = v
        default: break
        }
    }
}

@main
enum WaylandXdgShellFixture {
    static func main() {
        guard let router = NucleusWaylandRouter() else { fail("router") }
        let compositor = WlCompositor()
        compositor.register(in: router)
        let shell = XdgShell()
        let delegate = StubDelegate()
        shell.delegate = delegate
        shell.register(in: router)

        guard let client = WaylandTestClient(display: router.display) else { fail("client") }
        let globals = client.globals()
        func name(_ iface: String) -> (name: UInt32, version: UInt32) {
            guard let g = globals.first(where: { $0.interface == iface }) else { fail("no \(iface)") }
            return (g.name, g.version)
        }
        let compG = name("wl_compositor")
        let wmG = name("xdg_wm_base")

        // ids: compositor 3, wm_base 4, surface 5, xdg_surface 6, toplevel 7.
        let compId: UInt32 = 3, wmId: UInt32 = 4
        let surfId: UInt32 = 5, xdgId: UInt32 = 6, topId: UInt32 = 7

        var a = WireBuilder()
        a.message(object: 2, opcode: 0) {  // bind wl_compositor
            $0.uint(compG.name); $0.string("wl_compositor"); $0.uint(compG.version); $0.newId(compId)
        }
        a.message(object: 2, opcode: 0) {  // bind xdg_wm_base
            $0.uint(wmG.name); $0.string("xdg_wm_base"); $0.uint(wmG.version); $0.newId(wmId)
        }
        a.message(object: compId, opcode: 0) { $0.newId(surfId) }            // create_surface
        a.message(object: wmId, opcode: 2) { $0.newId(xdgId); $0.object(surfId) }  // get_xdg_surface
        a.message(object: xdgId, opcode: 1) { $0.newId(topId) }              // get_toplevel
        a.message(object: surfId, opcode: 6) { _ in }                        // commit (bufferless → initial configure)
        guard client.send(a) else { fail("send a") }
        client.pump()
        let afterInitial = client.drainEvents()

        // Initial configure: xdg_toplevel.configure(width,height,states) opcode 0.
        guard let topConf = WireMessage.first(afterInitial, object: topId, opcode: 0) else {
            fail("missing initial xdg_toplevel.configure")
        }
        let stateCount = Int(topConf.u32(8)) / 4
        guard topConf.i32(0) == 0, topConf.i32(4) == 0, stateCount == 4 else {
            fail("initial toplevel configure size/states (w=\(topConf.i32(0)) h=\(topConf.i32(4)) n=\(stateCount))")
        }
        // xdg_surface.configure(serial) opcode 0 — the serial the client must ack.
        guard let surfConf = WireMessage.first(afterInitial, object: xdgId, opcode: 0) else {
            fail("missing initial xdg_surface.configure")
        }
        let initialSerial = surfConf.u32(0)

        // the exact serial the router minted and sent on the wire — this is the
        // serial the driver queues the pending configure under for the ack→commit
        // latch.
        guard delegate.initialConfigureSentSerial == initialSerial else {
            fail("configureSent serial \(String(describing: delegate.initialConfigureSentSerial)) != sent \(initialSerial)")
        }

        // Ack the configure, then a second commit maps the window.
        var b = WireBuilder()
        b.message(object: xdgId, opcode: 4) { $0.uint(initialSerial) }  // ack_configure
        b.message(object: surfId, opcode: 6) { _ in }                   // commit → map
        guard client.send(b) else { fail("send b") }
        client.pump()
        _ = client.drainEvents()
        guard delegate.mappedSerial == initialSerial else {
            fail("map did not latch acked serial (got \(String(describing: delegate.mappedSerial)))")
        }

        // set_maximized re-plans → a fresh configure carrying the maximized state.
        var c = WireBuilder()
        c.message(object: topId, opcode: 9) { _ in }  // set_maximized
        guard client.send(c) else { fail("send c") }
        client.pump()
        let afterMax = client.drainEvents()
        guard let maxConf = WireMessage.first(afterMax, object: topId, opcode: 0) else {
            fail("missing re-plan xdg_toplevel.configure")
        }
        let maxStates = (0..<Int(maxConf.u32(8)) / 4).map { maxConf.u32(12 + $0 * 4) }
        guard maxStates.contains(1) else { fail("re-plan missing maximized state \(maxStates)") }
        guard delegate.maximizeRequested == true else { fail("set_maximized not recorded") }

        // set_title reaches the policy.
        var d = WireBuilder()
        d.message(object: topId, opcode: 2) { $0.string("hello") }  // set_title
        guard client.send(d) else { fail("send d") }
        client.pump()
        _ = client.drainEvents()
        guard delegate.lastTitle == "hello" else { fail("set_title not recorded") }

        // close: the compositor asks the client to close (in-process trigger).
        compositor.surface(id: surfId)?.role.flatMap { $0 as? XdgSurface }?.toplevel?.sendClose()
        let afterClose = client.drainEvents()
        guard WireMessage.first(afterClose, object: topId, opcode: 1) != nil else {
            fail("missing xdg_toplevel.close")
        }

        // Popup: positioner with a known anchor/gravity, then get_popup → assert the
        // resolved parent-local placement. anchor_rect (0,0,200,30), anchor
        // bottom_left, gravity bottom_right, size 100×50 → (0,30,100,50).
        let posId: UInt32 = 8, surf2Id: UInt32 = 9, xdg2Id: UInt32 = 10, popId: UInt32 = 11
        var e = WireBuilder()
        e.message(object: wmId, opcode: 1) { $0.newId(posId) }                  // create_positioner
        e.message(object: posId, opcode: 1) { $0.int(100); $0.int(50) }         // set_size
        e.message(object: posId, opcode: 2) { $0.int(0); $0.int(0); $0.int(200); $0.int(30) }  // set_anchor_rect
        e.message(object: posId, opcode: 3) { $0.uint(6) }                      // set_anchor bottom_left
        e.message(object: posId, opcode: 4) { $0.uint(8) }                      // set_gravity bottom_right
        e.message(object: compId, opcode: 0) { $0.newId(surf2Id) }              // create_surface
        e.message(object: wmId, opcode: 2) { $0.newId(xdg2Id); $0.object(surf2Id) }  // get_xdg_surface
        e.message(object: xdg2Id, opcode: 2) {                                  // get_popup(id, parent, positioner)
            $0.newId(popId); $0.object(xdgId); $0.object(posId)
        }
        guard client.send(e) else { fail("send e") }
        client.pump()
        let afterPopup = client.drainEvents()
        guard let popConf = WireMessage.first(afterPopup, object: popId, opcode: 0) else {
            fail("missing xdg_popup.configure")
        }
        let px = popConf.i32(0), py = popConf.i32(4), pw = popConf.i32(8), ph = popConf.i32(12)
        guard px == 0, py == 30, pw == 100, ph == 50 else {
            fail("popup placement \(px),\(py),\(pw),\(ph) != 0,30,100,50")
        }
        guard WireMessage.first(afterPopup, object: xdg2Id, opcode: 0) != nil else {
            fail("missing popup's xdg_surface.configure")
        }

        print("OK wayland xdg-shell configure_states=4 configure_sent_serial=\(initialSerial) mapped=1 maximized=1 title=hello close=1 popup=\(px),\(py),\(pw),\(ph)")
    }
}
