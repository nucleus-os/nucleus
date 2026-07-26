# Wayland Client Proxy and Resource Safety

## Invariant

Wayland XML remains the single source of truth for protocol interfaces, versions,
requests, events, argument types, enum and bitfield values, object relationships,
`new_id` ownership, and destructor behavior.

Generated Swift owns every mechanical translation of that schema on both sides of
the connection:

- client interface descriptors;
- registry binding types;
- owned client proxies;
- client request methods;
- client event listeners;
- owned event-created proxies;
- server request dispatch;
- server event sending;
- typed child and server-created resource factories;
- interface-specific protocol errors.

Handwritten code owns connection policy, compositor behavior, protocol state
machines, authorization, layout, rendering, and application models. It does not
carry routine `OpaquePointer` proxies, call wayland-scanner request functions,
reconstruct escaped proxy addresses, recover client pointers to create related
objects, or repeat native resource destruction and SHM access mechanics.

Unsafe operations remain explicit inside the generated ABI boundary and small
handwritten native wrappers. Application, shell, Android host, and compositor policy
consume safe typed APIs.

Macros are not part of this architecture. XML-derived APIs are emitted as visible,
cacheable Swift source through the existing SwiftSyntax generator. Non-XML native
mechanics use ordinary handwritten types with narrow unsafe implementations.

Status: complete — Phases 1–11 complete

## Progress

- [x] Phase 1: Establish owned client proxy semantics.
- [x] Phase 2: Generate the complete client request surface.
- [x] Phase 3: Generate typed client registry binding.
- [x] Phase 4: Migrate client consumers and delete raw paths.
- [x] Phase 5: Restore interface-specific error checking.
- [x] Phase 6: Type retained server resource references.
- [x] Phase 7: Add scoped SHM buffer access.
- [x] Phase 8: Generate parent-scoped server-created objects.
- [x] Phase 9: Consolidate display operations.
- [x] Phase 10: Remove pure forwarding global bindings.
- [x] Phase 11: Run the final unsafe and boilerplate audit.

### 2026-07-25 Baseline Audit

Phase 1 is the first incomplete phase. The tree already generates typed client
interface descriptors and nonescapable `WaylandBorrowedProxy` event values, but it
does not define `WaylandProxy`, retain listener owners in proxy-scoped contexts, or
represent event `new_id` arguments as owned proxies. `WaylandRegistry` and all
production client consumers still own raw `OpaquePointer` values. Generated
listeners still install `Unmanaged.passUnretained(owner)` directly.

The later server phases also remain incomplete. Existing typed server request
dispatch is retained as the starting substrate, not counted as completion of
Phases 5–10.

### 2026-07-25 Phase 1 Complete

`WaylandProxy<Interface>` now privately owns its native proxy, negotiated version,
live state, connection lifetime, and one retained listener context. Local
destruction and generated protocol-destructor invalidation are distinct operations;
both reject duplicate use, and deinitialization only destroys local proxy storage.
`WaylandConnection` moved native display ownership into the shared connection token,
so a proxy prevents `wl_display_disconnect` until its own teardown completes.

Generated listeners now install only through `WaylandProxy.installListener(_:)`.
There is no raw `addListener` compatibility overload. Listener userdata recovers the
retained proxy-owned context, ordinary object arguments remain
`WaylandBorrowedProxy`, and event `new_id` arguments become owned
`WaylandProxy` values using the parent proxy's connection token.

Verified:

- `swift build --package-path swift-wayland`;
- `swift test --package-path swift-wayland`;
- connection retention through proxy release;
- local and protocol-destructor invalidation;
- duplicate destruction and post-destruction rejection;
- listener-owner retention, duplicate installation rejection, and teardown;
- a real foreign-toplevel loopback event whose `new_id` proxy escapes and remains
  live after the callback.

Shell and Android raw listener call sites no longer compile against the generated
surface. This is intentional forward-only staging: Phases 2–4 replace their raw
request, registry, proxy, and listener paths without a compatibility API.

### 2026-07-25 Phase 2 Implementation Progress

The generator now emits the complete request surface for all 192 selected client
interfaces. Every ordinary request is a constrained method on its typed
`WaylandProxy`; `wl_registry.bind` is a generated generic typed bind operation.
Generated nonvariadic C wrappers marshal requests from XML opcodes and signatures,
so the Swift surface does not depend on the host's possibly older
wayland-scanner inline declarations.

The generated methods now cover integers, open enums, bitfields, fixed-point
values, nullable and nonnullable strings and objects, scoped array arguments,
consuming owned file descriptors, typed `new_id` results, request version gates,
and protocol destructors. File descriptors close after the marshalling call,
including failure paths. A destructor invalidates the owned proxy only after its
wire request has been emitted.

Verified:

- the entire generated client dispatch target compiles;
- the full `swift-wayland` test suite passes;
- a real compositor loopback creates a typed `wl_surface`;
- an unsupported `wl_surface.damage_buffer` is rejected before entering C;
- a real release-style request reaches the server and invalidates its proxy
  exactly once;
- array request storage is copied and scoped to the marshalling call;
- consuming request file descriptors close after marshalling.

The named protocol-family matrix now runs over one real libwayland client/server
socket. It binds the selected globals, creates the typed client object graph, and
checks the exact emitted object/opcode pairs before server dispatch can mask a
client marshalling error. The matrix covers:

