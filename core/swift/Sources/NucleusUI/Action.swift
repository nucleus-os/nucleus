public struct ActionID: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let primary = ActionID(rawValue: 1)
}

public enum EventType: Int32, Sendable {
    case action = 1
    case pointerDown = 2
    case pointerUp = 3
}

public struct Event: Sendable, Equatable {
    public var type: EventType
    public var button: UInt32
    public var location: Point
    public var timestampNanoseconds: UInt64

    public init(type: EventType, button: UInt32 = 0, location: Point = Point(x: 0, y: 0), timestampNanoseconds: UInt64 = 0) {
        self.type = type
        self.button = button
        self.location = location
        self.timestampNanoseconds = timestampNanoseconds
    }
}
