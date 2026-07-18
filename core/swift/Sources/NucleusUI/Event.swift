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
public struct KeyCode: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let unknown = KeyCode(rawValue: 0)

    public static let escape = KeyCode(rawValue: 1)
    public static let `return` = KeyCode(rawValue: 2)
    public static let tab = KeyCode(rawValue: 3)
    public static let space = KeyCode(rawValue: 4)
    public static let delete = KeyCode(rawValue: 5)
    public static let forwardDelete = KeyCode(rawValue: 6)

    public static let leftArrow = KeyCode(rawValue: 10)
    public static let rightArrow = KeyCode(rawValue: 11)
    public static let upArrow = KeyCode(rawValue: 12)
    public static let downArrow = KeyCode(rawValue: 13)
    public static let home = KeyCode(rawValue: 14)
    public static let end = KeyCode(rawValue: 15)
    public static let pageUp = KeyCode(rawValue: 16)
    public static let pageDown = KeyCode(rawValue: 17)
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
}
