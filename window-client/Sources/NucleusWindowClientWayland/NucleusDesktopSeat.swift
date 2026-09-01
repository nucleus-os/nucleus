// The desktop client's seat driver: binds wl_seat, pointer, and keyboard.
// and turns their callbacks into a neutral event record.
//
// The client mirror of the compositor's input host. Where the compositor reads
// libinput and *owns* the xkb state, a client is handed a compiled keymap over
// `wl_keyboard.keymap` and tracks modifier state from `wl_keyboard.modifiers`
// serials. Composition still happens here, because the compositor sends
// keycodes, never text.
//
// This target deliberately does not import NucleusUI. It resolves native
// evdev/Wayland values here and emits the process-neutral NucleusTypes record.

package import NucleusTypes
import NucleusWindowClientRuntime
import NucleusWindowClientXkbC
import WaylandClient
package import WaylandClientDispatch
import WaylandProtocolTypes
import WaylandProtocolsC

#if canImport(Glibc)
import Glibc
#endif

package struct NucleusDesktopDragAuthorization: Sendable, Equatable {
    package let serial: UInt32
    package let surface: UInt

    package init(serial: UInt32, surface: UInt) {
        precondition(serial != 0)
        precondition(surface != 0)
        self.serial = serial
        self.surface = surface
    }
}

@MainActor
package protocol NucleusDesktopSeatDelegate: AnyObject {
    func seat(_ seat: NucleusDesktopSeat, didProduce event: ApplicationInputEvent)
}

@MainActor
@safe private final class WindowClientXkbRuntime {
    @unsafe private let context: OpaquePointer
    @unsafe private var keymap: OpaquePointer?
    @unsafe private var state: OpaquePointer?

    init?() {
        guard let context = unsafe xkb_context_new(XKB_CONTEXT_NO_FLAGS)
        else { return nil }
        unsafe self.context = context
    }

    func applyKeymap(
        format: WlKeyboardKeymapFormat,
        fileDescriptor: Int32,
        size: UInt32
    ) {
        defer { close(fileDescriptor) }
        guard format == .xkbV1,
            let mapped = unsafe nucleus_shell_map_keymap_fd(
                fileDescriptor, size)
        else { return }
        defer { unsafe nucleus_shell_unmap_keymap(mapped, size) }
        guard
            let replacementKeymap = unsafe xkb_keymap_new_from_string(
                context,
                mapped,
                XKB_KEYMAP_FORMAT_TEXT_V1,
                XKB_KEYMAP_COMPILE_NO_FLAGS)
        else { return }
        guard let replacementState = unsafe xkb_state_new(replacementKeymap)
        else {
            unsafe xkb_keymap_unref(replacementKeymap)
            return
        }

        if let state = unsafe state {
            unsafe xkb_state_unref(state)
        }
        if let keymap = unsafe keymap {
            unsafe xkb_keymap_unref(keymap)
        }
        unsafe keymap = replacementKeymap
        unsafe state = replacementState
    }

