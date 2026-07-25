# Wayland Main-Actor Isolation

## Invariant

Every mutable Swift object that represents compositor-owned Wayland protocol state is
`@MainActor`-isolated.

Libwayland invokes C ABI callbacks synchronously on the compositor's main-actor-driven
event loop. A C callback may recover a borrowed Swift owner and may decode raw ABI
arguments, but it must enter `MainActor.assumeIsolated` before invoking Swift protocol
policy or accessing the recovered owner. From that point inward, APIs carry typed object
references or nominal identity values. They do not erase Swift objects to integer
addresses to cross an isolation boundary.

This refactor preserves synchronous Wayland request ordering. It introduces no
`Task { @MainActor in ... }`, continuation, queue hop, custom executor, or second global
actor.

Status: complete

## Progress

- Phase 1 is complete.
  - `SwiftWaylandGen` emits `@MainActor` server request protocols.
  - Every generated server request trampoline enters
    `MainActor.assumeIsolated` before invoking its recovered handler.
  - Borrowed handler and C pointer arguments use localized
    `nonisolated(unsafe)` bindings because strict region isolation does not infer
    their synchronous borrowed lifetime across the global-actor closure.
  - Handler-associated destructor work remains inside the isolated closure.
  - All 152 server dispatch interfaces were regenerated.
  - `swift build --package-path swift-wayland` passes.
  - `swift test --package-path swift-wayland` passes, including direct runtime
    coverage of `new_id`, default destructor, overridden destructor, isolated
    owner teardown, and synchronous request effects.
- Phase 2 is complete.
  - `WaylandRouterRuntime`, `NucleusWaylandRouter`, global registrations, global
    handles, and every router-retained protocol global are `@MainActor`.
  - `WaylandResource`, `WaylandResourceReference`, `WlNewId` resource creation,
    and `WaylandGlobal` now keep resource ownership and teardown on the main
    actor, with isolated teardown where state is touched.
  - All handwritten global bind callbacks use the centralized
    `NucleusWaylandRouter.withBoundImpl` C-boundary helper. It recovers borrowed
    ABI values and enters `MainActor.assumeIsolated` before invoking the typed
    owner.
  - Address-bit erasure was removed from the global-bind paths, including
    screencopy, workspace, and foreign-toplevel binds.
  - `swift test --package-path swift-wayland` still passes after the ownership
    changes.
- Phase 3 is complete.
  - The full XDG shell cluster, configure ledger, decoration peers, and policy
    protocols are main-actor-isolated.
  - `XdgShell` monotonically mints nominal `XdgToplevelID` values.
    `XdgToplevel`, `RouterWindowDriver`, `XdgRole`, and `WindowManager` carry that
    type end to end.
  - `RouterWindowDriver.toplevelState` retains only real configure-policy
    correlation keyed by `XdgToplevelID`; every toplevel and popup address-token
    thunk was deleted.
  - Popup ordering remains a real registry and is now keyed by nominal
    `WaylandClientID`.
- Phase 4 is complete.
  - `WlSurface`, compositor/subcompositor bindings, regions, subsurfaces, core
    roles, commit observers, scene publication, presentation state, and
    subsurface topology are main-actor-isolated.
  - `WlSurfaceID` nominally types the compositor's process-wide live surface
    identity, including collision-free synthetic IDs where client wire IDs
    overlap.
  - Surface commits carry `WlSurfaceID` and a lifetime-checked
    `WaylandResourceReference`; scene import no longer reconstructs a buffer from
    integer address bits.
  - The pointer-cursor address token was replaced with a typed weak relationship.
  - Surface teardown uses `isolated deinit` and preserves synchronous release,
    presentation, role, topology, cursor, compositor-index, and scene cleanup.
- Phase 5 is complete.
  - The seat, pointer/keyboard/touch owners, serial ledger, popup grabs,
    relative-pointer and constraint state, text input, data-device, data-source,
    data-offer, data-control, and selection policy clusters are
    main-actor-isolated.
  - `WaylandClientID` now keys device fan-out, focus, serial authorization,
    inhibitors, drag state, popup ordering, text input, relative pointer, and
    screencopy admission.
  - The seat and data-exchange Swift-owner address bridges were deleted. Data
    source callbacks retain a checked resource reference rather than a raw
    address.
