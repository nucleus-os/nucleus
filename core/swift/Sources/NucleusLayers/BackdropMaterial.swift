public import NucleusTypes

// Backdrop discriminators and the semantic visual-effect value pass unchanged
// through authoring and commit, so NucleusTypes owns them.

public typealias BackdropMaterialKind = NucleusTypes.BackdropMaterialKind
public typealias BackdropBlendingMode = NucleusTypes.BackdropBlendingMode
public typealias BackdropState = NucleusTypes.BackdropState
public typealias BackdropAppearance = NucleusTypes.BackdropAppearance
public typealias BackdropMask = NucleusTypes.BackdropMask
public typealias EffectShape = NucleusTypes.EffectShape

/// Producer-side description of a backdrop. Role-level only — kernel
/// parameters (passes/offset/noise/saturation/alpha) are decided by the
/// consumer-side BackdropCatalog from `(material, state, appearance)` plus
/// the per-appearance intensity override.
public typealias BackdropMaterial = NucleusTypes.VisualEffect

extension NucleusTypes.VisualEffect {
    // The consumer ignores blending mode when the material is `.none`.
    public static let none = BackdropMaterial(
        material: .none, blendingMode: .behindWindow, opacity: 0)
    public static let popover = BackdropMaterial(
        material: .popover, blendingMode: .behindWindow, cornerRadius: 18, opacity: 1)
    public static let hudWindow = BackdropMaterial(
        material: .hudWindow, blendingMode: .behindWindow, cornerRadius: 18, opacity: 1)

    /// Returns this material with `tint.a` (mix factor) attenuated by
    /// `factor` (clamped to [0, 1]).
    package func attenuatingTint(by factor: Float) -> BackdropMaterial {
        withTint(
            NucleusTypes.Color(
                r: tint.r, g: tint.g, b: tint.b, a: tint.a * max(0, min(1, factor))))
    }
}
