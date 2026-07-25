# Typed Wayland Code Generation

## Invariant

Wayland XML is the single source of truth for protocol interface identity, versions,
request and event signatures, object relationships, enum values, bitfields, errors,
and destructor behavior.

Generated Swift owns every mechanical translation of that schema:

- interface descriptors;
- request vtables and C ABI trampolines;
- global resource creation;
- typed `new_id` creation;
- request-scoped resource and object arguments;
- protocol enum, option, and error values;
- event sending;
- client event decoding.

Handwritten compositor code owns protocol policy only. It does not allocate request
vtables, declare `@convention(c)` global-bind callbacks, repeat interface/version/vtable
triples, convert protocol strings manually, use numeric protocol-error codes, or pair
resource creation with a later `bind(_:)` call.

All server-side resource creation and request handling remains synchronous on
`MainActor`. Code generation introduces no task, actor hop, continuation, queue, custom
executor, compatibility path, or second protocol implementation.

Status: complete

## Progress

- Phase 1 is complete.
  - `WaylandProtocolModel` owns the normalized XML model and parser.
  - `SwiftWaylandGenerator` owns dependency-closure resolution, semantic validation,
    and the existing C/server/client emitters.
  - `SwiftWaylandGen` is a thin command-line entry point.
  - The model retains interface/message descriptions, request and event `since`
    values, destructors, nullability, interface and enum references, enum bitfield
    state, entry values, summaries, version metadata, and deprecation metadata.
  - Generation diagnoses unresolved interfaces and enums, duplicate interface and
    generated Swift names, unsupported argument types and enum expressions, and
    unsupported untyped `new_id` uses with semantic XML paths.
  - Full-closure validation established that `wl_output.transform` is intentionally
    used by both signed and unsigned wire arguments. The generated-value invariant now
    specifies a canonical raw representation with bit-preserving ABI conversion
    instead of rejecting valid upstream XML.
  - Collider fingerprints the model and generator-library sources.
  - `collider generate wayland` emits all 152 server and 101 client dispatch
    interfaces from the normalized model.
  - The complete `swift-wayland` build and test suite passes, including model,
    validation, server/client loopback, actor-isolated dispatch, and resource
    ownership coverage.
- Phase 2 is complete.
  - All 192 interfaces in the selected server closure now have generated
    `WaylandServerInterface` descriptors, including bootstrap, event-only, empty,
    and destroy-only interfaces.
  - Destroy-only interfaces receive generated request protocols, default destruction,
    actor-isolated trampolines, and request vtables.
  - The runtime now uses generated vtables for fractional scale, XDG output, idle,
    explicit sync, relative pointer, DMA-BUF, seat keyboard/touch/inhibitor resources,
    and `wl_output`.
  - All compositor-owned request-vtable allocation, storage, teardown, and duplicate
    destroy callbacks have been removed; the runtime source audit finds none.
  - Loopback coverage verifies synchronous release, an overridden destroy handler,
    and default destruction for an owner with no request-protocol conformance.
  - The complete `swift-wayland` test suite and the compositor-core build pass.
- Phase 3 is complete.
  - `WaylandResourceHandle<Interface>` gives owners a typed, lifetime-cleared
    reference to their native resource.
  - `WlNewId<Interface>` is nonescapable and uses Swift 6.4 lifetime dependencies
    to keep the borrowed client valid through typed child construction.
  - Generated child and server-created resource factories supply interface metadata,
    clamp versions, constrain request-bearing owners to the generated request
    protocol, and install owner state as one transaction.
  - `createBare()` exists only for the ownerless `wl_callback` and
    `wp_presentation_feedback` notification resources.
  - Every typed child cluster now accepts its handle during initialization; later
    mechanical resource binding and raw child vtable arguments are gone.
  - Allocation coverage verifies native creation failure, owner-factory rollback,
    suppressed installation on failure, handle clearing, and owner release on native
    destruction.
  - The complete `swift-wayland` test suite and the compositor Wayland runtime target
    build pass.
