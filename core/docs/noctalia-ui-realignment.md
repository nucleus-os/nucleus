# Realigning NucleusUI against what the reference actually does

**Invariant: the reference is not an AppKit application, and the places it diverges from AppKit are
the places our AppKit alignment is worth spending. Where the reference is weaker than we already
are, we stop building. Where it is structurally different, we change our model before building
anything on top of the wrong one.**

This supersedes the AppKit-alignment section of `noctalia-port-priorities.md`, which was written
from our side only.

## What the audit changed

The earlier assessment ranked the gaps as: scrolling, menus and popovers, tracking and tooltips,
pasteboard and drag-and-drop, gesture recognizers. Four of those five are now either done or wrong.

**Two things drop out entirely.** The reference has **no drag-and-drop framework** — no
`wl_data_device`, no data-offer negotiation, nothing. Every "drag" in it is ad-hoc pointer state
inside a slider, a scrollbar, or the dock's reorder. Its clipboard is copy/paste over
`wlr-data-control`, which is a service, not a UI facility. It also has **no gesture recognizers**.
Both were on our list because AppKit has them, which was the wrong reason.

**One thing is cheaper than it looked.** Menus do not need writing. `Menu`, `MenuItem`,
`WindowMenuVerb`, and a 415-line `ShellOverlayMenuView` with submenu levels already exist inside
`NucleusCompositorOverlay`. This is a move and a generalization, not new work.

**One thing is far worse than it looked, and it was not on the list at all.**

## The theming model is a structural mismatch

Ours is `SemanticColor`: a closed seven-case enum — label, secondaryLabel, tertiaryLabel,
quaternaryLabel, separator, accent, accentLabel — resolving to hardcoded RGBA against a light/dark
`Appearance`. That is AppKit's model, faithfully.

The reference's is not a superset of ours; it is a different shape. Sixteen Material-3 `ColorRole`s
with string tokens, a single global mutable `Palette`, and `ColorSpec` — a colour that is *either*
a role reference *or* a literal, carrying an alpha multiplier. Behind it sits a whole generation
pipeline: wallpaper images decoded into palettes, contrast solving, builtin and community and
custom palettes, and a template engine that exports the resolved palette into *other
applications'* config files.

And it is **reactive**. Every control subscribes to `paletteChanged()` in its constructor and
re-applies its role-derived colours to its scene nodes when the palette changes. Theme switches
cross-fade through `lerpPalette`.

We have no equivalent of any of that. A closed enum cannot express a user-authored sixteen-role
palette, and we have no invalidation path that would repaint a tree when colours change underneath
it.

**This blocks the control kit.** A control written against `SemanticColor` bakes in a colour
decision at every draw call. Ten controls built now are ten controls rewritten when the palette
model lands. The theming model has to come first for the same reason the bounds-origin model came
before tracking areas.

## Focus traversal is missing, and was never listed

The reference has a complete keyboard-focus system: `tabStop`, `tabFocusKey` (a string identity so
focus survives a subtree rebuild), `excludeSubtreeFromTabOrder`, `cycleTabFocus(reverse)`,
`cycleTabFocusInSubtree`, `stashTabFocus`/`restoreStashedTabFocus`, `firstTabFocusUnder`, plus a
`RovingListNavController` and split-pane focus traversal.

We have a responder chain and `makeFirstResponder`, and **no tab order at all**. The settings
window, the launcher, and every dialog need it. This is a genuine hole that neither the AppKit
comparison nor the widget-count analysis surfaced, because AppKit's key-view loop is old enough to
be invisible and the battery widget never wanted one.

## Where we are ahead, and should stop

**Animation.** The reference has scalar tweens with seven fixed easings — no springs, no keyframes,
no implicit animation. Our layers tier already has bezier *and* spring curves, and animatable
keypaths for opacity, position, bounds, transform, corner radius, borders, and scroll offset. We
are ahead on capability and behind only on *exposure*: no `View` can reach any of it. The work is a
seam, not an engine.

Two things there are worth copying rather than inventing: a global reduce-motion and speed scale
(their `MotionService`), and cancelling animations by owner.

