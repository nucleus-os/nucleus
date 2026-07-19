# Bar-first port order

**Invariant: the next thing to build is the first thing a user sees. Every phase below
either puts a working bar on screen or is required by one that does — and the toolkit
stops widening until it does.**

This supersedes the phase order in `noctalia-ui-realignment.md` from phase 10 onward.
That order was written to close gaps against AppKit and against the reference's *whole*
widget library. Both audits have since been redone, and both say the same thing: we are
building breadth we do not yet have a consumer for.

## What the re-audit changed

**The reference is ~262,000 lines, and 15% of it is two subsystems a bar does not need.**
The settings window (24,362) and control center (16,212) together are 40,574 lines. Neither
is required for a bar to work; the reference is configured by TOML and driven by IPC, and
its settings window is a GUI over the same TOML. Deferring both roughly halves the port.

**We already have most of what a minimal bar needs.** The reference's own foundation is
flex, box, label, glyph, image, button, progress bar, separator, spacer. We have seven of
those nine — `StackView`, `View` styling, `Label`, `GlyphView`, `ImageView`, `Button`, and
the layout system underneath them. The gap is three trivial views, not a control kit.

**So the control kit was mis-scoped.** Toggle, slider, range slider, checkbox, radio,
select, segmented, stepper, colour picker, keybind recorder — these are the settings and
control-center vocabulary. The audit's usage ranking is unambiguous: `flex`/`box`/`label`/
`glyph`/`button` are universal; `input`/`select`/`toggle`/`slider`/`checkbox` are "settings
and control-center workhorses". Building them now is building for a surface we have chosen
not to port yet, and every one of them would be written against a bar that does not exist
to check them against.

**Two subsystems were missing from the order entirely.** Configuration and IPC. The
reference's config is 12,626 lines across ~443 typed schema fields, with inotify
hot-reload, per-monitor and per-bar overrides, validation diagnostics, atomic writes, and
migrations. Its IPC is a Unix socket with 91 self-documenting commands, registered
distributed-style by each service. Neither is optional: config is how a bar is composed,
and IPC is how everything is bound to keys and scripted. A bar with a hardcoded widget list
is a demo, not the product.

## Defects to clear first

These are not gaps, they are wrong behaviour in shipped code. Each is small, and each is a
trap for anything built on top of it.

`View.transform` publishes to the backing layer, but `hitTest` and both window-space
conversions apply only `frame.origin` and `boundsOrigin`. A scaled or rotated view draws
transformed and hit-tests untransformed. `convert(_ rect:)` passes `size` through unchanged
and so cannot represent a scaled rect at all. Either transforms participate in hit testing
and conversion, or `transform` stops being public — the current state is the one option
that silently misleads.

`GraphicsContext.rotateBy` degrades every non-path draw to an axis-aligned bounding box:
`setGeometry` transforms two corners and keeps `min`/`abs` extents. Rotated images, text,
and rect fills render unrotated at the wrong size, while paths rotate correctly. The
asymmetry is invisible until something rotates.

`lineCap` and `lineJoin` are public settable state that nothing ever reads.

`fadeOut` assigns `alphaValue = 0` on the animated path as well as the reduce-motion path,
publishing a property update on the same keypath the compositor is animating.

`KeyCode` has seventeen members — arrows, escape, return, tab, space, delete, home/end/page.
No letters, digits, or function keys, so no shortcut is expressible. This blocks the
launcher and any keybinding, and it blocks IPC's usefulness less than it looks (IPC is
driven by the compositor's own keybinds), but it blocks in-shell shortcuts entirely.

## Phase 1 — clear the defects

The five above. `transform` participating in hit testing and coordinate conversion is the
only one with design content: the honest fix is to carry the transform through
`convert`/`hitTest` as a real matrix, because a shell animates scale on hover and will hit-
test mid-animation.

`KeyCode` grows to cover letters, digits, and function keys as part of this phase, since
every later phase that wants a shortcut needs it and widening an enum late means touching
every switch over it.

## Phase 2 — scroll fidelity

High-resolution wheel deltas (`axisValue120`) and detent accumulation, so a free-spinning
touchpad and a ratcheted wheel behave the same. `Event` already carries
`hasPreciseScrollingDeltas`; it does not carry phase or momentum, and its own doc comment
claims behaviour that nothing implements. Phase and momentum land here alongside the
detent accumulator.