- Phase 6 is complete.
  - Layer shell, session lock, activation, foreign toplevel, foreign surface,
    output/xdg-output, presentation, dmabuf, explicit sync, screencopy, gamma,
    workspace, decoration, blur/background effect, cursor shape, idle,
    fractional scale, viewport, and Xwayland-shell protocol objects and policy
    seams follow the same actor boundary.
  - Legacy request witnesses that re-entered `MainActor.assumeIsolated` were
    collapsed to direct actor-isolated calls. The only remaining
    `assumeIsolated` in the Wayland runtime is the handwritten global-bind
    boundary.
- Phase 7 is complete.
  - The runtime erasure audit finds no Swift Wayland owner converted to integer
    address bits.
  - Remaining `Unmanaged` conversions are C callback userdata for libinput,
    libseat, or libwayland global binds. Remaining C-owned identities are
    nominally wrapped.
  - The compositor build graph now runs a focused source lint that rejects
    `UInt(bitPattern: Unmanaged.passUnretained(...))` in the Wayland runtime and
    reports the offending conversion.
  - `collider generate wayland` regenerated all 152 server dispatch interfaces
    and 101 client dispatch interfaces.
  - `swift build` and `swift test` pass for `swift-wayland`.
  - `swift build` and the complete `swift test` suite pass for
    `compositor/compositor-core`; the unprovisioned DRM-node lane is skipped by
    the direct SwiftPM run and exercised through Collider's configured lanes.
  - `collider build` and `collider test` pass, including Vulkan loader/headless
    lanes and release stress suites.

## End State

The request path has one isolation assertion at the C boundary:

```text
libwayland C request
  -> generated @convention(c) trampoline
  -> recover borrowed request owner
  -> MainActor.assumeIsolated
  -> @MainActor generated request protocol
  -> @MainActor Wayland object
  -> @MainActor policy delegate
```

The object and policy path has these properties:

- `WlSurface`, xdg-shell objects, seat/data-device objects, and their mutable protocol
  peers are `@MainActor`.
- Generated server request protocols are `@MainActor`.
- Generated C request trampolines contain the request-boundary
  `MainActor.assumeIsolated`.
- Handwritten global bind callbacks and destroy callbacks follow the same boundary
  rule.
- Delegate protocols that are called only during a compositor turn are `@MainActor`.
- `RouterWindowDriver` accepts `XdgToplevel`, `XdgPopup`, and other typed objects
  directly.
- Public and package APIs do not accept a bare `UInt` that means "address of a Swift
  Wayland object."
- Required identity tables use nominal IDs. Tables that carry window policy,
  per-client protocol ordering, live resource delivery, or capability-epoch state
  remain.
- `@unchecked Sendable` is not used for mutable Wayland objects.
- Actor-isolated objects with teardown work use `isolated deinit`.

## Identity Model

Actor isolation removes the need to erase an object merely to call main-actor code. It
does not remove protocol identity or indexing requirements.

Introduce and use these identity categories:

- `XdgToplevelID`: a nominal, `Hashable`, `Sendable` value minted monotonically by
  `XdgShell` when it creates an `XdgToplevel`. It identifies one toplevel lifetime
  without deriving identity from a Swift heap address.
- `WaylandClientID`: a nominal, `Hashable`, `Sendable` wrapper for libwayland client
  identity. Construction from `wl_client` is explicitly unsafe and centralized in the
  Wayland support layer. It is an opaque identity value and is never converted back
  into a pointer for dereference.
- Existing wire object IDs remain wire IDs. They are not substituted for compositor
  identities where IDs can collide across clients.

`RouterWindowDriver` keeps a table equivalent to:

```swift
private struct ToplevelEntry {
    let windowID: WindowID
    var pendingPlan: ConfigurePlan?
    var replanReason: ConfigureReason
}

private var toplevelState: [XdgToplevelID: ToplevelEntry] = [:]
```

