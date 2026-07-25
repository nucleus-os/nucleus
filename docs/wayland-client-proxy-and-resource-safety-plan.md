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

Status: planned

## Current Inventory

The server request/event generator has already removed the major handwritten ABI
surface:

- 192 generated server interface files;
- 192 generated client interface files;
- no handwritten Wayland request trampolines;
- no handwritten global C callbacks;
- no routine raw server event senders;
- no numeric compositor protocol-error posts.

The remaining high-value work is concentrated in the client and server resource
substrates:

- approximately 150 direct client request calls across shell and Android consumers;
- 15 manually mapped shell registry-global kinds;
- 26 direct generated-listener attachment calls in shell and Android consumers;
- client models that retain raw `OpaquePointer` proxies;
- event `new_id` proxies represented as nonescapable borrowed values, forcing at
  least one pointer-bit escape and reconstruction;
- 104 compositor protocol-error posts backed by a public generic error method that
  accepts an error value from any interface;
- 33 direct `wl_resource_destroy` calls in compositor Wayland policy;
- 19 direct `wl_resource_get_client` calls;
- 34 direct `wl_shm_buffer_*` calls;
- four direct `wl_display_next_serial` calls;
- 25 handwritten raw `wl_resource` pointer declarations;
- seven server-created-resource sites that manually recover a client, create a
  resource, install its owner, and send the corresponding `new_id` event;
- 13 binding-owner classes, several of which contain only one forwarding property.

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
`WaylandProxy`. The context contains the event handler and connection token.
Generated C callbacks recover that context, not an arbitrary unretained consumer
object.

Keep `WaylandBorrowedProxy` nonescapable. Remove every pointer-bit conversion used
to evade its lifetime.

Test:

- connection retention through an owned proxy;
- explicit destructor invalidation;
- duplicate destruction rejection;
- no request after destruction;
- listener owner lifetime;
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
- listener owners have proxy-scoped retained lifetimes;
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
