/// Modifier keys held when an event occurred. Mirrors `NSEvent.ModifierFlags`.
public struct EventModifierFlags: OptionSet, Sendable, Hashable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let shift = EventModifierFlags(rawValue: 1 << 0)
    public static let control = EventModifierFlags(rawValue: 1 << 1)
    /// The Alt key. Named for the AppKit convention rather than the keycap.
    public static let option = EventModifierFlags(rawValue: 1 << 2)
    /// The Super/Meta/Windows key.
    public static let command = EventModifierFlags(rawValue: 1 << 3)
    public static let capsLock = EventModifierFlags(rawValue: 1 << 4)
    public static let numericPad = EventModifierFlags(rawValue: 1 << 5)
    public static let function = EventModifierFlags(rawValue: 1 << 6)
}

/// A pointer button. Platform-neutral: adapters map evdev codes, Wayland button
/// codes, or anything else onto these.
public struct PointerButton: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let left = PointerButton(rawValue: 0)
    public static let right = PointerButton(rawValue: 1)
    public static let middle = PointerButton(rawValue: 2)
    /// Back/forward and higher buttons keep their platform ordering above the
    /// three named ones.
    public static let back = PointerButton(rawValue: 3)
    public static let forward = PointerButton(rawValue: 4)
}

/// A physical key, in a platform-neutral space.
///
/// Deliberately *not* evdev, XKB, or virtual-keycode values: `core/` resolves no
/// compositor or shell dependency, so it cannot adopt either platform's
/// numbering without picking a side. Adapters translate. Text input comes from
/// `Event.characters`, which is composed input — a key code answers "which key",
/// never "what did the user type".
/// A key, in the framework's own vocabulary.
///
/// **A closed space.** A platform code that does not map to a named key becomes
/// `.unknown` rather than passing through as a raw value. That is not fastidious:
/// when raw evdev codes were passed through, they landed on the low-numbered
/// named constants — the "1" key (evdev 2) compared equal to `.return`, "q"
/// (evdev 16) to `.pageUp` — and every view that switches on `keyCode` before
/// inserting text acted on a keystroke the user never made.
///
/// Text is carried by `Event.characters`, which is what a view should insert.
/// `keyCode` answers "which key", never "what did it produce".
public struct KeyCode: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let unknown = KeyCode(rawValue: 0)

    // Editing and control. These values are historical and kept stable.
    public static let escape = KeyCode(rawValue: 1)
    public static let `return` = KeyCode(rawValue: 2)
    public static let tab = KeyCode(rawValue: 3)
    public static let space = KeyCode(rawValue: 4)
    public static let delete = KeyCode(rawValue: 5)
    public static let forwardDelete = KeyCode(rawValue: 6)
    public static let insert = KeyCode(rawValue: 7)

    // Navigation.
    public static let leftArrow = KeyCode(rawValue: 10)
    public static let rightArrow = KeyCode(rawValue: 11)
    public static let upArrow = KeyCode(rawValue: 12)
    public static let downArrow = KeyCode(rawValue: 13)
    public static let home = KeyCode(rawValue: 14)
    public static let end = KeyCode(rawValue: 15)
    public static let pageUp = KeyCode(rawValue: 16)
    public static let pageDown = KeyCode(rawValue: 17)

    // Letters, identified by the key's unmodified legend rather than by what it
    // types — a shortcut is bound to a position on the keyboard, and the
    // character depends on the layout and the modifiers.
    public static let letterA = KeyCode(rawValue: 100)
    public static let letterB = KeyCode(rawValue: 101)
    public static let letterC = KeyCode(rawValue: 102)
    public static let letterD = KeyCode(rawValue: 103)
    public static let letterE = KeyCode(rawValue: 104)
    public static let letterF = KeyCode(rawValue: 105)
    public static let letterG = KeyCode(rawValue: 106)
    public static let letterH = KeyCode(rawValue: 107)
    public static let letterI = KeyCode(rawValue: 108)
    public static let letterJ = KeyCode(rawValue: 109)
    public static let letterK = KeyCode(rawValue: 110)
    public static let letterL = KeyCode(rawValue: 111)
    public static let letterM = KeyCode(rawValue: 112)
    public static let letterN = KeyCode(rawValue: 113)
    public static let letterO = KeyCode(rawValue: 114)
    public static let letterP = KeyCode(rawValue: 115)
    public static let letterQ = KeyCode(rawValue: 116)
    public static let letterR = KeyCode(rawValue: 117)
    public static let letterS = KeyCode(rawValue: 118)
    public static let letterT = KeyCode(rawValue: 119)
    public static let letterU = KeyCode(rawValue: 120)
    public static let letterV = KeyCode(rawValue: 121)
    public static let letterW = KeyCode(rawValue: 122)
    public static let letterX = KeyCode(rawValue: 123)
    public static let letterY = KeyCode(rawValue: 124)
    public static let letterZ = KeyCode(rawValue: 125)

    // Digit row.
    public static let digit0 = KeyCode(rawValue: 130)
    public static let digit1 = KeyCode(rawValue: 131)
    public static let digit2 = KeyCode(rawValue: 132)
    public static let digit3 = KeyCode(rawValue: 133)
    public static let digit4 = KeyCode(rawValue: 134)
    public static let digit5 = KeyCode(rawValue: 135)
    public static let digit6 = KeyCode(rawValue: 136)
    public static let digit7 = KeyCode(rawValue: 137)
    public static let digit8 = KeyCode(rawValue: 138)
    public static let digit9 = KeyCode(rawValue: 139)

    /// The digit-row key for `value`, or `.unknown` outside 0...9.
    public static func digit(_ value: Int) -> KeyCode {
        guard (0...9).contains(value) else { return .unknown }
        return KeyCode(rawValue: UInt32(130 + value))
    }

    // Punctuation that shortcuts commonly bind: zoom is minus/equal everywhere.
    public static let minus = KeyCode(rawValue: 150)
    public static let equal = KeyCode(rawValue: 151)
    public static let leftBracket = KeyCode(rawValue: 152)
    public static let rightBracket = KeyCode(rawValue: 153)
    public static let backslash = KeyCode(rawValue: 154)
    public static let semicolon = KeyCode(rawValue: 155)
    public static let quote = KeyCode(rawValue: 156)
    public static let grave = KeyCode(rawValue: 157)
    public static let comma = KeyCode(rawValue: 158)
    public static let period = KeyCode(rawValue: 159)
    public static let slash = KeyCode(rawValue: 160)

    // Function keys.
    public static let f1 = KeyCode(rawValue: 170)
    public static let f2 = KeyCode(rawValue: 171)
    public static let f3 = KeyCode(rawValue: 172)
    public static let f4 = KeyCode(rawValue: 173)
    public static let f5 = KeyCode(rawValue: 174)
    public static let f6 = KeyCode(rawValue: 175)
    public static let f7 = KeyCode(rawValue: 176)
    public static let f8 = KeyCode(rawValue: 177)
    public static let f9 = KeyCode(rawValue: 178)
    public static let f10 = KeyCode(rawValue: 179)
    public static let f11 = KeyCode(rawValue: 180)
    public static let f12 = KeyCode(rawValue: 181)
}

