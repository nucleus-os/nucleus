// wl_seat on the router — the seat mints each client's wl_pointer / wl_keyboard /
// wl_touch device resources and owns the encoding of every pointer/keyboard/touch
// event. The focus + grab mechanism (hit-testing, implicit grab, button tracking)
// stays out of here and drives the seat through the send methods below. Because the
// device resources live only here, there is no separate device list or bridge.
//
// keyboard_shortcuts_inhibit lives here too: an inhibitor is scoped to a
// (client, surface) and goes active/inactive exactly as that surface gains/loses
// keyboard focus — which the seat already drives through keyboardEnter/Leave.
//
// The send methods port the retired SeatProtocol encoding 1:1 (opcodes, argument
// order, fixed-point scaling, the version-gated axis sequence, the keymap fd), but
// the wire bytes now flow through libwayland's own wl_*_send_* inlines (Rule 7)
// rather than a handwritten codec.

@unsafe import WaylandServerC
internal import NucleusCompositorServer
import NucleusLinuxPrimitives
@unsafe import WaylandServer
import WaylandServerDispatch
import WaylandProtocolTypes

/// Owner bound to each wl_seat resource (Rule 9). Routes get_pointer / get_keyboard
/// / get_touch back to the shared WlSeat.
@MainActor
@safe final class SeatBinding {
    unowned let seat: WlSeat
    private let resource: WaylandResourceHandle<WlSeatServer>
    init(
        resource: WaylandResourceHandle<WlSeatServer>,
        seat: WlSeat
    ) {
        self.resource = resource
        self.seat = seat
    }
    isolated deinit {
        seat.unregisterSeatResource(resource)
    }
}

@MainActor
@safe final class WlSeat {
    unowned let host: RouterHost

    private let display: WaylandDisplay

    /// wl_seat capability bits: pointer=1, keyboard=2, touch=4. History is
    /// retained because get_* is valid while a capability is absent only when
    /// that seat advertised it previously.
    private(set) var capabilities: UInt32 = 0
    private var capabilityHistory: UInt32 = 0
    private var seatResources: [WaylandResourceHandle<WlSeatServer>] = []

    /// xkb keymap memfd shared with clients via wl_keyboard.keymap (format xkb_v1).
    /// Owned by the input subsystem; the seat only borrows the fd to send it. Set by
    /// the owner before clients bind (a fixture provides a synthetic one).
    private var keymapDescriptor: LinuxOwnedFileDescriptor?
    private(set) var keymapSize: UInt32 = 0

    // Every live device resource eligible in the current capability epoch, keyed
    // by wl_client. On capability removal the maps are cleared: v5+ objects made
    // before a later re-add must remain inert, while clients mint fresh objects.
    private var pointers: [WaylandClientID: [WaylandResourceHandle<WlPointerServer>]] = [:]
    private var keyboards: [WaylandClientID: [WaylandResourceHandle<WlKeyboardServer>]] = [:]
    private var touches: [WaylandClientID: [WaylandResourceHandle<WlTouchServer>]] = [:]
    private let serials = SeatSerialLedger()

    // The seat owns relative-pointer emission and pointer-constraint application:
    // every absolute motion also emits zwp_relative_pointer_v1.relative_motion for
    // the focused client, and a locked constraint suppresses the absolute motion
    // (relative still flows). The managers are retained by the router's global set;
    // the seat holds them to reach the delivery semantics. The currently
    // pointer-focused surface drives the constraint active/inactive transitions.
    var relativePointer: RelativePointerManager?
    var pointerConstraints: PointerConstraintsManager?
    weak var dataDeviceManager: WlDataDeviceManager?
    weak var textInputManager: TextInputManagerV3?
    private weak var pointerFocusSurface: WlSurface?
    private weak var keyboardFocusSurface: WlSurface?
    private let popupGrabs = PopupGrabState()

    // set_cursor validation: the protocol honors wl_pointer.set_cursor only from the
    // client that currently holds pointer focus, and only when its `serial` matches the
    // latest wl_pointer.enter serial that client received. Track that (serial, client)
    // pair; it is set on enter and cleared on leave so a stale or wrong-client request
    // (a common way clients race a cursor set against a focus change) is dropped.
    private var lastPointerEnterSerial: UInt32 = 0
    private var pointerFocusClientKey: WaylandClientID?