- Phase 4 is complete.
  - `WaylandGlobalSpecification<Interface>` erases only after generated descriptor
    and request-owner constraints have type-checked each declaration.
  - `WaylandGlobalRegistration` retains the implementation, per-client owner factory,
    post-install policy, native global, and display lifetime in destruction order.
  - One shared `@convention(c)` callback validates native values, re-enters
    `MainActor`, clamps the negotiated version, and runs typed resource installation.
  - Every compositor global uses a generated `FooServer.global(...)` factory; raw
    interface/version/vtable triples and all handwritten bind callbacks are gone.
  - Global projection owners receive typed handles during initialization, including
    seat, output, workspace, and foreign-toplevel resources.
  - Loopback coverage exercises one implementation behind multiple globals,
    multiple clients, distinct per-binding owners, version clamping, removable
    globals, self-owned resources, and synchronous initial events.
  - The complete `swift-wayland` test suite and compositor Wayland runtime target
    build pass.
- Phase 5 is complete.
  - `WaylandProtocolTypes` is generated from the normalized enum model. Open
    `RawRepresentable` values preserve unknown enum values and generated `OptionSet`
    values preserve unknown bits.
  - Every generated server request receives `WaylandRequest<Interface>` and decodes
    XML arguments to Swift strings, `Double`, typed nonescapable borrowed objects,
    read-only nonescapable arrays, move-only owned file descriptors, generated
    protocol values, or unadorned scalar integers as appropriate.
  - Generated typed error overloads bind each protocol error value to the request's
    own resource; compositor policy contains no numeric protocol-error codes.
  - All compositor request handlers use the generated typed surface. Manual C-string
    decoding, raw request arrays, raw object-argument pointers, and implicit
    file-descriptor ownership are gone.
  - Runtime dispatch coverage exercises nullable and empty strings, nullable and
    nonnullable objects, unknown option bits, fixed-point conversion, and automatic
    file-descriptor close through the generated C vtables. Value-wrapper coverage
    exercises unknown enum values, empty/aligned/malformed arrays, automatic close,
    and explicit descriptor transfer.
  - Generated request-protocol audits find no public C-string, `wl_array`, or untyped
    object-resource pointer parameters.
  - The complete `swift-wayland` test suite and compositor Wayland runtime target
    build pass.
- Phase 6 is complete.
  - Every generated server event is available as a constrained method on
    `WaylandResourceHandle<Interface>`. Senders return `false` when their target or
    required object argument has been destroyed.
  - Events marshal Swift strings, generic array element collections, `Double`
    fixed-point values, generated protocol values, typed object/new-id handles, file
    descriptors, and scalar integers without exposing C argument types to policy.
  - Every event introduced after version 1 has a generated `supports<Event>` property;
    its sender preconditions that capability, and compositor version checks use those
    properties.
  - Output, seat device, and cross-protocol output registries now retain typed handles
    instead of raw resource pointers. One-shot references can derive a checked typed
    handle for their final event before destruction.
  - The compositor runtime contains no routine Wayland `<interface>_send_<event>` or
    generated static descriptor-sender calls. The remaining `xcb_send_event` is an
    unrelated X11 operation.
  - Loopback coverage sends the complete `wl_output` burst through typed handles, and
    dispatch coverage verifies a send after native resource destruction returns
    `false`.
  - The complete `swift-wayland` test suite and compositor Wayland runtime target
    build pass.
- Phase 7 is complete.
  - Every generated client interface has a descriptor distinct from its server
    descriptor. Listener callbacks receive nonescapable
    `WaylandBorrowedProxy<InterfaceClient>` values, so client proxies cannot
    type-check as server resources or escape synchronous dispatch accidentally.
  - Generated client callbacks copy strings, convert fixed-point values, construct
    generated enum and option values, expose arrays through
    `WaylandClientArrayView`, and transfer file descriptors through the move-only
    `WaylandClientOwnedFileDescriptor`.
  - Stable client runtime support lives in the handwritten
    `WaylandClientDispatch/Support` subtree. Collider owns and replaces only the
    sibling `Generated` subtree.
  - The shell Wayland, input, pasteboard, Android display-host, and Android surface
    probe consumers use the typed event surface. Manual C-string and `wl_array`
    decoding was deleted, and transferred descriptors are explicitly taken only
    where ownership moves into existing domain code.
  - The server/client `wl_output` loopback now asserts generated enum, option, and
    copied-string values on both sides. Client tests cover callback-scoped array
    copying and automatic descriptor closure.
  - The complete `swift-wayland` test suite and every migrated shell/Android
    consumer target build pass.
