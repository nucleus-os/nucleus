// wl_seat on the router — the seat mints each client's wl_pointer / wl_keyboard /
// wl_touch device resources and owns the encoding of every pointer/keyboard/touch
// event. The focus + grab mechanism (hit-testing, implicit grab, button tracking)
// stays out of here; at go-live (#12) it drives the seat through the send methods
// below. Because the device resources live only here, there is no separate device
// list or bridge.
//
// keyboard_shortcuts_inhibit lives here too: an inhibitor is scoped to a
// (client, surface) and goes active/inactive exactly as that surface gains/loses
// keyboard focus — which the seat already drives through keyboardEnter/Leave.
//
// The send methods port the retired SeatProtocol encoding 1:1 (opcodes, argument
// order, fixed-point scaling, the version-gated axis sequence, the keymap fd), but
// the wire bytes now flow through libwayland's own wl_*_send_* inlines (Rule 7)
// rather than a handwritten codec.

import WaylandServerC
import NucleusCompositorServer
import WaylandServer
import WaylandServerDispatch

/// Owner bound to each wl_seat resource (Rule 9). Routes get_pointer / get_keyboard
/// / get_touch back to the shared WlSeat.
final class SeatBinding {
    unowned let seat: WlSeat
    init(_ seat: WlSeat) { self.seat = seat }
}

/// Owner bound to each zwp_keyboard_shortcuts_inhibit_manager_v1 resource.
final class ShortcutsInhibitManagerBinding {
    unowned let seat: WlSeat
    init(_ seat: WlSeat) { self.seat = seat }
}

final class WlSeat {
    // wl_keyboard / wl_touch / zwp_keyboard_shortcuts_inhibitor_v1 are destroy-only
    // (no generated dispatch): keep their hand-wired vtables. fileprivate so the seat
    // binding / inhibit-manager binding can pass them to id.create.
    fileprivate let keyboardVtable: UnsafeMutableRawPointer
    fileprivate let touchVtable: UnsafeMutableRawPointer
    fileprivate let inhibitorVtable: UnsafeMutableRawPointer

    /// Display handle for serial minting; set on register.
    private var display: OpaquePointer?

    /// wl_seat capability bits: pointer=1, keyboard=2, touch=4.
    private let capabilities: UInt32 = 0x1 | 0x2 | 0x4

    /// xkb keymap memfd shared with clients via wl_keyboard.keymap (format xkb_v1).
    /// Owned by the input subsystem; the seat only borrows the fd to send it. Set by
    /// the owner before clients bind (a fixture provides a synthetic one).
    var keymapFd: Int32 = -1
    var keymapSize: UInt32 = 0

    // One device resource per client (a client binds one of each in practice; a
    // re-get_* after release overwrites). Keyed by the wl_client pointer.
    private var pointers: [UInt: UnsafeMutablePointer<wl_resource>] = [:]
    private var keyboards: [UInt: UnsafeMutablePointer<wl_resource>] = [:]
    private var touches: [UInt: UnsafeMutablePointer<wl_resource>] = [:]

    // The seat owns relative-pointer emission and pointer-constraint application:
    // every absolute motion also emits zwp_relative_pointer_v1.relative_motion for
    // the focused client, and a locked constraint suppresses the absolute motion
    // (relative still flows). The managers are retained by the router's global set;
    // the seat holds them to reach the delivery semantics. The currently
    // pointer-focused surface drives the constraint active/inactive transitions.
    var relativePointer: RelativePointerManager?
    var pointerConstraints: PointerConstraintsManager?
    private weak var pointerFocusSurface: WlSurface?

    // set_cursor validation: the protocol honors wl_pointer.set_cursor only from the
    // client that currently holds pointer focus, and only when its `serial` matches the
    // latest wl_pointer.enter serial that client received. Track that (serial, client)
    // pair; it is set on enter and cleared on leave so a stale or wrong-client request
    // (a common way clients race a cursor set against a focus change) is dropped.
    private var lastPointerEnterSerial: UInt32 = 0
    private var pointerFocusClientKey: UInt = 0

