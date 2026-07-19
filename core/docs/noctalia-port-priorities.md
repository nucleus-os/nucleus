# Priorities for the Noctalia port, and where NucleusUI stands against AppKit

**Invariant: the widget kit is not the bottleneck. Roughly a fifth of the reference is UI; the
rest is system services and the surfaces built on them. Work is sequenced by what a real widget
needs end to end, not by finishing the UI layer first.**

## What the port actually is

Counting the reference: 479 implementation files. 97 of them are UI and render — about a fifth.
61 are system services. The remaining three hundred are surfaces, configuration, theming,
localization, scripting, the launcher, capture, and IPC.

The bar alone has **35 widgets**. Sorting them by what they need to display anything at all:

- **UPower** — battery
- **BlueZ** — bluetooth
- **NetworkManager** — network
- **PipeWire** — volume, media, audio visualizer
- **MPRIS** — media, apple music
- **StatusNotifierItem** — tray
- **logind / power-profiles** — session, power profile, idle inhibitor
- **backlight and gamma** — brightness, nightlight
- **wlr-data-control** — clipboard
- **the compositor** — workspaces, taskbar, active window
- **nothing** — clock, spacer, custom button, and the two debug widgets

Five of thirty-five need no system service. Nucleus has a D-Bus *server* helper in the compositor
for exposing its own methods, and no D-Bus client stack, no PipeWire, and no tray host anywhere.

The shell's current bar is 114 lines of JSX showing a clock and a window list. That is not a bar
that a widget kit is holding back; it is a bar with nothing to display.

## Where NucleusUI stands against AppKit

**The object model matches closely.** `View` carries `frame`, `bounds`, `subviews`, `superview`,
`window`, `hitTest`, `layout`, `setNeedsDisplay`, `needsLayout`, `alphaValue`, `isHidden`,
`shadow`, `appearance`/`effectiveAppearance`, and the accessibility properties, under AppKit's
names and with AppKit's meanings. `Responder` is `NSResponder` — `nextResponder`,
`acceptsFirstResponder`, `becomeFirstResponder`, `resignFirstResponder`, and a chain that climbs
view → controller → window. `Window` matches `NSWindow` on `contentView`,
`contentViewController`, `firstResponder`, `makeFirstResponder`, `orderFront`, `orderOut`,
`makeKey`, `styleMask`, and `level`. `ViewController`, `Control`, `Button`, `TextField`,
`ImageView`, and `StackView` all match their counterparts, `StackView` down to
`NSStackView.Distribution`'s cases.

`Event` is `NSEvent`-shaped. `TextInputClient` is `NSTextInputClient`. `Appearance` and semantic
colours are present. `VisualEffectView` is `NSVisualEffectView`.

**The graphics layer matches CoreGraphics and CoreAnimation.** `GraphicsContext` is `CGContext`'s
model — `saveGState`/`restoreGState`, clip, fill, stroke, per-state paint attributes. `Path` is
`CGPath`. `AffineTransform` is `CGAffineTransform`, including `concatenating` order. `Layer` is
`CALayer` and `Transaction` is `CATransaction`, with an action policy standing in for implicit
animation control.

**Three divergences are deliberate.**

`draw(in: GraphicsContext)` replaces `draw(_ dirtyRect: NSRect)` with an implicit current context,
and there is no dirty rect. The pipeline records a whole-canvas command list and rasterizes into a
fresh texture, so a subrect-only redraw would produce a texture containing only that subrect —
AppKit's contract preserves the undrawn pixels and this one structurally cannot.

**Layout is flexbox, not Auto Layout.** `measure`/`arrange` with `LayoutConstraints`, plus
`growFactor`/`shrinkFactor`/`layoutBasis` and stack distribution. Neither constraints nor
springs-and-struts exist. This is the largest semantic departure, and it is right for this
consumer: the reference's own layout primitive is `Flex` with `flexGrow`, gap, padding, and size
policies. "AppKit-like" is true of the object model, not of the layout engine.

Actions are closures rather than target/selector pairs, which is the only sane Swift answer.

**One divergence is a latent problem, now decided.** `bounds` exposes size only, with a zero
origin, and its setter silently drops what it is given. AppKit implements scrolling by moving a
clip view's `bounds.origin`, and its coordinate conversion, hit testing, and drawing all account
for that. `bounds-origin-model.md` adopts that model and lands it before Phase 3, because tracking
rectangles written against a zero-origin assumption would all need revisiting.

**What is missing, ranked by what the port needs.** Scrolling and its clip view, with
virtualization that AppKit puts in `NSTableView` rather than `NSScrollView`. Menus and popovers as
NucleusUI types — they exist only inside the compositor overlay today, so no product view can
raise one. Tracking areas, cursor rectangles, and tooltips: the reference's `InputArea` carries a
tooltip provider, a refresh interval, placement, and anchor insets, which is a real feature and
has no counterpart here. A pasteboard and drag-and-drop, which the clipboard surface needs.
Gesture recognizers.

## The reprioritization

Finishing the widget kit before touching services would produce a native bar that shows a clock
and a window list — precisely what the React Native bar already shows. The kit would be exercised
by nothing that needed it.

