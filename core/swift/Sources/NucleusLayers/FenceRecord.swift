import NucleusTypes

/// Typed fence-hold descriptor. Replaces the legacy transaction-wide
/// `fence_holds` u32 mask with a per-record scope: `kind` selects the
/// hold mechanism, `scopeField` (for FIELD_HOLD) targets one property
/// mask bit, `scopeNodeId` is the layer it applies to, and `generation`
/// is the release token (or matched ContentGeneration for content-gating).
///
/// This is the generated wire type itself (`kind`/`scopeField` are the
/// typed `FenceKind`/`FenceField`); there are no relocated conveniences.
public typealias FenceKind = NucleusTypes.FenceKind
public typealias FenceField = NucleusTypes.FenceField
public typealias FenceRecord = NucleusTypes.FenceRecord