    // keyboard_shortcuts_inhibit: scoped to (client, surface), active while that
    // surface holds keyboard focus. Keyed by the inhibitor's own (client, objectId)
    // so teardown is O(1); the surface + active state ride the entry.
    private struct Inhibitor {
        let clientKey: UInt
        let surfaceId: UInt32
        let resource: UnsafeMutablePointer<wl_resource>
        var active: Bool
    }
    private var inhibitors: [InhibitorKey: Inhibitor] = [:]
    private struct InhibitorKey: Hashable { let clientKey: UInt; let objectId: UInt32 }

    init() {
        keyboardVtable = Self.makeKeyboardVtable()
        touchVtable = Self.makeTouchVtable()
        inhibitorVtable = Self.makeInhibitorVtable()
    }

    func register(in router: NucleusWaylandRouter) {
        display = router.display.display
        router.addGlobal(
            interface: swift_wayland_iface_wl_seat(), version: 9, impl: self, bind: Self.bind
        )
        router.addGlobal(
            interface: swift_wayland_iface_zwp_keyboard_shortcuts_inhibit_manager_v1(), version: 1,
            impl: self, bind: Self.bindInhibitManager
        )
    }

    static func clientKey(_ client: OpaquePointer) -> UInt {
        UInt(bitPattern: UnsafeRawPointer(client))
    }

    private func nextSerial() -> UInt32 {
        guard let display else { return 0 }
        return wl_display_next_serial(display)
    }

    // MARK: device registry (called by the get_* handlers / device deinit)

    fileprivate func registerPointer(_ key: UInt, _ res: UnsafeMutablePointer<wl_resource>) { pointers[key] = res }
    fileprivate func registerKeyboard(_ key: UInt, _ res: UnsafeMutablePointer<wl_resource>) { keyboards[key] = res }
    fileprivate func registerTouch(_ key: UInt, _ res: UnsafeMutablePointer<wl_resource>) { touches[key] = res }

    fileprivate func unregisterPointer(_ key: UInt, _ res: UnsafeMutablePointer<wl_resource>) {
        if pointers[key] == res { pointers[key] = nil }
    }
    fileprivate func unregisterKeyboard(_ key: UInt, _ res: UnsafeMutablePointer<wl_resource>) {
        if keyboards[key] == res { keyboards[key] = nil }
    }
    fileprivate func unregisterTouch(_ key: UInt, _ res: UnsafeMutablePointer<wl_resource>) {
        if touches[key] == res { touches[key] = nil }
    }

    // MARK: pointer sends (driven by the focus/grab mechanism at #12)

    private func client(of surface: WlSurface) -> (key: UInt, surface: UnsafeMutablePointer<wl_resource>)? {
        guard let sres = surface.resource, let c = wl_resource_get_client(sres) else { return nil }
        return (Self.clientKey(c), sres)
    }

    @discardableResult
    func pointerEnter(_ surface: WlSurface, surfaceX: Double, surfaceY: Double) -> UInt32 {
        guard let (key, sres) = client(of: surface), let ptr = pointers[key] else { return 0 }
        let serial = nextSerial()
        wl_pointer_send_enter(ptr, serial, sres,
            swift_wayland_fixed_from_double(surfaceX), swift_wayland_fixed_from_double(surfaceY))
        // Record the (serial, client) so a later set_cursor from this client can be
        // validated against the focus it was granted.
        lastPointerEnterSerial = serial
        pointerFocusClientKey = key
        // The constrained surface gains pointer focus: drive its constraint active.
        pointerConstraints?.notifyPointerFocus(old: pointerFocusSurface, new: surface)
        pointerFocusSurface = surface
        return serial
    }

    func pointerLeave(_ surface: WlSurface) {
        // Drive the constraint inactive even if the device resource is gone — the
        // focus transition is what the constraint lifetime keys on.
        pointerConstraints?.notifyPointerFocus(old: surface, new: nil)
        if pointerFocusSurface === surface {
            pointerFocusSurface = nil
            // Focus left this client: its enter serial no longer authorizes a cursor set.
            pointerFocusClientKey = 0
        }
        guard let (key, sres) = client(of: surface), let ptr = pointers[key] else { return }
        wl_pointer_send_leave(ptr, nextSerial(), sres)
    }

