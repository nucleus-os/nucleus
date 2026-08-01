# Render Value Model Simplification Plan

Status: active.

## Invariant

The render path is an in-process Swift pipeline, not a binary wire protocol.
Types model semantic state, not an obsolete cross-language ABI.

A value used unchanged by multiple stages has one Swift type, owned by the
lowest dependency module that all users can import. A stage owns a distinct
type only when it changes the value's meaning, precision, lifetime, ownership,
validation state, or representation. Conversion between distinct stage types
is explicit semantic lowering.

Same-build Swift contracts do not preserve raw-value correspondence, reserved
padding, fixed C layout, unknown-discriminator fallback, or packet-shaped
storage. Those constraints exist only beside an actual byte encoder, socket
protocol, kernel ABI, Wayland protocol, D-Bus contract, or C/C++ entry point
that requires them.

## Target Architecture

The render path has three semantic stages:

1. `NucleusUI` owns AppKit- and UIKit-shaped authoring behavior.
2. `NucleusLayers` owns committed layer mutations and resource references.
3. `NucleusRenderModel` owns renderer-retained state and presentation state.

`NucleusTypes` remains the dependency-leaf module for values genuinely shared
unchanged across those stages and for values required by leaf host protocols.
It is a normal hand-maintained Swift module. It is not generated, does not own
an implied wire format, and does not define a second packet representation of
`NucleusLayers` transactions.

Ownership follows these rules:

- `NucleusTypes` owns shared geometry, color, transform, handle, paint-command,
  paint-payload, coordinate-space, and small shared discriminator values.
- `NucleusLayers` owns layer descriptors, sparse property mutations, layer
  transaction batches, layer content, content sampling, background-effect
  regions, and other producer-side composites.
- `NucleusRenderModel` owns float-domain renderer geometry, retained nodes,
  presentation overrides, renderer animation slots, and enriched renderer
  values.
- `NucleusUI` owns semantic colors, palette roles, visual-effect API enums,
  affine drawing transforms, edge insets, and other UI concepts that do not
  pass through the render path unchanged.

An actual encoded format keeps an explicitly scoped name such as
`PaintPayload`, `WireEventRecord`, or a Wayland protocol record. Its encoder and
decoder live together and its representation constraints do not propagate into
unrelated Swift values.

## Current State

`NucleusLayers.LayerTransaction` constructs an `EncodedTransaction` containing
Swift arrays, tuples, optionals, and domain objects, then invokes a Swift
`CommitSink` directly. `RenderCommitSink` immediately lowers that value into a
`NucleusRenderModel.Transaction`. No bytes are serialized and no independent
implementation consumes the intermediate value.

`foundation/Sources/NucleusTypes/Types.swift` still has the shape of its retired
ABI source: raw integer backing fields, computed enum accessors with fallback
cases, reserved padding, presence masks, fixed-capacity records, and packet
records for layer operations. There is no generator over this file and no C
header or cross-language consumer requiring those layouts.

This obsolete representation has two costs. It creates duplicate types and
conversion code, and it makes layout artifacts look like current architectural
requirements. The existing `NucleusUI` duplicates are one symptom; preserving
the fictional wire owner would consolidate around the wrong abstraction.

## Phase 1 — Delete the Obsolete Layer Packet Model

The unused transaction packet declarations are removed from `NucleusTypes`:
`LayerDescriptor`, `LayerPropertyUpdate`, `LayerCreatedRecord`,
`LayerInsertRecord`, `LayerRemoveRecord`, `LayerDetachRecord`,
`LayerPropertyRecord`, `AnimationRecord`, and `AnimationRemoveRecord`.

The associated property-mask constants, reserved fields, raw discriminator
storage, and record adapters are deleted with them. `NucleusLayers` already
owns the live transaction representation, so no replacement packet types are
introduced.

`NucleusLayers.DirectBridge` is reduced to conversions that still bridge
genuinely distinct concepts. Field-copy adapters for the deleted packet model
are removed. `EncodedTransaction` is renamed to `LayerTransactionBatch` to
state what it is: an owned Swift batch handed to a commit sink. `encoded()` and
`CommitEncoder` are renamed around materializing that batch; no API in this
path uses encoding terminology.

