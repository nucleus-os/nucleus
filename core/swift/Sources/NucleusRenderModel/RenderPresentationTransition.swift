// Phase 8.8 — Swift presentation-transition operation state machine.
//
// The render-server-owned presentation-transition operation: per-field material
// tables (from/to), per-field progress + holds, and the concrete crossfade
// sample state. Pure value type +
// its field accessors; nothing imports this yet. The authority (the render
// server driving these operations) co-lands with the renderer move (10b).
//
// `FenceHandle` and `PresentationTransitionMaterial` are
// defined here as their first Swift consumers; they migrate to a shared
// layers/content file if another slice needs them.

/// Opaque layers fence handle (`enum(u64)`, `none = 0`).
public struct FenceHandle: Equatable, Sendable {
    public var raw: UInt64 = 0
    public init(raw: UInt64 = 0) { self.raw = raw }
    public static let none = FenceHandle(raw: 0)
    public var isNone: Bool { raw == 0 }
}

/// Declarative presentation-transition material. Presentation transitions are
/// content-only. Mirrors `PresentationTransitionMaterial`.
public enum PresentationTransitionMaterial: Sendable {
    case crossfade
}

/// The independently-animated fields of a presentation transition. Mirrors
/// `TransitionField`.
public enum TransitionField: UInt8, Sendable {
    case geometry
    case contentReveal
    case opacity
    case visualStyle
}

/// Number of transition fields. Mirrors `field_count`.
public let transitionFieldCount = 4

/// Dense table index for a field. Mirrors `fieldIndex`.
public func fieldIndex(_ field: TransitionField) -> Int {
    switch field {
    case .geometry: return 0
    case .contentReveal: return 1
    case .opacity: return 2
    case .visualStyle: return 3
    }
}

/// A scalar / rect / matrix / visual-style material value. Mirrors `ScalarOrM44`.
public enum ScalarOrM44: Equatable, Sendable {
    case scalar(Float)
    case rect(Rect)
    case m44(M44)
    case visualStyle(VisualStyle)
}

/// Protocol-path identity for a content commit. Mirrors `ExpectedCommit`.
public struct ExpectedCommit: Equatable, Sendable {
    public var configureSerial: UInt32
    public var slotGeneration: UInt64

    public init(configureSerial: UInt32, slotGeneration: UInt64) {
        self.configureSerial = configureSerial
        self.slotGeneration = slotGeneration
    }
}

/// The `from` side of a field material. Mirrors `MaterialSource`.
public enum MaterialSource: Equatable, Sendable {
    case none
    case snapshot(SnapshotHandle)
    case value(ScalarOrM44)
}

/// The `to` side of a field material. Mirrors `MaterialTarget`.
public enum MaterialTarget: Equatable, Sendable {
    case none
    case pending(ExpectedCommit)
    case value(ScalarOrM44)
}

/// One field's from/to material pair. Mirrors `FieldMaterial`.
public struct FieldMaterial: Equatable, Sendable {
    public var from: MaterialSource = .none
    public var to: MaterialTarget = .none

    public init(from: MaterialSource = .none, to: MaterialTarget = .none) {
        self.from = from
        self.to = to
    }
}

/// What to do with an unmet field hold when the deadline passes. Mirrors
/// `SweepPolicy`.
public enum SweepPolicy: Sendable {
    case clampAtZero
    case freezeAtCurrent
    case skipToOne
}

/// A field-scoped fence hold gating progress. Mirrors `FieldHold`.
public struct FieldHold: Sendable {
    public var fence: FenceHandle = .none
    public var deadlineNs: UInt64 = 0
    public var sweep: SweepPolicy = .clampAtZero

    public init(fence: FenceHandle = .none, deadlineNs: UInt64 = 0, sweep: SweepPolicy = .clampAtZero) {
        self.fence = fence
        self.deadlineNs = deadlineNs
        self.sweep = sweep
    }
}

/// A render-server-owned presentation-transition operation. Mirrors
/// `PresentationTransition`.
public struct PresentationTransition: Sendable {
    public var operationId: OperationID
    public var expectedCommit: ExpectedCommit?
    public var materials: [FieldMaterial]
    public var progress: [Float]
    public var holds: [FieldHold?]
    // Concrete crossfade sample state.
    public var fromTexture: SnapshotHandle = .none
    public var fromSize = Bounds()
    public var fromPosition = Point2D()
    public var fromSample = ContentSample()
    public var toGeneration: ContentGeneration = .none
    public var expectedToSize = Bounds()
    public var toTexture: SnapshotHandle = .none
    public var toSize = Bounds()
    public var toPosition = Point2D()
    public var toSample = ContentSample()
    public var progressAtRetarget: Float = 0
    public var durationFractionAtRetarget: Float = 1
    public var material: PresentationTransitionMaterial = .crossfade
    public var contentRetired: Bool = false
    public var done: Bool = false

    public init(operationId: OperationID, expectedCommit: ExpectedCommit? = nil) {
        self.operationId = operationId
        self.expectedCommit = expectedCommit
        self.materials = Array(repeating: FieldMaterial(), count: transitionFieldCount)
        self.progress = Array(repeating: 0, count: transitionFieldCount)
        self.holds = Array(repeating: nil, count: transitionFieldCount)
    }

    public func contentRevealProgress() -> Float { progress[fieldIndex(.contentReveal)] }
    public func geometryProgress() -> Float { progress[fieldIndex(.geometry)] }

    public mutating func setGeometryProgress(_ value: Float) { progress[fieldIndex(.geometry)] = value }
    public mutating func setContentRevealProgress(_ value: Float) { progress[fieldIndex(.contentReveal)] = value }

    public func contentRevealHeld() -> Bool { holds[fieldIndex(.contentReveal)] != nil }
    public func contentRevealBlocksProgress() -> Bool { contentRevealHeld() }

    /// True when the crossfade still needs its `from` material drawn. Mirrors
    /// `contentNeedsMaterial`.
    public func contentNeedsMaterial() -> Bool { !contentRetired && !fromTexture.isNone }

    public mutating func holdContentReveal(_ hold: FieldHold) { holds[fieldIndex(.contentReveal)] = hold }
    public mutating func releaseContentRevealHold() { holds[fieldIndex(.contentReveal)] = nil }

    /// True when `commit` satisfies this transition's expected-commit gate. A
    /// nil expectation matches anything; a set expectation requires an exact
    /// serial + generation match. Mirrors `matchesExpectedCommit`.
    public func matchesExpectedCommit(_ commit: ExpectedCommit?) -> Bool {
        guard let expected = expectedCommit else { return true }
        guard let actual = commit else { return false }
        return actual.configureSerial == expected.configureSerial &&
            actual.slotGeneration == expected.slotGeneration
    }
}
