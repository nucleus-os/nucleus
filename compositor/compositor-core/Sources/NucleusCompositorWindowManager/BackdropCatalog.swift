@_spi(NucleusCompositor) public import NucleusLayers
public import enum NucleusTypes.BackdropMaterialKind

/// Fully resolved render contract for one backdrop layer. Values in this type
/// cross to the renderer once per frame and are executed without further policy lookup.
public struct ResolvedBackdropMaterial: Sendable, Equatable {
    public var enabled: Bool
    public var passes: UInt8
    public var offset: Float
    public var saturation: Float
    public var tint: SIMD4<Float>
    public var tintBlend: Float
    public var noise: Float
    public var alpha: Float
    public var solidFallback: SIMD4<Float>
    public var foregroundVariant: BackdropPolicy.ResolvedAppearance
    public var resolvedState: BackdropState
    public var resolvedAppearance: BackdropPolicy.ResolvedAppearance

    public static func inactive(
        appearance: BackdropPolicy.ResolvedAppearance,
        state: BackdropState
    ) -> Self {
        let color: SIMD4<Float> = appearance == .light
            ? SIMD4(0.95, 0.95, 0.95, 1)
            : SIMD4(0.18, 0.18, 0.18, 1)
        return .init(
            enabled: false, passes: 0, offset: 0, saturation: 1,
            tint: color, tintBlend: 1, noise: 0, alpha: 1,
            solidFallback: color, foregroundVariant: appearance,
            resolvedState: state, resolvedAppearance: appearance
        )
    }
}

/// Swift's single role/state/appearance/accessibility material catalog.
public enum BackdropCatalog {
    public struct Key: Sendable, Equatable {
        public var role: BackdropMaterialKind
        public var appearance: BackdropPolicy.ResolvedAppearance
        public var reduceTransparency: Bool
        public var increaseContrast: Bool
        public var state: BackdropState
        public var emphasized: Bool
    }

    public struct Producers: Sendable, Equatable {
        public var defaultMaterial: BackdropDynamics.Material
        public var waylandMaterial: BackdropDynamics.Material
        public var shellOverlayMaterial: BackdropDynamics.Material
    }

    public static func resolve(key: Key, producers: Producers) -> ResolvedBackdropMaterial {
        if key.state == .inactive || key.reduceTransparency {
            return .inactive(appearance: key.appearance, state: key.state)
        }

        var material: BackdropDynamics.Material
        switch key.role {
        case .contentBackground:
            material = producers.waylandMaterial
        case .shellOverlay, .sidebar, .hudWindow, .menu, .popover, .titlebar,
             .sheet, .headerView, .selection, .toolTip:
            material = producers.shellOverlayMaterial
        default:
            material = producers.defaultMaterial
        }
        if key.increaseContrast {
            material.saturation = min(material.saturation * 1.25, 2.5)
            material.tint.w = min(material.tint.w * 1.5, 1)
        }
        let fallback: SIMD4<Float> = key.appearance == .light
            ? SIMD4(0.95, 0.95, 0.95, 1)
            : SIMD4(0.18, 0.18, 0.18, 1)
        return .init(
            enabled: material.enabled,
            passes: material.passes,
            offset: material.offset,
            saturation: material.saturation,
            tint: material.tint,
            tintBlend: min(max(material.tint.w, 0), 1),
            noise: material.noise,
            alpha: material.alpha,
            solidFallback: fallback,
            foregroundVariant: key.appearance,
            resolvedState: key.state,
            resolvedAppearance: key.appearance
        )
    }
}
