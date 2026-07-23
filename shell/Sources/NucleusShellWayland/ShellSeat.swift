// The shell's seat driver: binds wl_seat, attaches wl_pointer and wl_keyboard,
// and turns their callbacks into a neutral event record.
//
// The client mirror of the compositor's input host. Where the compositor reads
// libinput and *owns* the xkb state, a client is handed a compiled keymap over
// `wl_keyboard.keymap` and tracks modifier state from `wl_keyboard.modifiers`
// serials. Composition still happens here, because the compositor sends
// keycodes, never text.
//
// This target deliberately does not import NucleusUI: it emits evdev-flavoured
// records and the runtime translates them, the same tier split the compositor's
// overlay adapter uses.

import WaylandClientC
public import WaylandClientDispatch
import WaylandClient
import WaylandProtocolsC
import NucleusShellInputC
#if canImport(Glibc)
import Glibc
#endif

public enum ShellInputEventKind: Sendable, Equatable {
    case pointerEnter
    case pointerLeave
    case pointerMotion
    case pointerButtonDown
    case pointerButtonUp
    case pointerAxis
    case keyDown
    case keyUp
    case keyboardEnter
    case keyboardLeave
}

/// One input event as the shell's Wayland client sees it. Codes are evdev
/// (`BTN_LEFT`, `KEY_ESC`); `text` is what xkb composed, which a keycode alone
/// cannot express.
public struct ShellInputEvent: Sendable, Equatable {
    public var kind: ShellInputEventKind
    /// The surface the event is for, so a multi-surface shell can route it.
    public var surface: UInt = 0
    public var x: Double = 0
    public var y: Double = 0
    public var scrollX: Double = 0
    public var scrollY: Double = 0
    /// What produced the scroll — `wl_pointer.axis_source`, carried through as
    /// the protocol's own value and mapped once at the framework boundary.
    public var scrollSource: UInt32 = 0
    /// Scroll in wheel detents from `axis_value120`, 120 units to a notch.
    public var scrollDetentsX: Double = 0
    public var scrollDetentsY: Double = 0
    /// `axis_stop`: the finger lifted.
    public var scrollEnded: Bool = false
    public var button: UInt32 = 0
    public var activeButtonCodes: Set<UInt32> = []
    public var keycode: UInt32 = 0
    public var modifiers: ShellModifierState = ShellModifierState()
    public var text: String?
    public var isRepeat: Bool = false
    public var timestampNanoseconds: UInt64 = 0

    public init(kind: ShellInputEventKind) {
        self.kind = kind
    }
}

public struct ShellModifierState: Sendable, Equatable {
    public var shift = false
    public var control = false
    public var alt = false
    public var logo = false
    public var capsLock = false

    public init() {}
}

public struct ShellDragAuthorization: Sendable, Equatable {
    public let serial: UInt32
    public let surface: UInt

    public init(serial: UInt32, surface: UInt) {
        precondition(serial != 0)
        precondition(surface != 0)
        self.serial = serial
        self.surface = surface
    }
}

@MainActor
public protocol ShellSeatDelegate: AnyObject {
    func seat(_ seat: ShellSeat, didProduce event: ShellInputEvent)
}

/// Binds the seat and its pointer/keyboard, compiles the keymap the compositor
/// sends, and reports events to a delegate.
@MainActor
public final class ShellSeat {
    public weak var delegate: (any ShellSeatDelegate)?

    /// Key repeat as the compositor advertises it over `wl_keyboard.repeat_info`.
    /// A client implements repeat itself; the protocol only states the rate.
    public private(set) var repeatRateHz: Int32 = 25
    public private(set) var repeatDelayMs: Int32 = 600

    private let seat: OpaquePointer
    private let client: ShellWaylandClient

