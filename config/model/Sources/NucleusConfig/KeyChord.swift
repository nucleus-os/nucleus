import Foundation

/// Modifiers a chord can require.
///
/// Names carry aliases because users arrive from different desktops and all of
/// `Super`, `Mod`, `Logo`, and `Cmd` mean the same physical key.
public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let alt = KeyModifiers(rawValue: 1 << 2)
    public static let superKey = KeyModifiers(rawValue: 1 << 3)

    static let names: [String: KeyModifiers] = [
        "shift": .shift,
        "ctrl": .control, "control": .control,
        "alt": .alt, "option": .alt, "mod1": .alt,
        "super": .superKey, "mod": .superKey, "logo": .superKey,
        "meta": .superKey, "cmd": .superKey, "command": .superKey,
        "win": .superKey,
    ]

    /// Canonical spelling, in a fixed order so a chord round-trips to one form.
    var canonicalNames: [String] {
        var names: [String] = []
        if contains(.superKey) { names.append("Super") }
        if contains(.control) { names.append("Ctrl") }
        if contains(.alt) { names.append("Alt") }
        if contains(.shift) { names.append("Shift") }
        return names
    }
}

/// One key combination, as a physical key plus required modifiers.
///
/// The key is an **evdev code**, not a keysym: binds follow physical position,
/// so `Super+Q` stays the same physical key whether the active layout is QWERTY,
/// AZERTY, or Dvorak. Names in the file denote those positions using their US
/// layout labels, which is the only naming that is both readable and stable.
public struct KeyChord: Hashable, Sendable {
    public var modifiers: KeyModifiers
    /// Linux evdev keycode (`KEY_*` in `input-event-codes.h`).
    public var keyCode: UInt32

    public init(modifiers: KeyModifiers = [], keyCode: UInt32) {
        self.modifiers = modifiers
        self.keyCode = keyCode
    }

    public enum ParseError: Error, Equatable, Sendable {
        case empty
        case unknownModifier(String)
        case unknownKey(String)
        case missingKey

        public var message: String {
            switch self {
            case .empty:
                "empty key combination"
            case .unknownModifier(let name):
                "unknown modifier '\(name)'"
            case .unknownKey(let name):
                "unknown key '\(name)'"
            case .missingKey:
                "key combination has modifiers but no key"
            }
        }
    }

    /// Parse `"Super+Shift+Left"`. Case-insensitive; whitespace around each
    /// component is ignored.
    public static func parse(_ text: String) throws(ParseError) -> KeyChord {
        let parts = text.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmed() }
        guard !parts.isEmpty, !(parts.count == 1 && parts[0].isEmpty) else {
            throw .empty
        }
        var modifiers: KeyModifiers = []
        for part in parts.dropLast() {
            guard let modifier = KeyModifiers.names[part.lowercased()] else {
                throw .unknownModifier(part)
            }
            modifiers.insert(modifier)
        }
        guard let last = parts.last, !last.isEmpty else { throw .missingKey }
        guard let code = KeyNames.code(for: last) else {
            throw .unknownKey(last)
        }
        return KeyChord(modifiers: modifiers, keyCode: code)
    }

    /// Canonical text form. Round-trips through `parse`.
    public var text: String {
        (modifiers.canonicalNames + [KeyNames.name(for: keyCode) ?? "\(keyCode)"])
            .joined(separator: "+")
    }
}

extension KeyChord: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        do {
            self = try KeyChord.parse(text)
        } catch {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: error.message))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

extension KeyChord: CustomStringConvertible {
    public var description: String { text }
}

extension StringProtocol {
    fileprivate func trimmed() -> String {
        var view = Substring(self)
        while let first = view.first, first == " " || first == "\t" {
            view = view.dropFirst()
        }
        while let last = view.last, last == " " || last == "\t" {
            view = view.dropLast()
        }
        return String(view)
    }
}

/// Physical key names ↔ evdev codes.
///
/// Names label the *position* by its US layout legend. Codes are from
/// `linux/input-event-codes.h`.
public enum KeyNames {
    /// Canonical name per code, used when writing a chord back out.
    static let canonical: [UInt32: String] = {
        var table: [UInt32: String] = [:]
        for (name, code) in ordered where table[code] == nil {
            table[code] = name
        }
        return table
    }()

