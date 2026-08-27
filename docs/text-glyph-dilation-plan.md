# Luminance-based glyph dilation plan

**Status: active.**

**Invariant: glyph weight compensation is a text-rendering concern applied in the Skia text backend from resolved foreground/background luminance. It does not create a second glyph atlas or a compositor-specific text path.**

## Phase 1 — Establish measurements and policy

Add golden and numeric contrast fixtures for representative sizes, weights, scales, and light/dark backgrounds. Define a bounded dilation curve in physical pixels and disable it when background luminance is unknown.

## Phase 2 — Carry background context

Extend the text draw request with resolved background luminance or an explicit unavailable state. Preserve that value through retained rendering without exposing Skia types in Swift domain models.

## Phase 3 — Apply the Skia effect

Implement the compensation in the existing Skia text paint path using the smallest supported mask/filter operation. Cache only immutable derived paint state and key it by every value that changes output.

## Phase 4 — Integrate and qualify

Enable the policy for NucleusUI text, validate fractional scale and HDR/color-managed outputs, and profile glyph-cache behavior and frame cost. Reject the feature if it destabilizes layout metrics or causes visible haloing.