    /// Borrowed seat proxy used to create seat-scoped protocol extensions.
    public var protocolSeat: OpaquePointer { seat }
    private var pointer: OpaquePointer?
    private var keyboard: OpaquePointer?
    // Retained for the proxies' lifetime: `addListener` borrows its owner.
    private var pointerListener: ShellPointerListener?
    private var keyboardListener: ShellKeyboardListener?

    private var xkbContext: OpaquePointer?
    private var xkbKeymap: OpaquePointer?
    private var xkbState: OpaquePointer?

    /// `wp_cursor_shape_device_v1` for this seat's pointer, when the compositor
    /// offers the protocol. Absent is normal: a compositor without it simply
    /// keeps whatever cursor it was already showing.
    private var cursorShapeDevice: OpaquePointer?
    /// The serial of the last `wl_pointer.enter`. `set_shape` must quote it —
    /// the compositor rejects a cursor request that does not name the enter that
    /// gave this client the pointer.
    private var pointerEnterSerial: UInt32 = 0
    private var currentCursor: ShellCursorShape = .default_

    private var modifiers = ShellModifierState()
    private var pointerSurface: UInt = 0
    private var keyboardSurface: UInt = 0
    private var lastPointerX: Double = 0
    private var lastPointerY: Double = 0
    private var pendingAxisSource: UInt32 = 0
    private var pressedPointerButtons: Set<UInt32> = []
    private var dragAuthorization: ShellDragAuthorization?

    /// The held key awaiting repeat, and when its next repeat is due.
    private var heldKeycode: UInt32?
    private var heldEvent: ShellInputEvent?
    private var nextRepeatNs: UInt64 = 0

    /// The cursor-shape manager, captured at bring-up. `nil` when the compositor
    /// does not offer the protocol, which the cursor path treats as "leave the
    /// cursor alone" rather than as an error.
    private let cursorShapeManager: OpaquePointer?

    public init?(client: ShellWaylandClient) {
        guard let seat = client.proxy(.seat) else { return nil }
        self.seat = seat
        self.client = client
        cursorShapeManager = client.proxy(.cursorShape)
        guard client.attachSeatConsumer(self) else { return nil }
        // Do not allocate native state until the unretained Wayland listener
        // owner has been accepted. A failed class initializer does not run this
        // type's deinit, so allocating first would leak the xkb context.
        xkbContext = xkb_context_new(XKB_CONTEXT_NO_FLAGS)
    }

    private func bindCursorShapeDevice(for pointer: OpaquePointer) {
        guard let manager = cursorShapeManager else { return }
        cursorShapeDevice = wp_cursor_shape_manager_v1_get_pointer(manager, pointer)
    }

    // `isolated deinit`: the xkb handles are @MainActor-confined state, so the
    // release runs on the actor that owns them rather than crossing an isolation
    // boundary with non-Sendable pointers.
    isolated deinit {
        client.detachSeatConsumer(self)
        if let cursorShapeDevice {
            wp_cursor_shape_device_v1_destroy(cursorShapeDevice)
        }
        if let pointer {
            wl_pointer_release(pointer)
        }
        if let keyboard {
            wl_keyboard_release(keyboard)
        }
        if let xkbState { xkb_state_unref(xkbState) }
        if let xkbKeymap { xkb_keymap_unref(xkbKeymap) }
        if let xkbContext { xkb_context_unref(xkbContext) }
    }

    // MARK: - Key repeat

    /// Whether a key is being held, so the host keeps scheduling wakeups.
    public var isRepeating: Bool { heldKeycode != nil }

    /// Nanoseconds until the next repeat is due, or `nil` when nothing is held.
    /// The host folds this into its poll timeout so repeats are not quantized to
    /// the frame rate.
    public func nanosecondsUntilNextRepeat(nowNs: UInt64) -> UInt64? {
        guard heldKeycode != nil else { return nil }
        return nowNs >= nextRepeatNs ? 0 : nextRepeatNs - nowNs
    }