extension KeyCode {
    /// Map a Linux evdev keycode to a framework key.
    ///
    /// The platform is named in the label because the table *is* platform
    /// knowledge, and it lives here so there is exactly one copy of it — the
    /// shell's input router and the compositor's overlay both used to carry
    /// their own, which is how they came to disagree with each other and with
    /// the constants they produced.
    ///
    /// Unmapped codes are `.unknown`. See the type's note on why.
    public init(linuxEvdevCode code: UInt32) {
        self = KeyCode.evdevTable[code] ?? .unknown
    }

    /// evdev's letter and digit rows are keyboard-ordered, not alphabetical, so
    /// this is a table rather than arithmetic.
    private static let evdevTable: [UInt32: KeyCode] = [
        1: .escape, 14: .delete, 15: .tab, 28: .return, 96: .return, 57: .space,
        110: .insert, 111: .forwardDelete,

        102: .home, 103: .upArrow, 104: .pageUp, 105: .leftArrow,
        106: .rightArrow, 107: .end, 108: .downArrow, 109: .pageDown,

        2: .digit1, 3: .digit2, 4: .digit3, 5: .digit4, 6: .digit5,
        7: .digit6, 8: .digit7, 9: .digit8, 10: .digit9, 11: .digit0,

        12: .minus, 13: .equal, 26: .leftBracket, 27: .rightBracket,
        43: .backslash, 39: .semicolon, 40: .quote, 41: .grave,
        51: .comma, 52: .period, 53: .slash,

        16: .letterQ, 17: .letterW, 18: .letterE, 19: .letterR, 20: .letterT,
        21: .letterY, 22: .letterU, 23: .letterI, 24: .letterO, 25: .letterP,
        30: .letterA, 31: .letterS, 32: .letterD, 33: .letterF, 34: .letterG,
        35: .letterH, 36: .letterJ, 37: .letterK, 38: .letterL,
        44: .letterZ, 45: .letterX, 46: .letterC, 47: .letterV, 48: .letterB,
        49: .letterN, 50: .letterM,

        59: .f1, 60: .f2, 61: .f3, 62: .f4, 63: .f5, 64: .f6,
        65: .f7, 66: .f8, 67: .f9, 68: .f10, 87: .f11, 88: .f12,
    ]
}

