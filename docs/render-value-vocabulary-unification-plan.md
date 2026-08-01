# Render Value Vocabulary Unification Plan

Status: active.

## Invariant

One concept in the render stack has one Swift type. `NucleusTypes` owns the
value vocabulary that crosses the render boundary. A module may narrow or
enrich that vocabulary when it carries information the wire type cannot, and it
may extend the wire types with behavior. No module redeclares a wire type whose
fields and cases it reproduces exactly.

Where a module does declare a narrowed or enriched type, conversion to and from
the wire vocabulary is an exhaustive `switch` over cases or an explicit field
mapping. No conversion reinterprets a raw value, and no type documents raw-value
compatibility with a type it is not compiled against.

## Current State

Four modules describe the same render vocabulary.

[`NucleusTypes`](../foundation/Sources/NucleusTypes/Types.swift) is the
generated wire vocabulary: 1,148 lines declaring `Point`, `Size`, `Rect`,
`Color`, `Transform`, `Shadow`, `LayerRole`, `ActionPolicy`, the backdrop
enums, the animation enums, and the layer records.

[`NucleusLayers`](../core/swift/Sources/NucleusLayers) is the reference
implementation of this invariant. It declares 30 `public typealias`
declarations onto `NucleusTypes` and states the rule in
[`Geometry.swift`](../core/swift/Sources/NucleusLayers/Geometry.swift): the
geometry value types are the wire types themselves, the `.zero` conveniences
are the only relocated logic, and no domain-to-wire adapter remains.

[`NucleusUI`](../core/swift/Sources/NucleusUI) does not follow it. It
redeclares `Point`, `Size`, `Rect`, `Color`, `Transform`, `Shadow`,
`ActionPolicy`, and `LayerRole`, and wraps `ImageHandle`. It carries 19
converter members — `wireValue`, `layersPolicy`, `layersRole`, `layersColor`,
`layersShadow`, `layersAppearance`, `layersTransform`, `cValue` — and those
converters are called from 75 sites across 16 files.

[`NucleusRenderModel`](../core/swift/Sources/NucleusRenderModel) redeclares a
further 20 names. Some are genuine enrichment. Several are not.

The result is that `Rect` names four distinct types across
`NucleusTypes`, `NucleusUI`, `NucleusRenderModel`, and
`NucleusCompositorWindowManager`, and `LayerRole`, `Shadow`, `LayerContent`,
`ContentSample`, `BackgroundEffectRegions`, and `LayerPropertyUpdate` each name
three.

## Classification

Every duplicated declaration falls into exactly one of three categories, and
each category has a different disposition.

### Category A — Exact redeclaration

Fields and cases reproduce the wire type with no narrowing and no added
information. These carry a converter that is pure ceremony.

In `NucleusUI`: `Point` and `Size` (identical `Double` fields), `Rect` (the
same rectangle, stored nested as `origin`/`size` rather than flat
`x`/`y`/`width`/`height`), `Color` (identical `Float` RGBA), `Transform`
(identical 4×4 `Double` matrix), `Shadow` (identical six fields),
`ActionPolicy` and `LayerRole` (identical cases in identical order),
`ImageHandle` (a wrapper holding `NucleusTypes.ImageHandle` as its storage).

In `NucleusRenderModel`: `ForegroundVibrancyMode` (`inherit`, `none`, `light`,
`dark`), `ImplicitActionKind` (`spring = 1`, `scalar = 2`), and
`ImplicitActionKeyPath` (`frame = 1`, `opacity = 2`).

`ImplicitActionKeyPath` additionally exists a third time as the nested
`ImplicitActionEntry.KeyPath` in
[`NucleusLayers/ImplicitActionPolicy.swift`](../core/swift/Sources/NucleusLayers/ImplicitActionPolicy.swift),
with the same two cases and the same raw values.

### Category B — Divergent encoding of the same concept

The same concept declared twice with encodings that do not agree. This is the
category that carries risk.

`BackdropBlendingMode` is declared in `NucleusRenderModel` as
`behindWindow = 0`, `withinWindow = 1`. The wire enum is `none = 0`,
`behindWindow = 1`, `withinWindow = 2`. The render-model declaration is
preceded by a comment stating its raw values are pinned to the wire encoding.
They are not. `RenderLayerStyleTests` asserts
`behindWindow.rawValue == 0 && withinWindow.rawValue == 1` under the name
`blending-wire-values`, so a test currently locks in the mismatch and names it
after the invariant it violates.

