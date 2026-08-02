# Render Value Model Simplification Plan

Status: complete.

## Invariant

The render path is an in-process Swift pipeline, not a binary wire protocol.
Types model semantic state, not an obsolete cross-language ABI.

A value used unchanged by multiple stages has one Swift type, owned by the
lowest dependency module that all users can import. A stage owns a distinct
type only when it changes the value's meaning, precision, lifetime, ownership,
validation state, or representation. Conversion between distinct stage types
is explicit semantic lowering.

## Completed architecture

The migration is implemented:

1. `NucleusTypes` owns the canonical shared geometry, color, transform,
   handles, animation values, layer values, paint commands, paint payloads,
   coordinate spaces, and host values. The former monolithic `Types.swift` and
   packet-shaped layer records are gone.
2. `NucleusLayers` commits `LayerTransactionBatch` directly to a Swift
   `CommitSink`. No `EncodedTransaction` or fictional in-process wire packet
   remains.
3. `NucleusUI` exposes the shared `Point`, `Size`, `Rect`, `Color`, `Transform`,
   `Shadow`, and `ImageHandle` values through type aliases and keeps UI-only
   semantics in its own module.
4. `NucleusRenderModel` retains renderer-owned geometry and animation state.
   `LayerAnimationKeyPath` lowers explicitly to `RenderAnimationKeyPath`; the
   two stages do not depend on raw-value correspondence.
5. `RenderTransactionLowering` is the single semantic lowering surface from a
   layer transaction batch into renderer-retained state.
6. Actual encoded boundaries remain scoped to their owners, including paint
   payloads, Wayland records, session IPC, D-Bus, kernel structures, and C/C++
   entry points.

## Enforcement

- Shared values have behavioral tests for their public invariants.
- Distinct stage types use exhaustive semantic conversions with no raw-value
  casts.
- Unsupported lowering is explicit.
- Tests exercise committed behavior rather than removed source shape.
- Representation tests remain beside the real encoder or foreign boundary
  that requires the representation.

The durable contract belongs in the NucleusUI graphics and runtime
architecture documents. This completed migration record can be removed after
those documents absorb the invariant and enforcement rules above.