    func composedText(xkbKeycode: UInt32) -> String? {
        guard let state = unsafe state else { return nil }
        let size = unsafe xkb_state_key_get_utf8(state, xkbKeycode, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        let written = buffer.withUnsafeMutableBufferPointer { pointer in
            unsafe xkb_state_key_get_utf8(
                state, xkbKeycode, pointer.baseAddress, pointer.count)
        }
        guard written == size else { return nil }
        let bytes = buffer.prefix(Int(written)).map {
            UInt8(bitPattern: $0)
        }
        guard let text = String(validating: bytes, as: UTF8.self),
            !text.isEmpty
        else { return nil }
        guard let scalar = text.unicodeScalars.first,
            text.unicodeScalars.count > 1
                || !(scalar.value < 0x20 || scalar.value == 0x7F)
        else { return nil }
        return text
    }

    func updateModifiers(
        depressed: UInt32,
        latched: UInt32,
        locked: UInt32,
        group: UInt32
    ) -> InputModifierFlags? {
        guard let state = unsafe state else { return nil }
        _ = unsafe xkb_state_update_mask(
            state, depressed, latched, locked, 0, 0, group)
        var modifiers: InputModifierFlags = []
        if unsafe isModifierActive(XKB_MOD_NAME_SHIFT, state: state) {
            modifiers.insert(.shift)
        }
        if unsafe isModifierActive(XKB_MOD_NAME_CTRL, state: state) {
            modifiers.insert(.control)
        }
        if unsafe isModifierActive(XKB_MOD_NAME_ALT, state: state) {
            modifiers.insert(.option)
        }
        if unsafe isModifierActive(XKB_MOD_NAME_LOGO, state: state) {
            modifiers.insert(.command)
        }
        if unsafe isModifierActive(XKB_MOD_NAME_CAPS, state: state) {
            modifiers.insert(.capsLock)
        }
        return modifiers
    }

    @unsafe
    private func isModifierActive(
        _ name: UnsafePointer<CChar>,
        state: OpaquePointer
    ) -> Bool {
        unsafe xkb_state_mod_name_is_active(
            state, name, XKB_STATE_MODS_EFFECTIVE) > 0
    }

    isolated deinit {
        if let state = unsafe state {
            unsafe xkb_state_unref(state)
        }
        if let keymap = unsafe keymap {
            unsafe xkb_keymap_unref(keymap)
        }
        unsafe xkb_context_unref(context)
    }
}

/// Binds the seat and its pointer/keyboard, compiles the keymap the compositor
/// sends, and reports events to a delegate.
@MainActor
@safe public final class NucleusDesktopSeat {
    package weak var delegate: (any NucleusDesktopSeatDelegate)?

    /// Key repeat as the compositor advertises it over `wl_keyboard.repeat_info`.
    /// A client implements repeat itself; the protocol only states the rate.
    package private(set) var repeatRateHz: Int32 = 25
    package private(set) var repeatDelayMs: Int32 = 600

    private let seat: WaylandProxy<WlSeatClient>
    private let client: NucleusDesktopConnection

    /// Borrowed seat proxy used to create seat-scoped protocol extensions.
    package var protocolSeat: WaylandProxy<WlSeatClient> { seat }
    private var pointer: WaylandProxy<WlPointerClient>?
    private var keyboard: WaylandProxy<WlKeyboardClient>?
    // Retained for the proxies' lifetime: `addListener` borrows its owner.
    private var pointerListener: WindowClientPointerListener?
    private var keyboardListener: WindowClientKeyboardListener?

    private let xkb: WindowClientXkbRuntime?

    /// `wp_cursor_shape_device_v1` for this seat's pointer, when the compositor
    /// offers the protocol. Absent is normal: a compositor without it simply
    /// keeps whatever cursor it was already showing.
    private var cursorShapeDevice: WaylandProxy<WpCursorShapeDeviceV1Client>?
    /// The serial of the last `wl_pointer.enter`. `set_shape` must quote it —
    /// the compositor rejects a cursor request that does not name the enter that
    /// gave this client the pointer.
    private var pointerEnterSerial: UInt32 = 0
    private var currentCursor: NucleusDesktopCursorShape = .default_

    private var modifiers: InputModifierFlags = []
    private var pointerSurface: UInt = 0
    private var keyboardSurface: UInt = 0
    private var lastPointerX: Double = 0
    private var lastPointerY: Double = 0
    private var pendingAxisSource: UInt32 = 0
    private var pressedPointerButtons: Set<UInt32> = []
    private var dragAuthorization: NucleusDesktopDragAuthorization?

    /// The held key awaiting repeat, and when its next repeat is due.
    private var heldKeycode: UInt32?
    private var heldEvent: ApplicationInputEvent?
    private var nextRepeatNs: UInt64 = 0

    /// The cursor-shape manager, captured at bring-up. `nil` when the compositor
    /// does not offer the protocol, which the cursor path treats as "leave the
    /// cursor alone" rather than as an error.
    private let cursorShapeManager: WaylandProxy<WpCursorShapeManagerV1Client>?

