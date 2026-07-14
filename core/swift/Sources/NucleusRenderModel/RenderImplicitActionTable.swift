// Phase 10c.4 — the resident implicit-action table.
//
// Template choice is policy authored Swift-side: a `(role, key path) → action
// template` lookup the transaction applier consults when a property update
// carries the `.defaultAction` policy. It reads the current presentation value
// as `from`, the new value as `to`, and the looked-up template's spring/scalar
// params to construct the implicit animation record. The table itself is pure
// data; expanding templates against live values is the applier's job.

/// Spring parameters for a default frame action. Mirrors `FrameSpringParams`.
public struct FrameSpringParams: Equatable, Sendable {
    public var mass: Float
    public var stiffness: Float
    public var damping: Float

    public init(mass: Float, stiffness: Float, damping: Float) {
        self.mass = mass
        self.stiffness = stiffness
        self.damping = damping
    }
}

/// Timed-curve parameters for a default scalar action. Mirrors
/// `BasicScalarParams`.
public struct BasicScalarParams: Equatable, Sendable {
    public var duration: Double
    public var timingFunction: TimingFunction

    public init(duration: Double, timingFunction: TimingFunction) {
        self.duration = duration
        self.timingFunction = timingFunction
    }
}

/// Which property a template row targets. Mirrors `ImplicitActionTable.KeyPath`.
public enum ImplicitActionKeyPath: UInt8, Sendable {
    case frame = 1
    case opacity = 2
}

/// Which animation kind a template row produces. Mirrors
/// `ImplicitActionTable.Kind`.
public enum ImplicitActionKind: UInt8, Sendable {
    case spring = 1
    case scalar = 2
}

/// One wire row used to (re)populate the table. Mirrors `ImplicitActionTable.Row`.
public struct ImplicitActionRow: Equatable, Sendable {
    public var role: LayerRole
    public var keyPath: ImplicitActionKeyPath
    public var kind: ImplicitActionKind
    public var mass: Float = 0
    public var stiffness: Float = 0
    public var damping: Float = 0
    public var duration: Double = 0
    public var c1x: Float = 0
    public var c1y: Float = 0
    public var c2x: Float = 0
    public var c2y: Float = 0

    public init(
        role: LayerRole, keyPath: ImplicitActionKeyPath, kind: ImplicitActionKind,
        mass: Float = 0, stiffness: Float = 0, damping: Float = 0, duration: Double = 0,
        c1x: Float = 0, c1y: Float = 0, c2x: Float = 0, c2y: Float = 0
    ) {
        self.role = role
        self.keyPath = keyPath
        self.kind = kind
        self.mass = mass
        self.stiffness = stiffness
        self.damping = damping
        self.duration = duration
        self.c1x = c1x
        self.c1y = c1y
        self.c2x = c2x
        self.c2y = c2y
    }
}

/// Resident lookup for Swift-authored implicit-action policy. Mirrors
/// `ImplicitActionTable`. `roleCount` is `dock + 1` (the last `LayerRole`).
public struct ImplicitActionTable: Equatable, Sendable {
    public static let roleCount = Int(LayerRole.dock.rawValue) + 1

    public var frames: [FrameSpringParams?]
    public var opacities: [BasicScalarParams?]

    public init() {
        frames = Array(repeating: nil, count: ImplicitActionTable.roleCount)
        opacities = Array(repeating: nil, count: ImplicitActionTable.roleCount)
    }

    /// Replace the whole table from a row set, validating each row (a spring row
    /// needs positive mass/stiffness; a scalar row needs positive duration).
    /// Mirrors `ImplicitActionTable.replace`.
    public mutating func replace(_ rows: [ImplicitActionRow]) {
        frames = Array(repeating: nil, count: ImplicitActionTable.roleCount)
        opacities = Array(repeating: nil, count: ImplicitActionTable.roleCount)
        for row in rows {
            let index = Int(row.role.rawValue)
            switch row.keyPath {
            case .frame:
                if row.kind == .spring && row.mass > 0 && row.stiffness > 0 && row.damping >= 0 {
                    frames[index] = FrameSpringParams(
                        mass: row.mass, stiffness: row.stiffness, damping: row.damping)
                }
            case .opacity:
                if row.kind == .scalar && row.duration > 0 {
                    opacities[index] = BasicScalarParams(
                        duration: row.duration,
                        timingFunction: TimingFunction(c1x: row.c1x, c1y: row.c1y, c2x: row.c2x, c2y: row.c2y))
                }
            }
        }
    }

    /// The default frame spring for `role`, if any. Mirrors `frameFor`.
    public func frameFor(_ role: LayerRole) -> FrameSpringParams? {
        frames[Int(role.rawValue)]
    }

    /// The default opacity curve for `role`, if any. Mirrors `opacityFor`.
    public func opacityFor(_ role: LayerRole) -> BasicScalarParams? {
        opacities[Int(role.rawValue)]
    }
}
