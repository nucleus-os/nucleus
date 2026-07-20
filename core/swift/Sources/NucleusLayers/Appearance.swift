/// Appearance variant carried by retained layer material descriptions.
///
/// `.light` corresponds behaviorally to Aqua and `.dark` to Dark Aqua.
/// Nucleus does not model named appearance bundles or the legacy vibrant
/// appearance names; semantic material resolution carries that responsibility.
public enum Appearance: Sendable, Equatable {
    case dark
    case light
}