- core surfaces;
- XDG surfaces and toplevels;
- layer surfaces;
- session-lock surfaces;
- text input;
- data sources, devices, and offers;
- DMA-BUF parameters and immediate buffers;
- explicit-sync timelines, surfaces, and acquire/release points;
- presentation feedback.

The dedicated matrix and the complete `swift-wayland` suite pass. Phase 2 is
complete.

### 2026-07-25 Typed Registry Progress

The old descriptor-based `DesiredGlobal`, raw `BoundGlobal.proxy`, registry-wide
untyped bind callbacks, and `WaylandConnection.adoptProxy` escape hatch have been
deleted. `DesiredGlobal<Interface>` now captures typed bind and removal policy,
`BoundGlobal<Interface>` carries an owned typed proxy, and registry lookup returns
`WaylandProxy<Interface>` values. Heterogeneous desired globals use one
`AnyDesiredGlobal` requirement box; bound values are erased only after the generic
requirement has checked and bound the generated interface type.

The `swift-wayland` singleton, multi-instance, version-clamping, removal, listener,
and connection-lifetime loopbacks use the typed API and pass. Shell now uses the
typed registry throughout. Android still requires its Phase 3/4 consumer migration;
the removed raw listener and registry APIs intentionally leave that package red
until its migration lands.

### 2026-07-25 Main-Actor Client Object Model

`WaylandConnection`, prepared reads, the typed registry, and every owned
`WaylandProxy` are `@MainActor`. Proxy deinitialization is isolated. Generated C
callbacks recover listener context outside isolation, then enter
`MainActor.assumeIsolated` once at the generated ABI boundary and deliver typed
values to generated `@MainActor` event protocols.

This promotes the shell event-loop invariant into the type system. Owned proxies
are Sendable by global-actor isolation, while mutable access stays checked.
Consumers no longer need `@unchecked Sendable`, pointer-address tokens, or
handwritten actor bridge thunks. Existing consumer thunks are removed as their
clusters migrate; the final audit rejects any that remain outside generated C
dispatch.

Both owned and borrowed proxies expose a stable integer `identity` for routing.
Identity cannot recover a native pointer. The only public raw-proxy operation is
the explicitly unsafe, synchronous `withUnsafeNativeProxy`, used for genuine native
integration boundaries.

### 2026-07-25 Shell Client Migration Complete

The shell connection, typed globals, compositor, outputs, seat, pointer, keyboard,
cursor shape, layer shell, session lock, foreign toplevel, screencopy, text input,
data control, clipboard, and data-device drag/drop clusters now retain typed owned
proxies and issue generated requests. Event-created foreign-toplevel, data-control,
and core data-offer objects arrive as owned proxies. Dictionary keys use safe proxy
identity; no consumer reconstructs a pointer from that identity.

Clipboard and drag/drop request file descriptors transfer through the generated
move-only descriptor API. Their existing client/server behavior tests pass.

`NativeSurfaceRegistry` retains typed `WlSurfaceClient` proxies. It opens the
native pointer only lexically when `ShellRenderEngine` creates the Vulkan Wayland
surface, using `withUnsafeNativeProxy`. The renderer remains the sole shell
consumer of that native proxy seam.

Verified:

- `swift build --package-path shell`;
- `swift build --package-path shell --target NucleusShellWayland`;
- `swift build --package-path shell --target NucleusShellPasteboard`;
- `swift test --package-path swift-wayland`;
- shell data-control client/server behavior;
- shell drag/drop negotiation, transfer, cancellation, and teardown;
- shell platform transport stress coverage.

The complete shell test command compiles all test targets. Its first combined run
was stopped after an aggregate runner stall; the affected Wayland pasteboard,
drag/drop, and transport suites pass when run directly. Repeat the complete suite
after the Android migration and final generated-handler cleanup.

### 2026-07-25 Android Client Migration Complete

The Android surface probe and display host now use typed registry requirements and
retain typed compositor, DMA-BUF, XDG shell, syncobj, presentation, surface,
timeline, buffer, and feedback proxies. Their manual descriptor switches,
`BoundGlobal` pointer extraction, raw listener installation, and direct protocol
request calls are deleted.

DMA-BUF and syncobj file descriptors cross generated requests as move-only owned
descriptors. Descriptors whose lifetime remains owned by an IPC packet or native
waiter are duplicated before transfer. Exported one-shot timeline descriptors
transfer directly. Presentation feedback is retained by owned proxy rather than
an address that is later reconstructed for destruction.

Verified:

- `swift build --package-path android-runtime`;
- `swift build --package-path android-runtime --target
  NucleusAndroidSurfaceProbeCore`;
- `swift build --package-path android-runtime --target
  NucleusAndroidDisplayHostCore`;
- no direct Wayland client request call remains in shell or Android Swift
  production sources;
- no routine Wayland client proxy remains stored as `OpaquePointer` in those
  consumers.

Phase 3 is complete.

### 2026-07-25 Phase 4 Complete

Generated client event protocols are `@MainActor`. Generated C callbacks perform
the single executor assertion at the ABI boundary, then call actor-isolated
handlers. Every handwritten shell listener and `WaylandRegistry` conformance is an
ordinary actor-checked method.

The obsolete handwritten `nonisolated`/`MainActor.assumeIsolated` shells and their
comments are deleted. Production shell and Android Swift sources contain no direct
Wayland client requests. Their retained Wayland proxies are typed; the remaining
`OpaquePointer` values belong to XKB, Android syncobj native helpers, and the
renderer-facing native display seam.

