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

## Phase 1 — clear the defects — **complete**

Five pieces of wrong behaviour in shipped code, cleared before anything is built on
top of them. Two were worse than the audit described and one was milder.

**The key code space was open, and keys collided.** This was the serious one, and the
audit understated it: it reported "no letters or digits", but the real fault was that
unmapped platform codes passed through as raw values while the named constants were
numbered from 1. Ordinary evdev codes landed on them — the "1" key (evdev 2) compared
equal to `.return`, "2" to `.tab`, "9" to `.leftArrow`, "q" to `.pageUp`. `TextField`
switches on `keyCode` before inserting text, so **typing a digit submitted the field or
moved the caret instead of typing**, including in the lock screen's password field.

`KeyCode` is now closed: letters, digits, punctuation and function keys are named, and
anything unmapped is `.unknown`. Text arrives through `Event.characters`, which is what a
view should insert; `keyCode` answers which key, never what it produced. The evdev table
moved into `KeyCode(linuxEvdevCode:)`. It had been duplicated in the shell's input router
and the compositor's overlay, on the reasoning that `core/` should not adopt a platform's
numbering — but the duplication is what broke it, since both copies fell through to raw
values. Naming the platform in the API keeps the numbering framework-owned with one copy
of the table.

**Transforms now participate in hit testing and conversion.** The step between a view and
its parent was open-coded in four places — `hitTest`, both window-space walks, and
`dispatchEvent` — and none applied `transform`. There is one definition now, which is also
why they were able to drift. It applies the transform about the anchor point, matching
what the renderer composes (`translate(position) · pivot · transform · unpivot`) with the
layer default anchor of (0.5, 0.5), so a view scales about its own centre.

Hit testing maps into local coordinates *first* and then tests `bounds`; testing the frame
in the parent's space tests an axis-aligned box that a rotated view does not occupy. A
transform that collapses the plane has no preimage, so such a view is hittable nowhere
rather than everywhere across its frame. Rectangle conversion maps all four corners and
takes their bounding box.

**Rotation reaches non-path draws.** `setGeometry` folded the transform into the geometry
as an axis-aligned bounding box. The scope was narrower than reported: `fill(rect)` is
encoded as a path whose points are transformed individually, so rect *fills* rotated
correctly all along. The broken commands were text, images, and the package background and
border fast paths — which is where every view's background is drawn. A command that
rotates or skews now states geometry in its own space and carries the matrix; translation
and scale still fold in, keeping the common case a plain rect. Scalars follow geometry: a
carried matrix scales radius and stroke width itself, so the recorder stops pre-scaling
them.

**Stroke caps and joins are encoded.** They were public settable state that nothing read,
so a caller could ask for a rounded stroke and get a butt-capped one with no indication the
request was dropped. They ride the command flags — absent bits mean butt and miter, so the
defaults cost nothing — and only strokes carry them, since a fill has no ends or corners.

**`fadeOut` was milder than reported.** It read as a race with the animation, but an
animation installs a *presentation override* that the compositor shows while it runs and
commits to the model on completion. Moving the model first is the Core Animation order and
the correct one; leaving it behind would be the bug, since `alphaValue` is the view tier's
authoritative value. The guard was redundant, not wrong, and is gone.

`KeyCode` widened here as planned, and `Transform` gained a rotation factory matching
`AffineTransform`'s sign convention — a disagreement there stays invisible until something
rotates and hit-tests the other way.

## Phase 2 — scroll and list fidelity — **complete**

`axis_value120` and `axis_stop` were arriving from the compositor and being discarded —
empty handlers in the seat — so a free-spinning wheel's sub-notch movement had nowhere to
land and every wheel event snapped a whole line.

Events carry the source, the detents, and the end of a gesture.
`hasPreciseScrollingDeltas` became *derived* from the source rather than stored: the
source is what the platform reports and the boolean was a lossy reading of it.

**Scrolling has two consumers that want different things**, and conflating them is what
makes shell widgets feel wrong. Content wants raw distance, so a list tracks a touchpad
exactly. Discrete stepping — volume, workspace cycling — wants notches that mean the same
thing whether they came from a ratcheted wheel, a high-resolution one, or a touchpad.
`ScrollDetentAccumulator` is the second: it accrues fractions, resets on reversal so a
direction change is not eaten by a stale remainder, and caps wheels at one step per event
so a compositor scaling the delta cannot turn one felt notch into several.

**There is no momentum phase, against the plan.** Wayland has no equivalent of AppKit's
`momentumPhase` — the compositor synthesizes no inertia. What it delivers is `axis_stop`,
so kinetic scrolling is the client's to start from the end of a gesture. Modelling a phase
we are never sent would have been inventing a contract.

`ListView` measures rows when asked to. Uniform rows keep the arithmetic path and stay
free — an index is a division and a ten-thousand-row list allocates no table. A height
provider builds one prefix-sum pass and every lookup becomes a binary search, because
scanning would make scrolling cost the length of the list. Negative heights clamp to zero
rather than being trusted, since a decreasing offset would break the search.

**Rows follow their item, not their slot.** `rowKey` gives an item its identity, and a
view already showing that item is reused *as it stands* rather than reconfigured. Without
it, inserting at the top hands every visible row's view to a different item along with
whatever it was holding — a pressed state, a caret, an in-flight animation.

## Phase 3 — the three missing bar primitives — **complete**

`Spacer`, `Separator`, and `ProgressBar`, which complete the foundation set the bar
composes from.

**`Spacer`** is flexible empty space. A stack's `Distribution` spaces items apart only
uniformly; a spacer expresses the uneven case — the bar's three sections pushed to their
edges — as an ordinary arranged view, the same way `NSStackView` and flexbox do. It both
grows *and* shrinks: slack is the first thing that should give when a stack is over-full,
because a spacer shrinking is invisible and a label shrinking is not.

**`Separator` infers its orientation from the stack it sits in.** A rule divides the items
a stack arranged, so it lies across that axis — horizontal inside a column, vertical inside
a row. That is what the caller means every time, and stating it per use site is a chance to
state it wrong in a way that stays invisible until the layout changes direction. `spacing`
belongs to the separator rather than the stack, because a rule wants more room around it
than the items it divides want from each other.

**`ProgressBar`'s fill is a full-size bar behind a moving clip**, which is the one detail
worth taking from the reference verbatim. Drawing the fill at the fraction's width squares
off its trailing end, so a rounded bar at 5% shows a stub rather than the rounded cap it
has at 100%. Clipping a full-size copy keeps both ends exactly the track's shape at every
value. It carries the reference's three orientations, including the centred one for values
that are a deviation rather than an amount.

Out-of-range progress clamps, and anything non-finite reads as empty — one rule rather than
clamping infinity to full and NaN to empty, since a caller producing either has a bug and
two behaviours would only make it harder to see.

`AccessibilityRole` gained `progressIndicator`.

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
