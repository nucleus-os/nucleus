public import NucleusCompositorOverlayTypes
public import NucleusUI

public struct ShellOverlayFrameInfo: Sendable, Equatable {
    public var outputWidth: UInt32
    public var outputHeight: UInt32
    public var devicePixelRatio: Float
    public var overlayRegionX: Float
    public var overlayRegionY: Float
    public var overlayRegionW: Float
    public var overlayRegionH: Float

    public init(
        outputWidth: UInt32,
        outputHeight: UInt32,
        devicePixelRatio: Float,
        overlayRegionX: Float,
        overlayRegionY: Float,
        overlayRegionW: Float,
        overlayRegionH: Float
    ) {
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.devicePixelRatio = devicePixelRatio
        self.overlayRegionX = overlayRegionX
        self.overlayRegionY = overlayRegionY
        self.overlayRegionW = overlayRegionW
        self.overlayRegionH = overlayRegionH
    }

    public init(_ frame: NucleusCompositorOverlayTypes.FrameInfo) {
        outputWidth = frame.outputWidth
        outputHeight = frame.outputHeight
        devicePixelRatio = frame.devicePixelRatio
        overlayRegionX = frame.overlayRegionX
        overlayRegionY = frame.overlayRegionY
        overlayRegionW = frame.overlayRegionW
        overlayRegionH = frame.overlayRegionH
    }

    public var backingScaleFactor: BackingScaleFactor {
        BackingScaleFactor(devicePixelRatio)
    }

    public var outputSizeInPoints: Size {
        backingScaleFactor.points(fromBackingPixels: Size(
            width: Double(outputWidth),
            height: Double(outputHeight)
        ))
    }

    public var overlayRegionInPoints: Rect {
        backingScaleFactor.points(fromBackingPixels: Rect(
            x: Double(overlayRegionX),
            y: Double(overlayRegionY),
            width: Double(max(1, overlayRegionW)),
            height: Double(max(1, overlayRegionH))
        ))
    }
}

public struct ShellOverlayNotificationInfo: Sendable, Equatable {
    public var id: UInt32
    public var appName: String
    public var summary: String
    public var body: String
    public var thumbnailHandle: UInt64
    public var showsThumbnail: Bool
    public var expireTimeoutMs: Int32

    public init(
        id: UInt32,
        appName: String,
        summary: String,
        body: String,
        thumbnailHandle: UInt64,
        showsThumbnail: Bool,
        expireTimeoutMs: Int32
    ) {
        self.id = id
        self.appName = appName
        self.summary = summary
        self.body = body
        self.thumbnailHandle = thumbnailHandle
        self.showsThumbnail = showsThumbnail
        self.expireTimeoutMs = expireTimeoutMs
    }
}

public enum ShellOverlayInputKind: UInt32, Sendable {
    case pointerMove = 1
    case pointerDown = 2
    case pointerUp = 3
    case scroll = 4
    case keyDown = 5
    case keyUp = 6
}

public enum ShellOverlayCursor: UInt32, Sendable {
    case `default` = 0
    case pointer = 1
}

public struct ShellOverlayInputEvent: Sendable, Equatable {
    public var kind: ShellOverlayInputKind
    public var button: UInt32
    public var activeButtons: PointerButtonMask
    public var location: Point
    public var scrollX: Float
    public var scrollY: Float
    public var keycode: UInt32
    public var modifiers: UInt32
    /// Composed text for a key event, produced by XKB with compose state — not
    /// derived from `keycode`, which cannot account for layout or dead keys.
    public var text: String?
    public var timestampNanoseconds: UInt64

    public init(_ event: NucleusCompositorOverlayTypes.InputEvent) {
        kind = ShellOverlayInputKind(rawValue: event.kind.rawValue) ?? .pointerMove
        button = event.button
        activeButtons = []
        location = Point(x: Double(event.x), y: Double(event.y))
        scrollX = event.scrollX
        scrollY = event.scrollY
        keycode = event.keycode
        modifiers = event.modifiers
        text = event.text
        timestampNanoseconds = event.timestampNs
    }

    public func convertedFromBackingPixels(_ scale: BackingScaleFactor) -> ShellOverlayInputEvent {
        var copy = self
        copy.location = scale.points(fromBackingPixels: location)
        copy.scrollX = scale.points(fromBackingPixels: scrollX)
        copy.scrollY = scale.points(fromBackingPixels: scrollY)
        return copy
    }