- Phase 8 is complete.
  - One actor-isolated `WeakReference<Value>` now owns the generic one-property
    weak-storage case throughout the compositor Wayland runtime.
  - Popup/toplevel stacks, text input, relative pointer, pointer constraints,
    screencopy, data-device targets, XDG output, gamma, data control, idle,
    foreign-toplevel, workspace, exported-surface, and subsurface topology
    relationships use the generic type.
  - Named weak boxes remain only where they preserve additional resource identity
    and renderer-index teardown metadata, or where a class-bound protocol
    existential cannot satisfy the generic constraint without erasing its domain
    type.
  - The compositor Wayland runtime target builds with the consolidated storage.
- Phase 9 is complete.
  - The repository-managed `third-party/swift-syntax` checkout is pinned at
    `050f1a346fbbac0ca2cfb15a95274f7bd1cf0ccf`, matching the installed Swift
    6.4 development snapshot, and `swift-wayland` consumes it through a relative
    package dependency.
  - XML parsing, dependency closure, semantic validation, and normalized protocol
    IR remain in `WaylandProtocolModel` and `SwiftWaylandGenerator` without a
    SwiftSyntax dependency.
  - `SwiftSourceFileBuilder` assembles and deterministically formats syntax trees.
    The Swift emitters structurally build imports, protocol value structs, request
    and event protocols, server and client descriptors, constrained extensions,
    C ABI trampoline members, event senders, and resource/global factories.
  - Whole-file mutable string assembly has been removed from Swift emission. The
    remaining string emitter produces only the generated C façade header, module
    map, and closure manifest.
  - Stable client runtime support remains handwritten under
    `WaylandClientDispatch/Support`; only XML-derived declarations are generated.
  - Regeneration emitted all 192 server and 192 client interface files. A forced
    second generator invocation produced a byte-identical SHA-256 manifest across
    the server dispatch, client dispatch, and shared protocol-value trees.
  - The complete `swift-wayland` package builds and its model, generator, server,
    client, ownership, actor-isolation, and loopback test suites pass against the
    regenerated sources.
- Phase 10 is complete.
  - Generator/model tests, the complete `swift-wayland` build and test suite, the
    compositor-core build, and the compositor-core test suite pass.
  - Wire conformance testing exposed one typed-owner projection gap: bound
    `wl_output` resources own `WlOutputBinding`, not `WlOutput` directly. A
    `WaylandBorrowedObject<WlOutputServer>.output` projection now resolves that
    relationship for layer shell, session lock, screencopy, gamma, XDG output,
    foreign toplevel, and XDG toplevel policy.
  - Cursor-shape registration explicitly preserves the supported version 1
    contract instead of inheriting the XML maximum, and duplicate XDG decoration
    construction reports the generated `alreadyConstructed` value.
  - `collider generate wayland` leaves a complete SHA-256 manifest unchanged across
    the generated server C, client C, protocol C, protocol-value, server-dispatch,
    and client-dispatch trees.
  - `collider build` passes.
  - `collider test` passes. An interrupted aggregate attempt left a stale Linux
    test runner; after terminating that exact runner, `collider test linux` and the
    resumed complete Collider test graph both passed.
  - The final source audit finds 192 server and 192 client interface files, no
    handwritten Wayland C callbacks, raw protocol-error posts, routine raw event
    sends, whole-file Swift string emitters, or references to the removed protocol
    policy checker. The remaining weak boxes preserve protocol-existential identity
    or renderer-index teardown metadata.

## Current Baseline

The server dispatch generator already emits actor-aware request protocols, vtables,
trampolines, and event sender functions for 152 interfaces. The remaining handwritten
runtime contains the following repeated mechanics:

- 33 global registrations;
- 28 per-type `@convention(c)` global-bind callbacks;
- 13 manually allocated request vtables;
- 36 `WlNewId.create(vtable:owner:)` call sites that repeat generated metadata;
- 54 raw `WaylandResource.owner(of:as:)` resolutions;
- 25 resource-reference assignments performed through a later `bind(_:)` method;
- 96 raw protocol-error posts;
- 155 direct C event sends and 28 generated event-sender calls;
- 20 small weak-reference box types.

These counts are a migration inventory, not permanent acceptance criteria. Recount each
category after the phase that removes it and keep the enforcement checks based on
forbidden behavior rather than exact source counts.

## End State

A routine global implementation has no C callback:

```swift
router.addGlobal(
    WpFractionalScaleManagerV1Server.global(
        implementation: self,
        owner: { manager, resource in
            WpFractionalScaleManagerBinding(
                manager: manager,
                resource: resource)
        }))
```