    /// Whether a wl_pointer.set_cursor from `client` carrying `serial` is authorized:
    /// the client must currently hold pointer focus and the serial must match the enter
    /// event that granted it. Mismatches (wrong client, stale serial) are ignored per
    /// the protocol rather than applied.
    func acceptsCursorRequest(client key: UInt, serial: UInt32) -> Bool {
        Self.cursorRequestAuthorized(
            requestClient: key, requestSerial: serial,
            focusClient: pointerFocusClientKey, enterSerial: lastPointerEnterSerial)
    }

    /// Pure set_cursor authorization: a request is honored only when a client currently
    /// holds pointer focus (`focusClient != 0`), the request comes from that same client,
    /// and its serial matches the enter event that granted focus. `focusClient == 0`
    /// means no client has focus, so every request is rejected. Isolation-free/tested.
    nonisolated static func cursorRequestAuthorized(
        requestClient: UInt, requestSerial: UInt32, focusClient: UInt, enterSerial: UInt32
    ) -> Bool {
        focusClient != 0 && requestClient == focusClient && requestSerial == enterSerial
    }

    /// Deliver one motion sample for the focused surface: emit relative_motion for
    /// the client (always, even while locked), then the absolute wl_pointer.motion
    /// unless a locked constraint is active for the surface. The input dispatch clamps the
    /// cursor (confined) / freezes it (locked) before this, so the absolute coords
    /// are already constraint-consistent.
    func pointerMotionRaw(
        _ surface: WlSurface, clientKey key: UInt, timeMsec: UInt32,
        surfaceX: Double, surfaceY: Double,
        dx: Double, dy: Double, dxUnaccel: Double, dyUnaccel: Double
    ) {
        guard let ptr = pointers[key] else { return }
        relativePointer?.emitRelativeMotion(
            clientKey: key, timestampUs: UInt64(timeMsec) &* 1000,
            dx: dx, dy: dy, dxUnaccel: dxUnaccel, dyUnaccel: dyUnaccel)
        if let constraints = pointerConstraints,
            constraints.activeConstraintKind(for: surface) == .locked { return }
        wl_pointer_send_motion(ptr, timeMsec,
            swift_wayland_fixed_from_double(surfaceX), swift_wayland_fixed_from_double(surfaceY))
    }

    @discardableResult
    func pointerButton(clientKey key: UInt, timeMsec: UInt32, button: UInt32, state: UInt32) -> UInt32 {
        guard let ptr = pointers[key] else { return 0 }
        let serial = nextSerial()
        wl_pointer_send_button(ptr, serial, timeMsec, button, state)
        return serial
    }

    /// The version-gated axis sequence, ported from the retired sendPointerAxis:
    /// axis_source → [axis_value120 | axis_discrete] → axis | axis_stop.
    func pointerAxis(
        clientKey key: UInt, timeMsec: UInt32, axis: UInt32, delta: Double,
        value120: Int32, source: UInt32
    ) {
        guard let ptr = pointers[key] else { return }
        let version = wl_resource_get_version(ptr)
        if version >= 5 { wl_pointer_send_axis_source(ptr, source) }
        if delta == 0.0 {
            // axis_source 1 == WL_POINTER_AXIS_SOURCE_FINGER: a stop is meaningful.
            if version >= 5 && source == 1 { wl_pointer_send_axis_stop(ptr, timeMsec, axis) }
            return
        }
        if value120 != 0 {
            if version >= 8 {
                wl_pointer_send_axis_value120(ptr, axis, value120)
            } else if version >= 5 {
                let discrete = value120 / 120
                if discrete != 0 { wl_pointer_send_axis_discrete(ptr, axis, discrete) }
            }
        }
        wl_pointer_send_axis(ptr, timeMsec, axis, swift_wayland_fixed_from_double(delta))
    }

    func pointerFrame(clientKey key: UInt) {
        guard let ptr = pointers[key], wl_resource_get_version(ptr) >= 5 else { return }
        wl_pointer_send_frame(ptr)
    }

    // MARK: touch sends

    @discardableResult
    func touchDown(
        _ surface: WlSurface, timeMsec: UInt32, id: Int32, surfaceX: Double, surfaceY: Double
    ) -> UInt32 {
        guard let (key, sres) = client(of: surface), let touch = touches[key] else { return 0 }
        let serial = nextSerial()
        wl_touch_send_down(touch, serial, timeMsec, sres, id,
                           swift_wayland_fixed_from_double(surfaceX),
                           swift_wayland_fixed_from_double(surfaceY))
        return serial
    }