    // keyboard_shortcuts_inhibit: scoped to (client, surface), active while that
    // surface holds keyboard focus. Keyed by the inhibitor's own (client, objectId)
    // so teardown is O(1); the surface + active state ride the entry.
    @safe private struct Inhibitor {
        let clientKey: WaylandClientID
        let surfaceId: UInt32
        let resource:
            WaylandResourceHandle<ZwpKeyboardShortcutsInhibitorV1Server>
        var active: Bool
    }
    private var inhibitors: [InhibitorKey: Inhibitor] = [:]
    private struct InhibitorKey: Hashable { let clientKey: WaylandClientID; let objectId: UInt32 }

    init(host: RouterHost, display: WaylandDisplay) {
        self.host = host
        self.display = display
    }

    private func nextSerial() -> UInt32 {
        display.nextSerial()
    }

    // MARK: device registry (called by the get_* handlers / device deinit)

    func registerSeatResource(
        _ resource: WaylandResourceHandle<WlSeatServer>
    ) {
        seatResources.append(resource)
    }

    fileprivate func unregisterSeatResource(
        _ resource: WaylandResourceHandle<WlSeatServer>
    ) {
        let clientKey = resource.clientID
        seatResources.removeAll { $0 === resource }
        if let clientKey,
            !seatResources.contains(where: { $0.clientID == clientKey })
        {
            serials.invalidate(clientKey: clientKey)
        }
    }

    fileprivate func registerPointer(
        _ key: WaylandClientID,
        _ res: WaylandResourceHandle<WlPointerServer>
    ) {
        pointers[key, default: []].append(res)
    }
    fileprivate func registerKeyboard(
        _ key: WaylandClientID,
        _ res: WaylandResourceHandle<WlKeyboardServer>
    ) {
        keyboards[key, default: []].append(res)
    }
    fileprivate func registerTouch(
        _ key: WaylandClientID,
        _ res: WaylandResourceHandle<WlTouchServer>
    ) {
        touches[key, default: []].append(res)
    }

    fileprivate func unregisterPointer(
        _ key: WaylandClientID,
        _ res: WaylandResourceHandle<WlPointerServer>
    ) {
        pointers[key]?.removeAll { $0 === res }
        if pointers[key]?.isEmpty == true { pointers[key] = nil }
    }
    fileprivate func unregisterKeyboard(
        _ key: WaylandClientID,
        _ res: WaylandResourceHandle<WlKeyboardServer>
    ) {
        keyboards[key]?.removeAll { $0 === res }
        if keyboards[key]?.isEmpty == true { keyboards[key] = nil }
    }
    fileprivate func unregisterTouch(
        _ key: WaylandClientID,
        _ res: WaylandResourceHandle<WlTouchServer>
    ) {
        touches[key]?.removeAll { $0 === res }
        if touches[key]?.isEmpty == true { touches[key] = nil }
    }

    func updateCapabilities(pointer: Bool, keyboard: Bool, touch: Bool) {
        let next = (pointer ? UInt32(1) : 0)
            | (keyboard ? UInt32(2) : 0)
            | (touch ? UInt32(4) : 0)
        guard next != capabilities else { return }
        let removed = capabilities & ~next
        if removed & (1 | 4) != 0 {
            dataDeviceManager?.cancelActiveDrag(
                notifySource: true)
        }
        if removed & 1 != 0 {
            if let pointerFocusSurface {
                pointerLeave(pointerFocusSurface)
            }
            pointers.removeAll(keepingCapacity: true)
            serials.invalidate(kind: .pointerEnter)
            serials.invalidate(kind: .pointerButton)
            lastPointerEnterSerial = 0
            pointerFocusClientKey = nil
        }
        if removed & 2 != 0 {
            if let keyboardFocusSurface {
                keyboardLeave(keyboardFocusSurface)
            }
            keyboards.removeAll(keepingCapacity: true)
            serials.invalidate(kind: .keyboardKey)
        }
        if removed & 4 != 0 {
            for resources in touches.values {
                for resource in resources { resource.sendCancel() }
            }
            touches.removeAll(keepingCapacity: true)
            serials.invalidate(kind: .touchDown)
        }
        capabilities = next
        capabilityHistory |= next
        for resource in seatResources {
            resource.sendCapabilities(
                capabilities: WlSeatCapability(rawValue: capabilities))
        }
    }

    fileprivate func hasEverAdvertised(_ capability: UInt32) -> Bool {
        capabilityHistory & capability != 0
    }

