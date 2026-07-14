public enum TransitionType: Sendable, Equatable {
    case fade
}

public struct Transition: Sendable, Equatable {
    public var type: TransitionType
    public var duration: Double

    public init(type: TransitionType = .fade, duration: Double) {
        self.type = type
        self.duration = duration
    }
}
