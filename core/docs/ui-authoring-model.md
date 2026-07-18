# The UI authoring model

**Invariant: NucleusUI stays retained and imperative. Views are objects a surface holds and
mutates. A declarative layer may describe how a subtree is *built*; it never describes how it is
*updated*, and there is no reconciler on the first-party path.**

A reconciler exists in exactly one place: where a tree of UI arrives as data from outside the
process's own code — a script runtime, a JavaScript bundle — and must be matched against retained
views it cannot hold references to. That is a boundary property, not an authoring style, and it is
already solved in Nucleus by React Native's mounting layer.

## What Noctalia actually does

The production reference settles this, and it settles it against the assumption that a shell of
this size wants a reconciler.

`src/ui/ui_tree.h` describes `UiTreeNode` as "one node of a declarative control tree produced by
**plugin code**", which "crosses the **script-worker → UI-thread** boundary by value". Its values
are `std::variant<bool, double, ...>` because "numbers are always double (**Luau** numbers)".
`UiTreeReconciler` is "the single place **plugin** UI intent becomes controls: **plugin code never
sees a Node**". Its callbacks carry a "plugin-global function name" and stringly-typed arguments,
because a Luau function cannot be handed a C++ closure.

Every consumer of that machinery is a plugin host: the scripting bindings, `plugin_panel`,
`plugin_widget`, `plugin_desktop_widget`. Nothing else in the tree references it.

Their own surfaces — around twenty-five of them, with settings alone spanning forty-seven files —
are written a different way entirely. `BatteryWidget::create()` constructs its subtree once through
the builders in `src/ui/builders.h`, capturing non-owning pointers to the pieces it will change
later:

```cpp
.out = &m_fillRect,
.out = &m_label,
```

and then mutates those retained controls directly for the rest of the widget's life:

```cpp
m_fillRect->setRadius(cornerR);
m_fillRect->setPosition(m_bodyBg->x(), m_bodyBg->y() + bodyH - fillH);
```

So the pattern is **declarative construction, imperative update, retained controls** — with a
reconciler bolted on only at the untrusted-script boundary, where nothing else would work.

## The decision

NucleusUI keeps the AppKit shape it already has. A control is a class with properties; a surface
holds its controls as stored properties and mutates them when its data changes. `Slider.value` is a
settable property, not a prop diffed out of a tree.

Nucleus does not build a reconciler for the native shell. The case that justifies one is already
covered: React Native's mounting layer is precisely a reconciler over retained `View`s, reached
through `ReactLayerBinding`. If scripted plugins arrive later, that path is the precedent to
follow, and the vocabulary to reuse is `PaintRecording` and the view tree — not a second diffing
engine.

What Nucleus adds is the layer it is currently missing: a **builder** for construction. Today a
surface writes `let stack = StackView(axis: .vertical); stack.spacing = 8; parent.addSubview(stack)`
and repeats that for every node. Across thirty controls and twenty-five surfaces that is the
dominant cost of the port, and it is the cost the reference paid `builders.h` — a thousand lines of
props structs — to avoid.

Swift removes the reason those structs are so large. The reference needs `.out = &m_fillRect`
because a C++ builder expression has nowhere to put the reference; in Swift the control is already
a stored property, so it can be declared, referenced inside the builder, and mutated afterwards
with no capture mechanism at all:

```swift
private let fill = RectangleView()
private let label = Label()

override init() {
    super.init()
    setBody {
        HStack(spacing: Style.spaceSmall) {
            fill.width(22).height(14).cornerRadius(3)
            label.textColor(.secondaryLabel)
        }
    }
}

func update(_ battery: BatteryState) {
    label.text = battery.percentageText
    fill.frame.size.width = battery.fraction * 22
}
```

The builder arranges; the properties are the API. Nothing in `update` goes through a tree.

## Why not a reconciler for first-party surfaces

**It buys nothing here.** A reconciler earns its cost when the code describing the UI cannot hold a
reference to the view — across a script boundary, a serialization boundary, or a process boundary.
First-party Swift code holds references trivially. Diffing a tree to discover that a battery
percentage changed, when the widget already knows, is work performed to recover information that
was never lost.

**It would fight the phases already landed.** Layout is measure/arrange over retained views with
subtree dirty bits, and display caches a `PaintRecording` per view invalidated by
`setNeedsDisplay`. Both are built on view identity persisting across frames. A reconciler that
replaces a subtree on a type mismatch throws that away and re-records paint for a subtree whose
pixels did not change.

**It would relocate the hard part.** Keyed reconciliation, subtree replacement, and callback
identity are real complexity, and the reference carries all of it — because it must. Adopting that
complexity for surfaces that could instead call a setter is choosing the harder mechanism to
express the easier problem.

## Phases

**Phase 1 — The view builder.** A `@resultBuilder` producing subviews, plus `setBody { }` on
`View`, so a container's structure reads as a nested expression rather than a sequence of
`addSubview` calls. Children are `View` instances, so a stored property placed inside the builder
is the same object the surface mutates later. Rebuilding a body replaces the subtree, which is the
escape hatch for structure that genuinely changes, not the update path.

**Phase 2 — Chainable configuration.** `@discardableResult` modifiers returning `Self` for the
properties a builder expression sets inline: sizing, spacing, colour, corner radius, flex factors,
visibility. Each one sets the same stored property a caller could set directly; a modifier is
sugar over the property and never the only way to reach it.

**Phase 3 — The control kit.** `Toggle`, `Slider`, `Checkbox`, `RadioButton`, `Select`,
`Segmented`, `Stepper`, `ProgressBar`, `Spinner`, `Separator`, `Spacer`, built on `Control` and
the responder chain. Each exposes its value as a settable property and its changes through a
target-action callback, matching `Button`.

**Phase 4 — Collection views.** `ScrollView`, `ScrollBar`, and a virtualized list and grid that
realize only visible rows. The reference ships `virtual_list_view` and `virtual_grid_view`
alongside the plain scroller, which is the evidence that a clipboard history or an application
launcher does not get a fixed handful of rows.

**Phase 5 — The popup layer.** Popover chrome, anchoring, dismissal, and the window level a menu
or dropdown occupies. `Select` and any context menu need it, so it lands before the surfaces that
use them.

**Phase 6 — The bar, natively.** The first production surface migrated off React Native, and the
proof of the thesis. It exercises the builder, the control kit, popups, live data, and hit testing
together, on a surface whose behaviour is already known.

## What this does not decide

Whether the shell eventually hosts scripted plugins. If it does, the reconciler question returns
in its proper form — an external tree arriving as data — and is answered by extending React
Native's mounting path rather than by changing how first-party surfaces are written.
