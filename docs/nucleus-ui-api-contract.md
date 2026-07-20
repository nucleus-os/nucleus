# Nucleus UI API Contract

## Invariant

Nucleus uses Apple-shaped names only where they communicate supported
behavior. NucleusUI is a retained, main-actor UI model over a retained layer
tree; it is not an AppKit, UIKit, Core Animation, or Core Graphics
implementation. The platform host owns surfaces, event-loop integration,
activation, environment sources, and teardown.

## Ownership and lifecycle

`View`, `Window`, `WindowScene`, controllers, and mutable UI services are
main-actor objects. Every view and window belongs to one `UIContext`. A
renderable `WindowScene` is created from an explicit `UIContext` and visual
`NucleusLayers.Context` pair. It never creates an in-memory renderer as a
fallback.

Construction closures install their context task-locally for the complete
synchronous or asynchronous operation. Async child tasks inherit the scope;
unrelated tasks do not share a process-wide context stack. The closures are
syntax for assigning ownership, not global application state. Different
`WindowGroup` leaves receive different semantic contexts, even when the host
chooses to render them through the same backend.

There is no implicit detached semantic context. Creating a `View`, `Window`,
or another identity-owning UI object outside an installed construction scope
is a programmer error. Tests, previews, and measurement tools explicitly use
`UIContext.construct { ... }`. Production composition roots install the
semantic and visual pair while materializing a scene. A retained object never
consults the construction scope again for ordinary mutation; APIs such as
`Transaction.run(in:)` take an owning view and derive the context from it.

NucleusApp materializes the app's scene description once. A platform host
provides a visual context for each typed presentation request, retains the
resulting scene, assigns protocol surfaces and outputs, drives activation
transitions, and disconnects the scene during teardown. NucleusApp does not
re-evaluate `body` to reconcile state and does not own a frame loop.

## Apple-to-Nucleus mapping

| Familiar concept | Nucleus API | Contract and deliberate difference |
| --- | --- | --- |
| `NSView` / `UIView` | `View` | Retained hierarchy, layout, hit testing, focus, accessibility, and drawing invalidation. Coordinates are top-left-origin with positive Y downward. |
| `NSWindow` | `Window` | Retained content and responder ownership. `WindowRole` is a portable host intent, while `WindowLevel` controls only scene ordering. Protocol configuration stays in the host adapter. |
| `NSWindowScene` / scene session | `WindowScene` | Explicit semantic and visual ownership, multiple windows, activation transitions, input routing, publication, and teardown. |
| `NSGraphicsContext` / `CGContext` | `GraphicsContext` | Records a whole-view immutable command list in logical `Double` coordinates. It is not an immediate framebuffer context; safe local invalidations can be replayed under a damage clip while preserving untouched backing pixels. |
| `CGPath` | `Path` | Value geometry for move, line, quadratic/cubic curve, arc, close, and winding/even-odd fill. It is not toll-free bridged and carries no paint state. |
| `CALayer` | `NucleusLayers.Layer` | Retained geometry, transform, clip, shadow, backdrop, content, and ordered children. Nucleus exposes only properties required by its renderer. |
| `CATransaction` | `LayerTransaction` and NucleusUI `Transaction` | Eager model writes with batched publication. Completion means accepted/terminal presentation according to the documented animation path, not arbitrary run-loop drainage. |
| `CABasicAnimation` / spring animation | Nucleus layer and view animation APIs | Presentation-time interpolation for frame, opacity, corner radius, backdrop opacity, and transform. Layout and arbitrary custom properties use main-actor value animation. |
| `NSVisualEffectView` / `UIVisualEffectView` | `VisualEffectView` | Semantic material, blend scope, active state, emphasis, mask, radius, and opacity. The host renderer resolves these into Nucleus backdrop parameters rather than Apple material internals. |
| `NSTextField`, `NSTextView`, text input client | `TextField`, `TextView`, `TextInputClient` | Retained shaped layout, UTF-safe editing, selection, composition, and platform input-method adapters. Secure values are redacted from accessibility and surrounding-text export. |
| `NSAccessibility` / UIKit accessibility | `Accessible`, `AccessibilityTree` | Neutral stable semantic snapshots and actions. Platform adapters translate them to AT-SPI or another native accessibility system. |

## Coordinates, scale, and drawing

Scene, window, view, and surface coordinates use logical points as `Double`.
Origins are top-left and Y increases downward. A host-provided
`BackingScaleFactor` converts at surface/backing-pixel boundaries. Public
geometry remains in `Double` until transaction lowering narrows it once for
the render model.

`draw(in:)` recreates the view's complete retained recording after display
invalidation. Save/restore, transforms, clips, paths, gradients, text, images,
and runtime effects are recording operations. Localized damage is an
optimization and does not change this semantic contract. Publication retains
equal recordings by content rather than view identity. When the backing size
is stable and every command is localizable, the renderer copies the prior
backing, clears only the outward-rounded pixel damage, and replays the complete
recording under that clip. First paint, size changes, runtime effects, invalid
damage, and composite-property changes conservatively repaint and damage the
complete affected footprint.

## Environment and materials

Appearance, increased contrast, reduced motion, reduced transparency, and text
scale are scene-local `UIEnvironment` values owned by `UIContext`. Platform
hosts update them. Views inherit explicit appearance and palette overrides
through ancestors before resolving against that environment.

