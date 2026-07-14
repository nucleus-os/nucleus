// InputClientPolicy — focused-client keyboard policy. Global session shortcuts run earlier in
// the shortcut tap; this layer owns only the client-facing translation that happens
// after a shortcut is allowed through: macOS-shaped Command chords become Linux
// Ctrl chords for clients that do not speak Super/Command natively.
//
// Stateful (tracks which translated keys are held), single-threaded on the
// compositor main actor. Seat sends go through SeatDelivery; the native-Command
// decision is owned by WindowManager (it keys on window identity).

import Glibc
import NucleusCompositorWindowManager

enum ClientKeyPolicy {
    case nativeCommand
    case commandToControl
}

@MainActor
final class InputClientPolicy {
    /// Bitset of evdev keycodes < 128 whose press we translated, so the matching
    /// release is translated identically.
    private var translatedKeysLow: UInt128 = 0
    private var logCount: UInt32 = 0

    func reset() { translatedKeysLow = 0 }

    /// The Command-handling policy for the window owning `surfaceID`. Native-Command
    /// windows (shell layers, matched app identities) get raw chords; everyone else
    /// gets Command→Control translation.
    static func policy(forSurfaceID surfaceID: UInt64) -> ClientKeyPolicy {
        guard let windowDriver = RouterHost.shared.runtime?.windowDriver else { return .nativeCommand }
        let windowID = windowDriver.windowId(forSurfaceId: UInt32(truncatingIfNeeded: surfaceID))
        if windowID == 0 { return .nativeCommand }
        return WindowManager.shared.nativeCommandPolicy(windowID: windowID)
            ? .nativeCommand : .commandToControl
    }

    /// Handle a focused-client key under the Command→Control policy. Returns true
    /// when the policy consumed/translated the key (the dispatch must not also
    /// deliver it raw). `commandActive` is the event's Command modifier; `physical`
    /// + `masks` are the xkb-serialized modifiers and per-modifier masks.
    func handleClientKey(
        surfaceID: UInt64, keycode: UInt32, pressed: Bool, timeMsec: UInt32, commandActive: Bool,
        policy: ClientKeyPolicy, physical: XkbKeyboard.SerializedModifiers, masks: XkbKeyboard.ModifierMasks
    ) -> Bool {
        if policy == .nativeCommand { return false }

        // The Command keys themselves never reach the client.
        if Self.isCommandKey(keycode) {
            logTranslated(keycode: keycode, pressed: pressed, reason: "suppress-command-key")
            return true
        }

        if pressed && commandActive {
            guard surfaceID != 0 else { return true }
            let mods = Self.translatedModifiers(physical, masks: masks, forceControl: true)
            SeatDelivery.keyboardModifiers(
                surfaceID: surfaceID, depressed: mods.depressed, latched: mods.latched,
                locked: mods.locked, group: mods.group)
            SeatDelivery.keyboardKey(surfaceID: surfaceID, timeMsec: timeMsec, keycode: keycode, keyState: 1)
            markTranslatedKey(keycode, down: true)
            logTranslated(keycode: keycode, pressed: true, reason: "command-to-control-down")
            return true
        }

        if !pressed && translatedKeyIsDown(keycode) {
            guard surfaceID != 0 else { return true }
            let mods = Self.translatedModifiers(physical, masks: masks, forceControl: true)
            SeatDelivery.keyboardModifiers(
                surfaceID: surfaceID, depressed: mods.depressed, latched: mods.latched,
                locked: mods.locked, group: mods.group)
            SeatDelivery.keyboardKey(surfaceID: surfaceID, timeMsec: timeMsec, keycode: keycode, keyState: 0)
            markTranslatedKey(keycode, down: false)
            let restored = Self.translatedModifiers(
                physical, masks: masks, forceControl: translatedKeysLow != 0)
            SeatDelivery.keyboardModifiers(
                surfaceID: surfaceID, depressed: restored.depressed, latched: restored.latched,
                locked: restored.locked, group: restored.group)
            logTranslated(keycode: keycode, pressed: false, reason: "command-to-control-up")
            return true
        }
        return false
    }

    private static func translatedModifiers(
        _ physical: XkbKeyboard.SerializedModifiers, masks: XkbKeyboard.ModifierMasks, forceControl: Bool
    ) -> XkbKeyboard.SerializedModifiers {
        var translated = physical
        translated.depressed &= ~masks.command
        if forceControl { translated.depressed |= masks.control }
        return translated
    }

    private func markTranslatedKey(_ keycode: UInt32, down: Bool) {
        guard keycode < 128 else { return }
        let mask: UInt128 = 1 << UInt128(keycode)
        if down { translatedKeysLow |= mask } else { translatedKeysLow &= ~mask }
    }

    private func translatedKeyIsDown(_ keycode: UInt32) -> Bool {
        guard keycode < 128 else { return false }
        return (translatedKeysLow & (1 << UInt128(keycode))) != 0
    }

    private static func isCommandKey(_ keycode: UInt32) -> Bool { keycode == 125 || keycode == 126 }

    private func logTranslated(keycode: UInt32, pressed: Bool, reason: String) {
        guard logCount < 64 else { return }
        logCount += 1
        let line = "input policy: keycode=\(keycode) pressed=\(pressed) \(reason)\n"
        line.withCString { _ = write(2, $0, strlen($0)) }
    }
}
