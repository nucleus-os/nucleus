public import NucleusTypes

// The backdrop discriminant enums and the visual-effect value are wire-owned:
// `Step.SwiftInterfaceEmit` emits them into `NucleusTypes` from the wire
// schema (the single source of truth for their integer encodings). These
// typealiases preserve the producer-facing names so call sites read the same
// as before; `BackdropMaterial` *is* the generated `NucleusTypes.VisualEffect`,
// with typed accessors (`material`, `emphasized`, `shapeRect`, …) over the
// pinned wire layout. No hand-written domain mirror or wire adapter remains.

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
    // `blendingMode: .behindWindow` is the historical default for every
    // backdrop material; it is inert for `.none` (the consumer ignores
    // blending mode when the material is none) but pins the wire bytes so the
    // collapse stays byte-for-byte wire-transparent.
    public static let none = BackdropMaterial(material: .none, blendingMode: .behindWindow, opacity: 0)
    public static let popover = BackdropMaterial(material: .popover, blendingMode: .behindWindow, cornerRadius: 18, opacity: 1)
    public static let hudWindow = BackdropMaterial(material: .hudWindow, blendingMode: .behindWindow, cornerRadius: 18, opacity: 1)

    /// Returns this material with `tint.a` (mix factor) attenuated by
    /// `factor` (clamped to [0, 1]).
    package func attenuatingTint(by factor: Float) -> BackdropMaterial {
        var copy = self
        copy.tint = NucleusTypes.Color(r: tint.r, g: tint.g, b: tint.b, a: tint.a * max(0, min(1, factor)))
        return copy
    }
}