    /// Emit any repeats now due.
    public func advanceKeyRepeat(nowNs: UInt64) {
        guard heldKeycode != nil, var event = heldEvent, nowNs >= nextRepeatNs else { return }
        guard repeatRateHz > 0 else { return }
        let intervalNs = UInt64(1_000_000_000 / Int64(repeatRateHz))
        var emitted = 0
        while nowNs >= nextRepeatNs, emitted < 8 {
            event.isRepeat = true
            event.timestampNanoseconds = nextRepeatNs
            delegate?.seat(self, didProduce: event)
            nextRepeatNs &+= intervalNs
            emitted += 1
        }
        if emitted == 8 {
            // Resynchronize rather than staying permanently behind after a stall.
            nextRepeatNs = nowNs &+ intervalNs
        }
    }

    private func beginRepeat(_ event: ShellInputEvent, keycode: UInt32, nowNs: UInt64) {
        guard repeatRateHz > 0, repeatDelayMs > 0 else { return }
        heldKeycode = keycode
        heldEvent = event
        nextRepeatNs = nowNs &+ UInt64(repeatDelayMs) &* 1_000_000
    }

    /// Stop any repeat outright — focus loss, or the keyboard going away.
    func cancelKeyRepeat() {
        heldKeycode = nil
        heldEvent = nil
    }

    private func endRepeat(keycode: UInt32) {
        // Only the held key's own release stops the repeat.
        if heldKeycode == keycode {
            heldKeycode = nil
            heldEvent = nil
        }
    }

    private func nowNanoseconds() -> UInt64 {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return UInt64(time.tv_sec) &* 1_000_000_000 &+ UInt64(time.tv_nsec)
    }

    // MARK: - Keymap

    func applyKeymap(format: UInt32, fd: Int32, size: UInt32) {
        defer { close(fd) }
        guard format == UInt32(WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1.rawValue) else { return }
        guard let mapped = nucleus_shell_map_keymap_fd(fd, size) else { return }
        defer { nucleus_shell_unmap_keymap(mapped, size) }
        guard let xkbContext else { return }

        guard let keymap = xkb_keymap_new_from_string(
            xkbContext, mapped, XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS)
        else { return }
        guard let state = xkb_state_new(keymap) else {
            xkb_keymap_unref(keymap)
            return
        }
        if let xkbState { xkb_state_unref(xkbState) }
        if let xkbKeymap { xkb_keymap_unref(xkbKeymap) }
        xkbKeymap = keymap
        xkbState = state
    }