Verification exercises transaction creation, in-memory commit sinks,
`RenderCommitSink`, render-model ingestion, resource lifetime, and completion
delivery. These tests assert the committed behavior, not the removed packet
shape.

## Phase 2 — Make `NucleusTypes` an Idiomatic Shared-Value Module

The remaining declarations in `Types.swift` are classified by ownership. A
type used only by one semantic stage moves to that stage. A type shared
unchanged remains in `NucleusTypes`. `Types.swift` is split into files named for
their concepts, including geometry, layer values, animation values, backdrop
values, paint commands, handles, and host values.

Shared composites store Swift enums directly. `_kind`, `_role`, `_state`, and
similar raw backing fields disappear. Accessors that turn an unknown integer
into an arbitrary default disappear. Reserved padding disappears. Raw types
and explicit numeric values remain only where an active algorithm requires
them, such as an `OptionSet`, table index, or encoded paint-payload field; the
requirement is documented beside the declaration.

`ClipOp` stores its semantic rectangle, radii, antialias flag, and transform
without padding fields. `VisualEffect` stores its enum properties directly and
uses semantic defaults. `ImplicitActionRow` stores `LayerRole`,
`ImplicitActionKeyPath`, and `ImplicitActionKind` directly and carries no
reserved ABI fields.

The old fixed transaction-oriented `LayerContent`, `ContentSample`, and
`BackgroundEffectRegions` declarations in `NucleusTypes` are deleted after
their live `NucleusLayers` equivalents become the sole producer-side types.
Fixed capacity is retained only where a renderer or protocol limit is active;
otherwise an array expresses a collection.

The constants representing historical C status codes are deleted when no
active C/C++ entry point consumes them. Constants still used by a real foreign
entry point move beside that entry point.

Verification covers construction, equality, mutation, invalid-input handling,
paint recording and rasterization, implicit-action registration, and backdrop
publication.

## Phase 3 — Establish Canonical Shared Value Semantics

Shared values become complete public Swift APIs rather than generated storage
containers.

`Point`, `Size`, and `Rect` use flat `Double` fields. They own `.zero`, finite
checks, rectangle emptiness, inset, union, corners, containment,
`Rect(origin:size:)`, and computed `origin` and `size` views. The existing
NucleusUI rectangle semantics remain authoritative: nonpositive dimensions are
empty, over-insetting collapses instead of inverting, and union ignores empty
or nonfinite rectangles.

`Color` represents finite normalized RGBA. Construction clamps every component
to `[0, 1]` and maps nonfinite input to zero. Components cannot be mutated into
an invalid state; operations such as replacing opacity return a new value. If
the renderer later needs extended-range color, that is introduced as a
distinct renderer color type rather than weakening the normalized UI/render
color contract.

`Transform` owns identity, finiteness, translation, rotation, scale, and its 2D
affine projection. Default construction is made semantically explicit: callers
use `.identity` or an initializer that supplies all matrix elements rather than
depending on a generated all-zero default.

`Shadow` becomes one shared value used by `NucleusUI` and `NucleusLayers`. It
owns the existing UI validation and CALayer-shaped defaults: finite offsets,
nonnegative radii, normalized opacity, opaque black color, and the documented
default offset and blur. `.none` remains the explicit absent-shadow value.
`NucleusLayers.Shadow` and its field-copy bridge are deleted.

`ImageHandle` directly stores its identifier and conforms to `Hashable` in its
owning module. The NucleusUI wrapper is deleted.

Behavior tests pin these semantic contracts, including invalid colors and
shadows, geometry edge cases, transform composition, and handle identity.

## Phase 4 — Collapse the NucleusUI Render Vocabulary

`NucleusUI.Point`, `Size`, `Rect`, `Color`, `Transform`, `Shadow`,
`ActionPolicy`, `LayerRole`, and `ImageHandle` become public typealiases to the
canonical shared values. Their relocated behavior is already present from
Phase 3, so this phase removes declarations and adapters without changing
semantics.

`wireValue`, `layersColor`, `layersShadow`, `layersTransform`, `layersPolicy`,
and `layersRole` are deleted. Callers pass the shared values directly.

