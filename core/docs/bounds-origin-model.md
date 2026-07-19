# The bounds-origin model

**Invariant: `bounds` is a view's own coordinate system, and `bounds.origin` is the translation
between it and the view's contents. Scrolling moves that origin. Nothing scrolls by mutating the
frames of the views being scrolled.**

## What exists today

`bounds` is asymmetric and lossy. The getter derives from `frame` and returns a zero origin
unconditionally:

```swift
get { Rect(x: 0, y: 0, width: frame.size.width, height: frame.size.height) }
```

The setter forwards only the size to the backing layer, so it neither round-trips with the getter
nor moves the frame. Assigning `bounds.origin` compiles and does nothing.

There is no coordinate conversion API. `hitTest` and `dispatchEvent` each open-code their own walk
over `frame.origin`, in opposite directions — one subtracting on the way down, one accumulating on
the way up. Those two walks are the whole coordinate system, and they exist twice.

## The decision

**`bounds.origin` becomes a real translation, stored on the view and honoured by hit testing,
drawing, and conversion.** A view with `bounds.origin == (0, 40)` shows its contents shifted up by
forty points. Its children's frames do not change.

The alternative — scrolling by moving the content views themselves — is rejected because layout
owns those frames. `arrange(in:)` computes a child frame from the flex distribution every time
layout runs. A scroll offset written into the same field is destroyed by the next layout pass, so
the scroll position would have to be re-applied after every arrange, by every container, forever.
Keeping the offset in `bounds.origin` puts it in a field layout never writes. Layout stays in
content coordinates and is entirely unaware that scrolling exists.

This is also AppKit's model, which matters here beyond consistency: it is the model the port's
divergence list already promises. Layout diverges deliberately — flexbox, not Auto Layout — and
that divergence is defensible because the reference's own primitive is flex. A second divergence in
the *coordinate system* has no such justification, and coordinate systems are where a subtle
mismatch produces bugs that read as rendering glitches rather than as logic errors.

One consequence is worth stating rather than discovering. Each view records its drawing into its
own backing layer, so a bounds origin is applied by offsetting child layer placement, not by
translating a shared canvas. A scroll is therefore a property update on one layer's children, and
the scrolled views neither redraw nor re-record.

## Status

Phases 1 through 4 are complete. Phase 5 is Port 3's, and lands with the tracking work.

The discovery that shaped Phase 4: `scrollOffset` **already existed** on `LayerPropertyUpdate`,
and was already carried through the layer model, the wire types, the lowering, and the render
model's `RenderTransactionApply` — and was then consumed by nothing. `layerLocalMatrix` reads
position, anchor, and transform, and the walk passed each layer's world matrix to its children
untouched. The field was inert end to end. Honouring it turned out to be one helper and one line at
the recursion, rather than the new layer property the phase anticipated.

## Phase 1 — `bounds` becomes storage

The origin is stored on the view. The getter returns it with the frame's size; the setter writes
the origin and invalidates. Setting a bounds *size* that disagrees with the frame is resolved by
having the frame remain authoritative for size — a view's size is its frame's size, and `bounds`
reports it rather than owning it.

Changing the origin invalidates layout and display of the *subtree placement*, not the subtree's
recordings. The recordings are unchanged by definition; that is the point of the model.

Landed as `boundsOrigin`, with `bounds` composing it against the frame's size. `clipsToBounds`
landed here too rather than in Phase 3, because the frame setter has to re-push the clip rect when
the view resizes and that is the same code path.

## Phase 2 — Conversion becomes API

`convert(_ point: Point, from view: View?)` and its `to:` counterpart, plus the `Rect` overloads,
matching `NSView`. A `nil` argument means window coordinates.

The walk accounts for both terms: descending into a child subtracts the child's `frame.origin` and
adds the parent's `bounds.origin`. This is the single definition of the coordinate system, and the
two open-coded walks are deleted in favour of it.

Rewriting dispatch in terms of the conversion API exposed a second defect. `hitTest` takes its
point in the *parent's* coordinates, and the old dispatch walk accumulated frame origins from the
target up to but **not including** `self` — so it never subtracted `self.frame.origin`. Dispatching
on a view whose own frame origin was non-zero delivered a location off by exactly that origin. It
went unnoticed because dispatch is usually rooted at a content view sitting at the origin.

## Phase 3 — Hit testing and dispatch adopt it

`hitTest` translates by `bounds.origin` before recursing into children. `dispatchEvent` stops
accumulating frame origins by hand and calls the conversion API. Without this a scrolled view's
click target stays where the content was drawn before scrolling — the defect this model exists to
prevent.

`clipsToBounds` lands here rather than with drawing, because hit testing must respect it: a view
scrolled out of sight must not receive a click, and the clip is what makes it out of sight.

## Phase 4 — Placement adopts it

Child layer placement offsets by the parent's `bounds.origin`, and `clipsToBounds` maps onto the
clip state the render model already carries. `GraphicsContext.clip(to:)` exists and the layer clip
state exists, so this phase connects two things that are both already present.

After this phase a scroll is one assignment, and the correctness of everything downstream of it is
verifiable without a `ScrollView` existing.

## Phase 5 — Tracking areas are written against the final model

Tracking rectangles and cursor rectangles are expressed in bounds coordinates and converted at
dispatch. This is why the model lands before them: written against the current zero-origin
assumption, every tracking rect in the tree would need revisiting.

## What this does not decide

`ScrollView` itself — the clip view, the scrollbar, the wheel and drag handling, and the
virtualization that belongs in a list view rather than in the scroll view. Those consume this
model. They do not shape it, and they land after the interaction and popup work rather than here.