A global whose implementation is also its per-client resource owner uses the generated
identity factory:

```swift
router.addGlobal(
    OrgKdeKwinBlurManagerServer.global(
        implementation: self,
        owner: { manager, resource in
            manager.bound(to: resource)
        }))
```

A factory request receives a child-interface-specific `new_id`, a typed request
resource, and a typed borrowed object:

```swift
func getFractionalScale(
    _ request: WaylandRequest<WpFractionalScaleManagerV1Server>,
    id: WlNewId<WpFractionalScaleV1Server>,
    surface: WaylandBorrowedObject<WlSurfaceServer>?
) {
    guard let surface = surface?.owner(as: WlSurface.self) else { return }
    guard surface.claimAux(.fractionalScale) else {
        request.postError(
            .fractionalScaleExists,
            "surface already has a fractional scale")
        return
    }

    guard let scale = id.create(
        owner: { resource in
            WpFractionalScale(resource: resource, surface: surface)
        },
        installed: { scale in
            surface.fractionalScaleSink = scale
            scale.sendPreferredScale(surface.preferredFractionalScale120)
        })
    else {
        surface.releaseAux(.fractionalScale)
        return
    }
}
```

The object is fully resource-bound at initialization:

```swift
@MainActor
final class WpFractionalScale {
    private let resource: WaylandResourceHandle<WpFractionalScaleV1Server>
    private weak var surface: WlSurface?

    init(
        resource: WaylandResourceHandle<WpFractionalScaleV1Server>,
        surface: WlSurface
    ) {
        self.resource = resource
        self.surface = surface
    }

    func sendPreferredScale(_ scale120: UInt32) {
        resource.sendPreferredScale(scale120)
    }
}
```

The generated server request path is:

```text
libwayland request
  -> generated C ABI trampoline
  -> MainActor.assumeIsolated
  -> generated typed request/resource arguments
  -> handwritten protocol-policy method
```

The global-bind path is:

```text
libwayland global bind
  -> one WaylandServer callback
  -> recover WaylandGlobalRegistration
  -> MainActor.assumeIsolated
  -> create native resource
  -> construct fully bound Swift owner
  -> install owner and generated vtable
  -> run typed post-install policy
```

## Generated Type Model

### Interface Descriptors

Add a policy-free descriptor protocol to `WaylandServer`:

```swift
public protocol WaylandServerInterface {
    static var interface: UnsafePointer<wl_interface>? { get }
    static var maximumVersion: Int32 { get }
    static func requestVtable() -> UnsafeRawPointer?
}
```

Every generated `FooServer` conforms. Generate descriptors for:

- interfaces with ordinary requests;
- interfaces with only destructor requests;
- event-only interfaces;
- interfaces with neither requests nor events when another interface references them.

`requestVtable()` returns `nil` only when the interface has no server-handled requests. A
destroy-only interface receives a generated vtable and the existing default destroy
behavior.

Do not represent descriptor identity with strings or integer tags. The generated
descriptor type is the phantom type used by all typed resources for that interface.

### Shared Protocol Values

Add a pure Swift `WaylandProtocolTypes` target generated from the protocol closure. It
imports neither `WaylandServerC` nor `WaylandClientC`. Both dispatch targets depend on
it.

For each XML enum:

- generate a `RawRepresentable`, `Hashable`, `Sendable` value type;
- preserve unknown raw values so invalid or future client values reach policy code;
- generate named static values for every XML entry;
- carry `since` and deprecation metadata into generated availability documentation;
- use `UInt32` for bitfields;
- use `Int32` for a non-bitfield referenced by any signed argument and `UInt32`
  otherwise;
- preserve the exact 32 wire bits when converting between a generated value and a
  referring argument with the other signedness.

For each XML bitfield:

- generate an `OptionSet`, `Hashable`, `Sendable` value type;
- preserve unknown bits;
- emit named options for every XML entry.

Error values use the same open raw-value representation. Generated request helpers
restrict `postError` to the error type belonging to the request resource's interface.

Names include the defining interface, such as `WpViewportError` and
`ZwlrLayerSurfaceV1Anchor`, so protocol closures cannot introduce collisions.

### Typed Resource Values

Add these server primitives:

