public struct BackdropGroup: RawRepresentable, Sendable, Equatable, Hashable {
    public var rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let none = BackdropGroup(rawValue: 0)
    public static let notifications = BackdropGroup(rawValue: 0x6e6f_7469_665f_6267)
    public static let hotkeyOverlay = BackdropGroup(rawValue: 0x686f_746b_6579_6267)
    public static let dock = BackdropGroup(rawValue: 0x646f_636b_5f5f_6267)
}