Verified:

- zero `nonisolated func` and `MainActor.assumeIsolated` occurrences in shell
  Wayland, input, pasteboard, and typed registry sources;
- `swift build --package-path shell`;
- `swift build --package-path android-runtime`;
- `swift test --package-path swift-wayland`.

Phase 4 is complete.

### 2026-07-25 Phase 5 Complete

The public generic `postError<Code: WaylandProtocolErrorValue>` escape hatch is
deleted from both `WaylandRequest` and `WaylandResourceHandle`. The raw numeric
operation is package-scoped inside `WaylandServer`. Generated per-interface
extensions remain the only ordinary public `postError` surface, so the resource
interface and error enum must agree at compile time.

`WaylandCrossInterfaceErrorPolicy.swift` declares the two protocol-defined
exceptions as named request and retained-handle operations:

- `postToplevelDecorationAlreadyConstructedError` on
  `ZxdgDecorationManagerV1Server`, carrying
  `ZxdgToplevelDecorationV1Error.alreadyConstructed`;
- `postLayerShellInvalidLayerError` on `ZwlrLayerSurfaceV1Server`, carrying
  `ZwlrLayerShellV1Error.invalidLayer`.

Compositor policy uses these explicit names. The layer-surface `set_layer` path no
longer relies on the numeric coincidence between layer-shell `invalidLayer` and
layer-surface `invalidSize`.

Verified:

- removing the generic method makes the decoration mismatch fail to type-check;
- the complete compositor-core package builds with only same-interface posts and
  the two named exceptions;
- loopback tests inspect the `wl_display.error` wire event and verify the offending
  object ID and numeric code for one same-interface error and both exceptions;
- retained-handle operations return `false` and emit no wire data after native
  resource destruction;
- no public generic or raw-code error-posting API remains.

Phase 5 is complete.

### 2026-07-25 Phase 6 Implementation Progress

`WaylandResourceReference` now carries its `WaylandServerInterface` type for its
complete lifetime. One private type-erased lifetime object owns the native destroy
listener and optional retained semantic owner; native destruction clears that
shared state before libwayland frees the resource. The public typed reference and
handle expose only liveness, version, client identity, object ID, destruction,
no-memory reporting, and retained semantic-owner recovery.

Raw handle construction and native-resource access are package-scoped. Compositor
policy can no longer reconstruct a retained resource as another protocol
interface. Ownerless callback and presentation-feedback factories return typed
references, and callback/feedback call sites no longer recover handles from raw
resources.

The compositor migration landed directly on this end state. Raw convenience
properties were deleted as the compiler found them: liveness uses `isLive`, wire
diagnostics use `objectID`, client association uses `clientID`, and teardown uses
`destroy()`. No compatibility handle or temporary public pointer escape is being
introduced.

Verified:

- native destruction and client disconnect clear typed liveness;
- explicit destruction is idempotent and clears version, client, and object ID;
- retained semantic storage survives wire destruction and releases with the typed
  reference;
- typed owner construction failure rolls back the native resource;
- the complete `swift-wayland` test suite passes;
- `swift build --package-path compositor/compositor-core`;
- compositor production policy contains no direct `wl_resource_destroy`.

Phase 6 is complete.

### 2026-07-25 Phase 7 Complete

`WaylandResourceReference<WlBufferServer>` now exposes validated SHM metadata and
two synchronous scoped storage operations: read-only `withShmBytes` and writable
`withMutableShmBytes`. The implementation recognizes SHM buffers, rejects
nonpositive dimensions and negative strides, checks byte-count multiplication,
and balances libwayland begin/end access with `defer`, including throwing bodies.
The raw pixel pointer remains closure-scoped.

Core surface metadata, cursor extraction, screencopy validation, scene import,
renderer upload, and screencopy readback use the typed wrapper. Read and write
access are distinct at the API level; screencopy does not cast read-only storage
back to mutable memory. DMA-BUF paths continue to use retained semantic owners.

Verified:

- real ARGB8888 and XRGB8888 SHM buffers report the expected metadata;
- read-only pixels can be copied and remain valid after the access scope;
- mutable screencopy-style access writes through to the SHM pool;
- a throwing body is followed by successful access, proving balanced teardown;
- zero, negative, and otherwise invalid native layout values are rejected;
- compositor production sources contain no direct `wl_shm_buffer_*` operation;
- `swift build --package-path compositor/compositor-core`;
- targeted SHM and resource-ownership tests pass.

Phase 7 is complete.

### 2026-07-25 Phase 8 Complete

The generator emits parent-scoped factories for all 15 selected XML events whose
sole argument is a typed `new_id`. Each generated method supplies only the
interface-specific child type, version contract, owner constraint, and event
publisher. `WaylandResource.createChild` owns the common transaction:

1. require a live parent;
2. derive its native client;
3. clamp the child version;
4. allocate and install the typed child owner;
5. publish the event;
6. run the policy installation callback only after publication;
7. destroy the child on owner or publication failure;
8. post `wl_display.no_memory` through the parent on allocation failure.

Foreign-toplevel, workspace/group, core data-offer, data-control-offer, and
DMA-BUF server-created buffers use these generated methods. The old public
`Interface.createResource(client:...)` generated surface is deleted, and
compositor policy has no manual related-object allocation site.

