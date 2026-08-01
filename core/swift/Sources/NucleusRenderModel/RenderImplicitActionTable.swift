package import NucleusTypes

//
// Template choice is policy authored Swift-side: a `(role, key path) → action
// template` lookup the transaction applier consults when a property update
// carries the `.defaultAction` policy. It reads the current presentation value
// as `from`, the new value as `to`, and the looked-up template's spring/scalar
// params to construct the implicit animation record. The table itself is pure
// data; expanding templates against live values is the applier's job.

/// Spring parameters for a default frame action. Mirrors `FrameSpringParams`.
package struct FrameSpringParams: Equatable, Sendable {
    package var mass: Float
    package var stiffness: Float
    package var damping: Float

    package init(mass: Float, stiffness: Float, damping: Float) {
        self.mass = mass
        self.stiffness = stiffness
        self.damping = damping
    }
}

/// Timed-curve parameters for a default scalar action. Mirrors
/// `BasicScalarParams`.
package struct BasicScalarParams: Equatable, Sendable {
    package var duration: Double
    package var timingFunction: TimingFunction

    package init(duration: Double, timingFunction: TimingFunction) {
        self.duration = duration
        self.timingFunction = timingFunction
    }
}

package typealias ImplicitActionKeyPath = NucleusTypes.ImplicitActionKeyPath
package typealias ImplicitActionKind = NucleusTypes.ImplicitActionKind
package typealias ImplicitActionRow = NucleusTypes.ImplicitActionRow

/// Resident lookup for Swift-authored implicit-action policy. Mirrors
/// `ImplicitActionTable`. `roleCount` is `dock + 1` (the last `LayerRole`).
package struct ImplicitActionTable: Equatable, Sendable {
    package static let roleCount = Int(LayerRole.dock.rawValue) + 1

    package var frames: [FrameSpringParams?]
    package var opacities: [BasicScalarParams?]

    package init() {
        frames = Array(repeating: nil, count: ImplicitActionTable.roleCount)
        opacities = Array(repeating: nil, count: ImplicitActionTable.roleCount)
    }

    /// Replace the whole table from a row set, validating each row (a spring row
    /// needs positive mass/stiffness; a scalar row needs positive duration).
    /// Mirrors `ImplicitActionTable.replace`.
    package mutating func replace(_ rows: [ImplicitActionRow]) {
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
                        timingFunction: TimingFunction(
                            c1x: row.c1x, c1y: row.c1y, c2x: row.c2x, c2y: row.c2y))
                }
            }
        }
    }

    /// The default frame spring for `role`, if any. Mirrors `frameFor`.
    package func frameFor(_ role: LayerRole) -> FrameSpringParams? {
        frames[Int(role.rawValue)]
    }

    /// The default opacity curve for `role`, if any. Mirrors `opacityFor`.
    package func opacityFor(_ role: LayerRole) -> BasicScalarParams? {
        opacities[Int(role.rawValue)]
    }
}