`BackdropState` is declared in `NucleusRenderModel` as `active`, `inactive`,
`followsWindowActive`; the wire enum's third case is
`followsWindowActiveState`. The ordinals coincide; the names do not.

`AnimationKeyPath` is declared in `NucleusRenderModel` as `UInt8` beginning
`positionX`, `positionY`, `opacity`; the wire enum is `UInt32` beginning
`none = 0`, `opacity = 1`, `cornerRadius = 2`, `positionX = 3`, `positionY = 4`.
Both the width and the numbering differ.

Nothing crosses these boundaries by raw value today —
[`RenderTransactionLowering`](../core/swift/Sources/NucleusRenderHost/RenderTransactionLowering.swift)
converts through eight explicit `…FromWire` functions over 616 lines. The
defect is that the declarations claim an alignment the code does not rely on
and does not have, so the next reader who trusts the comment and reaches for
`rawValue` introduces a silent miscompilation of backdrop blending.

One raw-value bridge already exists.
[`ImplicitActionPolicy.swift`](../core/swift/Sources/NucleusLayers/ImplicitActionPolicy.swift)
constructs `NucleusTypes.ImplicitActionKeyPath(rawValue: entry.keyPath.rawValue)!`
at two sites. It is correct today only because two independently maintained
declarations happen to agree, and it force-unwraps in a codebase that otherwise
contains four `fatalError` sites and two `try!` sites across 1,021 non-test
source files.

### Category C — Genuine enrichment

The module type carries information the flat wire discriminator cannot, and the
two must stay distinct.

`NucleusRenderModel.LayerKind` carries `backdrop(BackdropKindParams)` and
`remoteHost(ContextID)` against a flat `none`/`container`/`backdrop`/`host`
wire enum. `NucleusRenderModel.BackdropMask` carries `roundedRect(Float)` and
`image(SnapshotHandle)`. `NucleusRenderModel.EffectShape` carries
`rect(Float4)` and `rrect(rect:radii:)`. These stay as they are.

## Phase 1 — Correct the Divergent Encodings

The false claims are removed before any mechanical replacement, because a
subsequent phase that collapses a type must not inherit a documented invariant
that was never true.

The comment asserting wire-pinned raw values is deleted from
`NucleusRenderModel.BackdropBlendingMode`. The `blending-wire-values`
assertions in `RenderLayerStyleTests` are replaced by a round-trip test: every
`NucleusLayers.BackdropBlendingMode` case lowers through
`blendingModeFromWire` and the result maps back to the originating case. That
test asserts the property the renderer actually depends on, and it fails if
either declaration gains, loses, or reorders a case.

`NucleusRenderModel.BackdropState.followsWindowActive` is renamed to
`followsWindowActiveState` to match the wire vocabulary. The name divergence is
the only thing that makes the two enums look like different concepts.

`AnimationKeyPath` in `NucleusRenderModel` keeps its narrower case set and its
`UInt8` width — the render model has no representation for the wire `none` —
and gains the same round-trip test. Its declaration states that it is a
narrowing of the wire enum and that no raw-value correspondence exists.

## Phase 2 — Collapse the NucleusUI Geometry Vocabulary

`Point`, `Size`, and `Rect` stop being NucleusUI declarations and become the
`NucleusTypes` types, following the pattern already established in
`NucleusLayers`.

NucleusUI's geometry *behavior* is preserved and moves to extensions on the
wire types: `isFinite` on all three, and `isEmpty`, `insetBy(dx:dy:)`,
`insetBy(_:)`, `union(_:)`, `corners`, and `contains(_:)` on `Rect`. The
documented semantics stay with them — that a rectangle with either nonpositive
dimension is empty, that a rectangle inset past its own size collapses to zero
rather than inverting, and that `union` ignores an empty rectangle rather than
including it.

`Rect.origin` and `Rect.size` become computed properties over the flat wire
fields, so NucleusUI call sites that compose and decompose rectangles are
unaffected. `Rect(origin:size:)` is retained as an initializer.

The six `wireValue` members in
[`NucleusUI/Geometry.swift`](../core/swift/Sources/NucleusUI/Geometry.swift)
are deleted along with all 75 call sites that invoke them. `EdgeInsets` and
`AffineTransform` remain NucleusUI declarations: neither has a wire
counterpart, and `AffineTransform` is the six-scalar `GraphicsContext`
vocabulary, distinct from the 4×4 `Transform`.