The server-dispatch source layout now separates generated and handwritten
ownership. The 192 XML-derived interfaces live under `Generated/`; the
cross-interface error policy and typed SHM façade live under `Support/`.
Regeneration replaces only `Generated/`, so it cannot erase handwritten support.

Verified:

- parent/client association and child version clamping;
- owner construction rollback;
- event publication rollback;
- owner installation after successful publication;
- deterministic native allocation failure and the exact
  `wl_display.no_memory` wire error;
- dead-parent rejection before allocation;
- a real foreign-toplevel `new_id` event published through its generated factory;
- all 15 eligible event interfaces call the shared transaction;
- no compositor production `createResource` call remains;
- `swift test --package-path swift-wayland`;
- `swift build --package-path compositor/compositor-core`.

Phase 8 is complete.

### 2026-07-25 Phase 9 Complete

`WaylandDisplay` now owns serial minting through `nextSerial()`. Its native display
and event-loop pointers are package-scoped implementation details rather than
public server API.

XDG shell, layer shell, session lock, seat, and the core data-device manager retain
the `WaylandDisplay` that backs their router. Their constructors require the
display, so a manager cannot silently cache a borrowed native pointer or mint
serials against an unrelated display. `WaylandRouterRuntime` establishes this
ownership when it constructs the complete protocol graph.

Verified:

- successive `WaylandDisplay.nextSerial()` calls produce nonzero increasing
  serials;
- compositor production sources contain no direct
  `wl_display_next_serial` call;
- compositor production managers contain no cached native display pointer;
- `swift test --package-path swift-wayland`;
- `swift build --package-path compositor/compositor-core`;
- the compositor Wayland test target compiles after its typed-resource fixtures
  were brought forward from Phase 6.

The focused compositor runtime test run exposed heap corruption in
`layerShellRejectsBufferBeforeAckConfigure`. Phase 11 traced it with AddressSanitizer
to foreign `wl_shm_buffer` userdata being interpreted as a Swift resource owner and
replaced that unchecked recovery with a checked runtime-owned resource registry.

Phase 9 is complete.

### 2026-07-25 Phase 10 Complete

Every generated server interface now has a constrained
`global(implementation:advertisedVersion:installed:)` overload for implementations
that directly conform to the interface request protocol. The implementation is the
resource owner, and the shorter installation callback receives the implementation
and typed resource handle. The existing generic owner factory remains for globals
that genuinely construct per-client binding state.

Compositor registration uses the direct overload everywhere an identity owner
closure previously returned the implementation. Request conformances moved onto
the shared manager and ten one-property binding classes were deleted:

- compositor;
- decoration manager;
- layer-shell manager;
- subcompositor;
- relative-pointer manager;
- pointer-constraints manager;
- cursor-shape manager;
- XDG activation manager;
- XDG output manager;
- keyboard-shortcuts-inhibit manager.

Four binding types remain because they encode real ownership:

- `SeatBinding` tracks a per-client seat resource and unregisters it on teardown;
- `WlOutputBinding` tracks a per-client output resource;
- `XdgWmBaseBinding` retains the per-client wm-base resource used by shell
  behavior;
- `XdgForeignBinding` deliberately projects one shared policy object into exporter
  and importer protocol roles.

Verified:

- no identity owner closure remains in compositor production sources;
- no semantically empty binding class remains;
- the generated direct-owner overload drives a real output loopback;
- `swift test --package-path swift-wayland`;
- `swift build --package-path compositor/compositor-core`.

Phase 10 is complete.

### 2026-07-25 Phase 11 Complete

The final audit landed directly on the intended ownership model. No transitional
proxy, resource, binding, or compatibility API remains.

Two lifetime faults surfaced during the complete gates:

- a proxy-owned listener context strongly retained the listener owner while the
  owner retained the proxy, preventing client disconnect; the context now retains
  the connection lifetime and weakly references the owner, so callbacks acquire a
  live owner for their duration without creating an ownership cycle;
- generic resource-owner lookup interpreted foreign libwayland userdata as a Swift
  object; `WaylandResource` now registers only resources it creates and returns
  `nil` for foreign resources without reading their userdata.

The production audit confirms:

- shell and Android contain no routine direct client requests, raw stored proxies,
  pointer-bit proxy escape or reconstruction, or direct listener installation;
- compositor policy contains no direct `wl_resource_destroy`,
  `wl_resource_get_client`, `wl_shm_buffer_*`, or `wl_display_next_serial` call;
- no public generic cross-interface error API, untyped retained resource, raw-client
  child factory, identity owner closure, or empty forwarding binding remains;
- the four remaining binding types encode per-client state, teardown, or deliberate
  multi-role projection;
- remaining unsafe sites belong to generated protocol ABI, connection/resource
  substrate, scoped SHM access, XCB/Xwayland, libinput/XKB, Vulkan/DRM, file
  descriptor/syscall integration, or another explicit native boundary.

Generated output produced the identical aggregate SHA-256
`54a8e64e29fdbe4877a3eb60da85ae56500b9e7f803968bbd3277de9ef958dab`
before and after regeneration.

Verified:

- generator and protocol-model tests;
- `swift build --package-path swift-wayland`;
- `swift test --package-path swift-wayland`;
- `swift build --package-path shell`;
- `swift test --package-path shell`;
- `swift build --package-path android-runtime`;
- `swift test --package-path android-runtime`;
- `swift build --package-path compositor/compositor-core`;
- `swift test --package-path compositor/compositor-core`;
- `collider generate wayland`;
- `collider build`;
- `collider test`, including loopback, loader, GPU-headless, and release stress
  lanes.