```swift
@MainActor
public final class WaylandResourceHandle<Interface: WaylandServerInterface>

@unsafe
public struct WaylandRequest<Interface: WaylandServerInterface>: ~Escapable

@unsafe
public struct WaylandBorrowedObject<Interface: WaylandServerInterface>: ~Escapable

@unsafe
public struct WaylandArrayView: ~Escapable

@unsafe
public struct WlNewId<Interface: WaylandServerInterface>: ~Escapable
```

`WaylandResourceHandle` owns a `WaylandResourceReference` and exposes:

- checked access to the live resource;
- resource version;
- `WaylandClientID`;
- generated event methods;
- generated event-version capability properties.

It does not retain the native resource and cannot resurrect a destroyed resource.

`WaylandRequest` and `WaylandBorrowedObject` are nonescapable views over pointers valid
only for the synchronous callback. Raw pointers are not public API. They expose only
the operations appropriate to their role:

- request error posting;
- request resource version and client identity;
- typed owner resolution for object arguments;
- explicit unsafe access inside `WaylandServer` implementation code.

`WaylandArrayView` is a read-only byte view. Protocol-specific typed decoding remains
handwritten when XML does not describe array element layout.

Request-side strings are copied to `String` or `String?` inside the generated
main-actor boundary. The handwritten handler never receives a C string pointer.

Request-side file descriptors arrive as a move-only owned descriptor whose deinitializer
closes an unconsumed descriptor. A handler transfers ownership explicitly when it
stores or imports the descriptor. This makes descriptor leaks and double-closes
visible in the type system.

### Resource Construction

Replace two-phase owner construction with one resource factory:

```swift
id.create(
    owner: (WaylandResourceHandle<Interface>) -> Owner,
    installed: (Owner) -> Void = { _ in })
```

The implementation performs this exact order:

1. Create the native `wl_resource`.
2. Create its typed, lifetime-checked resource handle.
3. Invoke the owner factory with that handle.
4. Retain the owner in native user data.
5. Install the generated request vtable and destroy callback.
6. Invoke the typed `installed` closure.
7. Return the owner.

If any step before installation fails, destroy the native resource and release all
intermediate Swift state. The `installed` closure cannot run on failure.

The owner factory is generated with the appropriate request-protocol constraint for
interfaces that handle requests. Destroy-only and event-only interfaces accept an
`AnyObject` owner because their generated vtable requires no policy witness.

Objects that need post-install work use `installed`. Examples include:

- registering an XDG popup in its shell stack;
- publishing a newly created output or workspace handle;
- sending initial capabilities or state;
- linking a surface auxiliary role;
- registering an observer that may synchronously inspect the resource.

Do not perform those actions in the owner initializer. The native user data and vtable
must be installed before policy publishes the object.

### Generated Event Surface

Generate event methods as constrained extensions on
`WaylandResourceHandle<Interface>`. Methods:

- accept Swift `String` values and manage `withCString` internally;
- accept generated enum and option types;
- accept typed resource handles for object and `new_id` event arguments;
- convert fixed-point values internally;
- expose an explicit `supports<Event>` property for events introduced after version
  one;
- precondition that the bound resource version supports the event;
- no-op when the target resource has already been destroyed.

Do not expose the C sender as the preferred Swift API. Keep raw C access available only
inside the generated implementation and narrow interoperability code.

## Phase 1: Expand the Protocol Model

Refactor `SwiftWaylandGen` into:

- `WaylandProtocolModel`, a library target containing XML parsing and normalized
  protocol IR;
- `SwiftWaylandGenerator`, a library target containing dependency closure,
  validation, and emitters;
- the existing `SwiftWaylandGen` executable as a thin command-line entry point.

Extend the normalized IR to retain:

- interface versions and descriptions;
- request and event `since` values;
- destructor markers;
- argument nullability;
- referenced interfaces;
- referenced enums, including cross-interface references;
- enum names, bitfield markers, entries, values, summaries, `since`, and deprecation;
- request and event descriptions.

Validate the entire selected dependency closure before emitting files. Generation
fails with the protocol, interface, message, and argument path when it finds:

- an unresolved non-core interface reference;
- an unresolved enum reference;
- duplicate generated Swift names;
- an unsupported enum value expression;
- an untyped `new_id` outside the explicitly supported registry bootstrap case;
- an unsupported request or event argument type.

Add parser and model tests using in-memory XML fixtures. Assert normalized semantic
values and validation diagnostics. Do not assert generated source spelling or
declaration presence.

