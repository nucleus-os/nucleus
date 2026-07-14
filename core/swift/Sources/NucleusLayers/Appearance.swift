/// System appearance variant. Mirrors `NSAppearance` in role: a named
/// bundle that, paired with a material role, decides what tint and color
/// values producers resolve to. Today only `dark` is the day-to-day surface;
/// `light` is fully populated so the resolver tables are honest, but no
/// system glue switches to it yet.
///
/// AppKit correspondence: `.light` ≘ `NSAppearance.Name.aqua`,
/// `.dark` ≘ `.darkAqua`. The historical `aqua`/`darkAqua` names are
/// modernized to `light`/`dark`. The legacy `vibrantLight`/`vibrantDark`
/// appearances are intentionally not modeled — modern AppKit moved
/// vibrancy resolution into `NSVisualEffectView.Material`, which
/// `VisualEffectView.Material` and `VibrancyEffect` already express.
public enum Appearance: Sendable, Equatable {
    case dark
    case light

    /// Process-wide fallback for views that don't specify an appearance and
    /// have no ancestor that does. Set this from system preferences when the
    /// glue lands; it is the single seam producers go through.
    @MainActor public static var systemDefault: Appearance = .dark
}
