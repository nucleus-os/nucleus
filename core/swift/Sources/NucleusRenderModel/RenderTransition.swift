// Phase 8.7 — Swift transition-shaped semantic metadata.
//
// Wire-shaped semantic intent for display/group transitions: the producer ships
// `TransitionMetadata`; the render server expands it into presentation-transition
// operations. Pure value types; nothing imports
// this yet. `TransitionSubtype` lives here (its canonical home) and is reused by
// the 8.4 `RenderLayerStore` rect helpers.

/// Transition family.
public enum TransitionType: UInt8, Sendable {
    case fade
    case moveIn
    case push
    case reveal
}

/// Slide-in direction for a directional transition. Mirrors
/// `RenderTransition.TransitionSubtype`.
public enum TransitionSubtype: UInt8, Sendable {
    case fromLeft
    case fromRight
    case fromTop
    case fromBottom
}

/// Named timing-curve template id. Mirrors `RenderTransition.TimingTemplateId`
/// (raw values pinned to the wire encoding).
public enum TimingTemplateId: UInt32, Sendable {
    case `default` = 0
    case linear
    case easeIn
    case easeOut
    case easeInEaseOut
}

/// Default transition duration. Mirrors `default_transition_duration_ns`.
public let defaultTransitionDurationNs: UInt64 = 250_000_000

/// Wire-shaped transition intent. Mirrors `TransitionMetadata`.
public struct TransitionMetadata: Equatable, Sendable {
    public var type: TransitionType
    public var subtype: TransitionSubtype?
    public var durationNs: UInt64 = defaultTransitionDurationNs
    public var timing: TimingTemplateId = .default

    public init(
        type: TransitionType,
        subtype: TransitionSubtype? = nil,
        durationNs: UInt64 = defaultTransitionDurationNs,
        timing: TimingTemplateId = .default
    ) {
        self.type = type
        self.subtype = subtype
        self.durationNs = durationNs
        self.timing = timing
    }
}

/// Structural equality of two transition descriptors (equivalent to
/// `TransitionMetadata`'s synthesized `==`).
public func equivalentTransitionMetadata(_ a: TransitionMetadata, _ b: TransitionMetadata) -> Bool {
    a == b
}
