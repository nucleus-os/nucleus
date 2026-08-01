package import NucleusLayers

package import enum NucleusTypes.BackdropMaterialKind

/// Fully resolved render contract for one backdrop layer. Values in this type
/// cross to the renderer once per frame and are executed without further policy lookup.
package struct ResolvedBackdropMaterial: Sendable, Equatable {
    package var enabled: Bool
    package var passes: UInt8
    package var offset: Float
    package var saturation: Float
    package var tint: SIMD4<Float>
    package var tintBlend: Float
    package var noise: Float
    package var alpha: Float
    package var solidFallback: SIMD4<Float>
    package var foregroundVariant: BackdropPolicy.ResolvedAppearance
    package var resolvedState: BackdropState
    package var resolvedAppearance: BackdropPolicy.ResolvedAppearance

    package static func inactive(
        appearance: BackdropPolicy.ResolvedAppearance,
        state: BackdropState
    ) -> Self {
        let color: SIMD4<Float> =
            appearance == .light
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
package enum BackdropCatalog {
    package struct Key: Sendable, Equatable {
        package var role: BackdropMaterialKind
        package var appearance: BackdropPolicy.ResolvedAppearance
        package var reduceTransparency: Bool
        package var increaseContrast: Bool
        package var state: BackdropState
        package var emphasized: Bool
    }

    package struct Producers: Sendable, Equatable {
        package var defaultMaterial: BackdropDynamics.Material
        package var waylandMaterial: BackdropDynamics.Material
        package var shellOverlayMaterial: BackdropDynamics.Material
    }

    package static func resolve(key: Key, producers: Producers) -> ResolvedBackdropMaterial {
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
        let fallback: SIMD4<Float> =
            key.appearance == .light
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
