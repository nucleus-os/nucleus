public struct ActionID: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let primary = ActionID(rawValue: 1)
    public static let copy = ActionID(rawValue: 2)
    public static let cut = ActionID(rawValue: 3)
    public static let paste = ActionID(rawValue: 4)
    public static let selectAll = ActionID(rawValue: 5)
    public static let undo = ActionID(rawValue: 6)
    public static let redo = ActionID(rawValue: 7)
}