    fileprivate func currentlyAdvertises(_ capability: UInt32) -> Bool {
        capabilities & capability != 0
    }

    func updateKeymap(
        descriptor: consuming LinuxOwnedFileDescriptor,
        size: UInt32
    ) {
        keymapDescriptor = consume descriptor
        keymapSize = size
        for resources in keyboards.values {
            for resource in resources {
                sendKeymap(to: resource)
            }
        }
    }

    fileprivate func sendKeymap(
        to resource: WaylandResourceHandle<WlKeyboardServer>
    ) {
        keymapDescriptor?.withBorrowedDescriptor {
            _ = resource.sendKeymap(
                format: .xkbV1,
                fd: $0.rawValue,
                size: keymapSize)
        }
    }

    /// Start a new serial-validity epoch. Session loss invalidates every user-intent
    /// token, even if libwayland's display serial itself continues increasing.
    func invalidateSerialsForSessionTransition() {
        dataDeviceManager?.cancelActiveDrag(
            notifySource: true)
        cancelPopupGrabs()
        serials.beginNewSession()
        lastPointerEnterSerial = 0
        pointerFocusClientKey = nil
    }

    func beginPopupGrab(_ popup: XdgPopup) {
        popupGrabs.begin(popup)
    }

    func popupGrabDeliverySurface(fallback: WlSurface) -> WlSurface {
        popupGrabs.deliverySurface(fallback: fallback)
    }

    /// Dismiss the grabbed popup subtree and swallow the outside interaction.
    func dismissPopupGrabIfOutside(_ target: WlSurface) -> Bool {
        popupGrabs.dismissIfOutside(target)
    }

    func cancelPopupGrabs() {
        popupGrabs.cancel()
    }

    /// Serial authority for requests scoped to a client rather than one exact
    /// surface, such as clipboard selection.
    func authorize(
        serial: UInt32,
        clientKey: WaylandClientID,
        surfaceID: UInt32? = nil,
        kinds: Set<SeatSerialKind>,
        consume: Bool = true
    ) -> Bool {
        serials.authorizes(
            serial: SeatInputSerial(rawValue: serial),
            kinds: kinds,
            clientKey: clientKey,
            surfaceID: surfaceID,
            consume: consume)
    }

    // MARK: pointer sends

    private func client(
        of surface: WlSurface
    ) -> (
        key: WaylandClientID,
        surface: WaylandResourceHandle<WlSurfaceServer>
    )? {
        guard let resource = surface.protocolResource,
            let client = resource.clientID
        else { return nil }
        return (client, resource)
    }

    @discardableResult
    func pointerEnter(_ surface: WlSurface, surfaceX: Double, surfaceY: Double) -> UInt32 {
        guard let (key, sres) = client(of: surface),
            let resources = pointers[key], !resources.isEmpty
        else { return 0 }
        let serial = nextSerial()
        serials.invalidate(kind: .pointerEnter)
        serials.record(
            serial: SeatInputSerial(rawValue: serial),
            kind: .pointerEnter, clientKey: key,
            surfaceID: surface.objectId)
        for pointer in resources {
            pointer.sendEnter(
                serial: serial, surface: sres,
                surface_x: surfaceX, surface_y: surfaceY)
        }
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
        let leavingClientKey = client(of: surface)?.key
        // Drive the constraint inactive even if the device resource is gone — the
        // focus transition is what the constraint lifetime keys on.
        pointerConstraints?.notifyPointerFocus(old: surface, new: nil)
        if pointerFocusSurface === surface {
            pointerFocusSurface = nil
            // Focus left this client: its enter serial no longer authorizes a cursor set.
            pointerFocusClientKey = nil
            if let leavingClientKey {
                serials.invalidate(kind: .pointerEnter, clientKey: leavingClientKey)
                serials.invalidate(kind: .pointerButton, clientKey: leavingClientKey)
            }
        }
        guard let (key, sres) = client(of: surface),
            let resources = pointers[key]
        else { return }
        let serial = nextSerial()
        for pointer in resources {
            pointer.sendLeave(serial: serial, surface: sres)
        }
    }