The table remains because it correlates an xdg role with the authoritative window and
holds configure-planning state. The driver's callable API takes `XdgToplevel`, derives
its `XdgToplevelID` internally, and never exposes the ID where an object reference is
available.

Do not use `[XdgToplevel: ToplevelEntry]`: a strong dictionary key would retain the
toplevel, prevent resource-owned teardown, and defeat `deinit` cleanup.

Keep and nominally type these real protocol registries:

- `XdgShell.popupStacks`, which enforces one popup stack per Wayland client.
- `WlSeat.pointers`, `WlSeat.keyboards`, and `WlSeat.touches`, which track live device
  resources by client and capability epoch.
- Seat serial, inhibitor, data-device, and focus indexes whose keys represent client
  or wire-resource identity.

Delete a registry only after every value it carries has a single replacement owner and
all lookup behavior has been replaced. Actor isolation alone is not a reason to delete
one.

## Phase 1: Make Generated Server Dispatch the Isolation Boundary

Change `swift-wayland/Sources/SwiftWaylandGen/main.swift` so every generated server
request protocol is declared `@MainActor`.

For every generated request trampoline:

1. Validate required C arguments.
2. Recover the borrowed handler from `wl_resource` user data.
3. Enter `MainActor.assumeIsolated`.
4. Construct request-side Swift values, including `WlNewId` and converted fixed-point
   values, inside that isolated closure.
5. Invoke the handler inside the isolated closure.
6. Perform handler-associated resource destruction inside the same closure so an
   actor-isolated resource owner can run its isolated teardown synchronously.

Pure-destructor fallback behavior remains available when no conforming owner is
installed. The fallback may call `wl_resource_destroy` directly because no Swift
handler is recovered. When a handler exists, its default or overridden destroy method
runs under main-actor isolation.

Preserve these generated properties:

- The static vtable remains `nonisolated(unsafe)`.
- C function values remain `@convention(c)`.
- Owner recovery remains borrowed through `Unmanaged.takeUnretainedValue`; the
  resource owner continues to be retained by the existing resource-lifetime
  mechanism.
- Trampolines remain synchronous and return only after the request handler completes.
- Event senders remain callable from main-actor-isolated protocol objects. Do not add
  asynchronous dispatch to event sending.

Regenerate all of `swift-wayland/Sources/WaylandServerDispatch`. Do not hand-edit
generated files.

Add generator coverage by compiling and exercising a small generated server-dispatch
fixture whose handler is `@MainActor`. Verify that a C-shaped trampoline:

- invokes the handler while the caller is already on the main actor;
- preserves request argument decoding;
- preserves default and overridden destructor behavior;
- preserves create-and-destroy requests that carry `new_id`;
- destroys the resource in the same synchronous turn.

Do not add tests that inspect generated source text or declaration spelling. Tests
compile the generated interface and assert runtime behavior.

Phase 1 is complete when all generated server dispatch code builds without requiring a
nonisolated request witness.

## Phase 2: Isolate Router Ownership and Global Bind Entry Points

Annotate the router-side ownership spine with `@MainActor`:

- `WaylandRouterRuntime`;
- `NucleusWaylandRouter`;
- `NucleusWaylandRouter.GlobalRegistration`;
- `NucleusWaylandRouter.GlobalHandle`;
- shared protocol-global implementations retained by the router.

Keep raw display and event-loop access inside this actor-isolated ownership spine.
`WaylandRouterRuntime.dispatchClientsNonBlocking()` and the production reactor entry
remain the authoritative synchronous dispatch paths.

Convert every handwritten global bind callback to this shape:

```swift
private static let bind: @convention(c) (...) -> Void = { ..., data, ... in
    guard let owner = unsafe NucleusWaylandRouter.impl(data, as: Owner.self)
    else { return }
    MainActor.assumeIsolated {
        owner.bindClient(...)
    }
}
```

The C callback itself remains nonisolated. All owner access, resource-owner creation,
registration mutation, and protocol initialization happen inside
`MainActor.assumeIsolated`.

