/// UIKit-shaped visual effect value. Mirrors `UIVisualEffect`.
///
/// `VisualEffectView.init(effect:)` accepts any of these; the view
/// derives its `material`/`blendingMode`/`isEmphasized` from the effect
/// through `MaterialBridge`.
public protocol VisualEffect: Sendable {}

/// `UIBlurEffect`, verbatim. A blur effect carries a style; the style
/// maps to a `VisualEffectView.Material` via `MaterialBridge`.
public final class BlurEffect: VisualEffect {
    public enum Style: Sendable, Equatable {
        // Adaptive (light/dark by current trait).
        case systemUltraThinMaterial
        case systemThinMaterial
        case systemMaterial
        case systemThickMaterial
        case systemChromeMaterial
        // Explicit light.
        case systemUltraThinMaterialLight
        case systemThinMaterialLight
        case systemMaterialLight
        case systemThickMaterialLight
        case systemChromeMaterialLight
        // Explicit dark.
        case systemUltraThinMaterialDark
        case systemThinMaterialDark
        case systemMaterialDark
        case systemThickMaterialDark
        case systemChromeMaterialDark
        // Legacy. Collapsed onto modern adaptive equivalents by
        // `MaterialBridge`; kept so apps porting from older UIKit
        // compile without churn.
        case extraLight
        case light
        case dark
        case regular
        case prominent
    }

    public let style: Style

    public init(style: Style) {
        self.style = style
    }
}

/// `UIVibrancyEffect`, verbatim. Wraps a `BlurEffect` and optionally a
/// `Style` tint preset. The catalog folds the style into the chain's
/// tint pass when resolving.
public final class VibrancyEffect: VisualEffect {
    public enum Style: Sendable, Equatable {
        case label, secondaryLabel, tertiaryLabel, quaternaryLabel
        case fill, secondaryFill, tertiaryFill
        case separator
    }

    public let blurEffect: BlurEffect
    public let style: Style?

    public init(blurEffect: BlurEffect) {
        self.blurEffect = blurEffect
        self.style = nil
    }

    public init(blurEffect: BlurEffect, style: Style) {
        self.blurEffect = blurEffect
        self.style = style
    }
}