    /// Whether a wl_pointer.set_cursor from `client` carrying `serial` is authorized:
    /// the client must currently hold pointer focus and the serial must match the enter
    /// event that granted it. Mismatches (wrong client, stale serial) are ignored per
    /// the protocol rather than applied.
    func acceptsCursorRequest(
        client key: WaylandClientID,
        serial: UInt32
    ) -> Bool {
        pointerFocusClientKey == key
            && serial == lastPointerEnterSerial
            && serials.authorizes(
                serial: SeatInputSerial(rawValue: serial),
                kinds: [.pointerEnter], clientKey: key,
                surfaceID: pointerFocusSurface?.objectId, consume: false)
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
        _ surface: WlSurface, clientKey key: WaylandClientID, timeMsec: UInt32,
        surfaceX: Double, surfaceY: Double,
        dx: Double, dy: Double, dxUnaccel: Double, dyUnaccel: Double
    ) {
        guard let resources = pointers[key] else { return }
        relativePointer?.emitRelativeMotion(
            clientKey: key, timestampUs: UInt64(timeMsec) &* 1000,
            dx: dx, dy: dy, dxUnaccel: dxUnaccel, dyUnaccel: dyUnaccel)
        if let constraints = pointerConstraints,
            constraints.activeConstraintKind(for: surface) == .locked { return }
        for pointer in resources {
            pointer.sendMotion(
                time: timeMsec,
                surface_x: surfaceX,
                surface_y: surfaceY)
        }
    }

    @discardableResult
    func pointerButton(
        clientKey key: WaylandClientID,
        surface: WlSurface? = nil,
        timeMsec: UInt32,
        button: UInt32,
        state: UInt32
    ) -> UInt32 {
        guard let resources = pointers[key], !resources.isEmpty else { return 0 }
        let serial = nextSerial()
        if state != 0 {
            serials.record(
                serial: SeatInputSerial(rawValue: serial),
                kind: .pointerButton, clientKey: key,
                surfaceID: surface?.objectId)
        } else {
            serials.invalidate(kind: .pointerButton, clientKey: key)
        }
        for pointer in resources {
            pointer.sendButton(
                serial: serial, time: timeMsec, button: button,
                state: WlPointerButtonState(rawValue: state))
        }
        return serial
    }

    /// The version-gated axis sequence, ported from the retired sendPointerAxis:
    /// axis_source → [axis_value120 | axis_discrete] → axis | axis_stop.
    func pointerAxis(
        clientKey key: WaylandClientID, timeMsec: UInt32, axis: UInt32, delta: Double,
        value120: Int32, source: UInt32
    ) {
        guard let resources = pointers[key] else { return }
        for pointer in resources {
            if pointer.supportsAxisSource {
                pointer.sendAxisSource(
                    axis_source: WlPointerAxisSource(rawValue: source))
            }
            if delta == 0.0 {
                if pointer.supportsAxisStop, source == 1 {
                    pointer.sendAxisStop(
                        time: timeMsec,
                        axis: WlPointerAxis(rawValue: axis))
                }
                continue
            }
            if value120 != 0 {
                if pointer.supportsAxisValue120 {
                    pointer.sendAxisValue120(
                        axis: WlPointerAxis(rawValue: axis),
                        value120: value120)
                } else if pointer.supportsAxisDiscrete {
                    let discrete = value120 / 120
                    if discrete != 0 {
                        pointer.sendAxisDiscrete(
                            axis: WlPointerAxis(rawValue: axis),
                            discrete: discrete)
                    }
                }
            }
            pointer.sendAxis(
                time: timeMsec,
                axis: WlPointerAxis(rawValue: axis),
                value: delta)
        }
    }

    func pointerFrame(clientKey key: WaylandClientID) {
        guard let resources = pointers[key] else { return }
        for pointer in resources where pointer.supportsFrame {
            pointer.sendFrame()
        }
    }

    // MARK: touch sends

    @discardableResult
    func touchDown(
        _ surface: WlSurface, timeMsec: UInt32, id: Int32, surfaceX: Double, surfaceY: Double
    ) -> UInt32 {
        guard let (key, sres) = client(of: surface),
            let resources = touches[key], !resources.isEmpty
        else { return 0 }
        let serial = nextSerial()
        serials.record(
            serial: SeatInputSerial(rawValue: serial),
            kind: .touchDown, clientKey: key,
            surfaceID: surface.objectId)
        for touch in resources {
            touch.sendDown(
                serial: serial, time: timeMsec, surface: sres, id: id,
                x: surfaceX, y: surfaceY)
        }
        return serial
    }

    func touchUp(clientKey key: WaylandClientID, timeMsec: UInt32, id: Int32) {
        guard let resources = touches[key] else { return }
        let serial = nextSerial()
        for touch in resources {
            touch.sendUp(serial: serial, time: timeMsec, id: id)
        }
        serials.invalidate(kind: .touchDown, clientKey: key)
    }