The checkout-wide test workflow encountered two unrelated intermittent failures in
core observation and compositor-shell tests. Each exact failing test passed on its
immediate isolated rerun, and the resumed complete Collider workflow passed.

Phase 11 is complete.

## Completion Inventory

The server request/event generator has already removed the major handwritten ABI
surface:

- 192 generated server interface files;
- 192 generated client interface files;
- no handwritten Wayland request trampolines;
- no handwritten global C callbacks;
- no routine raw server event senders;
- no numeric compositor protocol-error posts.

The client and server resource substrates now provide:

- typed owned proxies for registry, request-created, and event-created objects;
- generated typed client requests and listener installation;
- typed registry binding and lookup;
- interface-specific protocol errors;
- typed retained server resources;
- scoped SHM access;
- parent-scoped server-created objects;
- display-owned serial minting;
- direct-owner globals for shared implementations.

Generated trampoline `unsafe` markers, XCB/Xwayland native operations, libinput/XKB
callbacks, and the four libinput `Unmanaged` userdata operations are expected native
boundaries. They are not targets for mechanical erasure.

## End State

A client binds globals by interface type:

```swift
let registry = WaylandRegistry(
    connection,
    wanting: [
        DesiredGlobal<WlCompositorClient>(maximumVersion: 4),
        DesiredGlobal<WlOutputClient>(
            maximumVersion: 3,
            allowsMultiple: true),
    ])

let compositor: WaylandProxy<WlCompositorClient> =
    registry.singleton(WlCompositorClient.self)
```

A client request is fully typed:

```swift
let surface: WaylandProxy<WlSurfaceClient> =
    try compositor.createSurface()

surface.attach(buffer: buffer, x: 0, y: 0)
surface.damageBuffer(
    x: 0,
    y: 0,
    width: width,
    height: height)
surface.commit()
```

An event-created `new_id` arrives as an owned proxy that can be retained without
address erasure:

```swift
func toplevel(
    _ manager: WaylandBorrowedProxy<
        ZwlrForeignToplevelManagerV1Client
    >,
    toplevel: WaylandProxy<
        ZwlrForeignToplevelHandleV1Client
    >
) {
    let model = ForeignToplevelHandle(proxy: toplevel)
    toplevel.installListener(model)
    handles[toplevel.identity] = model
}
```

A server-created child is allocated from its live parent resource:

```swift
managerResource.createToplevel(
    owner: { resource in
        ForeignToplevelHandle(
            resource: resource,
            manager: manager,
            windowID: windowID)
    },
    installed: { handle in
        handles[windowID] = WeakReference(handle)
    })
```

Retained server resources remain interface-typed:

```swift
var buffer: WaylandResourceReference<WlBufferServer>?
var frameCallbacks:
    [WaylandResourceReference<WlCallbackServer>] = []
var presentationFeedbacks:
    [WaylandResourceReference<WpPresentationFeedbackServer>] = []
```

SHM access is scoped and balanced:

```swift
try buffer.withShmBytes { metadata, bytes in
    consume(metadata: metadata, bytes: bytes)
}
```

## Phase 1: Establish Owned Client Proxy Semantics

Add `WaylandProxy<Interface>` to `WaylandClientDispatch/Support`.

The proxy owns:

- the native proxy pointer;
- a strong connection-lifetime token;
- negotiated protocol version;
- live/destroyed state;
- one listener context when the interface has events.

Keep the native pointer private. Do not expose a general raw-pointer property.
Provide one narrowly unsafe native access operation for integrations that genuinely
require a proxy pointer, such as Vulkan Wayland surface creation.

Define these lifecycle rules:

1. A newly bound registry global produces one live owned proxy.
2. A request `new_id` result produces one live owned proxy.
3. An event `new_id` argument transfers one live owned proxy into the callback.
4. Ordinary event object arguments remain nonescapable
   `WaylandBorrowedProxy<Interface>` values.
5. A generated destructor or release request invalidates the owned proxy exactly
   once.
6. Later operations on an invalid proxy fail deterministically before entering C.
7. Proxy deinitialization never silently sends protocol policy requests.
8. Proxy deinitialization releases native client-side proxy storage when the
   protocol lifecycle permits local destruction.
9. Listener userdata remains alive for the complete native proxy lifetime.
10. The proxy retains the connection token so neither listener callbacks nor proxy
    teardown can outlive `wl_display`.

Represent listener userdata with a dedicated retained context owned by
`WaylandProxy`. The context weakly references the event handler and strongly retains
the connection token. Generated C callbacks recover that context and acquire the
handler for the callback duration. The consumer owns its handler explicitly, and a
handler that owns its proxy does not form a cycle.

Keep `WaylandBorrowedProxy` nonescapable. Remove every pointer-bit conversion used
to evade its lifetime.

Test:

- connection retention through an owned proxy;
- explicit destructor invalidation;
- duplicate destruction rejection;
- no request after destruction;
- listener owner non-retention and callback lifetime;
- listener teardown;
- ordinary borrowed object nonescape;
- event-created owned proxy escape;
- interface mismatch compile-time coverage through ordinary typed fixtures;
- proxy destruction after connection teardown prevention.