    /// Translate a compositor input event into NucleusUI's platform-neutral
    /// vocabulary.
    ///
    /// This is the adapter the tier split calls for: `core/` resolves no
    /// compositor dependency, so evdev button and key codes are mapped here
    /// rather than leaking into the UI framework. It used to narrow six kinds
    /// to two and drop the keycode and modifiers entirely.
    public var nucleonEvent: Event? {
        let modifiers = nucleonModifiers
        switch kind {
        case .pointerDown:
            return Event(
                type: .pointerDown, modifierFlags: modifiers, location: location,
                timestampNanoseconds: timestampNanoseconds,
                button: Self.nucleonButton(button),
                activeButtons: activeButtons,
                pointerTool: .mouse,
                clickCount: 1)
        case .pointerUp:
            return Event(
                type: .pointerUp, modifierFlags: modifiers, location: location,
                timestampNanoseconds: timestampNanoseconds,
                button: Self.nucleonButton(button),
                activeButtons: activeButtons,
                pointerTool: .mouse,
                clickCount: 1)
        case .pointerMove:
            return Event(
                type: activeButtons.isEmpty ? .pointerMoved : .pointerDragged,
                modifierFlags: modifiers,
                location: location,
                timestampNanoseconds: timestampNanoseconds,
                activeButtons: activeButtons,
                pointerTool: .mouse)
        case .scroll:
            return Event(
                type: .scrollWheel, modifierFlags: modifiers, location: location,
                timestampNanoseconds: timestampNanoseconds,
                scrollDeltaX: Double(scrollX), scrollDeltaY: Double(scrollY),
                scrollSource: .finger,
                scrollPhase: .changed)
        case .keyDown:
            return Event(
                type: .keyDown, modifierFlags: modifiers, location: location,
                timestampNanoseconds: timestampNanoseconds,
                keyCode: Self.nucleonKeyCode(keycode), characters: text)
        case .keyUp:
            return Event(
                type: .keyUp, modifierFlags: modifiers, location: location,
                timestampNanoseconds: timestampNanoseconds,
                keyCode: Self.nucleonKeyCode(keycode), characters: text)
        }
    }

    /// evdev `BTN_*` codes to platform-neutral buttons.
    static func nucleonButton(_ code: UInt32) -> PointerButton {
        switch code {
        case 272: .left     // BTN_LEFT
        case 273: .right    // BTN_RIGHT
        case 274: .middle   // BTN_MIDDLE
        case 275: .back     // BTN_SIDE
        case 276: .forward  // BTN_EXTRA
        default: PointerButton(rawValue: code)
        }
    }

    /// evdev `KEY_*` codes to the framework's own key space. Unmapped codes
    /// become `.unknown` rather than keeping their platform value — passing raw
    /// codes through made them collide with the named constants.
    static func nucleonKeyCode(_ code: UInt32) -> KeyCode {
        KeyCode(linuxEvdevCode: code)
    }

    /// The compositor packs modifier state as XKB-style bits; `EventFlagBit`
    /// already mirrors CGEventFlags positions, so this maps those onto the
    /// framework's flags.
    var nucleonModifiers: EventModifierFlags {
        var flags: EventModifierFlags = []
        if modifiers & (1 << 17) != 0 { flags.insert(.shift) }
        if modifiers & (1 << 18) != 0 { flags.insert(.control) }
        if modifiers & (1 << 19) != 0 { flags.insert(.option) }
        if modifiers & (1 << 20) != 0 { flags.insert(.command) }
        if modifiers & (1 << 16) != 0 { flags.insert(.capsLock) }
        return flags
    }
}

public struct ShellOverlayInputResult: Sendable, Equatable {
    public var consumed: Bool
    public var wantsFrame: Bool
    public var cursor: ShellOverlayCursor

    public static let passThrough = ShellOverlayInputResult(
        consumed: false,
        wantsFrame: false,
        cursor: .default
    )

    public var abiValue: NucleusCompositorOverlayTypes.InputResult {
        .init(
            consumed: consumed,
            wantsFrame: wantsFrame,
            reserved: 0,
            cursor: NucleusCompositorOverlayTypes.CursorKind(rawValue: cursor.rawValue) ?? .default
        )
    }
}

public enum ShellOverlayEvent: Sendable, Equatable {
    case frame(ShellOverlayFrameInfo)
    case notification(ShellOverlayNotificationInfo)
    case dismissNotification(id: UInt32, reason: UInt32)
    case hotkeyVisibility(Bool)

}

public struct HostedSurfaceID: Sendable, Hashable, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}

package struct ShellOverlayPublication: Sendable, Equatable {
    package var frame: ShellOverlayFrameInfo
    package var scene: PublishedScene
}