    func touchUp(clientKey key: UInt, timeMsec: UInt32, id: Int32) {
        guard let touch = touches[key] else { return }
        wl_touch_send_up(touch, nextSerial(), timeMsec, id)
    }

    func touchMotion(clientKey key: UInt, timeMsec: UInt32, id: Int32, x: Double, y: Double) {
        guard let touch = touches[key] else { return }
        wl_touch_send_motion(touch, timeMsec, id,
                             swift_wayland_fixed_from_double(x), swift_wayland_fixed_from_double(y))
    }

    func touchFrame(clientKey key: UInt) {
        guard let touch = touches[key] else { return }
        wl_touch_send_frame(touch)
    }

    func touchCancel(clientKey key: UInt) {
        guard let touch = touches[key] else { return }
        wl_touch_send_cancel(touch)
    }

    // MARK: keyboard sends

    func keyboardEnter(_ surface: WlSurface) {
        guard let (key, sres) = client(of: surface), let kbd = keyboards[key] else { return }
        var keys = wl_array()
        wl_array_init(&keys)
        // Report the currently-held evdev keys, so a surface gaining keyboard focus
        // while a key is physically down sees correct key state instead of an empty
        // set (which desyncs the client's repeat/stuck-key handling). keyboardEnter is
        // nonisolated for C-interop but only ever driven by @MainActor focus logic.
        let pressed = MainActor.assumeIsolated {
            NucleusCompositorServer.shared.inputControl?.currentPressedEvdevKeys() ?? []
        }
        for code in pressed {
            if let slot = wl_array_add(&keys, MemoryLayout<UInt32>.size) {
                slot.assumingMemoryBound(to: UInt32.self).pointee = code
            }
        }
        wl_keyboard_send_enter(kbd, nextSerial(), sres, &keys)
        wl_array_release(&keys)
        // An inhibitor on the surface gaining focus goes active (after enter).
        setInhibitorActive(clientKey: key, surfaceId: surface.objectId, true)
    }

    func keyboardLeave(_ surface: WlSurface) {
        guard let (key, sres) = client(of: surface), let kbd = keyboards[key] else { return }
        wl_keyboard_send_leave(kbd, nextSerial(), sres)
        // An inhibitor on the surface losing focus goes inactive (after leave).
        setInhibitorActive(clientKey: key, surfaceId: surface.objectId, false)
    }

    func keyboardKey(clientKey key: UInt, timeMsec: UInt32, keycode: UInt32, keyState: UInt32) {
        guard let kbd = keyboards[key] else { return }
        wl_keyboard_send_key(kbd, nextSerial(), timeMsec, keycode, keyState)
    }

    func keyboardModifiers(
        clientKey key: UInt, depressed: UInt32, latched: UInt32, locked: UInt32, group: UInt32
    ) {
        guard let kbd = keyboards[key] else { return }
        wl_keyboard_send_modifiers(kbd, nextSerial(), depressed, latched, locked, group)
    }

    // MARK: keyboard_shortcuts_inhibit registry

    /// Whether (clientKey, surface) already holds an inhibitor — the
    /// `already_inhibited` protocol-error guard.
    fileprivate func hasInhibitor(clientKey key: UInt, surfaceId: UInt32) -> Bool {
        inhibitors.values.contains { $0.clientKey == key && $0.surfaceId == surfaceId }
    }

    fileprivate func registerInhibitor(
        clientKey key: UInt, objectId: UInt32, surfaceId: UInt32,
        resource: UnsafeMutablePointer<wl_resource>
    ) {
        inhibitors[InhibitorKey(clientKey: key, objectId: objectId)] =
            Inhibitor(clientKey: key, surfaceId: surfaceId, resource: resource, active: false)
    }

    fileprivate func unregisterInhibitor(clientKey key: UInt, objectId: UInt32) {
        inhibitors[InhibitorKey(clientKey: key, objectId: objectId)] = nil
    }

