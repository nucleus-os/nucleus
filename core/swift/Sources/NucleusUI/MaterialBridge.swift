import NucleusLayers

/// Internal bridge between the AppKit-shaped public API
/// (`VisualEffectView.Material`, `BlurEffect.Style`, ...) and the
/// substrate `BackdropMaterial` / `BackdropMaterialKind`. Centralizes
/// the legacy → modern style collapse so `MaterialBridge` is the single
/// table to update when extending the catalog.
enum MaterialBridge {

    struct ResolvedStyle {
        var material: VisualEffectView.Material
        var isEmphasized: Bool
        /// Legacy explicit-appearance styles force the appearance to
        /// `.light` or `.dark`; adaptive styles leave it nil (inherit).
        var forcedAppearance: Appearance?
    }

    /// `BlurEffect.Style` → modern AppKit material + appearance forcing.
    static func material(for style: BlurEffect.Style) -> ResolvedStyle {
        switch style {
        // Adaptive system materials (modern UIKit naming).
        case .systemUltraThinMaterial:
            ResolvedStyle(material: .toolTip, isEmphasized: false, forcedAppearance: nil)
        case .systemThinMaterial:
            ResolvedStyle(material: .headerView, isEmphasized: false, forcedAppearance: nil)
        case .systemMaterial:
            ResolvedStyle(material: .contentBackground, isEmphasized: false, forcedAppearance: nil)
        case .systemThickMaterial:
            ResolvedStyle(material: .windowBackground, isEmphasized: false, forcedAppearance: nil)
        case .systemChromeMaterial:
            ResolvedStyle(material: .titlebar, isEmphasized: false, forcedAppearance: nil)
        // Explicit light variants.
        case .systemUltraThinMaterialLight:
            ResolvedStyle(material: .toolTip, isEmphasized: false, forcedAppearance: .light)
        case .systemThinMaterialLight:
            ResolvedStyle(material: .headerView, isEmphasized: false, forcedAppearance: .light)
        case .systemMaterialLight:
            ResolvedStyle(material: .contentBackground, isEmphasized: false, forcedAppearance: .light)
        case .systemThickMaterialLight:
            ResolvedStyle(material: .windowBackground, isEmphasized: false, forcedAppearance: .light)
        case .systemChromeMaterialLight:
            ResolvedStyle(material: .titlebar, isEmphasized: false, forcedAppearance: .light)
        // Explicit dark variants.
        case .systemUltraThinMaterialDark:
            ResolvedStyle(material: .toolTip, isEmphasized: false, forcedAppearance: .dark)
        case .systemThinMaterialDark:
            ResolvedStyle(material: .headerView, isEmphasized: false, forcedAppearance: .dark)
        case .systemMaterialDark:
            ResolvedStyle(material: .contentBackground, isEmphasized: false, forcedAppearance: .dark)
        case .systemThickMaterialDark:
            ResolvedStyle(material: .windowBackground, isEmphasized: false, forcedAppearance: .dark)
        case .systemChromeMaterialDark:
            ResolvedStyle(material: .titlebar, isEmphasized: false, forcedAppearance: .dark)
        // Legacy pre-iOS-13 styles. Collapsed onto the closest modern
        // adaptive material; appearance is carried for the light/dark
        // pair so visual intent survives.
        case .extraLight:
            ResolvedStyle(material: .headerView, isEmphasized: false, forcedAppearance: .light)
        case .light:
            ResolvedStyle(material: .contentBackground, isEmphasized: false, forcedAppearance: .light)
        case .dark:
            ResolvedStyle(material: .contentBackground, isEmphasized: false, forcedAppearance: .dark)
        case .regular:
            ResolvedStyle(material: .contentBackground, isEmphasized: false, forcedAppearance: nil)
        case .prominent:
            ResolvedStyle(material: .windowBackground, isEmphasized: true, forcedAppearance: nil)
        }
    }

    /// Reverse mapping: synthesize a `BlurEffect` from a view's current
    /// `material`/`blendingMode`/`isEmphasized`. Used by
    /// `VisualEffectView.effect` getter. Picks the closest adaptive
    /// style so round-tripping via `init(effect:)` does not lose the
    /// inherited-appearance default.
    static func effect(material: VisualEffectView.Material, blendingMode: VisualEffectView.BlendingMode, isEmphasized: Bool) -> VisualEffect? {
        let style: BlurEffect.Style? = switch material {
        case .toolTip: .systemUltraThinMaterial
        case .headerView: .systemThinMaterial
        case .contentBackground: .systemMaterial
        case .windowBackground: .systemThickMaterial
        case .titlebar: .systemChromeMaterial
        default: nil
        }
        return style.map { BlurEffect(style: $0) }
    }

    /// Build a substrate `BackdropMaterial` from the AppKit-typed
    /// fields. Producer-side only; the consumer-side `BackdropCatalog`
    /// owns the actual chain parameters.
    static func backdropMaterial(
        material: VisualEffectView.Material,
        blendingMode: VisualEffectView.BlendingMode,
        state: VisualEffectView.State,
        isEmphasized: Bool,
        cornerRadius: Double,
        opacity: Double,
        appearance: Appearance,
        maskImage: ImageHandle?
    ) -> BackdropMaterial {
        let radius = max(0, cornerRadius)
        return BackdropMaterial(
            material: kind(for: material),
            blendingMode: blendingMode.cValue,
            state: state.cValue,
            appearance: appearance.backdropAppearance,
            emphasized: isEmphasized,
            maskKind: maskImage == nil ? .none : .image,
            shapeKind: radius > 0 ? .rrect : .rect,
            cornerRadius: radius,
            opacity: opacity,
            maskImageHandle: maskImage.map { $0.id } ?? 0,
            shapeRadius: SIMD4<Float>(Float(radius), Float(radius), Float(radius), Float(radius))
        )
    }

    static func kind(for material: VisualEffectView.Material) -> BackdropMaterialKind {
        switch material {
        case .titlebar: .titlebar
        case .selection: .selection
        case .menu: .menu
        case .popover: .popover
        case .sidebar: .sidebar
        case .headerView: .headerView
        case .sheet: .sheet
        case .windowBackground: .windowBackground
        case .hudWindow: .hudWindow
        case .fullScreenUI: .fullScreenUi
        case .toolTip: .toolTip
        case .contentBackground: .contentBackground
        case .underWindowBackground: .underWindowBackground
        case .underPageBackground: .underPageBackground
        }
    }
}

extension VisualEffectView.BlendingMode {
    package var cValue: BackdropBlendingMode {
        switch self {
        case .behindWindow: .behindWindow
        case .withinWindow: .withinWindow
        }
    }
}

extension VisualEffectView.State {
    package var cValue: BackdropState {
        switch self {
        case .followsWindowActiveState: .followsWindowActiveState
        case .active: .active
        case .inactive: .inactive
        }
    }
}

extension Appearance {
    package var backdropAppearance: BackdropAppearance {
        switch self {
        case .light: .light
        case .dark: .dark
        }
    }
}