Phase 1 is complete when an owned typed proxy can represent a registry global,
request-created object, and event-created object without exposing a raw pointer.

## Phase 2: Generate the Complete Client Request Surface

Extend `SwiftWaylandGenerator` to emit constrained request methods on
`WaylandProxy<Interface>` for every XML request.

Map XML arguments as follows:

- `int` to `Int32`;
- `uint` to `UInt32`;
- referenced enums to generated open value types;
- referenced bitfields to generated option sets;
- `fixed` to `Double`;
- strings to `String` or `String?`;
- arrays to typed read-only collections accepted for the duration of the call;
- object arguments to `WaylandProxy<ReferencedInterface>` or an explicitly
  borrowed equivalent;
- FDs to move-only owned descriptors with explicit transfer;
- typed `new_id` results to `WaylandProxy<CreatedInterface>`.

Generate request availability checks from XML `since` metadata. A request introduced
after version 1 must precondition or return a typed unsupported-version result before
calling C.

Generate destructor behavior from XML request type:

- marshal the destructor once;
- invalidate the proxy;
- release listener state;
- prevent later requests.

Generate local proxy destruction only where the client ABI requires it and the
protocol does not supply a destructor request.

Do not expose the wayland-scanner request inlines to consumers. They remain an
implementation detail of the generated methods.

Add generator/model tests for:

- every wire argument category;
- nullable strings and objects;
- enum and bitfield arguments;
- fixed-point conversion;
- FD transfer and close-on-failure;
- request `new_id` return types;
- destructor requests;
- release-style requests;
- request version gating;
- interfaces with no requests.

Add loopback tests that create and drive:

- `wl_surface`;
- XDG surface and toplevel;
- layer surface;
- session-lock surface;
- text input;
- data source/device/offer;
- DMA-BUF parameters and buffer;
- explicit-sync timelines;
- presentation feedback.

Phase 2 is complete when generated client request methods cover the full selected
protocol closure and direct wayland-scanner request calls remain only inside
generated code.

## Phase 3: Generate Typed Client Registry Binding

Replace untyped `DesiredGlobal`, `BoundGlobal`, and descriptor comparisons with
interface-parameterized declarations.

Generate or implement:

```swift
DesiredGlobal<Interface: WaylandClientInterface>
BoundGlobal<Interface: WaylandClientInterface>
```

`DesiredGlobal` derives its interface descriptor and XML maximum version from
`Interface`. Handwritten policy supplies only:

- the maximum version the consumer actually implements;
- whether multiple globals are accepted;
- bind/remove behavior.

`WaylandRegistry` stores bound proxies behind an internal type-erased box only after
the interface type has checked the descriptor. Its public lookup operations recover
typed values:

```swift
registry.singleton(WlCompositorClient.self)
registry.instances(WlOutputClient.self)
```

Registry removal drops the advertisement entry but preserves the native lifecycle
of already-bound proxies until their protocol-specific teardown.

Migrate `ShellWaylandClient` away from:

- the manual interface-descriptor switch;
- raw descriptor reverse lookup;
- raw `BoundGlobal.proxy`;
- raw singleton and output proxies;
- direct listener installation.

Represent the shell's set of required globals as a typed policy declaration. Keep
the choice of globals and supported versions handwritten.

Migrate Android display-host and surface-probe registry consumers to the same typed
binding surface.

Test:

- singleton binding;
- multi-instance output binding;
- version clamping;
- duplicate singleton advertisements;
- global removal;
- connection retention;
- typed lookup mismatch;
- listener delivery immediately after binding.

Phase 3 is complete when registry consumers do not compare descriptors or store
untyped bound proxies.

## Phase 4: Migrate Client Consumers and Delete Raw Paths

Migrate client consumers in strict order:

1. shell connection, registry, compositor, output, and seat;
2. shell layer-shell and session-lock surfaces;
3. shell foreign-toplevel and screencopy;
4. shell text input and cursor shape;
5. shell data control and data-device drag/drop;
6. Android surface probe;
7. Android display host and explicit synchronization.

For each consumer:

- replace stored `OpaquePointer` proxies with `WaylandProxy<Interface>`;
- replace direct request functions with generated methods;
- attach listeners through the owned proxy;
- accept owned proxies for event `new_id` values;
- delete address-to-integer and integer-to-address reconstruction;
- remove consumer imports of `WaylandClientC` when no genuine platform seam
  remains;
- preserve the native display/proxy access required by Vulkan behind one narrowly
  unsafe adapter;
- delete duplicate local destruction bookkeeping now owned by the proxy.

Retain independent raw-wire fixtures where they intentionally verify opcodes,
marshalling, or error behavior without trusting the same generated client code under
test. Do not rewrite every wire-conformance test to use the generated client surface.

Run behavior tests after each consumer cluster. Do not retain parallel raw and typed
request paths.

Phase 4 is complete when shell and Android production code issue no routine direct
Wayland client request calls and retain no routine raw proxies.

## Phase 5: Restore Interface-Specific Error Checking

Make the generic `postError<Code: WaylandProtocolErrorValue>` operation unavailable
to policy code.

Keep the raw-code implementation package-scoped inside `WaylandServer`.
Generate only the same-interface overload:

```swift
extension WaylandRequest
where Interface == XdgSurfaceServer {
    func postError(
        _ code: XdgSurfaceError,
        message: String)
}
```