    /// Whether the surface currently has an active inhibitor — consulted by the
    /// shortcut path to suppress a compositor chord (used at #12).
    func isInhibited(clientKey key: UInt, surfaceId: UInt32) -> Bool {
        inhibitors.values.contains { $0.clientKey == key && $0.surfaceId == surfaceId && $0.active }
    }

    private func setInhibitorActive(clientKey key: UInt, surfaceId: UInt32, _ active: Bool) {
        // Collect the slots that actually change first, so the mutation pass isn't
        // iterating `inhibitors` while writing it.
        let staleKeys = inhibitors.compactMap { k, e in
            e.clientKey == key && e.surfaceId == surfaceId && e.active != active ? k : nil
        }
        for k in staleKeys {
            guard var entry = inhibitors[k] else { continue }
            entry.active = active
            inhibitors[k] = entry
            if active {
                zwp_keyboard_shortcuts_inhibitor_v1_send_active(entry.resource)
            } else {
                zwp_keyboard_shortcuts_inhibitor_v1_send_inactive(entry.resource)
            }
        }
    }

    deinit {
        keyboardVtable.deallocate()
        touchVtable.deallocate()
        inhibitorVtable.deallocate()
    }
}

// MARK: - wl_seat global + device handlers

extension WlSeat {
    private static let bind: @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Void = { client, data, version, id in
        guard let client, let me = NucleusWaylandRouter.impl(data, as: WlSeat.self) else { return }
        guard let resource = WaylandResource.create(
            client: client, interface: swift_wayland_iface_wl_seat(), version: Int32(version), id: id,
            vtable: WlSeatServer.vtable, owner: SeatBinding(me)
        ) else { return }
        wl_seat_send_capabilities(resource, me.capabilities)
        if version >= 2 { wl_seat_send_name(resource, "seat0") }
    }

    // MARK: device request vtables (wl_keyboard / wl_touch are destroy-only)

    private static func makeKeyboardVtable() -> UnsafeMutableRawPointer {
        let raw = allocVtable(MemoryLayout<swift_wayland_wl_keyboard_requests>.stride,
            MemoryLayout<swift_wayland_wl_keyboard_requests>.alignment)
        let vt = raw.bindMemory(to: swift_wayland_wl_keyboard_requests.self, capacity: 1)
        vt.pointee.release = keyboardRelease
        return raw
    }

    private static func makeTouchVtable() -> UnsafeMutableRawPointer {
        let raw = allocVtable(MemoryLayout<swift_wayland_wl_touch_requests>.stride,
            MemoryLayout<swift_wayland_wl_touch_requests>.alignment)
        let vt = raw.bindMemory(to: swift_wayland_wl_touch_requests.self, capacity: 1)
        vt.pointee.release = touchRelease
        return raw
    }

    private static let keyboardRelease: @convention(c) (
        OpaquePointer?, UnsafeMutablePointer<wl_resource>?
    ) -> Void = { _, resource in if let resource { wl_resource_destroy(resource) } }

    private static let touchRelease: @convention(c) (
        OpaquePointer?, UnsafeMutablePointer<wl_resource>?
    ) -> Void = { _, resource in if let resource { wl_resource_destroy(resource) } }
}

// The wl_seat request handlers, recovered from the per-resource SeatBinding owner.
// get_pointer mints a migrated wl_pointer (WlPointerServer.vtable); get_keyboard /
// get_touch mint destroy-only devices, so they keep the hand-wired vtables.
extension SeatBinding: WlSeatRequests {
    func getPointer(_ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId) {
        let me = seat
        let owner = WlPointer(seat: me, client: id.client)
        guard let pres = id.create(vtable: WlPointerServer.vtable, owner: owner) else { return }
        me.registerPointer(WlSeat.clientKey(id.client), pres)
        owner.bind(pres)
    }

    func getKeyboard(_ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId) {
        let me = seat
        let owner = WlKeyboard(seat: me, client: id.client)
        guard let kres = id.create(
            vtable: UnsafeRawPointer(me.keyboardVtable), owner: owner
        ) else { return }
        me.registerKeyboard(WlSeat.clientKey(id.client), kres)
        owner.bind(kres)
        // Share the xkb keymap (format 1 = xkb_v1). The fd is borrowed; libwayland
        // dups it into the wire message, so the seat keeps owning it.
        if me.keymapFd >= 0 {
            wl_keyboard_send_keymap(kres, 1, me.keymapFd, me.keymapSize)
        }
        if id.version >= 4 { wl_keyboard_send_repeat_info(kres, 25, 600) }
    }