    /// Lowercased lookup, so `"pageup"`, `"PageUp"`, and `"PAGEUP"` agree.
    static let lookup: [String: UInt32] = {
        var table: [String: UInt32] = [:]
        for (name, code) in ordered + aliases {
            table[name.lowercased()] = code
        }
        return table
    }()

    public static func code(for name: some StringProtocol) -> UInt32? {
        lookup[name.lowercased()]
    }

    public static func name(for code: UInt32) -> String? {
        canonical[code]
    }

    /// Canonical names first; the first entry for a code wins when encoding.
    private static let ordered: [(String, UInt32)] = {
        var table: [(String, UInt32)] = []

        // Letters, in evdev's keyboard-row order rather than alphabetical.
        let rows: [(String, UInt32)] = [
            ("Q", 16), ("W", 17), ("E", 18), ("R", 19), ("T", 20), ("Y", 21),
            ("U", 22), ("I", 23), ("O", 24), ("P", 25),
            ("A", 30), ("S", 31), ("D", 32), ("F", 33), ("G", 34), ("H", 35),
            ("J", 36), ("K", 37), ("L", 38),
            ("Z", 44), ("X", 45), ("C", 46), ("V", 47), ("B", 48), ("N", 49),
            ("M", 50),
        ]
        table += rows

        // Number row: KEY_1…KEY_9 are 2…10, and KEY_0 is 11, not 1.
        for digit in 1...9 {
            table.append(("\(digit)", UInt32(digit + 1)))
        }
        table.append(("0", 11))

        // Function keys. F1–F10 are contiguous; F11/F12 sit apart, and F13+
        // start a separate run.
        for index in 1...10 {
            table.append(("F\(index)", UInt32(58 + index)))
        }
        table.append(("F11", 87))
        table.append(("F12", 88))
        for index in 13...24 {
            table.append(("F\(index)", UInt32(183 + index - 13)))
        }

        table += [
            ("Escape", 1), ("Minus", 12), ("Equal", 13), ("Backspace", 14),
            ("Tab", 15), ("LeftBracket", 26), ("RightBracket", 27),
            ("Return", 28), ("Semicolon", 39), ("Apostrophe", 40),
            ("Grave", 41), ("Backslash", 43), ("Comma", 51), ("Period", 52),
            ("Slash", 53), ("Space", 57), ("CapsLock", 58), ("NumLock", 69),
            ("ScrollLock", 70), ("Pause", 119), ("Menu", 127),

            ("Home", 102), ("Up", 103), ("PageUp", 104), ("Left", 105),
            ("Right", 106), ("End", 107), ("Down", 108), ("PageDown", 109),
            ("Insert", 110), ("Delete", 111),

            // The Print Screen key emits KEY_SYSRQ; KEY_PRINT (210) is a
            // different, rarely-present key.
            ("Print", 99),

            // Keypad.
            ("KP0", 82), ("KP1", 79), ("KP2", 80), ("KP3", 81), ("KP4", 75),
            ("KP5", 76), ("KP6", 77), ("KP7", 71), ("KP8", 72), ("KP9", 73),
            ("KPPlus", 78), ("KPMinus", 74), ("KPMultiply", 55),
            ("KPDivide", 98), ("KPEnter", 96), ("KPDot", 83),

            // Media and hardware keys, which a desktop is expected to bind.
            ("Mute", 113), ("VolumeDown", 114), ("VolumeUp", 115),
            ("Power", 116), ("NextSong", 163), ("PlayPause", 164),
            ("PreviousSong", 165), ("Stop", 166),
            ("BrightnessDown", 224), ("BrightnessUp", 225),
        ]
        return table
    }()

    /// Alternate spellings. Never chosen when encoding.
    private static let aliases: [(String, UInt32)] = [
        ("Esc", 1), ("Enter", 28), ("PrintScreen", 99), ("PrtSc", 99),
        ("BracketLeft", 26), ("BracketRight", 27), ("Dot", 52),
        ("Quote", 40), ("Backtick", 41), ("PgUp", 104), ("PgDn", 109),
        ("PageDn", 109), ("Del", 111), ("Ins", 110), ("Spacebar", 57),
    ]
}