Do the same for `WaylandResourceHandle`.

Declare legitimate cross-interface error relationships explicitly in a small
handwritten protocol-policy extension. Do not infer them from prose descriptions.
The initial explicit cases include:

- duplicate decoration construction reported on the decoration-manager request
  using `ZxdgToplevelDecorationV1Error.alreadyConstructed`;
- layer-surface `set_layer` rejection using the layer-shell
  `invalidLayer` semantic value on the layer-surface resource.

Give cross-interface operations names that expose the exception instead of
overloading the ordinary same-interface method ambiguously.

Audit all compositor error posts after the generic escape hatch is removed. Replace
numeric coincidences such as spelling `invalid_layer` as `.invalidSize`.

Test:

- same-interface errors;
- each declared cross-interface exception;
- object ID and numeric wire code;
- behavior after resource destruction.

Phase 5 is complete when an arbitrary error value from another interface cannot
type-check at a request or resource call site.

## Phase 6: Type Retained Server Resource References

Parameterize `WaylandResourceReference` by interface:

```swift
WaylandResourceReference<
    Interface: WaylandServerInterface
>
```

The reference provides:

- a checked typed handle while the resource is live;
- `version`;
- `clientID`;
- wire object ID;
- explicit destruction;
- resource-liveness state;
- optional retained semantic storage needed by DMA-BUF buffers.

Keep the raw resource pointer private. Expose it only through package-scoped native
operations used by generated dispatch and the SHM wrapper.

Change ownerless generated factories to return typed references or handles rather
than raw resources. Replace `_createBare()` raw-pointer results for callbacks and
presentation feedback with typed objects.

Migrate retained server resources in strict order:

1. `wl_buffer`;
2. `wl_callback`;
3. `wp_presentation_feedback`;
4. output resources;
5. seat device resources;
6. data offers and sources;
7. screencopy buffers;
8. remaining one-shot notification resources.

Delete reconstruction such as:

```swift
reference.typedHandle(as: WlCallbackServer.self)
```

The interface type is already carried by the reference.

Add safe operations to `WaylandRequest` and `WaylandResourceHandle`:

- `destroy()`;
- `postNoMemory()`;
- `objectID`;
- `clientID`;
- liveness queries.

Use these operations to remove direct resource destruction and client/object lookup
from policy code.

Test:

- native destruction clears the typed reference;
- explicit destruction is idempotent;
- wrong-interface construction is impossible;
- retained semantic storage lifetime;
- one-shot event then destruction;
- client disconnect cleanup;
- request after destruction rejection.

Phase 6 is complete when retained compositor resources remain interface-typed for
their full Swift lifetime and policy performs no routine direct
`wl_resource_destroy`.

## Phase 7: Add Scoped SHM Buffer Access

Add `WaylandShmBufferView` to the handwritten Wayland server runtime.

Construction accepts a typed `WlBufferServer` reference or borrowed object and
returns nil for non-SHM buffers.

Expose immutable metadata:

- format;
- width;
- height;
- stride;
- validated byte count.

Validate:

- positive dimensions;
- nonnegative stride;
- row-byte requirements;
- multiplication and addition overflow;
- supported format requirements at the consumer boundary.

Expose pixel storage only through a synchronous nonescaping closure:

```swift
func withBytes<Result>(
    _ body: (
        WaylandShmMetadata,
        UnsafeRawBufferPointer
    ) throws -> Result
) rethrows -> Result
```

The wrapper performs balanced `wl_shm_buffer_begin_access` and
`wl_shm_buffer_end_access` with `defer`. The pixel pointer cannot escape the closure.

Migrate in strict order:

1. core `wl_surface` buffer metadata;
2. pointer-cursor image extraction;
3. screencopy buffer validation;
4. surface scene import;
5. renderer upload and readback.

Keep DMA-BUF handling separate; it uses semantic buffer owners and GPU lifetime
contracts, not SHM access.

Test:

- non-SHM rejection;
- every supported SHM format;
- invalid and overflowing layouts;
- begin/end balance on success and throw;
- zero-sized and negative native metadata rejection;
- copied pixel lifetime after the access scope.

Phase 7 is complete when compositor policy does not call
`wl_shm_buffer_begin_access`, `wl_shm_buffer_end_access`, or raw SHM metadata
functions directly.

## Phase 8: Generate Parent-Scoped Server-Created Objects

For XML events with typed `new_id` arguments, generate a creation operation on the
parent `WaylandResourceHandle`.

The operation:

1. validates that the parent is live;
2. derives the native client from the parent internally;
3. clamps the child version to the parent/event/interface contract;
4. allocates the typed child resource;
5. constructs and installs its owner;
6. sends the event carrying the new object;
7. destroys and rolls back the child if event publication cannot complete;
8. posts no-memory through the parent when allocation fails.

Generate distinct names from the event, including:

- `createToplevel`;
- `createWorkspace`;
- `createWorkspaceGroup`;
- `createDataOffer`;
- `createDataControlOffer`.

Migrate:

- foreign-toplevel handles;
- workspace handles and groups;
- core data offers;
- data-control offers;
- DMA-BUF server-created buffers;
- every remaining server-created `new_id` event.

Delete public generated factories that accept a raw client pointer once all callers
use parent-scoped creation.

Test:

- parent/client association;
- version clamping;
- owner construction failure;
- native allocation failure;
- event publication order;
- owner installation before synchronous observation;
- rollback and no-memory behavior;
- parent destruction before creation.

