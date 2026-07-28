/// The key binding table.
///
/// A user's `binds` array replaces the built-in table outright rather than
/// merging into it. Merging would mean a bind you cannot see in your own file
/// is still active, and removing a default would need a syntax for absence.
/// Replacement keeps the file the whole truth; `ConfigExport` writes the
/// complete default table, so starting from it is copy-and-edit.
public enum DefaultBinds {
    public static let table: [KeyBind] = {
        var binds: [KeyBind] = [
            // Applications.
            KeyBind(
                keys: KeyChord(modifiers: .superKey, keyCode: 20), // T
                action: .launch(
                    appIDs: [
                        "kitty.desktop",
                        "org.wezfurlong.wezterm.desktop",
                        "foot.desktop",
                    ],
                    command: ["kitty"])),
            KeyBind(
                keys: KeyChord(modifiers: .superKey, keyCode: 33), // F
                action: .launch(
                    appIDs: ["foot.desktop", "kitty.desktop"],
                    command: ["foot"])),
            KeyBind(
                keys: KeyChord(modifiers: .superKey, keyCode: 31), // S
                action: .launch(
                    appIDs: [
                        "sublime_text.desktop",
                        "com.sublimetext.three.desktop",
                        "code.desktop",
                    ],
                    command: ["subl"])),
            KeyBind(
                keys: KeyChord(modifiers: .superKey, keyCode: 46), // C
                action: .launch(
                    appIDs: ["google-chrome.desktop", "chromium.desktop"],
                    command: ["google-chrome"])),

            // Session.
            KeyBind(
                keys: KeyChord(modifiers: .superKey, keyCode: 16), // Q
                action: .closeWindow),
            KeyBind(
                keys: KeyChord(
                    modifiers: [.superKey, .shift], keyCode: 50), // M
                action: .showWindowMenu),
            KeyBind(
                keys: KeyChord(modifiers: .superKey, keyCode: 53), // Slash
                action: .toggleHotkeyOverlay),
            KeyBind(
                keys: KeyChord(keyCode: 1), // Escape
                action: .dismissHotkeyOverlay),

            // Backdrop intensity.
            KeyBind(
                keys: KeyChord(
                    modifiers: [.superKey, .alt], keyCode: 26), // LeftBracket
                action: .adjustBackdropIntensity(-0.2)),
            KeyBind(
                keys: KeyChord(
                    modifiers: [.superKey, .alt], keyCode: 27), // RightBracket
                action: .adjustBackdropIntensity(0.2)),

            // Tiling. Arrows half-tile; U/I/J/K corner-tile as a positional
            // 2×2 cluster; Return maximizes.
            KeyBind(
                keys: KeyChord(modifiers: [.control, .alt], keyCode: 105),
                action: .tile(.left)),
            KeyBind(
                keys: KeyChord(modifiers: [.control, .alt], keyCode: 106),
                action: .tile(.right)),
            KeyBind(
                keys: KeyChord(modifiers: [.control, .alt], keyCode: 103),
                action: .tile(.top)),
            KeyBind(
                keys: KeyChord(modifiers: [.control, .alt], keyCode: 108),
                action: .tile(.bottom)),
            KeyBind(
                keys: KeyChord(modifiers: [.control, .alt], keyCode: 22), // U
                action: .tile(.topLeft)),
            KeyBind(
                keys: KeyChord(modifiers: [.control, .alt], keyCode: 23), // I
                action: .tile(.topRight)),
            KeyBind(
                keys: KeyChord(modifiers: [.control, .alt], keyCode: 36), // J
                action: .tile(.bottomLeft)),
            KeyBind(
                keys: KeyChord(modifiers: [.control, .alt], keyCode: 37), // K
                action: .tile(.bottomRight)),
            KeyBind(
                keys: KeyChord(modifiers: [.control, .alt], keyCode: 28),
                action: .tile(.maximize)),
        ]

        // Workspaces: Super+N switches, Super+Shift+N moves the focused window.
        // Generated so the 1…9 table stays one source of truth.
        for index in UInt32(1)...9 {
            // evdev puts KEY_1…KEY_9 at 2…10.
            let code = index + 1
            binds.append(KeyBind(
                keys: KeyChord(modifiers: .superKey, keyCode: code),
                action: .activateWorkspace(index)))
            binds.append(KeyBind(
                keys: KeyChord(
                    modifiers: [.superKey, .shift], keyCode: code),
                action: .moveWindowToWorkspace(index)))
        }
        return binds
    }()
}