`EdgeInsets` and `AffineTransform` remain NucleusUI types. `SemanticColor`,
`ColorSpec`, palettes, and visual-effect API enums remain NucleusUI concepts.
Their conversions into shared render values remain exhaustive semantic
mappings and are renamed for their destination rather than called `cValue`.
`Appearance` stays distinct from the shared backdrop appearance because UI
appearance has no automatic state.

Verification runs the NucleusUI layout, hit-testing, painting, damage,
publication, animation, image, palette, and visual-effect suites, followed by
the render-host apply suites.

## Phase 5 — Align Shared and Renderer-Retained Vocabulary

Exact enum duplicates in `NucleusRenderModel` are replaced by shared values:
`LayerRole`, `ForegroundVibrancyMode`, `ImplicitActionKind`, and
`ImplicitActionKeyPath`.

Backdrop absence is represented by the absence of a backdrop attachment or a
material of `.none`, not by a second sentinel in every property. The shared
`BackdropBlendingMode` contains `behindWindow` and `withinWindow` only.
`BackdropState` uses `followsWindowActiveState`. `BackdropAppearance` contains
`auto`, `light`, and `dark`. Renderer declarations that become exact after
these corrections are replaced by the shared types.

`NucleusRenderModel.AnimationKeyPath` remains distinct. It is not a narrowing
of the producer key path: it contains renderer-owned transform-component and
compound-frame slots, while the producer path contains authored properties
that may not lower to renderer animations. The types are renamed
`LayerAnimationKeyPath` and `RenderAnimationKeyPath` so their stage ownership
is explicit. Lowering is an exhaustive switch returning `nil` for intentionally
unsupported producer properties. No raw-value relationship exists or is
tested.

Renderer geometry remains distinct where it changes precision or meaning.
Generic duplicate names are replaced with semantic names such as
`RenderRect`, `Bounds`, `Point2D`, `Frame`, and `M44`. Conversion from shared
`Double` geometry to renderer `Float` geometry stays in
`RenderTransactionLowering` and is tested for the accepted finite range.

Enriched renderer types remain renderer-owned, including associated-value
layer kinds, backdrop masks, effect shapes, content deltas, retained animation
records, and presentation overrides.

Verification covers every supported producer-to-renderer animation property,
every explicitly rejected property, backdrop creation and removal, implicit
actions, geometry precision conversion, and retained-tree application.

## Phase 6 — Remove Wire and Generated Vocabulary

Comments and APIs in the in-process render path stop using `wire`, `ABI`,
`generated`, `C-compatible`, `pinned`, and `encoded` when those words do not
describe a real boundary. `RenderTransactionLowering` remains a lowering
surface because it performs genuine semantic transformation.

Conversion names state direction and meaning: `lowerBackdrop`,
`makeRenderShadow`, `makeRenderGeometry`, or similarly specific names. A
conversion that has become identity is deleted instead of renamed.

`NUCLEUS_LAYERS_PUBLIC_NAMES` is removed from the package manifest. Its
always-taken conditional blocks are made unconditional, and the public aliases
they provide remain ordinary declarations.

Repository documentation is updated to describe the direct Swift commit path.
References to a generated render schema or wire-stable render discriminants are
deleted. Documentation for actual encoded formats remains scoped to those
formats.

Verification includes a complete build and test run through Collider after
sourcing `tools/host-env.sh`, plus formatting of every touched Swift file with
the pinned toolchain's `swift-format` and the root `.swift-format` contract.

## Enforcement

Behavior and exhaustive semantic lowering enforce the architecture.

- Shared values have tests for their public invariants.
- Distinct stage types have exhaustive conversions with no raw-value casts.
- Unsupported lowering is represented explicitly by `nil`, a typed error, or a
  documented precondition chosen by the caller's contract.
- New enum cases force all relevant switches to be reconsidered.
- Tests do not inspect source shape or assert that declarations are absent.
- Actual byte formats test encoding, decoding, malformed input, and exact
  representation only within the module that owns the format.

## Out of Scope

This plan does not remove or weaken real protocol boundaries. Wayland records,
compositor-server event records, shell IPC, D-Bus payloads, kernel and Vulkan
structures, C/C++ entry points, and the paint payload byte blob retain the
representation rules required by their consumers.

The plan does not flatten renderer-retained state into producer state. Types
whose distinct representation carries renderer semantics remain distinct even
when they share similar field names.