    /// Composed text for a keycode, or nil when the key produces none.
    ///
    /// Control characters are rejected: Return must not insert U+000D into a
    /// text field, and Escape must not insert U+001B.
    func composedText(evdevKeycode: UInt32) -> String? {
        guard let xkbState else { return nil }
        let xkbKeycode = evdevKeycode + ShellSeat.evdevKeycodeOffset
        let size = xkb_state_key_get_utf8(xkbState, xkbKeycode, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        let written = buffer.withUnsafeMutableBufferPointer { pointer in
            xkb_state_key_get_utf8(xkbState, xkbKeycode, pointer.baseAddress, pointer.count)
        }
        guard written == size else { return nil }
        let bytes = buffer.prefix(Int(written)).map {
            UInt8(bitPattern: $0)
        }
        guard let text = String(validating: bytes, as: UTF8.self),
              !text.isEmpty
        else { return nil }
        guard let scalar = text.unicodeScalars.first,
              text.unicodeScalars.count > 1 || !(scalar.value < 0x20 || scalar.value == 0x7F)
        else { return nil }
        return text
    }

    /// XKB keycodes are evdev keycodes plus 8.
    static let evdevKeycodeOffset: UInt32 = 8

    func updateModifiers(
        depressed: UInt32, latched: UInt32, locked: UInt32, group: UInt32
    ) {
        guard let xkbState else { return }
        _ = xkb_state_update_mask(xkbState, depressed, latched, locked, 0, 0, group)
        modifiers.shift = isModifierActive(XKB_MOD_NAME_SHIFT)
        modifiers.control = isModifierActive(XKB_MOD_NAME_CTRL)
        modifiers.alt = isModifierActive(XKB_MOD_NAME_ALT)
        modifiers.logo = isModifierActive(XKB_MOD_NAME_LOGO)
        modifiers.capsLock = isModifierActive(XKB_MOD_NAME_CAPS)
    }

    private func isModifierActive(_ name: UnsafePointer<CChar>) -> Bool {
        guard let xkbState else { return false }
        return xkb_state_mod_name_is_active(xkbState, name, XKB_STATE_MODS_EFFECTIVE) > 0
    }

    func emit(_ event: ShellInputEvent) {
        delegate?.seat(self, didProduce: event)
    }

    func makeEvent(_ kind: ShellInputEventKind) -> ShellInputEvent {
        var event = ShellInputEvent(kind: kind)
        event.modifiers = modifiers
        event.timestampNanoseconds = nowNanoseconds()
        return event
    }

    func bindPointerIfNeeded(_ capabilities: UInt32) {
        let hasPointer = capabilities & UInt32(WL_SEAT_CAPABILITY_POINTER.rawValue) != 0
        if hasPointer, pointer == nil {
            pointer = wl_seat_get_pointer(seat)
            let listener = ShellPointerListener(seat: self)
            pointerListener = listener
            if let pointer {
                _ = WlPointerClient.addListener(pointer, owner: listener)
                bindCursorShapeDevice(for: pointer)
            }
        } else if !hasPointer, let existing = pointer {
            if let device = cursorShapeDevice {
                wp_cursor_shape_device_v1_destroy(device)
                cursorShapeDevice = nil
            }
            wl_pointer_release(existing)
            pointer = nil
            pointerListener = nil
            pointerEnterSerial = 0
        }
    }

    func bindKeyboardIfNeeded(_ capabilities: UInt32) {
        let hasKeyboard = capabilities & UInt32(WL_SEAT_CAPABILITY_KEYBOARD.rawValue) != 0
        if hasKeyboard, keyboard == nil {
            keyboard = wl_seat_get_keyboard(seat)
            let listener = ShellKeyboardListener(seat: self)
            keyboardListener = listener
            if let keyboard { _ = WlKeyboardClient.addListener(keyboard, owner: listener) }
        } else if !hasKeyboard, let existing = keyboard {
            wl_keyboard_release(existing)
            keyboard = nil
            keyboardListener = nil
            cancelKeyRepeat()
        }
    }

    /// Surfaces are identified by a scalar rather than the proxy itself: an
    /// `OpaquePointer` is non-Sendable, and the listener callbacks have to reduce
    /// it before hopping onto the actor anyway.
    func notePointerSurface(_ surfaceID: UInt) {
        pointerSurface = surfaceID
    }

    func notePointerEnterSerial(_ serial: UInt32) {
        pointerEnterSerial = serial
        // A fresh enter resets the compositor's idea of the cursor, so the shape
        // has to be re-asserted rather than assumed to have survived.
        let wanted = currentCursor
        currentCursor = .default_
        setCursor(wanted)
    }

    /// Ask the compositor for a cursor shape.
    ///
    /// Silently does nothing when the compositor does not offer
    /// `wp_cursor_shape_manager_v1`: a missing cursor is a cosmetic degradation,
    /// not a failure worth propagating to a widget that only wanted a hand
    /// pointer.
    public func setCursor(_ shape: ShellCursorShape) {
        guard shape != currentCursor else { return }
        currentCursor = shape
        guard let device = cursorShapeDevice, pointerEnterSerial != 0 else { return }
        wp_cursor_shape_device_v1_set_shape(device, pointerEnterSerial, shape.rawValue)
    }

    func noteKeyboardSurface(_ surfaceID: UInt) {
        keyboardSurface = surfaceID
    }

    var currentPointerSurface: UInt { pointerSurface }
    var currentKeyboardSurface: UInt { keyboardSurface }

    func notePointerPosition(x: Double, y: Double) {
        lastPointerX = x
        lastPointerY = y
    }

    var pointerPosition: (x: Double, y: Double) { (lastPointerX, lastPointerY) }

    func noteAxisSource(_ source: UInt32) {
        pendingAxisSource = source
    }

    var currentAxisSource: UInt32 { pendingAxisSource }
    var currentPointerButtons: Set<UInt32> { pressedPointerButtons }

    func notePointerButton(_ button: UInt32, pressed: Bool) {
        if pressed {
            pressedPointerButtons.insert(button)
        } else {
            pressedPointerButtons.remove(button)
            if pressedPointerButtons.isEmpty {
                dragAuthorization = nil
            }
        }
    }

    func noteDragAuthorization(serial: UInt32) {
        guard serial != 0, pointerSurface != 0 else { return }
        dragAuthorization = ShellDragAuthorization(
            serial: serial,
            surface: pointerSurface)
    }

    /// Consumes the pointer-down authority required by
    /// `wl_data_device.start_drag`. It is intentionally one-shot, matching the
    /// compositor's serial ledger.
    public func takeDragAuthorization(
        for surface: OpaquePointer
    ) -> ShellDragAuthorization? {
        guard !pressedPointerButtons.isEmpty,
              let authorization = dragAuthorization,
              authorization.surface == UInt(bitPattern: surface)
        else {
            return nil
        }
        dragAuthorization = nil
        return authorization
    }

    func clearPointerButtons() {
        pressedPointerButtons.removeAll(keepingCapacity: true)
        dragAuthorization = nil
    }

    /// Detents accumulate across `axis_value120` and are consumed by the `axis`
    /// event they belong to; the compositor sends both for one wheel movement.
    var pendingAxisDetents: (x: Double, y: Double) = (0, 0)

    func handleKey(keycode: UInt32, pressed: Bool) {
        var event = makeEvent(pressed ? .keyDown : .keyUp)
        event.surface = keyboardSurface
        event.keycode = keycode
        // Press only: a release commits nothing.
        event.text = pressed ? composedText(evdevKeycode: keycode) : nil
        emit(event)

        if pressed {
            if shouldRepeat(event) {
                beginRepeat(event, keycode: keycode, nowNs: nowNanoseconds())
            } else {
                heldKeycode = nil
                heldEvent = nil
            }
        } else {
            endRepeat(keycode: keycode)
        }
    }

    /// Whether holding this key repeats. Matches the overlay's rule: navigation
    /// and deletion do, action keys do not, and anything producing text does.
    private func shouldRepeat(_ event: ShellInputEvent) -> Bool {
        switch event.keycode {
        case 103, 105, 106, 108, 104, 109, 14, 111:  // arrows, page up/down, backspace, delete
            return true
        case 1, 28, 15, 96:  // escape, enter, tab, keypad enter
            return false
        default:
            return !(event.text ?? "").isEmpty
        }
    }

    func noteRepeatInfo(rate: Int32, delay: Int32) {
        repeatRateHz = rate
        repeatDelayMs = delay
        if rate == 0 {
            // A rate of zero disables repeat entirely, per the protocol.
            heldKeycode = nil
            heldEvent = nil
        }
    }
}

// The generated event dispatch is nonisolated (a @convention(c) libwayland
// callback); the shell pumps wl_display on its main-thread event loop, so each
// handler reasserts the main actor.
//
// Pointer and keyboard get their own listener owners rather than both hanging
// off `ShellSeat`: `wl_pointer.leave` and `wl_keyboard.leave` have identical
// Swift signatures, so one type cannot conform to both protocols. The seat owns
// these boxes for the proxies' lifetime, which is also what `addListener`'s
// unretained owner requires.
@MainActor
final class ShellPointerListener: WlPointerEvents {
    // Unowned: the seat owns this box, so it cannot outlive the seat.
    private unowned let seat: ShellSeat