    func touchMotion(clientKey key: WaylandClientID, timeMsec: UInt32, id: Int32, x: Double, y: Double) {
        guard let resources = touches[key] else { return }
        for touch in resources {
            touch.sendMotion(time: timeMsec, id: id, x: x, y: y)
        }
    }

    func touchFrame(clientKey key: WaylandClientID) {
        guard let resources = touches[key] else { return }
        for touch in resources { touch.sendFrame() }
    }

    func touchCancel(clientKey key: WaylandClientID) {
        if let resources = touches[key] {
            for touch in resources { touch.sendCancel() }
        }
        serials.invalidate(kind: .touchDown, clientKey: key)
    }

    // MARK: keyboard sends

    func keyboardEnter(_ surface: WlSurface) {
        textInputManager?.keyboardEnter(surface)
        guard let (key, sres) = client(of: surface),
            let resources = keyboards[key], !resources.isEmpty
        else { return }
        // Report the currently-held evdev keys, so a surface gaining keyboard focus
        // while a key is physically down sees correct key state instead of an empty
        // set (which desyncs the client's repeat/stuck-key handling). keyboardEnter is
        // set from the same compositor turn that emits the enter event.
        let pressed =
            host.server.inputControl?.currentPressedEvdevKeys() ?? []
        let serial = nextSerial()
        keyboardFocusSurface = surface
        for keyboard in resources {
            keyboard.sendEnter(
                serial: serial, surface: sres, keys: pressed)
        }
        // An inhibitor on the surface gaining focus goes active (after enter).
        setInhibitorActive(clientKey: key, surfaceId: surface.objectId, true)
    }

    func keyboardLeave(_ surface: WlSurface) {
        textInputManager?.keyboardLeave(surface)
        guard let (key, sres) = client(of: surface),
            let resources = keyboards[key]
        else { return }
        let serial = nextSerial()
        for keyboard in resources {
            keyboard.sendLeave(serial: serial, surface: sres)
        }
        // An inhibitor on the surface losing focus goes inactive (after leave).
        setInhibitorActive(clientKey: key, surfaceId: surface.objectId, false)
        if keyboardFocusSurface === surface { keyboardFocusSurface = nil }
        serials.invalidate(kind: .keyboardKey, clientKey: key)
    }

    func keyboardKey(clientKey key: WaylandClientID, timeMsec: UInt32, keycode: UInt32, keyState: UInt32) {
        guard let resources = keyboards[key] else { return }
        let serial = nextSerial()
        if keyState != 0 {
            serials.record(
                serial: SeatInputSerial(rawValue: serial),
                kind: .keyboardKey, clientKey: key,
                surfaceID: keyboardFocusSurface?.objectId)
        } else {
            serials.invalidate(kind: .keyboardKey, clientKey: key)
        }
        for keyboard in resources {
            keyboard.sendKey(
                serial: serial, time: timeMsec, key: keycode,
                state: WlKeyboardKeyState(rawValue: keyState))
        }
    }

    func keyboardModifiers(
        clientKey key: WaylandClientID, depressed: UInt32, latched: UInt32, locked: UInt32, group: UInt32
    ) {
        guard let resources = keyboards[key] else { return }
        let serial = nextSerial()
        for keyboard in resources {
            keyboard.sendModifiers(
                serial: serial,
                mods_depressed: depressed,
                mods_latched: latched,
                mods_locked: locked,
                group: group)
        }
    }

    // MARK: keyboard_shortcuts_inhibit registry

    /// Whether (clientKey, surface) already holds an inhibitor — the
    /// `already_inhibited` protocol-error guard.
    fileprivate func hasInhibitor(clientKey key: WaylandClientID, surfaceId: UInt32) -> Bool {
        inhibitors.values.contains { $0.clientKey == key && $0.surfaceId == surfaceId }
    }

    fileprivate func registerInhibitor(
        clientKey key: WaylandClientID, objectId: UInt32, surfaceId: UInt32,
        resource:
            WaylandResourceHandle<ZwpKeyboardShortcutsInhibitorV1Server>
    ) {
        inhibitors[InhibitorKey(clientKey: key, objectId: objectId)] =
            Inhibitor(
                clientKey: key, surfaceId: surfaceId,
                resource: resource, active: false)
    }