Phase 1 is complete when the existing server and client outputs regenerate from the
new IR without behavioral changes and all generator/model tests pass.

## Phase 2: Generate Descriptors and Destroy-Only Dispatch

Add `WaylandServerInterface` and emit conformance from every server interface
descriptor.

Remove the generator condition that drops interfaces whose requests are all pure
destructors. Generate:

- their request protocol;
- the default destroy implementation;
- their request vtable;
- the actor-isolated destructor trampoline;
- their event methods.

Migrate every manually allocated destroy-only vtable, including the current
fractional-scale, XDG-output, idle, explicit-sync, relative-pointer, DMA-BUF, and seat
cases, to its generated descriptor.

Delete:

- `allocVtable` when its final caller is gone;
- per-object `objectDestroy` callbacks replaced by generated default destruction;
- vtable storage properties;
- vtable allocation initializers;
- vtable deallocation in `isolated deinit`.

Exercise destroy-only resources through a real Wayland loopback:

- create the resource with a retained Swift owner;
- dispatch its destroy request;
- verify synchronous owner release;
- verify overridden destructor policy runs when supplied;
- verify an owner without a request conformance receives default destruction.

Phase 2 is complete when no compositor runtime file allocates a Wayland request vtable
and all selected XML interfaces have a generated descriptor.

## Phase 3: Introduce Typed Resource Construction

Implement `WaylandResourceHandle`, typed `WlNewId`, and the single-phase owner factory.
Keep the native ownership rule in one place:

- the native resource retains exactly one Swift owner;
- the typed handle observes but does not retain the native resource;
- resource destruction clears the handle before releasing the owner;
- owner teardown remains `MainActor`-isolated.

Change generated request signatures so every typed `new_id` carries its child
descriptor:

```swift
WlNewId<ChildServer>
```

Generate the request-protocol constraint on `create(owner:installed:)`.

Migrate child-resource creation one protocol cluster at a time in this order:

1. fractional scale and viewport;
2. decoration and background effects;
3. XDG shell and layer shell;
4. output, presentation, and workspace;
5. seat, relative pointer, constraints, text input, and idle;
6. data device and data control;
7. DMA-BUF, explicit sync, and screencopy;
8. session lock, activation, foreign protocols, and Xwayland shell;
9. remaining core and extension resources.

For each object:

- accept its typed resource handle in `init`;
- make the handle nonoptional when the object sends events or inspects resource
  lifetime;
- move post-install behavior into the `installed` closure;
- delete its `bind(_:)` method;
- delete raw vtable arguments at the creation site;
- preserve cleanup and protocol-error behavior.

Keep `createBare()` only for a genuinely ownerless, requestless notification resource.
Make it descriptor-specific so a request-bearing child cannot be created bare.

Add allocation-failure tests that cover failure before owner creation, owner-factory
failure where supported, and native resource destruction. Assert that no semantic
registration or initial event occurs on failure.

Phase 3 is complete when no typed child creation supplies a raw vtable and no resource
owner requires a later mechanical `bind(_:)` solely to store its resource.

## Phase 4: Replace Handwritten Global Binds

Add `WaylandGlobalRegistration` and `WaylandGlobalSpecification` to `WaylandServer`.
The registration retains:

- the implementation object;
- the erased but type-checked owner factory;
- the optional post-install closure;
- the generated interface descriptor;
- the advertised version;
- the native `WaylandGlobal`.

Use the registration object, not the implementation object, as `wl_global_create`
userdata. Install one `@convention(c)` callback for every Swift global. That callback:

1. validates the raw client and registration pointer;
2. creates stable nonisolated bindings for the borrowed C values;
3. enters `MainActor.assumeIsolated`;
4. clamps the client version to the advertised and XML maximum versions;
5. invokes the registration's typed resource factory;
6. runs post-install policy before returning.

Generate `FooServer.global(...)` factory overloads that constrain the returned resource
owner to `FooRequests` when the interface has requests. The generated factory supplies
the descriptor and vtable; handwritten code supplies only:

- the implementation object;
- an advertised version when lower than the XML maximum;
- the binding-owner constructor;
- optional post-install policy.

Change `NucleusWaylandRouter` to retain completed
`WaylandGlobalRegistration` objects and preserve independently removable global
handles. Preserve destruction order: globals are destroyed before their registration
userdata and before the display.