    init(seat: ShellSeat) {
        self.seat = seat
    }

    nonisolated func enter(
        _ proxy: OpaquePointer, serial: UInt32, surface: OpaquePointer?,
        surface_x: Double, surface_y: Double
    ) {
        let surfaceID = surface.map { UInt(bitPattern: $0) } ?? 0
        MainActor.assumeIsolated {
            seat.notePointerSurface(surfaceID)
            seat.notePointerEnterSerial(serial)
            seat.notePointerPosition(x: surface_x, y: surface_y)
            var event = seat.makeEvent(.pointerEnter)
            event.surface = seat.currentPointerSurface
            event.x = surface_x
            event.y = surface_y
            event.activeButtonCodes = seat.currentPointerButtons
            seat.emit(event)
        }
    }

    nonisolated func leave(_ proxy: OpaquePointer, serial: UInt32, surface: OpaquePointer?) {
        // Reduced to a scalar identity before the actor hop: an OpaquePointer is
        // non-Sendable, and only its identity is wanted here.
        let surfaceID = surface.map { UInt(bitPattern: $0) } ?? 0
        MainActor.assumeIsolated {
            var event = seat.makeEvent(.pointerLeave)
            event.surface = surfaceID
            seat.emit(event)
            seat.clearPointerButtons()
            seat.notePointerSurface(0)
        }
    }