Backdrop materials are semantic requests. `VisualEffectView` never promises
Apple's private blur, vibrancy, saturation, or noise recipes. Reduced
transparency resolves the same request to an opaque semantic fallback.

## Window roles and host boundaries

`WindowRole` communicates one of ordinary application, layer surface, popup,
notification, overlay, lock, or hosted-content intent. It does not contain
Wayland anchors, exclusive zones, margins, keyboard-interactivity flags,
configure serials, or ack state. Those values belong to the Wayland adapter.
`WindowLevel` independently orders portable scene content and must not be used
as a protocol-role substitute.

## Supported animation properties

Compositor-side retained animation supports presentation-safe layer
properties: frame, opacity, corner radius, backdrop opacity, and transform.
Animation replacement is keyed by retained layer/property identity and reports
one terminal outcome. Main-actor value animation covers properties that must
mutate semantic state or trigger layout. Reduced motion atomically applies the
terminal semantic value for motion-scaled animation.

## Transactions and presentation completion

NucleusUI mutations update the live semantic model immediately. A
`Transaction` scopes immutable action policy around those writes; it does not
hold a second copy of view state. Publication authors one sparse visual
transaction from dirty generations. The publisher updates its accepted cache
only after the commit sink accepts that transaction, so a rejected commit can
be retried without semantic or visual cache divergence.

Transaction and animation completion is exactly-once terminal state:
completed, cancelled, superseded, skipped for reduced motion, or failed.
Compositor-backed completion resolves from presentation acknowledgement.
In-memory hosts resolve at accepted commit because they have no presentation
clock. Replacing an animation for the same retained layer/property identity
supersedes the previous request.

## Layout, scrolling, and collection identity

Layout is a two-phase main-actor contract. `measure(_:)` returns a size without
mutating geometry; `arrange(in:)` assigns final frames. `LayoutConstraints`
canonicalizes minimums, maximums, and invalid proposals. Baseline alignment is
explicit. `StackView`, `FlexView`, and `GridView` use the same measure/arrange
contract rather than owning independent geometry pipelines.

`frame` positions a view in its parent; `bounds.origin` scrolls the view's
contents without rewriting child frames. Scroll views clip to bounds and keep
logical offsets independent of backing scale. List and virtual-grid snapshots
require unique stable `CollectionItemID` values. Moves preserve retained cell
identity; a content `revision` controls reconfiguration independently of
selection and focus. View and paint counts remain bounded to the viewport,
overscan, and reuse pool.

## Responder, focus, pointer, and keyboard behavior

Every event sequence has stable device and sequence identity. Pointer/touch
capture belongs to the routed sequence and is cancelled on focus loss, window
removal, or scene deactivation. Hit testing applies bounds origins, affine
view transforms, clips, visibility, and window ordering before responder-chain
routing.

`Responder.nextResponder` rejects cycles. Keyboard events route from the key
window's first responder; pointer events route from the hit view. Focus scopes
and roving focus preserve one focused semantic item, while disabled or hidden
controls leave traversal. Context menus and popovers use retained scene
objects and explicit dismissal policy rather than a process-global menu loop.

## Text, editing, input methods, and pasteboard

Hosts install a `TextLayoutBackend` into `TextSystem`; NucleusUI itself does
not import the native C++ text module. One retained shaped layout services
measurement, baselines, glyph positions, selection rectangles, and caret
geometry. Layout handles and their backend resources are released together on
the main actor.

`TextEditorModel` uses UTF-16 as its internal selection space and converts
UTF-8 byte offsets at the input-method boundary. Caret movement respects
grapheme clusters, composition replaces one provisional marked range, and
typing/deletion/commit operations maintain undo and redo state. Each hosted
window owns a `TextInputContext`; a platform adapter supplies surrounding-text
and candidate-rectangle protocol traffic. Secure entry masks by grapheme,
exports no surrounding or selected text, clears recoverable history when
security changes, and redacts accessibility.

`Pasteboard.general` is a portable in-process service surface. A host installs
the native clipboard adapter where system clipboard integration is required;
secure controls never write their contents through either path.

## Accessibility publication

Accessible objects have stable context-scoped identities independent of render
layer identity. `AccessibilityTree` incrementally snapshots semantic nodes,
reuses clean cached subtrees, diffs insertion/update/removal, and drains
explicit notifications. Frames are exported in scene coordinates. Virtualized
collections can expose offscreen virtual elements without materializing their
views.

Platform bridges translate the neutral snapshot and action vocabulary. The
Linux shell installs the AT-SPI bridge out of process; NucleusUI contains no
DBus or toolkit dependency. Secure text is redacted from value, description,
selection, and action-related exports.

## Teardown and host obligations

The platform host owns protocol surfaces, outputs, frame scheduling, and
shutdown order. It stops input and presentation, disconnects the scene,
invalidates embedded publishers, releases registered content and visual
layers, and then releases the visual context. Close, remove, and invalidate
operations are idempotent. A host must not release an RN or embedder surface
while its publisher remains attached; teardown failures are propagated or
reported as programmer diagnostics rather than silently ignored.

`WindowScene.disconnect()` is idempotent and terminal. It removes the accepted
visual tree before releasing windows, popovers, hover/tracking state, captures,
focus restorations, and host callbacks. A disconnected scene rejects later
publication or visual attachment and ignores later input. RN mount failures
during the synchronous attach are thrown to the caller; failures from later
asynchronous mount batches remain queryable on the RN host and are delivered
to its optional publication-failure callback.