Migrate all globals in strict protocol-cluster order matching Phase 3. For globals
advertising initial state, move that send into the post-install closure.

Delete:

- all per-type static C bind callbacks;
- `NucleusWaylandRouter.impl(_:as:)`;
- `NucleusWaylandRouter.withBoundImpl`;
- the old `addGlobal(interface:version:impl:bind:)` API;
- direct global interface/version/vtable triples in compositor policy code.

Test:

- one implementation serving multiple globals;
- multiple clients binding one global;
- distinct per-client binding owners;
- a self-owned global resource;
- lower advertised versions;
- removable globals;
- registration and display destruction order;
- synchronous initial events.

Phase 4 is complete when the compositor declares globals only through generated global
specifications and the entire process contains one Swift global-bind C callback.

## Phase 5: Generate Protocol Values and Typed Request Arguments

Generate `WaylandProtocolTypes` from the normalized enum model. Change server request
and event signatures to use the generated types wherever XML supplies an enum
reference.

Generate `WaylandRequest<Interface>` as the first parameter of every server request.
Generate `WaylandBorrowedObject<ReferencedInterface>` for every typed object argument.
Preserve XML nullability in the Swift optional type.

Marshal inside the generated `MainActor.assumeIsolated` closure:

- C strings to `String` or `String?`;
- fixed-point values to `Double`;
- object pointers to typed nonescapable object views;
- arrays to read-only nonescapable array views;
- file descriptors to move-only owned descriptors;
- enum scalars to generated open value types;
- bitfields to generated option sets.

Keep scalar integers as integers only when XML does not assign an enum.

Migrate handlers cluster by cluster:

- replace the raw leading request resource with `WaylandRequest`;
- replace numeric error codes with the generated error value;
- replace C string conversions with direct Swift string use;
- replace raw object pointers with typed object views;
- replace raw array traversal with `WaylandArrayView`;
- make file-descriptor ownership transfer explicit;
- remove redundant `unsafe` annotations that disappear with the typed surface.

Domain owner resolution remains explicit:

```swift
surface?.owner(as: WlSurface.self)
```

The policy-free generator does not encode Nucleus class names or import compositor
modules.

Add runtime tests for:

- nullable and nonnullable object arguments;
- unknown enum values and unknown option bits;
- nullable and empty strings;
- fixed-point conversion;
- empty, aligned, and malformed arrays;
- file-descriptor consumption and automatic close;
- error posting on the request's own resource;
- nonescapable borrowed values rejected when a fixture attempts to store them.

Phase 5 is complete when generated server request protocols expose no public C string,
`wl_array`, or untyped object-resource pointer parameters, and compositor policy uses
no numeric protocol-error codes.

## Phase 6: Move Event Sending onto Typed Handles

Generate constrained event methods on `WaylandResourceHandle<Interface>`.

For every event with `since > 1`, generate:

```swift
var supports<EventName>: Bool
```

and require the corresponding sender to precondition that support. Migrate existing
manual version checks to the generated capability property.

Migrate event senders in this order:

1. surface, callback, region, and output;
2. XDG shell, layer shell, decoration, and activation;
3. pointer, keyboard, touch, relative pointer, constraints, and text input;
4. data device, data source, data offer, and data control;
5. presentation, DMA-BUF, explicit sync, and screencopy;
6. workspace, foreign toplevel, idle, gamma, effects, session lock, and remaining
   extensions.

At each call site:

- send through the typed handle;
- pass Swift strings directly;
- pass generated enums and option sets;
- pass typed handles for object arguments;
- remove local C-string closures;
- remove raw version queries replaced by generated capabilities.

Keep direct C senders only inside generated code and narrowly documented
interoperability paths that cannot possess a typed handle.

Test event delivery over a real server/client loopback, including:

- strings and nullable strings;
- object and `new_id` arguments;
- arrays;
- fixed-point values;
- generated enums and option sets;
- version-gated events;
- a send attempted after resource destruction.

Phase 6 is complete when compositor protocol implementations send events through typed
resource handles and contain no routine `<interface>_send_<event>` calls.

## Phase 7: Apply the Same Value Surface to Client Dispatch

Keep server and client C ABI modules separate. Share only the pure
`WaylandProtocolTypes` target.

Update generated client event handlers to use:

- generated enum and option types;
- copied Swift strings;
- typed borrowed proxy values parameterized by the referenced client interface;
- read-only array views;
- owned file descriptors;
- converted fixed-point values.