Apply the same rule to handwritten resource destroy callbacks and hand-built vtables
that are not emitted by `SwiftWaylandGen`. Centralize repeated callback shapes in the
Wayland support layer where a helper can preserve the exact C ABI type. Do not retain a
parallel token-based callback path.

Mark teardown-bearing router objects with `isolated deinit`. Ensure the destruction
order remains:

1. destroy globals and resource registrations;
2. run protocol-owner teardown;
3. release the display and underlying libwayland state.

Phase 2 is complete when the router ownership graph is main-actor-isolated and every C
entry into it has an explicit synchronous isolation assertion.

## Phase 3: Convert the Complete XDG Shell Cluster

Convert the xdg-shell cluster as one connected unit:

- `XdgShell`;
- xdg-wm-base binding owners;
- `XdgPositioner`;
- `XdgSurface`;
- `XdgToplevel`;
- `XdgPopup`;
- `XdgToplevelDecoration` and its manager-side peers;
- weak boxes and ledgers whose mutable state belongs to these objects.

Add `@MainActor` to the classes and to xdg-shell policy protocols, including
`XdgShellDelegate` and `DecorationDelegate`. Remove `nonisolated` from conforming
request methods now that generated dispatch enters the actor before invoking them.

Use `isolated deinit` for `XdgToplevel`, `XdgSurface`, popup objects, decoration
objects, and every peer whose teardown reads or mutates isolated state. Preserve the
existing resource-owned lifetime graph:

- resources own their Swift semantic owners;
- parent/manager links remain `unowned` only where the parent strictly outlives the
  child;
- relationship links that may disappear independently remain `weak`;
- teardown does not create a new strong cycle.

Add `XdgToplevelID` and mint it in `XdgShell` with a monotonically increasing counter.
Use the ID for persistent model correlation. Do not derive it with
`Unmanaged.passUnretained`, `toOpaque`, `ObjectIdentifier`, or a heap-address integer.
Handle counter exhaustion as a precondition failure; identity reuse during one
compositor lifetime is invalid.

Change `RouterWindowDriver` xdg-shell entry points to typed signatures:

```swift
func configure(
    for toplevel: XdgToplevel,
    initial: Bool
) -> XdgToplevelConfigure

func toplevelConfigureSent(
    _ toplevel: XdgToplevel,
    serial: UInt32,
    initial: Bool
)

func toplevelDidCommit(
    _ toplevel: XdgToplevel,
    ackedSerial: UInt32,
    hasBuffer: Bool
)

func toplevelDidRequest(
    _ toplevel: XdgToplevel,
    _ request: XdgToplevelRequest
)

func toplevelWillDestroy(_ toplevel: XdgToplevel)
```

Read `xdgSurface`, geometry, parent, and committed surface state directly within these
main-actor methods. Delete the paired `configureImpl(token:surfaceId:initial:)`,
`setTitleImpl(token:_:)`, `setParentImpl(token:parentToken:)`, and equivalent
token-projection APIs. There is one typed implementation per operation.

Rename `byToplevel` to `toplevelState` and key it by `XdgToplevelID`. Retain
`ToplevelEntry` because it owns real policy correlation and pending configure state.
Change the WindowManager xdg role-creation seam to accept the nominal
`XdgToplevelID`, deleting the bare `UInt64` xdg-toplevel identity API and fixing every
caller in the same phase.

Delete:

- the local `token(_:)` helper in `RouterWindowDriver`;
- every toplevel `UInt(bitPattern:)` conversion;
- `token: UInt` and `parentToken: UInt?` method parameters;
- comments that describe pointer tokens as the isolation contract;
- main-actor thunks whose only work was projecting fields and re-looking up the
  toplevel.

Keep:

- `toplevelState` cleanup in `toplevelWillDestroy`;
- pending configure-plan correlation;
- replan-reason correlation;
- surface-to-window indexing used by scene, focus, and input paths;
- popup-stack ordering.

Change `popupStacks` from `[UInt: [WeakPopup]]` to
`[WaylandClientID: [WeakPopup]]`. Continue removing dead weak entries on mutation and
topology walks. This is nominal typing of a real registry, not registry removal.

