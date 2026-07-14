// Parity fixture for wl_seat on the router: capabilities + name on bind, device
// creation (wl_pointer/keyboard/touch), the keymap + repeat_info a keyboard
// receives, and the encoding of every pointer/keyboard event the focus mechanism
// drives — enter (serial + surface), button (state), the version-gated axis
// sequence (axis_source → axis_value120 → axis), frame, keyboard enter/key/
// modifiers. It also covers keyboard_shortcuts_inhibit going active/inactive with
// keyboard focus and the already_inhibited protocol error.
//
// The seat send methods are normally called by the Zig focus/grab mechanism; here
// the fixture calls them in-process (like the surface fixture drives present()),
// then asserts the wire bytes libwayland flushed back.

import Glibc
import WaylandServerC

private func fail(_ msg: String) -> Never {
    print("FAIL: \(msg)")
    exit(1)
}

@main
enum WaylandSeatFixture {
    static func main() {
        guard let router = NucleusWaylandRouter() else { fail("router") }
        let seat = WlSeat()
        // A synthetic xkb keymap memfd (8 bytes) the seat shares via wl_keyboard.keymap.
        let keymapSize: UInt32 = 8
        let kfd = memfd_create("nucleus-seat-keymap", 0)
        guard kfd >= 0, ftruncate(kfd, off_t(keymapSize)) == 0 else { fail("keymap memfd") }
        seat.keymapFd = kfd
        seat.keymapSize = keymapSize
        seat.register(in: router)
        let compositor = WlCompositor()
        compositor.register(in: router)

        guard let client = WaylandTestClient(display: router.display) else { fail("client") }
        let globals = client.globals()
        func name(_ iface: String) -> (name: UInt32, version: UInt32) {
            guard let g = globals.first(where: { $0.interface == iface }) else { fail("no \(iface)") }
            return (g.name, g.version)
        }
        let seatG = name("wl_seat")
        let compG = name("wl_compositor")
        let inhibitG = name("zwp_keyboard_shortcuts_inhibit_manager_v1")

        // ids (sequential per libwayland): seat 3, compositor 4, pointer 5,
        // keyboard 6, touch 7, surface 8, inhibit-mgr 9, inhibitor 10.
        let seatId: UInt32 = 3, compId: UInt32 = 4
        let ptrId: UInt32 = 5, kbdId: UInt32 = 6, touchId: UInt32 = 7
        let surfId: UInt32 = 8, mgrId: UInt32 = 9, inhibId: UInt32 = 10

        var a = WireBuilder()
        a.message(object: 2, opcode: 0) {  // bind wl_seat
            $0.uint(seatG.name); $0.string("wl_seat"); $0.uint(seatG.version); $0.newId(seatId)
        }
        a.message(object: 2, opcode: 0) {  // bind wl_compositor
            $0.uint(compG.name); $0.string("wl_compositor"); $0.uint(compG.version); $0.newId(compId)
        }
        a.message(object: seatId, opcode: 0) { $0.newId(ptrId) }   // get_pointer
        a.message(object: seatId, opcode: 1) { $0.newId(kbdId) }   // get_keyboard
        a.message(object: seatId, opcode: 2) { $0.newId(touchId) } // get_touch
        a.message(object: compId, opcode: 0) { $0.newId(surfId) }  // create_surface
        a.message(object: 2, opcode: 0) {  // bind shortcuts-inhibit manager
            $0.uint(inhibitG.name); $0.string("zwp_keyboard_shortcuts_inhibit_manager_v1")
            $0.uint(inhibitG.version); $0.newId(mgrId)
        }
        a.message(object: mgrId, opcode: 1) {  // inhibit_shortcuts(id, surface, seat)
            $0.newId(inhibId); $0.object(surfId); $0.object(seatId)
        }
        guard client.send(a) else { fail("send a") }
        client.pump()
        let setup = client.drainEvents()

        // Bind-time + device-setup events.
        guard let caps = WireMessage.first(setup, object: seatId, opcode: 0), caps.u32(0) == 3 else {
            fail("wl_seat.capabilities != pointer|keyboard")
        }
        guard let nm = WireMessage.first(setup, object: seatId, opcode: 1), nm.string(0) == "seat0" else {
            fail("wl_seat.name != seat0")
        }
        guard let keymap = WireMessage.first(setup, object: kbdId, opcode: 0),
            keymap.u32(0) == 1, keymap.u32(4) == keymapSize else {
            fail("wl_keyboard.keymap format/size")
        }
        guard let repeatInfo = WireMessage.first(setup, object: kbdId, opcode: 5),
            repeatInfo.i32(0) == 25, repeatInfo.i32(4) == 600 else {
            fail("wl_keyboard.repeat_info != 25/600")
        }

        // In-process seat sends (the focus/grab mechanism's calls at #12).
        let key = WlSeat.clientKey(client.client)
        guard let surface = compositor.surface(id: surfId) else { fail("surface model") }

        let enterSerial = seat.pointerEnter(surface, surfaceX: 12.0, surfaceY: 34.0)
        let buttonSerial = seat.pointerButton(clientKey: key, timeMsec: 100, button: 0x110, state: 1)
        // version >= 8: axis_source, then axis_value120, then axis.
        seat.pointerAxis(clientKey: key, timeMsec: 100, axis: 0, delta: 1.0, value120: 120, source: 0)
        seat.pointerFrame(clientKey: key)

        seat.keyboardEnter(surface)  // also activates the inhibitor
        seat.keyboardKey(clientKey: key, timeMsec: 100, keycode: 64, keyState: 1)
        seat.keyboardModifiers(clientKey: key, depressed: 4, latched: 0, locked: 0, group: 0)
        seat.keyboardLeave(surface)  // deactivates the inhibitor

        let evts = client.drainEvents()

        // wl_pointer.enter: serial matches, surface arg is our surface.
        guard let enter = WireMessage.first(evts, object: ptrId, opcode: 0),
            enter.u32(0) == enterSerial, enterSerial != 0, enter.u32(4) == surfId else {
            fail("wl_pointer.enter serial/surface")
        }
        // wl_pointer.button: state pressed, our button, distinct serial.
        guard let button = WireMessage.first(evts, object: ptrId, opcode: 3),
            button.u32(0) == buttonSerial, button.u32(8) == 0x110, button.u32(12) == 1 else {
            fail("wl_pointer.button")
        }
        guard WireMessage.first(evts, object: ptrId, opcode: 6) != nil else { fail("missing axis_source") }
        guard let v120 = WireMessage.first(evts, object: ptrId, opcode: 9), v120.i32(4) == 120 else {
            fail("wl_pointer.axis_value120 != 120")
        }
        guard WireMessage.first(evts, object: ptrId, opcode: 4) != nil else { fail("missing axis") }
        guard WireMessage.first(evts, object: ptrId, opcode: 5) != nil else { fail("missing frame") }

        // wl_keyboard.enter (surface + empty keys), key, modifiers.
        guard let kEnter = WireMessage.first(evts, object: kbdId, opcode: 1), kEnter.u32(4) == surfId else {
            fail("wl_keyboard.enter surface")
        }
        guard let kKey = WireMessage.first(evts, object: kbdId, opcode: 3),
            kKey.u32(8) == 64, kKey.u32(12) == 1 else { fail("wl_keyboard.key") }
        guard let kMods = WireMessage.first(evts, object: kbdId, opcode: 4), kMods.u32(4) == 4 else {
            fail("wl_keyboard.modifiers depressed")
        }

        // Inhibitor active on keyboard-enter (opcode 0), inactive on leave (opcode 1).
        guard WireMessage.first(evts, object: inhibId, opcode: 0) != nil else { fail("inhibitor not active") }
        guard WireMessage.first(evts, object: inhibId, opcode: 1) != nil else { fail("inhibitor not inactive") }

        // already_inhibited: a second inhibit_shortcuts on the same (surface, seat) is
        // a fatal protocol error posted on the manager. (Done last — it kills the client.)
        var c = WireBuilder()
        c.message(object: mgrId, opcode: 1) { $0.newId(11); $0.object(surfId); $0.object(seatId) }
        guard client.send(c) else { fail("send c") }
        client.pump()
        let errs = client.drainEvents()
        guard let err = WireMessage.first(errs, object: 1, opcode: 0),
            err.u32(0) == mgrId, err.u32(4) == 0 else {
            fail("missing already_inhibited protocol error")
        }

        print("OK wayland seat caps=3 keymap_size=\(keymapSize) repeat=25/600 "
            + "axis_value120=120 button_state=1 kbd_key=64 inhibit=active+inactive already_inhibited=1")
    }
}
