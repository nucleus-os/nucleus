// XkbKeyboard — the compositor's libxkbcommon context, keymap, and keyboard state,
// plus the sealed keymap memfd shared with Wayland clients. Swift owns keyboard
// compilation and state directly (Rule 7).
//
// The compositor runs single-threaded on the main actor; this type is only touched
// from there. It holds raw xkb pointers and an owned fd, so it is a reference type
// with explicit teardown rather than a value.

import Glibc
import NucleusCompositorInputC
import NucleusLinuxPrimitives

/// CGEventFlags-shaped modifier bit positions: the raw `UInt64` the event records
/// and dispatch policy read.
enum EventFlagBit {
    static let alphaShift: UInt64 = 1 << 16
    static let shift: UInt64 = 1 << 17
    static let control: UInt64 = 1 << 18
    static let alternate: UInt64 = 1 << 19
    static let command: UInt64 = 1 << 20
    static let numericPad: UInt64 = 1 << 21
}

/// The five xkbcommon rule fields.
///
/// Each is independently optional: an empty field becomes NULL so xkbcommon
/// resolves that one from its own defaults, rather than forcing a user who wants
/// a layout to also name a model and a rule set.
struct XkbRules: Equatable, Sendable {
    var rules = ""
    var model = ""
    var layout = ""
    var variant = ""
    var options = ""

    var isEmpty: Bool {
        rules.isEmpty && model.isEmpty && layout.isEmpty
            && variant.isEmpty && options.isEmpty
    }

    /// Borrow the fields as a C rule-names struct. The pointers are valid only
    /// for the duration of `body`, which is why xkb compilation happens inside.
    func withNativeNames<R>(
        _ body: (xkb_rule_names) throws -> R
    ) rethrows -> R {
        try unsafe withOptionalCString(rules) { rules in
            try unsafe withOptionalCString(model) { model in
                try unsafe withOptionalCString(layout) { layout in
                    try unsafe withOptionalCString(variant) { variant in
                        try unsafe withOptionalCString(options) { options in
                            try unsafe body(
                                xkb_rule_names(
                                    rules: rules,
                                    model: model,
                                    layout: layout,
                                    variant: variant,
                                    options: options))
                        }
                    }
                }
            }
        }
    }
}

private func withOptionalCString<R>(
    _ value: String,
    _ body: (UnsafePointer<CChar>?) throws -> R
) rethrows -> R {
    guard !value.isEmpty else { return try body(nil) }
    return try value.withCString(body)
}

@MainActor
@safe final class XkbKeyboard {
    /// XKB keycodes are evdev keycodes plus 8. Named rather than spelled `+ 8`
    /// at each call site, because getting it wrong silently yields the wrong
    /// character rather than an error.
    static let evdevKeycodeOffset: UInt32 = 8

    private let context: OpaquePointer
    private var keymap: OpaquePointer
    private var state: OpaquePointer

    /// Sealed keymap shared with clients via wl_keyboard.keymap; owned here.
    private var keymapFile: LinuxSealedFile?

    /// Bitset of currently-pressed evdev keycodes < 128, for physical-modifier
    /// detection independent of the xkb logical state.
    private var pressedKeysLow: UInt128 = 0

    // xkbcommon modifier names (the documented canonical strings).
    private static let modShift = "Shift"
    private static let modCaps = "Lock"
    private static let modCtrl = "Control"
    private static let modAlt = "Mod1"
    private static let modNum = "Mod2"
    private static let modLogo = "Mod4"

    /// Compile a keymap from an explicit rule set.
    ///
    /// Every field is optional independently: an empty string is passed as NULL
    /// so xkbcommon falls back to its own default for that field alone, which
    /// is what makes `{"layout": "us,de"}` work without also naming a model and
    /// a rule set. Passing no rules at all reproduces the previous behavior,
    /// where only `XKB_DEFAULT_*` in the environment had any effect.
    convenience init?() {
        self.init(rules: XkbRules())
    }

    init?(rules: XkbRules) {
        guard let ctx = unsafe xkb_context_new(XKB_CONTEXT_NO_FLAGS) else { return nil }
        guard
            let km = unsafe rules.withNativeNames({ names in
                withUnsafePointer(to: names) { pointer in
                    unsafe xkb_keymap_new_from_names(
                        ctx, rules.isEmpty ? nil : pointer,
                        XKB_KEYMAP_COMPILE_NO_FLAGS)
                }
            })
        else {
            unsafe xkb_context_unref(ctx)
            return nil
        }
        guard let st = unsafe xkb_state_new(km) else {
            unsafe xkb_keymap_unref(km)
            unsafe xkb_context_unref(ctx)
            return nil
        }
        unsafe self.context = ctx
        unsafe self.keymap = km
        unsafe self.state = st
        buildKeymapMemfd()
    }