    nonisolated func motion(
        _ proxy: OpaquePointer, time: UInt32, surface_x: Double, surface_y: Double
    ) {
        MainActor.assumeIsolated {
            seat.notePointerPosition(x: surface_x, y: surface_y)
            var event = seat.makeEvent(.pointerMotion)
            event.surface = seat.currentPointerSurface
            event.x = surface_x
            event.y = surface_y
            event.activeButtonCodes = seat.currentPointerButtons
            seat.emit(event)
        }
    }

    nonisolated func button(
        _ proxy: OpaquePointer, serial: UInt32, time: UInt32, button: UInt32, state: UInt32
    ) {
        MainActor.assumeIsolated {
            let pressed = state == UInt32(WL_POINTER_BUTTON_STATE_PRESSED.rawValue)
            seat.notePointerButton(button, pressed: pressed)
            if pressed {
                seat.noteDragAuthorization(serial: serial)
            }
            var event = seat.makeEvent(pressed ? .pointerButtonDown : .pointerButtonUp)
            event.surface = seat.currentPointerSurface
            event.button = button
            event.x = seat.pointerPosition.x
            event.y = seat.pointerPosition.y
            event.activeButtonCodes = seat.currentPointerButtons
            seat.emit(event)
        }
    }

    nonisolated func axis(_ proxy: OpaquePointer, time: UInt32, axis: UInt32, value: Double) {
        MainActor.assumeIsolated {
            var event = seat.makeEvent(.pointerAxis)
            event.surface = seat.currentPointerSurface
            event.x = seat.pointerPosition.x
            event.y = seat.pointerPosition.y
            if axis == UInt32(WL_POINTER_AXIS_VERTICAL_SCROLL.rawValue) {
                event.scrollY = value
            } else {
                event.scrollX = value
            }
            event.scrollSource = seat.currentAxisSource
            event.scrollDetentsX = seat.pendingAxisDetents.x
            event.scrollDetentsY = seat.pendingAxisDetents.y
            seat.pendingAxisDetents = (0, 0)
            seat.emit(event)
        }
    }

    nonisolated func frame(_ proxy: OpaquePointer) {}

    nonisolated func axisSource(_ proxy: OpaquePointer, axis_source: UInt32) {
        MainActor.assumeIsolated {
            // A finger or continuous source scrolls smoothly; a wheel is detented.
            seat.noteAxisSource(axis_source)
        }
    }

