public struct UIEnvironmentChanges: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let reducedMotion =
        UIEnvironmentChanges(rawValue: 1 << 0)
    public static let reducedTransparency =
        UIEnvironmentChanges(rawValue: 1 << 1)
    public static let increasedContrast =
        UIEnvironmentChanges(rawValue: 1 << 2)
    public static let appearance =
        UIEnvironmentChanges(rawValue: 1 << 3)
    public static let textScale =
        UIEnvironmentChanges(rawValue: 1 << 4)
}

public struct UIEnvironment: Sendable, Equatable {
    public var reducesMotion: Bool
    public var reducesTransparency: Bool
    public var increasesContrast: Bool
    public var appearance: Appearance
    public var textScale: Double

    public init(
        reducesMotion: Bool = false,
        reducesTransparency: Bool = false,
        increasesContrast: Bool = false,
        appearance: Appearance = .dark,
        textScale: Double = 1
    ) {
        self.reducesMotion = reducesMotion
        self.reducesTransparency = reducesTransparency
        self.increasesContrast = increasesContrast
        self.appearance = appearance
        self.textScale = textScale.isFinite && textScale > 0
            ? min(max(0.5, textScale), 4)
            : 1
    }

    package func changes(
        from old: UIEnvironment
    ) -> UIEnvironmentChanges {
        var changes: UIEnvironmentChanges = []
        if reducesMotion != old.reducesMotion {
            changes.insert(.reducedMotion)
        }
        if reducesTransparency != old.reducesTransparency {
            changes.insert(.reducedTransparency)
        }
        if increasesContrast != old.increasesContrast {
            changes.insert(.increasedContrast)
        }
        if appearance != old.appearance {
            changes.insert(.appearance)
        }
        if textScale != old.textScale {
            changes.insert(.textScale)
        }
        return changes
    }
}