    isolated deinit {
        unsafe xkb_state_unref(state)
        unsafe xkb_keymap_unref(keymap)
        unsafe xkb_context_unref(context)
    }

    /// Compile the keymap to its text form and publish it through a sealed memfd
    /// (the wl_keyboard.keymap contract). Best-effort: a missing string leaves the
    /// fd at -1 and clients simply do not receive a keymap.
    private func buildKeymapMemfd() {
        guard
            let cstr = unsafe xkb_keymap_get_as_string(
                keymap, XKB_KEYMAP_FORMAT_TEXT_V1)
        else { return }
        defer { unsafe free(cstr) }
        let byteCount = unsafe strlen(cstr) + 1
        let bytes = unsafe Array(
            UnsafeRawBufferPointer(start: cstr, count: byteCount))
        keymapFile = try? LinuxSealedFile(
            name: "nucleus-keymap",
            bytes: bytes)
    }

    var keymapSize: UInt32 {
        guard let size = keymapFile?.size,
            let result = UInt32(exactly: size)
        else { return 0 }
        return result
    }

    func duplicateKeymapDescriptor() -> LinuxOwnedFileDescriptor? {
        keymapFile?.duplicateDescriptor()
    }

    /// Adopt the XKB_V1 map supplied by a trusted virtual keyboard. A Wayland
    /// client receives this exact map from the seat after installation, so key
    /// codes and modifier masks cannot diverge across the injection boundary.
    func installKeymap(descriptor: Int32, size: UInt32) -> Bool {
        let maximumKeymapSize = 16 * 1024 * 1024
        guard descriptor >= 0, size > 0, size <= maximumKeymapSize else { return false }
        var bytes = [UInt8](repeating: 0, count: Int(size))
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes { buffer in
                unsafe pread(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    buffer.count - offset,
                    off_t(offset))
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return false }
            offset += count
        }
        guard bytes.last == 0 else { return false }
        let newKeymap = bytes.withUnsafeBytes { buffer in
            unsafe xkb_keymap_new_from_string(
                context,
                buffer.baseAddress?.assumingMemoryBound(to: CChar.self),
                XKB_KEYMAP_FORMAT_TEXT_V1,
                XKB_KEYMAP_COMPILE_NO_FLAGS)
        }
        guard let newKeymap = unsafe newKeymap,
            let newState = unsafe xkb_state_new(newKeymap)
        else {
            if let newKeymap = unsafe newKeymap {
                unsafe xkb_keymap_unref(newKeymap)
            }
            return false
        }
        let oldState = unsafe state
        let oldKeymap = unsafe keymap
        unsafe state = newState
        unsafe keymap = newKeymap
        pressedKeysLow = 0
        keymapFile = nil
        buildKeymapMemfd()
        unsafe xkb_state_unref(oldState)
        unsafe xkb_keymap_unref(oldKeymap)
        return true
    }

    // MARK: - state advancement

    /// Apply a physical key transition. `seatKeyCount` (libinput's per-seat count
    /// after the event) gates xkb updates to genuine first-press/last-release
    /// transitions so a key held on two devices does not double-toggle.
    func updateKey(evdevKeycode: UInt32, pressed: Bool, seatKeyCount: UInt32?) {
        if let count = seatKeyCount {
            if pressed && count != 1 { return }
            if !pressed && count != 0 { return }
        }
        if evdevKeycode < 128 {
            let mask: UInt128 = 1 << UInt128(evdevKeycode)
            if pressed { pressedKeysLow |= mask } else { pressedKeysLow &= ~mask }
        }
        // xkb keycodes are evdev + 8.
        _ = unsafe xkb_state_update_key(
            state, evdevKeycode + Self.evdevKeycodeOffset, pressed ? XKB_KEY_DOWN : XKB_KEY_UP)
    }

    func updateMask(depressed: UInt32, latched: UInt32, locked: UInt32, group: UInt32) {
        _ = unsafe xkb_state_update_mask(
            state, depressed, latched, locked, 0, 0, group)
    }

    func resetPressedKeys() { pressedKeysLow = 0 }

    /// The evdev keycodes currently held down (codes < 128, from the press bitmask),
    /// for wl_keyboard.enter's key array.
    func pressedEvdevKeys() -> [UInt32] {
        var out: [UInt32] = []
        var bits = pressedKeysLow
        while bits != 0 {
            out.append(UInt32(bits.trailingZeroBitCount))
            bits &= bits - 1  // clear the lowest set bit
        }
        return out
    }

    // MARK: - serialized views

    /// The CGEventFlags-shaped modifier mask reflecting the current xkb logical
    /// state — what every event record carries in its `flags` field.
    func flagsRaw() -> UInt64 {
        var raw: UInt64 = 0
        if modActive(Self.modCaps, locked: true) { raw |= EventFlagBit.alphaShift }
        if modActive(Self.modShift, locked: false) { raw |= EventFlagBit.shift }
        if modActive(Self.modCtrl, locked: false) { raw |= EventFlagBit.control }
        if modActive(Self.modAlt, locked: false) { raw |= EventFlagBit.alternate }
        if modActive(Self.modLogo, locked: false) { raw |= EventFlagBit.command }
        if modActive(Self.modNum, locked: false) { raw |= EventFlagBit.numericPad }
        return raw
    }

    /// Modifier mask derived purely from the physically-held modifier keys, used to
    /// cross-check the logical state in diagnostics.
    func physicalFlagsRaw() -> UInt64 {
        var raw: UInt64 = 0
        if isPressed(42) || isPressed(54) { raw |= EventFlagBit.shift }
        if isPressed(29) || isPressed(97) { raw |= EventFlagBit.control }
        if isPressed(56) || isPressed(100) { raw |= EventFlagBit.alternate }
        if isPressed(125) || isPressed(126) { raw |= EventFlagBit.command }
        return raw
    }

    struct SerializedModifiers {
        var depressed: UInt32 = 0
        var latched: UInt32 = 0
        var locked: UInt32 = 0
        var group: UInt32 = 0
    }

    func serializedModifiers() -> SerializedModifiers {
        unsafe SerializedModifiers(
            depressed: xkb_state_serialize_mods(state, XKB_STATE_MODS_DEPRESSED),
            latched: xkb_state_serialize_mods(state, XKB_STATE_MODS_LATCHED),
            locked: xkb_state_serialize_mods(state, XKB_STATE_MODS_LOCKED),
            group: xkb_state_serialize_layout(state, XKB_STATE_LAYOUT_DEPRESSED))
    }

    struct ModifierMasks {
        var shift: UInt32 = 0
        var control: UInt32 = 0
        var alternate: UInt32 = 0
        var command: UInt32 = 0
    }

    func modifierMasks() -> ModifierMasks {
        ModifierMasks(
            shift: modMask(Self.modShift),
            control: modMask(Self.modCtrl),
            alternate: modMask(Self.modAlt),
            command: modMask(Self.modLogo))
    }

    func keyGetOneSym(xkbKeycode: UInt32) -> UInt32 {
        unsafe xkb_state_key_get_one_sym(state, xkbKeycode)
    }

    /// The composed UTF-8 text this key produces in the current layout and
    /// modifier state, or nil if it produces none (a modifier, an arrow key).
    ///
    /// This is what `Event.characters` carries. A keysym cannot stand in for
    /// it: the same physical key yields different text under a different
    /// layout, and dead-key sequences produce text on a *later* press than the
    /// one that started them.
    func keyGetText(xkbKeycode: UInt32) -> String? {
        // Ask for the size first; xkb writes a NUL-terminated string and
        // returns the length excluding it.
        let needed = unsafe xkb_state_key_get_utf8(
            state, xkbKeycode, nil, 0)
        guard needed > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(needed) + 1)
        _ = buffer.withUnsafeMutableBufferPointer { out in
            unsafe xkb_state_key_get_utf8(
                state, xkbKeycode, out.baseAddress, out.count)
        }
        let text = String(
            decoding: buffer.prefix(Int(needed)).map { UInt8(bitPattern: $0) },
            as: UTF8.self)
        // Control characters are key *actions*, not text: Return, Escape, and
        // Backspace all produce one, and inserting it would put a control
        // character into a text field.
        guard let scalar = text.unicodeScalars.first,
            text.unicodeScalars.count > 1 || !(scalar.value < 0x20 || scalar.value == 0x7F)
        else { return nil }
        return text
    }

    // MARK: - helpers

    private func modActive(_ name: String, locked: Bool) -> Bool {
        let component = locked ? XKB_STATE_MODS_LOCKED : XKB_STATE_MODS_DEPRESSED
        return unsafe xkb_state_mod_name_is_active(state, name, component) > 0
    }

    private func modMask(_ name: String) -> UInt32 {
        let index = unsafe xkb_keymap_mod_get_index(keymap, name)
        if index == XKB_MOD_INVALID { return 0 }
        return UInt32(1) << index
    }

    private func isPressed(_ evdevKeycode: UInt32) -> Bool {
        guard evdevKeycode < 128 else { return false }
        return (pressedKeysLow & (1 << UInt128(evdevKeycode))) != 0
    }
}
