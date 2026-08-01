import Swift

public struct ImageHandle: Swift.Equatable, Swift.Hashable, Swift.Sendable {
    public let id: Swift.UInt64
    public init(id: Swift.UInt64 = Swift.UInt64()) {
        self.id = id
    }
}