    package init?(client: NucleusDesktopConnection) {
        guard let seat = client.seat else { return nil }
        self.seat = seat
        self.client = client
        cursorShapeManager = client.cursorShape
        xkb = WindowClientXkbRuntime()
        guard client.attachSeatConsumer(self) else { return nil }
    }

    private func bindCursorShapeDevice(
        for pointer: WaylandProxy<WlPointerClient>
    ) {
        guard let manager = cursorShapeManager else { return }
        cursorShapeDevice = try? manager.getPointer(pointer: pointer)
    }

    // `isolated deinit`: the xkb handles are @MainActor-confined state, so the
    // release runs on the actor that owns them rather than crossing an isolation
    // boundary with non-Sendable pointers.
    isolated deinit {
        client.detachSeatConsumer(self)
        try? cursorShapeDevice?.destroy()
        try? pointer?.release()
        try? keyboard?.release()
    }

    // MARK: - Key repeat

    /// Whether a key is being held, so the host keeps scheduling wakeups.
    package var isRepeating: Bool { heldKeycode != nil }

    /// Nanoseconds until the next repeat is due, or `nil` when nothing is held.
    /// The host folds this into its poll timeout so repeats are not quantized to
    /// the frame rate.
    package func nanosecondsUntilNextRepeat(nowNs: UInt64) -> UInt64? {
        guard heldKeycode != nil else { return nil }
        return nowNs >= nextRepeatNs ? 0 : nextRepeatNs - nowNs
    }