    fileprivate func unregisterInhibitor(clientKey key: WaylandClientID, objectId: UInt32) {
        inhibitors[InhibitorKey(clientKey: key, objectId: objectId)] = nil
    }

    /// Whether the surface currently has an active inhibitor — consulted by the
    /// shortcut path to suppress a compositor chord.
    func isInhibited(clientKey key: WaylandClientID, surfaceId: UInt32) -> Bool {
        inhibitors.values.contains { $0.clientKey == key && $0.surfaceId == surfaceId && $0.active }
    }

    private func setInhibitorActive(clientKey key: WaylandClientID, surfaceId: UInt32, _ active: Bool) {
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
                entry.resource.sendActive()
            } else {
                entry.resource.sendInactive()
            }
        }
    }

}

// MARK: - wl_seat global + device handlers

// The wl_seat request handlers, recovered from the per-resource SeatBinding owner.
// get_pointer mints a migrated wl_pointer (WlPointerServer.vtable); get_keyboard /
// get_touch mint devices whose release requests use generated dispatch.
extension SeatBinding: WlSeatRequests {
    func getPointer(
        _ request: WaylandRequest<WlSeatServer>,
        id: WlNewId<WlPointerServer>
    ) {
        let me = seat
        guard me.hasEverAdvertised(1) else {
            request.postError(.missingCapability, message: "seat has never advertised pointer capability")
            return
        }
        _ = id.create(
            owner: { handle in
                WlPointer(
                    resource: handle, seat: me, clientKey: id.clientID)
            },
            installed: { owner in
                guard me.currentlyAdvertises(1) else { return }
                me.registerPointer(id.clientID, owner.resource)
            })
    }

    func getKeyboard(
        _ request: WaylandRequest<WlSeatServer>,
        id: WlNewId<WlKeyboardServer>
    ) {
        let me = seat
        guard me.hasEverAdvertised(2) else {
            request.postError(.missingCapability, message: "seat has never advertised keyboard capability")
            return
        }
        _ = id.create(
            owner: { handle in
                WlKeyboard(
                    resource: handle, seat: me, clientKey: id.clientID)
            },
            installed: { owner in
                if me.currentlyAdvertises(2) {
                    me.registerKeyboard(id.clientID, owner.resource)
                }
                me.sendKeymap(to: owner.resource)
                if owner.resource.supportsRepeatInfo {
                    owner.resource.sendRepeatInfo(rate: 25, delay: 600)
                }
            })
    }

    func getTouch(
        _ request: WaylandRequest<WlSeatServer>,
        id: WlNewId<WlTouchServer>
    ) {
        let me = seat
        guard me.hasEverAdvertised(4) else {
            request.postError(.missingCapability, message: "seat has never advertised touch capability")
            return
        }
        _ = id.create(
            owner: { handle in
                WlTouch(
                    resource: handle, seat: me, clientKey: id.clientID)
            },
            installed: { owner in
                guard me.currentlyAdvertises(4) else { return }
                me.registerTouch(id.clientID, owner.resource)
            })
    }
}

// MARK: - zwp_keyboard_shortcuts_inhibit_manager_v1 + inhibitor

// The minted zwp_keyboard_shortcuts_inhibitor_v1 uses generated destroy dispatch.
extension WlSeat: ZwpKeyboardShortcutsInhibitManagerV1Requests {
    func inhibitShortcuts(
        _ request: WaylandRequest<ZwpKeyboardShortcutsInhibitManagerV1Server>,
        id: WlNewId<ZwpKeyboardShortcutsInhibitorV1Server>,
        surface surfaceRes: WaylandBorrowedObject<WlSurfaceServer>,
        seat seatRes: WaylandBorrowedObject<WlSeatServer>
    ) {
        guard let surface = surfaceRes.owner(as: WlSurface.self) else { return }
        let key = id.clientID
        // already_inhibited (code 0): one inhibitor per (surface, seat) — a fatal error.
        guard !hasInhibitor(clientKey: key, surfaceId: surface.objectId) else {
            request.postError(.alreadyInhibited, message: "shortcuts already inhibited for surface")
            return
        }
        _ = id.create(
            owner: { handle in
                WlShortcutsInhibitor(
                    resource: handle,
                    seat: self,
                    clientKey: key,
                    objectId: id.id)
            },
            installed: { owner in
                self.registerInhibitor(
                    clientKey: key,
                    objectId: id.id,
                    surfaceId: surface.objectId,
                    resource: owner.resource)
            })
    }
}