    func getTouch(_ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId) {
        let me = seat
        let owner = WlTouch(seat: me, client: id.client)
        guard let tres = id.create(
            vtable: UnsafeRawPointer(me.touchVtable), owner: owner
        ) else { return }
        me.registerTouch(WlSeat.clientKey(id.client), tres)
        owner.bind(tres)
    }
}

// MARK: - zwp_keyboard_shortcuts_inhibit_manager_v1 + inhibitor

extension WlSeat {
    private static func makeInhibitorVtable() -> UnsafeMutableRawPointer {
        let raw = allocVtable(MemoryLayout<swift_wayland_zwp_keyboard_shortcuts_inhibitor_v1_requests>.stride,
            MemoryLayout<swift_wayland_zwp_keyboard_shortcuts_inhibitor_v1_requests>.alignment)
        let vt = raw.bindMemory(to: swift_wayland_zwp_keyboard_shortcuts_inhibitor_v1_requests.self, capacity: 1)
        vt.pointee.destroy = inhibitorDestroy
        return raw
    }

    private static let bindInhibitManager: @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Void = { client, data, version, id in
        guard let client, let me = NucleusWaylandRouter.impl(data, as: WlSeat.self) else { return }
        _ = WaylandResource.create(
            client: client, interface: swift_wayland_iface_zwp_keyboard_shortcuts_inhibit_manager_v1(),
            version: Int32(version), id: id,
            vtable: ZwpKeyboardShortcutsInhibitManagerV1Server.vtable,
            owner: ShortcutsInhibitManagerBinding(me)
        )
    }

    private static let inhibitorDestroy: @convention(c) (
        OpaquePointer?, UnsafeMutablePointer<wl_resource>?
    ) -> Void = { _, resource in if let resource { wl_resource_destroy(resource) } }
}

// inhibit_shortcuts recovered from the per-resource ShortcutsInhibitManagerBinding owner.
// The minted zwp_keyboard_shortcuts_inhibitor_v1 is destroy-only, so it keeps the
// hand-wired inhibitorVtable.
extension ShortcutsInhibitManagerBinding: ZwpKeyboardShortcutsInhibitManagerV1Requests {
    func inhibitShortcuts(
        _ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId,
        surface surfaceRes: UnsafeMutablePointer<wl_resource>?,
        seat seatRes: UnsafeMutablePointer<wl_resource>?
    ) {
        let me = seat
        guard let surfaceRes, let surface = WaylandResource.owner(of: surfaceRes, as: WlSurface.self)
        else { return }
        let key = WlSeat.clientKey(id.client)
        // already_inhibited (code 0): one inhibitor per (surface, seat) — a fatal error.
        guard !me.hasInhibitor(clientKey: key, surfaceId: surface.objectId) else {
            swift_wayland_resource_post_error(resource, 0, "shortcuts already inhibited for surface")
            return
        }
        let owner = WlShortcutsInhibitor(seat: me, clientKey: key, objectId: id.id)
        guard let ires = id.create(
            vtable: UnsafeRawPointer(me.inhibitorVtable), owner: owner
        ) else { return }
        me.registerInhibitor(
            clientKey: key, objectId: id.id, surfaceId: surface.objectId, resource: ires)
    }
}

/// Shared raw-vtable allocation: zeroed C request struct the @convention(c)
/// handler fields are assigned into (memberwise init is unusable under C++ interop).
func allocVtable(_ size: Int, _ alignment: Int) -> UnsafeMutableRawPointer {
    let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: alignment)
    raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)
    return raw
}

// MARK: - device + inhibitor resource owners (Rule 9)

/// wl_pointer resource owner. Unregisters from the seat on destruction so the seat
/// stops delivering to a gone device.
final class WlPointer {
    private weak let seat: WlSeat?
    private let clientKey: UInt
    private var resource: UnsafeMutablePointer<wl_resource>?