    /// Emit any repeats now due.
    package func advanceKeyRepeat(nowNs: UInt64) {
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

    private func beginRepeat(
        _ event: ApplicationInputEvent,
        keycode: UInt32,
        nowNs: UInt64
    ) {
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
        NucleusWindowClientMonotonicClock.nowNanoseconds()
    }

    // MARK: - Keymap

    func applyKeymap(
        format: WlKeyboardKeymapFormat,
        fd: Int32,
        size: UInt32
    ) {
        guard let xkb else {
            close(fd)
            return
        }
        xkb.applyKeymap(
            format: format,
            fileDescriptor: fd,
            size: size)
    }

    /// Composed text for a keycode, or nil when the key produces none.
    ///
    /// Control characters are rejected: Return must not insert U+000D into a
    /// text field, and Escape must not insert U+001B.
    func composedText(evdevKeycode: UInt32) -> String? {
        let xkbKeycode = evdevKeycode + NucleusDesktopSeat.evdevKeycodeOffset
        return xkb?.composedText(xkbKeycode: xkbKeycode)
    }

    /// XKB keycodes are evdev keycodes plus 8.
    static let evdevKeycodeOffset: UInt32 = 8

    func updateModifiers(
        depressed: UInt32, latched: UInt32, locked: UInt32, group: UInt32
    ) {
        guard
            let updated = xkb?.updateModifiers(
                depressed: depressed,
                latched: latched,
                locked: locked,
                group: group)
        else { return }
        modifiers = updated
    }

    func emit(_ event: ApplicationInputEvent) {
        delegate?.seat(self, didProduce: event)
    }

    func makeEvent(_ kind: InputEventKind) -> ApplicationInputEvent {
        ApplicationInputEvent(
            kind: kind,
            timestampNanoseconds: nowNanoseconds(),
            modifiers: modifiers)
    }

    func bindPointerIfNeeded(_ capabilities: WlSeatCapability) {
        let hasPointer = capabilities.contains(.pointer)
        let pointerIsNil = pointer == nil
        if hasPointer, pointerIsNil {
            pointer = try? seat.getPointer()
            let listener = WindowClientPointerListener(seat: self)
            pointerListener = listener
            if let pointer {
                try? pointer.installListener(listener)
                bindCursorShapeDevice(for: pointer)
            }
        } else if !hasPointer, let existing = pointer {
            if let device = cursorShapeDevice {
                try? device.destroy()
                cursorShapeDevice = nil
            }
            try? existing.release()
            pointer = nil
            pointerListener = nil
            pointerEnterSerial = 0
        }
    }

    func bindKeyboardIfNeeded(_ capabilities: WlSeatCapability) {
        let hasKeyboard = capabilities.contains(.keyboard)
        let keyboardIsNil = keyboard == nil
        if hasKeyboard, keyboardIsNil {
            keyboard = try? seat.getKeyboard()
            let listener = WindowClientKeyboardListener(seat: self)
            keyboardListener = listener
            if let keyboard {
                try? keyboard.installListener(listener)
            }
        } else if !hasKeyboard, let existing = keyboard {
            try? existing.release()
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
    package func setCursor(_ shape: NucleusDesktopCursorShape) {
        guard shape != currentCursor else { return }
        currentCursor = shape
        guard let device = cursorShapeDevice,
            pointerEnterSerial != 0
        else { return }
        try? device.setShape(
            serial: pointerEnterSerial,
            shape: WpCursorShapeDeviceV1Shape(
                rawValue: shape.rawValue))
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
        dragAuthorization = NucleusDesktopDragAuthorization(
            serial: serial,
            surface: pointerSurface)
    }

    /// Consumes the pointer-down authority required by
    /// `wl_data_device.start_drag`. It is intentionally one-shot, matching the
    /// compositor's serial ledger.
    package func takeDragAuthorization(
        for surface: WaylandProxy<WlSurfaceClient>
    ) -> NucleusDesktopDragAuthorization? {
        guard !pressedPointerButtons.isEmpty,
            let authorization = dragAuthorization,
            authorization.surface == surface.identity
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
        event.surfaceID = surfaceID(keyboardSurface)
        event.key = PhysicalKey(linuxEvdevCode: keycode)
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
    private func shouldRepeat(_ event: ApplicationInputEvent) -> Bool {
        switch event.key {
        case .upArrow, .leftArrow, .rightArrow, .downArrow,
            .pageUp, .pageDown, .delete, .forwardDelete:
            return true
        case .escape, .return, .tab:
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

    fileprivate func surfaceID(_ rawValue: UInt) -> SurfaceID? {
        rawValue == 0 ? nil : SurfaceID(rawValue: UInt64(rawValue))
    }

    fileprivate func pointerButton(_ evdevCode: UInt32) -> PointerButtonCode {
        switch evdevCode {
        case 272: .left
        case 273: .right
        case 274: .middle
        case 275: .back
        case 276: .forward
        default: PointerButtonCode(rawValue: evdevCode)
        }
    }

    fileprivate func pointerButtons(_ evdevCodes: Set<UInt32>) -> PointerButtonSet {
        evdevCodes.reduce(into: PointerButtonSet()) {
            $0.formUnion(.button(pointerButton($1)))
        }
    }

    fileprivate func scrollSource(_ waylandValue: UInt32) -> InputScrollSource {
        switch waylandValue {
        case 0: .wheel
        case 1: .finger
        case 2: .continuous
        case 3: .wheelTilt
        default: .unknown
        }
    }
}

// Pointer and keyboard get their own listener owners rather than both hanging
// off `NucleusDesktopSeat`: `wl_pointer.leave` and `wl_keyboard.leave` have identical
// Swift signatures, so one type cannot conform to both protocols. The seat owns
// these boxes for the proxies' lifetime.
@MainActor
final class WindowClientPointerListener: WlPointerEvents {
    // Unowned: the seat owns this box, so it cannot outlive the seat.
    private unowned let seat: NucleusDesktopSeat

    init(seat: NucleusDesktopSeat) {
        self.seat = seat
    }

    func enter(
        _ proxy: WaylandBorrowedProxy<WlPointerClient>, serial: UInt32,
        surface: WaylandBorrowedProxy<WlSurfaceClient>,
        surface_x: Double, surface_y: Double
    ) {
        seat.notePointerSurface(surface.identity)
        seat.notePointerEnterSerial(serial)
        seat.notePointerPosition(x: surface_x, y: surface_y)
        var event = seat.makeEvent(.pointerEnter)
        event.surfaceID = seat.surfaceID(seat.currentPointerSurface)
        event.location = Point(x: surface_x, y: surface_y)
        event.activeButtons = seat.pointerButtons(seat.currentPointerButtons)
        event.pointerTool = .mouse
        seat.emit(event)
    }

    func leave(
        _ proxy: WaylandBorrowedProxy<WlPointerClient>, serial: UInt32,
        surface: WaylandBorrowedProxy<WlSurfaceClient>
    ) {
        var event = seat.makeEvent(.pointerLeave)
        event.surfaceID = seat.surfaceID(surface.identity)
        seat.emit(event)
        seat.clearPointerButtons()
        seat.notePointerSurface(0)
    }

    func motion(
        _ proxy: WaylandBorrowedProxy<WlPointerClient>, time: UInt32, surface_x: Double,
        surface_y: Double
    ) {
        seat.notePointerPosition(x: surface_x, y: surface_y)
        var event = seat.makeEvent(.pointerMotion)
        event.surfaceID = seat.surfaceID(seat.currentPointerSurface)
        event.location = Point(x: surface_x, y: surface_y)
        event.activeButtons = seat.pointerButtons(seat.currentPointerButtons)
        event.pointerTool = .mouse
        seat.emit(event)
    }

    /// The pointer's surface-local position changed without the device moving.
    ///
    /// The compositor sends this when the surface under the pointer moved, or
    /// when it repositioned the pointer itself -- leaving pointer confinement,
    /// for instance. It carries no timestamp, and the protocol forbids it in
    /// the same frame as an enter or a motion, because it is not input.
    ///
    /// So it records the position and emits nothing. A button or axis event
    /// arriving afterwards reads this cached location, which is what has to be
    /// current; synthesizing a motion here would report travel the user never
    /// made, and anything measuring drag distance would believe it.
    func warp(
        _ proxy: WaylandBorrowedProxy<WlPointerClient>, surface_x: Double,
        surface_y: Double
    ) {
        seat.notePointerPosition(x: surface_x, y: surface_y)
    }

    func button(
        _ proxy: WaylandBorrowedProxy<WlPointerClient>, serial: UInt32,
        time: UInt32, button: UInt32, state: WlPointerButtonState
    ) {
        let pressed = state == .pressed
        seat.notePointerButton(button, pressed: pressed)
        if pressed {
            seat.noteDragAuthorization(serial: serial)
        }
        var event = seat.makeEvent(
            pressed ? .pointerButtonDown : .pointerButtonUp)
        event.surfaceID = seat.surfaceID(seat.currentPointerSurface)
        event.button = seat.pointerButton(button)
        event.location = Point(
            x: seat.pointerPosition.x,
            y: seat.pointerPosition.y)
        event.activeButtons = seat.pointerButtons(seat.currentPointerButtons)
        event.pointerTool = .mouse
        seat.emit(event)
    }

    func axis(
        _ proxy: WaylandBorrowedProxy<WlPointerClient>, time: UInt32,
        axis: WlPointerAxis, value: Double
    ) {
        var event = seat.makeEvent(.pointerAxis)
        event.surfaceID = seat.surfaceID(seat.currentPointerSurface)
        event.location = Point(
            x: seat.pointerPosition.x,
            y: seat.pointerPosition.y)
        if axis == .verticalScroll {
            event.scrollY = value
        } else {
            event.scrollX = value
        }
        event.scrollPhase = .changed
        event.scrollSource = seat.scrollSource(seat.currentAxisSource)
        event.scrollDetentsX = seat.pendingAxisDetents.x
        event.scrollDetentsY = seat.pendingAxisDetents.y
        seat.pendingAxisDetents = (0, 0)
        seat.emit(event)
    }

    func frame(_ proxy: WaylandBorrowedProxy<WlPointerClient>) {}

    func axisSource(
        _ proxy: WaylandBorrowedProxy<WlPointerClient>,
        axis_source: WlPointerAxisSource
    ) {
        // A finger or continuous source scrolls smoothly; a wheel is detented.
        seat.noteAxisSource(axis_source.rawValue)
    }

    /// The finger lifted. There is no momentum phase to follow — the compositor
    /// does not synthesize inertia, so a view wanting kinetic scrolling starts
    /// it from here.
    func axisStop(
        _ proxy: WaylandBorrowedProxy<WlPointerClient>, time: UInt32,
        axis: WlPointerAxis
    ) {
        var event = seat.makeEvent(.pointerAxis)
        event.surfaceID = seat.surfaceID(seat.currentPointerSurface)
        event.location = Point(
            x: seat.pointerPosition.x,
            y: seat.pointerPosition.y)
        event.scrollSource = seat.scrollSource(seat.currentAxisSource)
        event.scrollPhase = .ended
        seat.emit(event)
    }

    /// Superseded by `axis_value120` since `wl_pointer` v8, and ignored here:
    /// a compositor sending both would otherwise have the notch counted twice.
    func axisDiscrete(
        _ proxy: WaylandBorrowedProxy<WlPointerClient>,
        axis: WlPointerAxis, discrete: Int32
    ) {}

    /// High-resolution wheel travel: 120 units to a detent. This is the only
    /// place a free-spinning wheel's sub-notch movement is reported.
    func axisValue120(
        _ proxy: WaylandBorrowedProxy<WlPointerClient>,
        axis: WlPointerAxis, value120: Int32
    ) {
        let detents = Double(value120) / 120
        if axis == .verticalScroll {
            seat.pendingAxisDetents.y = detents
        } else {
            seat.pendingAxisDetents.x = detents
        }
    }
    func axisRelativeDirection(
        _ proxy: WaylandBorrowedProxy<WlPointerClient>,
        axis: WlPointerAxis,
        direction: WlPointerAxisRelativeDirection
    ) {}
}

@MainActor
final class WindowClientKeyboardListener: WlKeyboardEvents {
    private unowned let seat: NucleusDesktopSeat

    init(seat: NucleusDesktopSeat) {
        self.seat = seat
    }

    func keymap(
        _ proxy: WaylandBorrowedProxy<WlKeyboardClient>,
        format: WlKeyboardKeymapFormat,
        fd: consuming WaylandClientOwnedFileDescriptor,
        size: UInt32
    ) {
        let descriptor = fd.take()
        seat.applyKeymap(
            format: format, fd: descriptor, size: size)
    }

    func enter(
        _ proxy: WaylandBorrowedProxy<WlKeyboardClient>, serial: UInt32,
        surface: WaylandBorrowedProxy<WlSurfaceClient>,
        keys: WaylandClientArrayView
    ) {
        seat.noteKeyboardSurface(surface.identity)
        var event = seat.makeEvent(.keyboardEnter)
        event.surfaceID = seat.surfaceID(seat.currentKeyboardSurface)
        seat.emit(event)
    }

    func leave(
        _ proxy: WaylandBorrowedProxy<WlKeyboardClient>, serial: UInt32,
        surface: WaylandBorrowedProxy<WlSurfaceClient>
    ) {
        var event = seat.makeEvent(.keyboardLeave)
        event.surfaceID = seat.surfaceID(surface.identity)
        seat.emit(event)
        seat.noteKeyboardSurface(0)
        // Focus left, so nothing is held any more whatever the last state was.
        seat.cancelKeyRepeat()
    }

    func key(
        _ proxy: WaylandBorrowedProxy<WlKeyboardClient>, serial: UInt32,
        time: UInt32, key: UInt32, state: WlKeyboardKeyState
    ) {
        seat.handleKey(
            keycode: key,
            pressed: state == .pressed)
    }

    func modifiers(
        _ proxy: WaylandBorrowedProxy<WlKeyboardClient>, serial: UInt32, mods_depressed: UInt32,
        mods_latched: UInt32, mods_locked: UInt32, group: UInt32
    ) {
        seat.updateModifiers(
            depressed: mods_depressed, latched: mods_latched,
            locked: mods_locked, group: group)
    }

    func repeatInfo(_ proxy: WaylandBorrowedProxy<WlKeyboardClient>, rate: Int32, delay: Int32) {
        seat.noteRepeatInfo(rate: rate, delay: delay)
    }
}
