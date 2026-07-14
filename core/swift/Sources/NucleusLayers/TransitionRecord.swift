import NucleusTypes

/// Producer-issued layer transition (Pillar: crossfade/clear handoff). `kind`
/// selects the transition mechanism, `layerId` targets the layer, `operationId`
/// correlates a producer-side operation, `generation` is the release token, and
/// `curve` is the consumer-side sampling rule.
///
/// This is the generated wire type itself (`kind` is the typed `TransitionKind`,
/// `curve` the ergonomic `AnimationCurve`); there are no relocated conveniences.
public typealias TransitionKind = NucleusTypes.TransitionKind
public typealias TransitionRecord = NucleusTypes.TransitionRecord