Variable row heights with a height cache in `ListView`, and keyed adapter identity, land
with this phase — the clipboard panel, notification history, and launcher all need lists
whose rows differ in height, and all three are near-term.

## Phase 3 — the three missing bar primitives

`Separator`, `Spacer`, and `ProgressBar`. In the reference these are 147, trivial, and 131
lines respectively. They complete the foundation set the bar composes from.

## Phase 4 — the widget framework

The reference's `Widget` base class is the good news of the whole audit: `create()`,
`doLayout`, `doUpdate`, `onPointerEvent`, `onFrameTick`/`needsFrameTick`, plus callbacks for
update, redraw, frame tick, and panel toggle. Everything else on it is styling state. That
contract ports directly.

Alongside it: the three-section layout (start/center/end, named along the main axis so a
vertical bar works), the capsule grouping that merges consecutive capsule widgets into runs,
and the hover underlay — a layer between background and content clip that hosts hover pills
so they neither affect layout nor clip at section boundaries. That last detail is the kind
of thing that is invisible until it is missing and then looks broken.

## Phase 5 — configuration

TOML, a typed schema with validation diagnostics, atomic writes, and inotify hot-reload
with a changed-sections diff so subscribers reload only what moved. Per-monitor and per-bar
overrides are part of the model, not a later addition — the reference resolves them in 2,374
lines and multiple named bars are a first-class concept.

The schema is the product's surface area, and it is the one part of the reference that does
not shrink: ~443 fields is what a configurable bar costs. Config lands before the services
because every widget reads its own configuration, and retrofitting that is worse than
starting with it.

## Phase 6 — the bar, with a minimal widget set

Clock, workspaces, volume, battery, network, tray. Battery already exists. This is the
first phase whose output is a thing on screen.

Workspaces needs a compositor backend; the reference abstracts nine behind
`workspace_backend.h`, and `ext-workspace-v1` plus one native backend is enough. Tray needs
StatusNotifierItem and DBusMenu, which is also what makes menus real — so the menu lift out
of `NucleusCompositorOverlay` happens as part of this phase rather than speculatively before
it, with an actual consumer to shape it.

## Phase 7 — services, in the order the widgets need them

PipeWire for volume (native libpipewire, and the largest of them), NetworkManager for
network, StatusNotifierItem for tray, logind for session, brightness via sysfs and DDC,
gamma for night light, MPRIS for media, BlueZ for bluetooth, and the freedesktop
notification service. The D-Bus client seam and UPower are already in place.

Only one network backend. The reference carries three behind an interface; iwd and
wpa_supplicant are not needed to run.

## Phase 8 — IPC

A Unix socket and a CLI client, with handlers registered by each service rather than
centrally, and usage text attached at registration so `--help` is generated rather than
maintained. This is how the shell is scripted and bound to compositor keys, and it is worth
having early enough that the bar is controllable before it is complete.

## Phase 9 — panels

Launcher, clipboard, session menu, OSD, notification toasts. `Popover`, `PopupPlacement`,
and the dismissal model already exist and are the right shape; what is missing is the
panel registry — toggling by string id, anchoring to the widget that opened it, and the
click shield.

## What we are deliberately not building

**From AppKit**: `NSCell`, Auto Layout and constraints, autoresizing masks, sheets and
modal sessions, the key/main window split, drag and drop, gesture recognizers, `NSDocument`,
printing, the services menu, `NSTouchBar`. The reference has none of them and neither needs
them. Flexbox and closures remain the answer instead of constraints and target/selector.

**Pasteboard** stays unbuilt until the clipboard panel needs it, at which point it is a
`wlr-data-control` service rather than an `NSPasteboard`. `TextEditorModel.copyableSelection`
having no destination is a known dangling end, not an oversight.

**The presentation/model layer split** — reading an in-flight animated value — has no
consumer. The reference has no equivalent.

**Colour spaces.** `Color` is bare float RGBA. The reference is sRGB throughout and the
decode path now handles linearization where it matters, which is the only place it did.

**From the reference**: the settings window, the control center, desktop widgets, the Luau
scripting host, CEF, calendar/CalDAV, the theme template engine that exports palettes into
other applications' config files, screen time, EasyEffects, and seven of the nine compositor
backends.

**Animated GIF and icon atlasing** stay deferred with their reasoning recorded in
`image-file-loading.md`.