Verification is the existing `NucleusUITests` layout, paint, and damage suites,
which exercise this geometry directly, plus the render-model apply tests that
consume the lowered output.

## Phase 3 — Collapse the Remaining Exact Redeclarations

The Category A types that are not geometry follow the same treatment.

In NucleusUI: `Color`, `Transform`, `Shadow`, `ActionPolicy`, and `LayerRole`
become the `NucleusTypes` types. `Color`'s component clamping moves to a
factory initializer on the wire type so the invariant survives the collapse —
the clamping is real behavior, not ceremony, and is the one piece of NucleusUI
`Color` that is not a field copy. `ImageHandle` stops wrapping
`NucleusTypes.ImageHandle` and becomes it.

The converter members deleted with them are `layersColor`, `layersShadow`,
`layersAppearance`, `layersTransform`, `layersPolicy`, `layersRole`, and both
`cValue` properties in `MaterialBridge`.

In NucleusRenderModel: `ForegroundVibrancyMode`, `ImplicitActionKind`, and
`ImplicitActionKeyPath` become the `NucleusTypes` types.

In NucleusLayers: the nested `ImplicitActionEntry.KeyPath` becomes
`NucleusTypes.ImplicitActionKeyPath`, which removes the third declaration of
that two-case enum.

## Phase 4 — Delete the Force-Unwrapped Raw-Value Bridge

With `ImplicitActionEntry.KeyPath` collapsed in Phase 3, both
`NucleusTypes.ImplicitActionKeyPath(rawValue: entry.keyPath.rawValue)!`
constructions in `ImplicitActionPolicy.wireRow` become the identity and are
replaced by `entry.keyPath`. This removes the only raw-value reinterpretation
across a vocabulary boundary in the render stack, and with it two force
unwraps.

The lowering surface in `RenderTransactionLowering` is then re-examined against
what remains. The converters that survive are exactly those bridging Category C
enrichment — `backdropMaskFromWire`, `effectShapeFromWire`,
`effectShapeRadiiFromWire`, `backdropAttachmentFromWire`, and
`materialRoleFromWire`. `blendingModeFromWire`, `backdropStateFromWire`, and
`appearanceModeFromWire` reduce to a narrowing switch that rejects the wire
`none` case explicitly rather than mapping it silently.

## Phase 5 — Remove the Always-On Conditional Compilation

`NUCLEUS_LAYERS_PUBLIC_NAMES` is defined unconditionally for the `NucleusLayers`
target in the root manifest and guards two blocks, in
[`Geometry.swift`](../core/swift/Sources/NucleusLayers/Geometry.swift) and
[`LayerTransaction.swift`](../core/swift/Sources/NucleusLayers/LayerTransaction.swift).
A define that is always set is not a configuration point; it is a permanently
taken branch that reads as one. The `#if` and `#endif` are deleted, the guarded
`public typealias` declarations are kept, and the `.define` is removed from the
target's settings.

This lands after Phase 2, because the guarded block exports
`NucleusLayers.Rect` and `NucleusLayers.Size` and the collapse changes what
those names resolve to.

## Enforcement

The invariant is held by round-trip behavior tests at each vocabulary boundary,
not by assertions about which declarations exist. Every enum that narrows or
enriches a wire enum carries a test that lowers each wire case and maps the
result back, so a case added on either side fails a test rather than
silently widening a `default` branch.

`NucleusTypes` itself is generated. Its correspondence to the wire encoding is
the responsibility of the generator and its own verification, not of the
modules downstream of it.

## Out of Scope

The Category C enrichment types stay distinct, and this plan does not flatten
them.

The remaining duplicate public type names surfaced by a repository-wide scan
are coincidental reuse in unrelated domains — `Kind`, `State`, `Severity`,
`Phase`, `Settings`, `Snapshot`, `Host`, `Event`, and `Image` are nested or
domain-local types in modules that never meet. They are not renamed.

`NucleusCompositorWindowManager.Rect` and `NucleusCompositorWindowScene.WindowScene`
are compositor-side declarations reached through the
`@_spi(NucleusCompositor)` seam. They are governed by the compositor's own
boundary and are not part of this unification.