**Build one widget end to end instead, and let it pull the layers it needs.** A battery widget
requires a UPower client, a D-Bus client stack under it, an icon or glyph, a label, a tooltip, and
a click target that opens a panel. That single vertical slice forces the service pattern, the
tooltip and tracking gap, and the popup layer — each of which is currently a guess.

## Status

| Phase | | |
|---|---|---|
| 1 | The D-Bus client seam | **complete** |
| 2 | UPower, and the battery widget | **complete** |
| — | The bounds-origin model | pending, blocks 3 |
| 3 | Tracking, cursors, and tooltips | pending |
| 4 | The popup layer | pending |
| 5 | Scrolling | pending |
| 6 | The control kit | pending |
| 7 | The remaining bar services | pending |
| 8 | The bar, natively | pending |

## Phases

**Phase 1 — The D-Bus client seam — complete.** `DBusConnection` opens either bus and exposes what a poll loop
needs: a descriptor, the events it currently wants, and sd-bus's absolute CLOCK_MONOTONIC deadline
converted to a relative wait. `process()` drains and flushes, reporting whether it did anything so
a caller can tell a spurious wakeup from real work. Properties read as bool, uint32, int64, double,
and string; methods taking no arguments call; signals subscribe by match rule, with a helper for
the `PropertiesChanged` rule nearly every service uses.

The C façade came out nearly empty, which was the useful discovery. The compositor's equivalent
wraps the `SD_BUS_VTABLE_*` macros and the variadic message ops because a *service* needs them; a
client needs neither, and every entry point here imports directly from `<systemd/sd-bus.h>`.

Signal handlers take no arguments. Decoding a body means a full variant reader, and the pattern a
widget actually uses is "something changed, re-read what I display" — `PropertiesChanged` carries
an invalidated-properties list precisely because its payload is not always authoritative.

`DBusError` separates a service that is *absent* from one that *failed*, because a widget for a
service that is not running must render as unavailable rather than as broken.

Fifteen tests, against a live bus where one is reachable and degrading to a skip where it is not,
including a real round trip to the bus daemon and a real `NameOwnerChanged` signal arriving at a
handler.

**Phase 2 — UPower, and the battery widget — complete.** The tier split it forced is the result
worth keeping. `BatteryWidget` renders a `BatteryLevel` and nothing else — no bus, no service, no
device path — so every state a real machine takes weeks to produce is one assignment away in a
test. `UPowerService` maps the bus onto a `BatteryReading` and never sees a view. The runtime
composes them, which is the only place the two vocabularies meet, and is what keeps
`NucleusShellProduct` NucleusUI-only: a service-injected widget would have broken that.

UPower's `DisplayDevice` is read rather than a chosen battery. It already aggregates every battery
on the machine, and picking one is policy a service has no business inventing.

Absence is first-class throughout. A machine with no UPower, or UPower with no battery, is a
configuration and not an error: `start()` does not throw, the reading says absent rather than zero
percent, and the widget hides rather than drawing an empty cell. A transient bus failure leaves the
last good reading in place instead of blanking a working widget. Identical readings do not notify,
because UPower emits `PropertiesChanged` for values a bar never displays.

The system bus joined the poll loop with its own timeouts — sd-bus has deadlines for pending calls,
so the loop must not sleep past them.

Twenty-three tests. One of them asserted on `PaintCommand.w` for a path fill, which is meaningless:
path geometry lives in the payload blob. The fill rectangle is now computed separately, which is
the part worth testing, and `draw` fills it.

**Phase 3 — Tracking, cursors, and tooltips.** Confirmed by Phase 2: the battery widget has a
hover state and a click target with nowhere to put either. NucleusUI has whole-view enter/exit at
the scene, and no cursor, no tooltip, and no hover state on `Control`. Tracking areas producing enter/exit at the view level, a cursor
region model, and tooltips with a content provider — the reference's shape, since it is the one a
bar actually uses.

**Phase 4 — The popup layer.** Popover chrome, anchoring, dismissal, and the window level a menu
occupies, in NucleusUI rather than the compositor overlay. The battery widget opens a panel; every
menu and dropdown needs the same thing.

**Phase 5 — Scrolling.** `ScrollView`, a scrollbar, and virtualized list and grid, on the
bounds-origin model that landed before Phase 3. This lands after the popup layer because a panel is
the first thing that will overflow.

**Phase 6 — The control kit.** `Toggle`, `Slider`, `Checkbox`, `RadioButton`, `Select`,
`Segmented`, `Stepper`, `ProgressBar`, `Spinner`, `Separator`. Deliberately here rather than
earlier: by this point the control-centre and settings surfaces are the consumers, and each
control lands against a real use rather than a guess at one.

**Phase 7 — The remaining bar services.** PipeWire, NetworkManager, BlueZ, StatusNotifierItem,
logind, and the backlight and gamma paths, each with its widget, following the pattern Phase 2
establishes.

**Phase 8 — The bar, natively.** The composition of everything above, replacing the React Native
bundle. It is last because it is the sum of its widgets, not a prerequisite for them.

## What this changes

The previous sequence — builder, modifiers, control kit, collection views, popups, bar — assumed
the UI layer was the critical path. It is not. The builder and modifiers already landed and were
worth landing; the control kit moves behind the service work and the interaction gaps, because a
control with nothing to control is not progress.