Phase 3 is complete when the entire xdg-shell request/configure/commit/destroy cycle
contains no Swift-object-address token and all xdg policy calls are statically
main-actor-isolated.

## Phase 4: Convert Core Surface and Subsurface State

Convert the core surface cluster:

- `WlCompositor`;
- compositor binding owners;
- `WlSurface`;
- `WlSubcompositor`;
- `WlSubsurface`;
- region, callback, buffer-reference, presentation, and subsurface-topology owners
  whose mutable state is reachable from a surface;
- `WlSurfaceRole`, commit-observer, and scene delegate protocols.

Annotate `WlSurfaceRole`, `WlSurfaceCommitObserver`, and `SurfaceSceneDelegate` with
`@MainActor` when every conformer is part of the compositor turn. Remove projection
thunks that converted a surface to an integer only to re-resolve it through
`WlCompositor`.

Preserve nominal compositor surface identity. Wire object IDs remain unsuitable as
cross-client identities. Where an existing surface ID is already a compositor-minted
process-unique value, introduce a nominal `WlSurfaceID` around it and replace bare
`UInt32` parameters at policy boundaries. Keep raw wire IDs only in code that
specifically implements the Wayland wire contract.

Rewrite `WlSurface` teardown as `isolated deinit`. Keep buffer release, presentation
discard, frame callback destruction, role teardown, subsurface detachment, cursor
unbinding, compositor removal, and scene notification in their existing semantic
order. Remove the pointer-cursor address token by storing an actor-isolated weak or
unowned typed relationship whose lifetime contract matches the existing ownership
graph.

Do not move resource destruction into asynchronous work. A surface destroy request
must complete all synchronous protocol and model teardown before returning to
libwayland.

Phase 4 is complete when surface commit, role validation, scene publication, and
surface destruction carry typed actor-isolated references or nominal IDs.

## Phase 5: Convert Seat, Input, and Data-Device State

Convert the input and data-transfer cluster:

- `WlSeat` and `SeatBinding`;
- pointer, keyboard, and touch resource owners;
- popup grab and serial ledgers;
- relative-pointer and pointer-constraint managers;
- text-input objects;
- data-device, data-source, data-offer, primary-selection, and data-control objects;
- their router policy delegates.

Make the cluster `@MainActor` and add `isolated deinit` wherever teardown mutates seat,
focus, selection, drag, or resource registries.

Replace client-address `UInt` keys with `WaylandClientID` in:

- pointer, keyboard, and touch resource maps;
- serial ledgers;
- focus-client tracking;
- inhibitor keys;
- data-device and selection indexes;
- popup-grab authorization state.

Keep the pointer, keyboard, and touch maps. They deliver events to every live resource
for one client and enforce capability epochs. Clear them on the same capability
transitions as today.

Replace nonisolated router-driver methods that extract a client key, surface ID, or
resource bits before `assumeIsolated` with actor-isolated methods accepting the typed
seat, surface, source, offer, or device object. Raw `wl_resource` pointers remain only
where libwayland validation or event sending requires the live resource.

Phase 5 is complete when focus, input authorization, popup grabs, clipboard,
drag-and-drop, and text input no longer erase Swift owners to cross into policy code.

## Phase 6: Convert Remaining Protocol Globals and Drivers

Apply the established boundary to the remaining compositor-owned Wayland protocols:

- layer shell and session lock;
- activation and foreign toplevel protocols;
- output and xdg-output;
- presentation, dmabuf, explicit synchronization, screencopy, and gamma control;
- workspace, decoration, blur, background-effect, cursor-shape, and other extension
  globals;
- Xwayland-shell association objects.

For each cluster:

1. Mark mutable protocol owners `@MainActor`.
2. Mark compositor-turn delegate protocols `@MainActor`.
3. Change delegates to accept typed owners directly.
4. Replace address integers with nominal protocol identities only where persistent
   indexing remains necessary.
5. Preserve registries that carry protocol fan-out, ordering, authorization, or
   lifetime state.
6. Add `isolated deinit` where teardown reads isolated state.
7. Delete the replaced thunk and token APIs in the same phase.

