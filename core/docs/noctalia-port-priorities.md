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

**One divergence is a latent problem.** `bounds` exposes size only, with a zero origin. AppKit
implements scrolling by moving a clip view's `bounds.origin`, and its coordinate conversion,
hit testing, and drawing all account for that. Scrolling here will need an equivalent, and it
should be decided before `ScrollView` rather than during it.

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

## Phases

**Phase 1 — The D-Bus client seam.** A session and system bus client, an interface-proxy shape,
signal subscription, and a poll source folded into the shell's existing event loop. Modelled on the
compositor's `DBusService`, which already establishes the C interop and the descriptor style.
Nothing about a specific service belongs here.

**Phase 2 — UPower, and the battery widget.** The first service and the first real widget
together. Delivers a native bar item that displays live system state, and settles how a service's
updates reach a view: the widget holds its controls and mutates them, so a property change is the
whole update path.

**Phase 3 — Tracking, cursors, and tooltips.** What the battery widget's hover behaviour needs and
NucleusUI has no answer for. Tracking areas producing enter/exit at the view level, a cursor
region model, and tooltips with a content provider — the reference's shape, since it is the one a
bar actually uses.

**Phase 4 — The popup layer.** Popover chrome, anchoring, dismissal, and the window level a menu
occupies, in NucleusUI rather than the compositor overlay. The battery widget opens a panel; every
menu and dropdown needs the same thing.

**Phase 5 — Scrolling.** A bounds-origin model decided first, then `ScrollView`, a scrollbar, and
virtualized list and grid. This lands after the popup layer because a panel is the first thing
that will overflow.

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