// MARK: - device + inhibitor resource owners (Rule 9)

/// wl_pointer resource owner. Unregisters from the seat on destruction so the seat
/// stops delivering to a gone device.
@MainActor
@safe final class WlPointer {
    private weak let seat: WlSeat?
    private let clientKey: WaylandClientID
    fileprivate let resource: WaylandResourceHandle<WlPointerServer>

    init(
        resource: WaylandResourceHandle<WlPointerServer>,
        seat: WlSeat,
        clientKey: WaylandClientID
    ) {
        self.resource = resource
        self.seat = seat
        self.clientKey = clientKey
    }
    func authorizesCursor(serial: UInt32) -> Bool {
        seat?.acceptsCursorRequest(client: clientKey, serial: serial) == true
    }
    isolated deinit {
        seat?.unregisterPointer(clientKey, resource)
    }
}

extension WlPointer: WlPointerRequests {
    /// The client sets its cursor: bind the given surface as the cursor image (its
    /// committed SHM buffer becomes the cursor, updated on every commit) with the given
    /// hotspot, or hide the cursor when the surface is nil. The binding is cleared when
    /// pointer focus leaves the client (InputDispatch restores the default cursor).
    func setCursor(
        _ request: WaylandRequest<WlPointerServer>, serial: UInt32,
        surface: WaylandBorrowedObject<WlSurfaceServer>?, hotspot_x: Int32, hotspot_y: Int32
    ) {
        guard let seat,
            seat.acceptsCursorRequest(client: clientKey, serial: serial)
        else { return }
        guard let surfaceObject = surface?.owner(as: WlSurface.self)
        else {
            RenderBridge.requestCursorFrame(server: seat.host.server)
            seat.host.pointerCursorSurface.clear()
            seat.host.server.cursor.hide()
            return
        }
        guard surfaceObject.claimCursorRole() else {
            request.postError(.role, message: "cursor surface already has an incompatible role")
            return
        }
        seat.host.pointerCursorSurface.bind(
            surfaceId: surfaceObject.objectId,
            hotspotX: hotspot_x,
            hotspotY: hotspot_y)
        // Realize the surface's current buffer immediately (client may have committed
        // it before set_cursor); later commits refresh it via the commit hook.
        seat.host.pointerCursorSurface.applyCommittedImage(surfaceObject)
        RenderBridge.requestCursorFrame(server: seat.host.server)
    }
}

@MainActor
@safe final class WlKeyboard {
    private weak var seat: WlSeat?
    private let clientKey: WaylandClientID
    fileprivate let resource: WaylandResourceHandle<WlKeyboardServer>

    init(
        resource: WaylandResourceHandle<WlKeyboardServer>,
        seat: WlSeat,
        clientKey: WaylandClientID
    ) {
        self.resource = resource
        self.seat = seat
        self.clientKey = clientKey
    }
    isolated deinit {
        seat?.unregisterKeyboard(clientKey, resource)
    }
}

@MainActor
@safe final class WlTouch {
    private weak var seat: WlSeat?
    private let clientKey: WaylandClientID
    fileprivate let resource: WaylandResourceHandle<WlTouchServer>

    init(
        resource: WaylandResourceHandle<WlTouchServer>,
        seat: WlSeat,
        clientKey: WaylandClientID
    ) {
        self.resource = resource
        self.seat = seat
        self.clientKey = clientKey
    }
    isolated deinit {
        seat?.unregisterTouch(clientKey, resource)
    }
}

/// zwp_keyboard_shortcuts_inhibitor_v1 resource owner. Drops the seat's registry
/// entry on destruction.
@MainActor
final class WlShortcutsInhibitor {
    fileprivate let resource:
        WaylandResourceHandle<ZwpKeyboardShortcutsInhibitorV1Server>
    private weak var seat: WlSeat?
    private let clientKey: WaylandClientID
    private let objectId: UInt32

    init(
        resource:
            WaylandResourceHandle<ZwpKeyboardShortcutsInhibitorV1Server>,
        seat: WlSeat,
        clientKey: WaylandClientID,
        objectId: UInt32
    ) {
        self.resource = resource
        self.seat = seat
        self.clientKey = clientKey
        self.objectId = objectId
    }
    isolated deinit {
        seat?.unregisterInhibitor(clientKey: clientKey, objectId: objectId)
    }
}
