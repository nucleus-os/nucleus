public import NucleusTypes
public import NucleusAppHostProtocols

public struct Settings: Sendable, Equatable {
    public var reduceMotion: Bool

    public init(reduceMotion: Bool = false) {
        self.reduceMotion = reduceMotion
    }
}

public struct CubicBezier: Sendable, Equatable {
    public let c1x: Float
    public let c1y: Float
    public let c2x: Float
    public let c2y: Float

    public init(_ c1x: Float, _ c1y: Float, _ c2x: Float, _ c2y: Float) {
        self.c1x = c1x
        self.c1y = c1y
        self.c2x = c2x
        self.c2y = c2y
    }
}

public enum ImplicitActionTemplate: Sendable, Equatable {
    case spring(mass: Float, stiffness: Float, damping: Float)
    case scalar(duration: Double, timingFunction: CubicBezier)
}

public struct ImplicitActionEntry: Sendable, Equatable {
    public enum KeyPath: UInt8, Sendable {
        case frame = 1
        case opacity = 2
    }

    public let role: LayerRole
    public let keyPath: KeyPath
    public let template: ImplicitActionTemplate

    public init(role: LayerRole, keyPath: KeyPath, template: ImplicitActionTemplate) {
        self.role = role
        self.keyPath = keyPath
        self.template = template
    }
}

/// Swift owns implicit-action template selection and accessibility policy.
/// The layers substrate receives this table only at installation/settings
/// changes and owns the live-value read, animation expansion, retargeting,
/// and per-frame evaluation.
public enum ImplicitActionPolicy {
    public static func entries(settings: Settings) -> [ImplicitActionEntry] {
        guard !settings.reduceMotion else { return [] }

        // Window spring tuning:
        // ω₀ = sqrt(stiffness/mass), ζ = damping/(2·sqrt(stiffness·mass)).
        // Large tile changes must not overshoot, so ζ ≥ 1. Current 1100/68
        // is slightly overdamped (ζ≈1.025, ω₀≈33.2), roughly 18% faster
        // to settle than the prior critically damped 784/56. Tune speed by
        // changing stiffness and keeping damping near 2·sqrt(stiffness).
        return [
            .init(role: .windowRoot, keyPath: .frame, template: .spring(mass: 1, stiffness: 1100, damping: 68)),
            .init(role: .windowContentViewport, keyPath: .frame, template: .spring(mass: 1, stiffness: 1100, damping: 68)),
            .init(role: .notification, keyPath: .frame, template: .spring(mass: 1, stiffness: 900, damping: 60)),
            .init(role: .hotkeyOverlay, keyPath: .frame, template: .spring(mass: 1, stiffness: 900, damping: 60)),
            .init(role: .windowRoot, keyPath: .opacity, template: .scalar(duration: 0.18, timingFunction: .init(0, 0, 0.58, 1))),
            .init(role: .notification, keyPath: .opacity, template: .scalar(duration: 0.2, timingFunction: .init(0.42, 0, 0.58, 1))),
            .init(role: .hotkeyOverlay, keyPath: .opacity, template: .scalar(duration: 0.2, timingFunction: .init(0.42, 0, 0.58, 1))),
            .init(role: .wallpaper, keyPath: .opacity, template: .scalar(duration: 0.2, timingFunction: .init(0.42, 0, 0.58, 1))),
            .init(role: .dock, keyPath: .opacity, template: .scalar(duration: 0.2, timingFunction: .init(0.42, 0, 0.58, 1))),
        ]
    }

    public static func rows(settings: Settings) -> [NucleusTypes.ImplicitActionRow] {
        entries(settings: settings).map(wireRow)
    }

    private static func wireRow(_ entry: ImplicitActionEntry) -> NucleusTypes.ImplicitActionRow {
        switch entry.template {
        case let .spring(mass, stiffness, damping):
            return .init(
                role: entry.role,
                keyPath: NucleusTypes.ImplicitActionKeyPath(rawValue: entry.keyPath.rawValue)!,
                kind: .spring,
                reserved: 0,
                mass: mass, stiffness: stiffness, damping: damping, reserved2: 0,
                duration: 0, c1x: 0, c1y: 0, c2x: 0, c2y: 0
            )
        case let .scalar(duration, timingFunction):
            return .init(
                role: entry.role,
                keyPath: NucleusTypes.ImplicitActionKeyPath(rawValue: entry.keyPath.rawValue)!,
                kind: .scalar,
                reserved: 0,
                mass: 0, stiffness: 0, damping: 0, reserved2: 0, duration: duration,
                c1x: timingFunction.c1x, c1y: timingFunction.c1y,
                c2x: timingFunction.c2x, c2y: timingFunction.c2y
            )
        }
    }
}

@MainActor
public func registerImplicitActionSettings(
    _ settings: Settings,
    using registrar: any ImplicitActionRegistrar
) {
    let rows = ImplicitActionPolicy.rows(settings: settings)
    registrar.register(rows: rows.span)
}
