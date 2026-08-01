package import NucleusTypes

//
// Producers ship backdrop identity (material + appearance + state + emphasized +
// mask); the consumer-side catalog resolves it to concrete kernel params at
// presentation-lowering time. `apply` populates a backdrop layer's catalog
// fields directly; the layer commit path picks them up via the applier flow.
// Foreground-vibrancy `inherit` propagation is structural and lives on the
// layer, not here.

/// Renderer-owned helpers for applying catalog-backed visual effects.
package enum RenderVisualEffect: Sendable {
    /// Nucleus-native blending mode (AppKit `NSVisualEffectView.BlendingMode`
    /// shape).
    package enum Blending: Sendable {
        case behindWindow
        case withinWindow
    }

    /// Producer-supplied backdrop identity. The caller owns `shape` (geometry-
    /// dependent) and the parametric material override. Mirrors `Params`.
    package struct Params: Sendable {
        package var material: BackdropMaterialRole
        package var blending: Blending = .behindWindow
        package var appearance: BackdropAppearance = .auto
        package var state: BackdropState = .active
        package var emphasized: Bool = false
        package var mask: BackdropMask = .none

        package init(
            material: BackdropMaterialRole,
            blending: Blending = .behindWindow,
            appearance: BackdropAppearance = .auto,
            state: BackdropState = .active,
            emphasized: Bool = false,
            mask: BackdropMask = .none
        ) {
            self.material = material
            self.blending = blending
            self.appearance = appearance
            self.state = state
            self.emphasized = emphasized
            self.mask = mask
        }
    }

    /// Populate a backdrop `LayerKind`'s catalog fields from `params`. The
    /// `shape` field is the caller's responsibility. `blending` is carried by
    /// the producer but not yet differentiated by the consumer. Mirrors `apply`.
    package static func apply(to backdrop: inout BackdropKindParams, _ params: Params) {
        backdrop.materialRole = params.material
        backdrop.appearance = params.appearance
        backdrop.state = params.state
        backdrop.emphasized = params.emphasized
        backdrop.mask = params.mask
        _ = params.blending
    }

    /// AppKit `followsWindowActiveState` analogue scoped to emphasis: flip
    /// `emphasized` from the owning surface's key/active state. Mirrors
    /// `setEmphasizedForKeyWindow`.
    package static func setEmphasizedForKeyWindow(_ backdrop: inout BackdropKindParams, isKey: Bool)
    {
        backdrop.emphasized = isKey
    }
}