Add client interface descriptors distinct from server descriptors so a server resource
cannot type-check as a client proxy.

Preserve the client listener's synchronous callback and owner-recovery model. Do not
make client events asynchronous.

Migrate shell/client consumers to the typed event surface and delete redundant manual
decoding.

Extend the existing server/client loopback coverage so the same wire exchange proves
the typed value on both sides.

Phase 7 is complete when server and client dispatch agree on shared protocol value
types while retaining distinct typed native object wrappers.

## Phase 8: Consolidate Weak Relationships

Add one actor-isolated generic weak reference:

```swift
@MainActor
final class WeakReference<Value: AnyObject> {
    weak var value: Value?
}
```

Replace weak boxes whose only behavior is one weak property. Preserve named domain
boxes that carry additional identity, ordering, or teardown metadata.

For weak existential protocols that do not satisfy the generic constraint cleanly,
add a dedicated generic overload or keep the semantic box. Do not erase weak
relationships to `AnyObject` merely to force reuse.

Phase 8 is complete when every remaining named weak box carries domain behavior beyond
generic weak storage.

## Phase 9: Convert the Stabilized Generator to SwiftSyntax

Add a root-managed `swift-syntax` dependency pinned to the revision matching the
repository's Swift 6.4 toolchain. `swift-wayland` consumes it through a relative
package dependency.

Keep XML parsing, dependency closure, validation, and normalized IR independent of
SwiftSyntax. Replace only Swift source emission with `SwiftSyntaxBuilder`.

Build declarations structurally:

- imports and attributes;
- interface descriptors;
- shared protocol value types;
- request and client-event protocols;
- constrained resource extensions;
- C ABI trampoline declarations;
- global and child-resource factories.

Retain a small explicit naming layer for Wayland snake case, Swift keyword escaping,
and collision diagnostics. Format emitted syntax deterministically before writing it.

Do not convert the generated API into attached or freestanding macros. Generated source
remains visible, inspectable, cacheable, and independently compilable. SwiftSyntax
improves emitter correctness; it does not become a runtime or consumer dependency.

Verify the resulting generated modules through compilation and runtime behavior. Do
not add tests that compare complete generated files or inspect declaration spelling.

Phase 9 is complete when the string-concatenation Swift emitter is deleted and
regeneration produces deterministic, compilable output through SwiftSyntaxBuilder.

## Phase 10: Final Verification

Regenerate all server and client protocol outputs and run, in order:

1. generator/model tests;
2. `swift build --package-path swift-wayland`;
3. `swift test --package-path swift-wayland`;
4. `swift build --package-path compositor/compositor-core`;
5. `swift test --package-path compositor/compositor-core`;
6. `collider generate wayland` followed by a clean generated-output check;
7. `collider build`;
8. `collider test`.

Run host verification after sourcing `tools/host-env.sh`. The direct SwiftPM DRM-node
lane may skip only when its required render node is not provisioned; Collider's
configured DRM lanes remain required.

## Completion Criteria

The work is complete when:

- every selected XML interface has a generated server descriptor;
- no compositor code allocates a Wayland request vtable;
- one runtime callback implements all Swift global binds;
- no compositor global repeats an interface/version/vtable/C-callback tuple;
- typed child IDs cannot be created with another interface's vtable;
- resource owners that use their resource receive a typed handle during
  initialization;
- no mechanical post-creation resource bind remains;
- generated request handlers expose Swift strings, typed object views, protocol value
  types, owned descriptors, and read-only array views;
- protocol errors use generated interface-specific values;
- routine event sends use generated typed handle methods;
- server and client dispatch share pure protocol value types;
- remaining weak boxes carry real domain semantics;
- the generator emits Swift through a structured SwiftSyntax emitter;
- all generator, SwiftPM, compositor, Collider, and loopback gates pass.

## Explicit Non-Goals

- Do not generate compositor policy, role rules, serial authorization, configure
  sequencing, scene integration, or renderer behavior from XML.
- Do not map protocol interfaces to Nucleus owner classes inside `swift-wayland`.
- Do not introduce `@unchecked Sendable`.
- Do not introduce asynchronous request or event delivery.
- Do not retain raw resources to extend native lifetime.
- Do not use macros to hide generated protocol ABI.
- Do not preserve the raw and typed APIs as parallel supported paths.
- Do not keep deprecated wrappers after all callers land on the typed API.