Phase 8 is complete when policy never recovers a native client pointer to create a
related Wayland object.

## Phase 9: Consolidate Display Operations

Add safe operations to `WaylandDisplay`:

- `nextSerial()`;
- any required client identity lookup that can return `WaylandClientID`;
- narrowly scoped native display access for integrations that cannot use a typed
  operation.

Store `WaylandDisplay` in protocol managers that mint serials rather than copying its
raw display pointer:

- XDG shell;
- layer shell;
- session lock;
- seat;
- data device.

Preserve display ownership order through the router. Protocol managers must not
outlive the display they use.

Phase 9 is complete when compositor policy does not call
`wl_display_next_serial` or cache the native display pointer.

## Phase 10: Remove Pure Forwarding Global Bindings

Generate a `global(implementation:advertisedVersion:installed:)` overload when the
implementation itself conforms to the generated request protocol. The overload uses
the implementation as the resource owner without an identity closure.

Replace:

```swift
FooServer.global(
    implementation: manager,
    owner: { manager, _ in manager })
```

with:

```swift
FooServer.global(implementation: manager)
```

Move request conformances from one-property forwarding bindings onto the manager
when the manager has no per-client state.

Delete only bindings whose complete semantics are forwarding. Preserve bindings that
carry:

- a per-client resource handle;
- destruction-side unregister behavior;
- per-client negotiated state;
- a deliberate strong projection lifetime;
- client-specific event state;
- multiple protocol roles whose separation clarifies behavior.

Seat and output bindings remain explicit because they own per-binding resource
tracking and destruction behavior. XDG wm-base remains explicit because it carries
the per-client resource used by shell protocol behavior.

Do not introduce a macro for these bindings. The remaining declarations document
real ownership boundaries.

Phase 10 is complete when identity owner closures and semantically empty binding
classes are gone.

## Phase 11: Final Unsafe and Boilerplate Audit

Regenerate all Wayland outputs twice and compare complete generated-output hashes.

Run, in strict order:

1. generator/model tests;
2. `swift build --package-path swift-wayland`;
3. `swift test --package-path swift-wayland`;
4. shell Wayland/input/pasteboard builds and tests;
5. Android display-host and surface-probe builds and tests;
6. `swift build --package-path compositor/compositor-core`;
7. `swift test --package-path compositor/compositor-core`;
8. `collider generate wayland` followed by a clean generated-output check;
9. `collider build`;
10. `collider test`.

Audit production sources for:

- direct client request calls outside generated code;
- stored routine raw client proxies;
- pointer-bit proxy escape or reconstruction;
- direct client listener installation outside the owned proxy;
- public generic cross-interface error posting;
- untyped retained server resources;
- direct policy `wl_resource_destroy`;
- direct policy `wl_resource_get_client`;
- direct policy `wl_shm_buffer_*`;
- direct policy `wl_display_next_serial`;
- raw-client server-created-resource factories;
- identity owner closures;
- empty forwarding binding classes.

Classify every remaining `unsafe` site:

- generated protocol ABI;
- client/server connection substrate;
- SHM scoped-access implementation;
- XCB/Xwayland;
- libinput/XKB;
- Vulkan native Wayland surface integration;
- another documented native boundary.

Move an unsafe operation behind a safe abstraction only when that abstraction can
enforce a real lifetime, type, bounds, ownership, or sequencing invariant. Do not
hide inherently unsafe behavior behind a misleading safe method.

## Completion Criteria

The work is complete when:

- all selected client requests have generated typed methods;
- request-created and event-created proxies are owned and interface-typed;
- ordinary event object arguments remain nonescapable borrowed proxies;
- listener contexts have proxy-scoped retained lifetimes without retaining their
  owners;
- registry binding and lookup are interface-typed;
- shell and Android production consumers retain no routine raw proxies;
- shell and Android production consumers make no routine direct client request
  calls;
- no proxy address is erased to an integer to escape a borrow;
- arbitrary cross-interface protocol errors do not type-check;
- legitimate cross-interface errors are explicit and behavior-tested;
- retained server resources carry their interface type;
- ownerless child factories return typed resources;
- policy performs no routine direct resource destruction or client lookup;
- SHM access is scoped, validated, and balanced by one runtime abstraction;
- server-created event objects derive their client from a typed parent handle;
- serial minting stays behind `WaylandDisplay`;
- only semantically meaningful binding-owner classes remain;
- generated output is deterministic;
- all SwiftPM, compositor, shell, Android, Collider, loopback, loader, and GPU gates
  pass.

## Explicit Non-Goals

- Do not generate compositor policy, authorization, roles, configure sequencing,
  layout, scene integration, or renderer behavior.
- Do not map XML interfaces to Nucleus domain owner classes in the generator.
- Do not use macros to hide generated protocol declarations or ABI.
- Do not introduce `@unchecked Sendable`.
- Do not make request or event delivery asynchronous.
- Do not make client proxies `Sendable`.
- Do not expose general raw proxy or resource properties for convenience.
- Do not retain native resources to extend their protocol lifetime.
- Do not combine SHM and DMA-BUF ownership models.
- Do not remove independent raw-wire conformance fixtures.
- Do not preserve raw and typed client request APIs as parallel production paths.
- Do not reduce `unsafe` counts by moving unsafe behavior into falsely safe wrappers.