    init(seat: WlSeat, client: OpaquePointer) {
        self.seat = seat
        self.clientKey = WlSeat.clientKey(client)
    }
    func bind(_ resource: UnsafeMutablePointer<wl_resource>) { self.resource = resource }
    deinit { if let resource { seat?.unregisterPointer(clientKey, resource) } }
}

extension WlPointer: WlPointerRequests {
    /// The client sets its cursor: bind the given surface as the cursor image (its
    /// committed SHM buffer becomes the cursor, updated on every commit) with the given
    /// hotspot, or hide the cursor when the surface is nil. The binding is cleared when
    /// pointer focus leaves the client (InputDispatch restores the default cursor).
    func setCursor(
        _ resource: UnsafeMutablePointer<wl_resource>, serial: UInt32,
        surface: UnsafeMutablePointer<wl_resource>?, hotspot_x: Int32, hotspot_y: Int32
    ) {
        // Cross only Sendable values into the actor (raw pointers / the seat as opaque
        // bit patterns, the client key as an integer); reconstruct inside. Capturing
        // `self` would send the non-Sendable WlPointer into the main-actor closure.
        let surfaceBits = surface.map { UInt(bitPattern: $0) } ?? 0
        let requestClientKey = clientKey
        let seatBits = seat.map { UInt(bitPattern: Unmanaged.passUnretained($0).toOpaque()) } ?? 0
        MainActor.assumeIsolated {
            // Ignore the request entirely unless this client holds pointer focus with a
            // matching enter serial — including the nil-surface (hide) case, so a client
            // that lost focus can't hide the new focus owner's cursor.
            guard let seatPtr = UnsafeRawPointer(bitPattern: seatBits) else { return }
            let seat = Unmanaged<WlSeat>.fromOpaque(seatPtr).takeUnretainedValue()
            guard seat.acceptsCursorRequest(client: requestClientKey, serial: serial) else { return }
            guard let surfaceRes = UnsafeMutablePointer<wl_resource>(bitPattern: surfaceBits),
                  let surfaceObj = WaylandResource.owner(of: surfaceRes, as: WlSurface.self)
            else {
                // Nil surface → hide the cursor.
                PointerCursorSurface.clear()
                NucleusCompositorServer.shared.cursor.hide()
                RenderBridge.requestFrame(outputId: 0)
                return
            }
            PointerCursorSurface.bind(
                surfaceId: surfaceObj.objectId, hotspotX: hotspot_x, hotspotY: hotspot_y)
            // Realize the surface's current buffer immediately (client may have committed
            // it before set_cursor); later commits refresh it via the commit hook.
            PointerCursorSurface.applyCommittedImage(surfaceObj)
            RenderBridge.requestFrame(outputId: 0)
        }
    }
}

final class WlKeyboard {
    private weak var seat: WlSeat?
    private let clientKey: UInt
    private var resource: UnsafeMutablePointer<wl_resource>?

    init(seat: WlSeat, client: OpaquePointer) {
        self.seat = seat
        self.clientKey = WlSeat.clientKey(client)
    }
    func bind(_ resource: UnsafeMutablePointer<wl_resource>) { self.resource = resource }
    deinit { if let resource { seat?.unregisterKeyboard(clientKey, resource) } }
}

final class WlTouch {
    private weak var seat: WlSeat?
    private let clientKey: UInt
    private var resource: UnsafeMutablePointer<wl_resource>?

    init(seat: WlSeat, client: OpaquePointer) {
        self.seat = seat
        self.clientKey = WlSeat.clientKey(client)
    }
    func bind(_ resource: UnsafeMutablePointer<wl_resource>) { self.resource = resource }
    deinit { if let resource { seat?.unregisterTouch(clientKey, resource) } }
}

/// zwp_keyboard_shortcuts_inhibitor_v1 resource owner. Drops the seat's registry
/// entry on destruction.
final class WlShortcutsInhibitor {
    private weak var seat: WlSeat?
    private let clientKey: UInt
    private let objectId: UInt32

    init(seat: WlSeat, clientKey: UInt, objectId: UInt32) {
        self.seat = seat
        self.clientKey = clientKey
        self.objectId = objectId
    }
    deinit { seat?.unregisterInhibitor(clientKey: clientKey, objectId: objectId) }
}
