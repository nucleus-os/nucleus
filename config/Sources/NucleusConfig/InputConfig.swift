/// Input device configuration.
///
/// Structured per device class rather than as one flat block, because libinput
/// configuration *is* per device: a touchpad and a trackball do not share an
/// acceleration profile, and a user who sets natural scrolling on one rarely
/// wants it on the other. The shape mirrors what the runtime has to do with it
/// — one settings struct per class, applied to every device reporting that class.

// MARK: - Enumerated settings

public enum AccelProfile: String, Codable, Sendable, CaseIterable {
    case adaptive
    case flat
}

public enum ScrollMethod: String, Codable, Sendable, CaseIterable {
    case noScroll = "no-scroll"
    case twoFinger = "two-finger"
    case edge
    case onButtonDown = "on-button-down"
}

public enum TapButtonMap: String, Codable, Sendable, CaseIterable {
    case leftRightMiddle = "left-right-middle"
    case leftMiddleRight = "left-middle-right"
}

public enum ClickMethod: String, Codable, Sendable, CaseIterable {
    case buttonAreas = "button-areas"
    case clickfinger
}

// MARK: - Touchpad

public struct TouchpadConfig: Codable, Equatable, Sendable {
    public var tap: Bool
    public var tapButtonMap: TapButtonMap
    public var naturalScroll: Bool
    public var accelSpeed: Double
    public var accelProfile: AccelProfile
    public var scrollMethod: ScrollMethod
    public var clickMethod: ClickMethod
    public var disableWhileTyping: Bool
    public var disableWhileTrackpointing: Bool
    public var middleEmulation: Bool
    public var leftHanded: Bool

    /// Tap-to-click and natural scrolling default *on*. libinput's own defaults
    /// leave both off, which reads as broken hardware on a laptop; every
    /// shipping desktop overrides them.
    public static let defaults = TouchpadConfig(
        tap: true,
        tapButtonMap: .leftRightMiddle,
        naturalScroll: true,
        accelSpeed: 0,
        accelProfile: .adaptive,
        scrollMethod: .twoFinger,
        clickMethod: .clickfinger,
        disableWhileTyping: true,
        disableWhileTrackpointing: true,
        middleEmulation: false,
        leftHanded: false)

    public func applying(_ part: TouchpadConfigPart) -> TouchpadConfig {
        TouchpadConfig(
            tap: part.tap ?? tap,
            tapButtonMap: part.tapButtonMap ?? tapButtonMap,
            naturalScroll: part.naturalScroll ?? naturalScroll,
            accelSpeed: part.accelSpeed ?? accelSpeed,
            accelProfile: part.accelProfile ?? accelProfile,
            scrollMethod: part.scrollMethod ?? scrollMethod,
            clickMethod: part.clickMethod ?? clickMethod,
            disableWhileTyping: part.disableWhileTyping ?? disableWhileTyping,
            disableWhileTrackpointing: part.disableWhileTrackpointing
                ?? disableWhileTrackpointing,
            middleEmulation: part.middleEmulation ?? middleEmulation,
            leftHanded: part.leftHanded ?? leftHanded)
    }
}

public struct TouchpadConfigPart: Decodable, Equatable, Sendable {
    public var tap: Bool?
    public var tapButtonMap: TapButtonMap?
    public var naturalScroll: Bool?
    public var accelSpeed: Double?
    public var accelProfile: AccelProfile?
    public var scrollMethod: ScrollMethod?
    public var clickMethod: ClickMethod?
    public var disableWhileTyping: Bool?
    public var disableWhileTrackpointing: Bool?
    public var middleEmulation: Bool?
    public var leftHanded: Bool?

    public init() {}
}

// MARK: - Pointing devices

/// Mice, trackpoints, and trackballs share one settings shape. They stay
/// separate keys in the file so each class can be tuned independently.
public struct PointerConfig: Codable, Equatable, Sendable {
    public var naturalScroll: Bool
    public var accelSpeed: Double
    public var accelProfile: AccelProfile
    public var scrollMethod: ScrollMethod
    public var scrollButton: UInt32
    public var middleEmulation: Bool
    public var leftHanded: Bool

    public static let mouseDefaults = PointerConfig(
        naturalScroll: false,
        accelSpeed: 0,
        accelProfile: .adaptive,
        scrollMethod: .twoFinger,
        scrollButton: 0,
        middleEmulation: false,
        leftHanded: false)

    /// A trackpoint scrolls by holding its middle button, not by wheel.
    public static let trackpointDefaults = PointerConfig(
        naturalScroll: false,
        accelSpeed: 0,
        accelProfile: .adaptive,
        scrollMethod: .onButtonDown,
        scrollButton: 0,
        middleEmulation: true,
        leftHanded: false)

    public static let trackballDefaults = PointerConfig(
        naturalScroll: false,
        accelSpeed: 0,
        accelProfile: .adaptive,
        scrollMethod: .onButtonDown,
        scrollButton: 0,
        middleEmulation: false,
        leftHanded: false)