public enum EventType: Int32, Sendable {
    /// A semantic action dispatched through the responder chain rather than a
    /// raw input event — a button firing its target, a menu item chosen.
    case action = 1

    case pointerDown = 2
    case pointerUp = 3
    case pointerMoved = 4
    /// Movement with a button held. Separate from `pointerMoved` because a
    /// control tracking a press cares about the distinction.
    case pointerDragged = 5
    case pointerEntered = 6
    case pointerExited = 7
    case scrollWheel = 8

    case keyDown = 9
    case keyUp = 10
    /// Modifier state changed with no key press — Shift alone, for example.
    case flagsChanged = 11

    case touchDown = 12
    case touchMoved = 13
    case touchUp = 14
    case touchCancelled = 15
}

/// An input event, shaped after `NSEvent`: one record carrying whichever
/// payload its `type` implies.
///
/// A tagged struct rather than an enum with associated values because it
/// crosses the adapter boundary as data and is compared, copied, and defaulted
/// constantly; an enum would make every adapter a switch and every field access
/// a pattern match.
public struct Event: Sendable, Equatable {
    public var type: EventType
    public var modifierFlags: EventModifierFlags
    /// Location in the coordinate space of whatever is dispatching — window
    /// coordinates at the scene, converted to view-local as it descends.
    public var location: Point
    public var timestampNanoseconds: UInt64

    // Pointer
    public var button: PointerButton
    /// 1 for a single click, 2 for a double, and so on. 0 for non-pointer events.
    public var clickCount: Int

    // Scrolling
    public var scrollDeltaX: Double
    public var scrollDeltaY: Double
    /// Whether the scroll came from a device with continuous deltas (a
    /// touchpad) rather than discrete detents (a wheel). Momentum and
    /// rubber-banding behave differently for each.
    public var hasPreciseScrollingDeltas: Bool

    // Keyboard
    public var keyCode: KeyCode
    /// Composed text for this key event, or nil. Produced by the platform's
    /// input method — never derived from `keyCode`, which cannot account for
    /// layout, dead keys, or composition.
    public var characters: String?
    /// Whether this key event came from auto-repeat rather than a fresh press.
    public var isARepeat: Bool

    // Touch
    /// Identifies a finger across a touch sequence.
    public var touchID: UInt32

    public init(
        type: EventType,
        modifierFlags: EventModifierFlags = [],
        location: Point = Point(x: 0, y: 0),
        timestampNanoseconds: UInt64 = 0,
        button: PointerButton = .left,
        clickCount: Int = 0,
        scrollDeltaX: Double = 0,
        scrollDeltaY: Double = 0,
        hasPreciseScrollingDeltas: Bool = false,
        keyCode: KeyCode = .unknown,
        characters: String? = nil,
        isARepeat: Bool = false,
        touchID: UInt32 = 0
    ) {
        self.type = type
        self.modifierFlags = modifierFlags
        self.location = location
        self.timestampNanoseconds = timestampNanoseconds
        self.button = button
        self.clickCount = clickCount
        self.scrollDeltaX = scrollDeltaX
        self.scrollDeltaY = scrollDeltaY
        self.hasPreciseScrollingDeltas = hasPreciseScrollingDeltas
        self.keyCode = keyCode
        self.characters = characters
        self.isARepeat = isARepeat
        self.touchID = touchID
    }

    /// Whether this event routes by hit testing (pointer-like) rather than to
    /// the first responder (keyboard-like).
    public var isPointerEvent: Bool {
        switch type {
        case .pointerDown, .pointerUp, .pointerMoved, .pointerDragged,
             .pointerEntered, .pointerExited, .scrollWheel,
             .touchDown, .touchMoved, .touchUp, .touchCancelled:
            true
        case .action, .keyDown, .keyUp, .flagsChanged:
            false
        }
    }

    public var isKeyEvent: Bool {
        switch type {
        case .keyDown, .keyUp, .flagsChanged: true
        default: false
        }
    }

    /// A copy with `location` moved into a child's coordinate space.
    public func offsetting(by origin: Point) -> Event {
        var copy = self
        copy.location = Point(x: location.x - origin.x, y: location.y - origin.y)
        return copy
    }

    /// The same event at an already-converted location. Dispatch converts
    /// through the view tree rather than by accumulating offsets, so it has the
    /// final point in hand and nothing left to subtract.
    public func relocated(to point: Point) -> Event {
        var copy = self
        copy.location = point
        return copy
    }
}
