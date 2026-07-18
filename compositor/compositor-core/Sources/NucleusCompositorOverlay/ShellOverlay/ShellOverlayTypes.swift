import NucleusCompositorOverlayTypes
import NucleusUI
import NucleusUIEmbedder

public struct ShellOverlayFrameInfo: Sendable, Equatable {
    public var outputWidth: UInt32
    public var outputHeight: UInt32
    public var devicePixelRatio: Float
    public var overlayRegionX: Float
    public var overlayRegionY: Float
    public var overlayRegionW: Float
    public var overlayRegionH: Float

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

public enum ShellOverlayEventKind: UInt32, Sendable {
    case frame = 1
    case notification = 2
    case dismissNotification = 3
    case hotkeyVisibility = 5
}

public struct ShellOverlayNotificationInfo: Sendable, Equatable {
    public var id: UInt32
    public var appName: String
    public var summary: String
    public var body: String
    public var thumbnailHandle: UInt64
    public var showsThumbnail: Bool
    public var expireTimeoutMs: Int32
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
    public var location: Point
    public var scrollX: Float
    public var scrollY: Float
    public var keycode: UInt32
    public var modifiers: UInt32
    public var timestampNanoseconds: UInt64

    public init(_ event: NucleusCompositorOverlayTypes.InputEvent) {
        kind = ShellOverlayInputKind(rawValue: event.kind.rawValue) ?? .pointerMove
        button = event.button
        location = Point(x: Double(event.x), y: Double(event.y))
        scrollX = event.scrollX
        scrollY = event.scrollY
        keycode = event.keycode
        modifiers = event.modifiers
        timestampNanoseconds = event.timestampNs
    }

    public func convertedFromBackingPixels(_ scale: BackingScaleFactor) -> ShellOverlayInputEvent {
        var copy = self
        copy.location = scale.points(fromBackingPixels: location)
        copy.scrollX = scale.points(fromBackingPixels: scrollX)
        copy.scrollY = scale.points(fromBackingPixels: scrollY)
        return copy
    }

    public var nucleonEvent: Event? {
        switch kind {
        case .pointerDown:
            Event(type: .pointerDown, button: button, location: location, timestampNanoseconds: timestampNanoseconds)
        case .pointerUp:
            Event(type: .pointerUp, button: button, location: location, timestampNanoseconds: timestampNanoseconds)
        case .pointerMove, .scroll, .keyDown, .keyUp:
            nil
        }
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

    public init(_ event: NucleusCompositorOverlayTypes.OverlayEvent) {
        switch ShellOverlayEventKind(rawValue: event.kind.rawValue) {
        case .frame:
            self = .frame(.init(
                outputWidth: event.frame.outputWidth,
                outputHeight: event.frame.outputHeight,
                devicePixelRatio: event.frame.devicePixelRatio,
                overlayRegionX: event.frame.overlayRegionX,
                overlayRegionY: event.frame.overlayRegionY,
                overlayRegionW: event.frame.overlayRegionW,
                overlayRegionH: event.frame.overlayRegionH
            ))
        case .notification:
            self = .notification(.init(
                id: event.notification.id,
                appName: stringView(event.notification.appName),
                summary: stringView(event.notification.summary),
                body: stringView(event.notification.body),
                thumbnailHandle: event.notification.thumbnailHandle,
                showsThumbnail: event.notification.showThumbnail,
                expireTimeoutMs: event.notification.expireTimeoutMs
            ))
        case .dismissNotification:
            self = .dismissNotification(
                id: event.notificationId,
                reason: event.closeReason == 0 ? 2 : event.closeReason
            )
        case .hotkeyVisibility:
            self = .hotkeyVisibility(event.visible)
        case nil:
            self = .frame(.init(
                outputWidth: 0,
                outputHeight: 0,
                devicePixelRatio: 1,
                overlayRegionX: 0,
                overlayRegionY: 0,
                overlayRegionW: 0,
                overlayRegionH: 0
            ))
        }
    }
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