**Accessibility.** The reference has none — no AT-SPI, no accessibility tree anywhere. We have
accessibility properties on every view. Keep them; expect no guidance from the reference.

**Text.** Roughly at parity. They have paragraph layout, cursor stops, grapheme breaks, styled
runs, and ellipsize modes; we have text layout with glyph positions, selection rects, affinity, and
an editor model with undo coalescing and word navigation. Their `MarkdownView` is the one piece we
lack, and notifications need it.

## Icons are glyphs, not bitmaps

This reframes the image gap. The reference's primary icon path is an **icon font**: a `Glyph`
control, a `GlyphNode`, a `GlyphRegistry`, and a dedicated single-glyph renderer that bypasses
paragraph layout. Bitmaps are the minority case — wallpaper, custom images, tray icons, album art.

We have no `ImageHandle` producer at all: `GraphicsContext.draw(_ image:in:)` and `ImageView` both
exist, and nothing in the Swift tree can construct a handle to hand them. But the first thing to
build is glyph rendering, which our font and text stack can largely serve, not a PNG decoder.

## Smaller divergences that matter

**Scroll fidelity.** The reference carries `axisValue120` — high-resolution wheel deltas — and
accumulates detents so a free-spinning touchpad and a ratcheted wheel behave the same. Our
`ScrollView` consumes raw deltas and will feel wrong on both. Cheap to fix, and very visible.

**Variable row heights.** Their `VirtualListView` measures each item and caches heights, and its
adapter carries `itemKey` and `itemRevision` for identity across reloads. Our `ListView` is
uniform-height only. Notifications and markdown bodies are not uniform.

**Flex wrap.** Their `Flex` wraps onto multiple lines. Our `StackView` does not.

**Hit shapes and outsets.** Their `InputArea` supports a circular hit shape and per-side hit-test
outsets, so a small control can have a large touch target. Ours is rectangular and exact.

**Live tooltips.** Their tooltip provider carries a *refresh interval*, so a tooltip showing a
throughput figure updates while it is open. Ours computes once at display time.

## The revised order

Sequenced so nothing is built against a model that is about to change.

**Phase 6 — The palette and the theming model.** Roles, `ColorSpec`, a palette that can be
replaced at runtime, and the invalidation path that repaints a tree when it is. `SemanticColor`
resolves through it rather than beside it. Everything visual afterwards is authored against roles.

**Phase 7 — Focus traversal.** Tab order, focus keys stable across rebuilds, subtree exclusion,
directional and roving list navigation. Lands before the control kit, because a control that cannot
be tabbed to is half a control.

**Phase 8 — Animation at the view tier, and reduce-motion.** Exposing what the layers tier already
does, plus the global motion switch and cancel-by-owner.

**Phase 9 — Glyphs and images.** An icon-font glyph view and registry first; an `ImageHandle`
producer second, for wallpaper, tray, and album art.

**Phase 10 — Scroll and list fidelity.** High-resolution wheel and detent accumulation, variable
row heights with a height cache, and keyed adapter identity.

**Phase 11 — The control kit.** The full set the reference defines, now authored against roles and
tabbable: toggle, slider, range slider, checkbox, radio, select, segmented, stepper, progress,
spinner, separator, collapsible, and the pickers.

**Phase 12 — Menus, lifted.** Generalize the compositor overlay's menu into NucleusUI.

**Phase 13 — The remaining bar services.** PipeWire, NetworkManager, BlueZ, StatusNotifierItem,
logind, backlight and gamma, each with its widget.

**Phase 14 — The bar, natively.** The sum of everything above.

## What this does not change

The authoring model stays retained and imperative; nothing in the audit disturbs
`ui-authoring-model.md`. The reference's own declarative builders and reconciler exist to serve its
Luau plugin host, which is the conclusion that document already reached — and the audit confirms
the plugin surface is what constrains its widget API to be expressible as data.

Flexbox over Auto Layout is confirmed correct: the reference's layout is `measure`/`arrange` with
`LayoutConstraints` and `flexGrow`, which is very nearly our own. Our layout engine is the closest
match of anything in the two systems.