    /// The finger lifted. There is no momentum phase to follow — the compositor
    /// does not synthesize inertia, so a view wanting kinetic scrolling starts
    /// it from here.
    nonisolated func axisStop(_ proxy: OpaquePointer, time: UInt32, axis: UInt32) {
        MainActor.assumeIsolated {
            var event = seat.makeEvent(.pointerAxis)
            event.surface = seat.currentPointerSurface
            event.x = seat.pointerPosition.x
            event.y = seat.pointerPosition.y
            event.scrollSource = seat.currentAxisSource
            event.scrollEnded = true
            seat.emit(event)
        }
    }

    /// Superseded by `axis_value120` since `wl_pointer` v8, and ignored here:
    /// a compositor sending both would otherwise have the notch counted twice.
    nonisolated func axisDiscrete(_ proxy: OpaquePointer, axis: UInt32, discrete: Int32) {}

    /// High-resolution wheel travel: 120 units to a detent. This is the only
    /// place a free-spinning wheel's sub-notch movement is reported.
    nonisolated func axisValue120(_ proxy: OpaquePointer, axis: UInt32, value120: Int32) {
        MainActor.assumeIsolated {
            let detents = Double(value120) / 120
            if axis == UInt32(WL_POINTER_AXIS_VERTICAL_SCROLL.rawValue) {
                seat.pendingAxisDetents.y = detents
            } else {
                seat.pendingAxisDetents.x = detents
            }
        }
    }
    nonisolated func axisRelativeDirection(
        _ proxy: OpaquePointer, axis: UInt32, direction: UInt32
    ) {}
}

@MainActor
final class ShellKeyboardListener: WlKeyboardEvents {
    private unowned let seat: ShellSeat

    init(seat: ShellSeat) {
        self.seat = seat
    }

    nonisolated func keymap(_ proxy: OpaquePointer, format: UInt32, fd: Int32, size: UInt32) {
        MainActor.assumeIsolated {
            seat.applyKeymap(format: format, fd: fd, size: size)
        }
    }

    nonisolated func enter(
        _ proxy: OpaquePointer, serial: UInt32, surface: OpaquePointer?,
        keys: UnsafeMutablePointer<wl_array>?
    ) {
        let surfaceID = surface.map { UInt(bitPattern: $0) } ?? 0
        MainActor.assumeIsolated {
            seat.noteKeyboardSurface(surfaceID)
            var event = seat.makeEvent(.keyboardEnter)
            event.surface = seat.currentKeyboardSurface
            seat.emit(event)
        }
    }

    nonisolated func leave(_ proxy: OpaquePointer, serial: UInt32, surface: OpaquePointer?) {
        let surfaceID = surface.map { UInt(bitPattern: $0) } ?? 0
        MainActor.assumeIsolated {
            var event = seat.makeEvent(.keyboardLeave)
            event.surface = surfaceID
            seat.emit(event)
            seat.noteKeyboardSurface(0)
            // Focus left, so nothing is held any more whatever the last state was.
            seat.cancelKeyRepeat()
        }
    }

    nonisolated func key(
        _ proxy: OpaquePointer, serial: UInt32, time: UInt32, key: UInt32, state: UInt32
    ) {
        MainActor.assumeIsolated {
            seat.handleKey(
                keycode: key,
                pressed: state == UInt32(WL_KEYBOARD_KEY_STATE_PRESSED.rawValue))
        }
    }

    nonisolated func modifiers(
        _ proxy: OpaquePointer, serial: UInt32, mods_depressed: UInt32,
        mods_latched: UInt32, mods_locked: UInt32, group: UInt32
    ) {
        MainActor.assumeIsolated {
            seat.updateModifiers(
                depressed: mods_depressed, latched: mods_latched,
                locked: mods_locked, group: group)
        }
    }

    nonisolated func repeatInfo(_ proxy: OpaquePointer, rate: Int32, delay: Int32) {
        MainActor.assumeIsolated {
            seat.noteRepeatInfo(rate: rate, delay: delay)
        }
    }
}