    public func applying(_ part: PointerConfigPart) -> PointerConfig {
        PointerConfig(
            naturalScroll: part.naturalScroll ?? naturalScroll,
            accelSpeed: part.accelSpeed ?? accelSpeed,
            accelProfile: part.accelProfile ?? accelProfile,
            scrollMethod: part.scrollMethod ?? scrollMethod,
            scrollButton: part.scrollButton ?? scrollButton,
            middleEmulation: part.middleEmulation ?? middleEmulation,
            leftHanded: part.leftHanded ?? leftHanded)
    }
}

public struct PointerConfigPart: Decodable, Equatable, Sendable {
    public var naturalScroll: Bool?
    public var accelSpeed: Double?
    public var accelProfile: AccelProfile?
    public var scrollMethod: ScrollMethod?
    public var scrollButton: UInt32?
    public var middleEmulation: Bool?
    public var leftHanded: Bool?

    public init() {}
}

// MARK: - Keyboard

public struct XkbConfig: Codable, Equatable, Sendable {
    public var rules: String
    public var model: String
    public var layout: String
    public var variant: String
    public var options: String

    /// Empty strings mean "let xkbcommon resolve it", which is what
    /// `xkb_keymap_new_from_names` does with a null rule set — the same
    /// behavior the compositor had before configuration existed.
    public static let defaults = XkbConfig(
        rules: "", model: "", layout: "", variant: "", options: "")

    public func applying(_ part: XkbConfigPart) -> XkbConfig {
        XkbConfig(
            rules: part.rules ?? rules,
            model: part.model ?? model,
            layout: part.layout ?? layout,
            variant: part.variant ?? variant,
            options: part.options ?? options)
    }
}

public struct XkbConfigPart: Decodable, Equatable, Sendable {
    public var rules: String?
    public var model: String?
    public var layout: String?
    public var variant: String?
    public var options: String?

    public init() {}
}

public struct KeyboardConfig: Codable, Equatable, Sendable {
    public var xkb: XkbConfig
    /// Repeats per second.
    public var repeatRate: UInt32
    /// Milliseconds held before repeating begins.
    public var repeatDelay: UInt32

    public static let defaults = KeyboardConfig(
        xkb: .defaults, repeatRate: 25, repeatDelay: 600)

    public func applying(_ part: KeyboardConfigPart) -> KeyboardConfig {
        KeyboardConfig(
            xkb: xkb.applying(part.xkb ?? XkbConfigPart()),
            repeatRate: part.repeatRate ?? repeatRate,
            repeatDelay: part.repeatDelay ?? repeatDelay)
    }
}

public struct KeyboardConfigPart: Decodable, Equatable, Sendable {
    public var xkb: XkbConfigPart?
    public var repeatRate: UInt32?
    public var repeatDelay: UInt32?

    public init() {}
}

// MARK: - Touch

public struct TouchConfig: Codable, Equatable, Sendable {
    /// Name of the output touch events map onto. Empty means the device's own
    /// libinput-reported association, falling back to the first output.
    public var mapToOutput: String

    public static let defaults = TouchConfig(mapToOutput: "")

    public func applying(_ part: TouchConfigPart) -> TouchConfig {
        TouchConfig(mapToOutput: part.mapToOutput ?? mapToOutput)
    }
}

public struct TouchConfigPart: Decodable, Equatable, Sendable {
    public var mapToOutput: String?

    public init() {}
}

// MARK: - Root input block

public struct InputConfig: Codable, Equatable, Sendable {
    public var touchpad: TouchpadConfig
    public var mouse: PointerConfig
    public var trackpoint: PointerConfig
    public var trackball: PointerConfig
    public var keyboard: KeyboardConfig
    public var touch: TouchConfig

    public static let defaults = InputConfig(
        touchpad: .defaults,
        mouse: .mouseDefaults,
        trackpoint: .trackpointDefaults,
        trackball: .trackballDefaults,
        keyboard: .defaults,
        touch: .defaults)

    public func applying(_ part: InputConfigPart) -> InputConfig {
        InputConfig(
            touchpad: touchpad.applying(part.touchpad ?? TouchpadConfigPart()),
            mouse: mouse.applying(part.mouse ?? PointerConfigPart()),
            trackpoint: trackpoint.applying(
                part.trackpoint ?? PointerConfigPart()),
            trackball: trackball.applying(
                part.trackball ?? PointerConfigPart()),
            keyboard: keyboard.applying(part.keyboard ?? KeyboardConfigPart()),
            touch: touch.applying(part.touch ?? TouchConfigPart()))
    }
}

public struct InputConfigPart: Decodable, Equatable, Sendable {
    public var touchpad: TouchpadConfigPart?
    public var mouse: PointerConfigPart?
    public var trackpoint: PointerConfigPart?
    public var trackball: PointerConfigPart?
    public var keyboard: KeyboardConfigPart?
    public var touch: TouchConfigPart?

    public init() {}
}