Do not preserve dual token and typed-reference pipelines. Each converted cluster lands
with all of its callers updated.

Phase 6 is complete when every mutable server-side Wayland protocol object follows the
same generated or handwritten C-boundary isolation rule.

## Phase 7: Remove Erasure Infrastructure and Tighten Enforcement

Delete all helpers whose purpose is converting a Swift Wayland object reference into a
raw integer identity:

- `Unmanaged.passUnretained(object).toOpaque()` object-token helpers;
- `UInt(bitPattern:)` conversions of Swift object addresses;
- pointer-token comments and parameter names;
- lookup tables whose only payload was the original erased Swift reference;
- nonisolated delegate thunks that exist only to manufacture Sendable projections.

Retain explicitly documented raw identities for C-owned entities such as `wl_client`
and `wl_resource`, but expose them to Swift policy only through nominal types or typed
resource wrappers.

Add a focused lint/check in the existing build tooling that rejects newly introduced
Swift-object token helpers in `NucleusCompositorWaylandRuntime`. The check targets the
unsafe conversion operation, not declarations or API source shape, and reports the
offending conversion. It must not reject legitimate `Unmanaged` owner recovery at a C
ABI boundary.

Update isolation comments to state the executor invariant:

- production dispatch is initiated by the `@MainActor` runtime;
- libwayland invokes callbacks synchronously during that dispatch;
- generated and handwritten C callbacks reassert the main actor;
- typed mutable state is inaccessible outside the main actor.

Phase 7 is complete when repository search finds no Swift-object address token in the
Wayland policy path and all remaining raw-pointer conversions are documented C ABI or
C-owned identity operations.

## Verification

Source the host environment before every compile or test invocation:

```sh
source tools/host-env.sh
```

Run verification after each phase in this strict order:

1. Regenerate Wayland bindings after generator changes:

   ```sh
   collider generate wayland
   ```

2. Build and test the Wayland package:

   ```sh
   swift build --package-path swift-wayland
   swift test --package-path swift-wayland
   ```

3. Build the compositor core package:

   ```sh
   swift build --package-path compositor/compositor-core
   ```

4. Run compositor-core tests, including the existing Wayland wire fixtures:

   ```sh
   swift test --package-path compositor/compositor-core
   ```

5. Run the complete checkout build and test gates:

   ```sh
   collider build
   collider test
   ```

The behavioral test matrix must cover:

- xdg toplevel create, initial configure, ack, map, reconfigure, unmap, and destroy;
- title, app ID, parent, maximize, fullscreen, minimize, move, resize, and window-menu
  requests;
- parent-cycle rejection and parent teardown reparenting;
- popup nesting, per-client stack ordering, grabs, dismissal, and reactive
  repositioning;
- surface commit, null-buffer unmap, callbacks, presentation feedback, and buffer
  release during teardown;
- multiple clients with colliding wire object IDs;
- seat capability removal and re-add with old resources remaining inert;
- pointer and keyboard focus authorization by client and serial;
- selection and drag cancellation during surface, source, device, and client teardown;
- compositor shutdown with live client resources.

Use the thread-sanitizer-capable test configuration where available for the Wayland
wire fixtures. No test may depend on an asynchronous actor hop; request effects must be
observable immediately after the synchronous dispatch turn.

## Completion Criteria

The refactor is complete when all of the following hold:

- Mutable compositor-owned Wayland protocol objects are `@MainActor`.
- Generated server request protocols are `@MainActor`.
- Every generated and handwritten C entry point asserts main-actor isolation before
  accessing a Swift owner.
- No mutable Wayland wrapper uses `@unchecked Sendable`.
- No second Wayland global actor or custom executor exists.
- Router and policy APIs accept typed Wayland objects or nominal IDs, never
  Swift-object address integers.
- `RouterWindowDriver` retains its necessary configure-policy state under
  `XdgToplevelID`.
- Popup, seat-device, serial, and data-device registries retain their protocol
  semantics under nominal client/resource identities.
- All teardown that touches isolated state uses `isolated deinit` and remains
  synchronous.
- Generated output, the Wayland package, compositor-core, and complete-checkout build
  and test gates pass.
