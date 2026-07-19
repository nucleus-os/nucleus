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

**But it scopes tightly, which is the good news.** Only *colour* is data-driven in the reference.
Font sizes, spacing, radii, control heights, border widths, and animation durations are all
compile-time constants in a `Style` namespace — 11/13/14/16/20 for text, 4/8/12/16 for spacing,
3/6/9/12 for radii. Exactly two runtime knobs escape: a corner-radius scale and a
button-borders toggle, each with its own change signal. Font *family* is runtime; font *size* is
not.

So this phase is a palette, a role-or-literal colour spec, and a repaint path. It is not a design-token
system, and chasing one would be building something the reference deliberately does not have.

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

## Icons are three unrelated systems, not one

This reframes the image gap, and it is bigger than "add a decoder".

**Font glyphs are the primary path.** A `Glyph` control, a `GlyphNode`, and a single-glyph renderer
that bypasses paragraph layout entirely. The catalog is Tabler Icons, bundled as a TTF plus a JSON
name→codepoint map, so most shell iconography is a *named string* resolved to a codepoint and
tinted by a colour role — free recolouring, free scaling, no texture.

**XDG icon-theme lookup is separate**, and needed by anything showing a third-party application:
the taskbar, the dock, the tray, the launcher. Size-aware — prefers scalable SVG, and among bitmaps
takes the smallest theme size at or above the target rather than crushing a 1024px PNG. Cached,
with a generation counter and a poll source watching for theme changes at runtime.

**File loading is a third path**: SVG rasterized at target size through Skia's own SVG module,
`data:` URIs with base64 and MIME sniffing, raster through stb, and animated GIF with disposal
compositing and memory caps. Behind it sit an async texture cache and a thumbnail service, loading
off the UI thread with a ready callback.

Their `Image` control also takes an **external texture handle** directly, which is the same shape as
our `ImageHandle` — so our seam is right and only its producers are missing. There is also
app-icon colorization: recolouring a third-party icon toward the palette.

We have no `ImageHandle` producer at all. Glyphs come first because they cover most of the
iconography and our font stack largely serves them; XDG theme lookup comes second because the
taskbar and tray cannot work without it; general file loading and animation come last.

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

**Phase 9 — Glyphs, then icon themes, then files.** A glyph view and a name→codepoint registry over
a bundled icon font first, since it covers most of the iconography and the font stack largely
serves it. XDG icon-theme resolution second, size-aware and cached, because the taskbar, dock, and
tray cannot work without it. General file loading — SVG through Skia's SVG module, raster, animated
GIF — and the async texture cache last.

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
