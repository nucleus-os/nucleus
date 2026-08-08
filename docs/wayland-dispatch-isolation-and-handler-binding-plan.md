# Wayland Dispatch Isolation and Handler Binding

## Invariant

Every generated Wayland dispatch entry point is statically `MainActor`-isolated and reaches its
handler through a box bound once at resource creation. A request trampoline performs no dynamic
cast, no isolation laundering, and no global-table lookup. Resource identity is established by
`wl_resource_instance_of` against the interface's own request vtable, so the runtime holds no
side table keyed by resource address.

Status: complete

## Why

The generated dispatch layer is 192 server interfaces (28,082 lines) and 192 client interfaces
(14,715 lines). It currently carries, purely as a consequence of crossing a `@convention(c)`
boundary:

- 530 `MainActor.assumeIsolated` closures — one per trampoline.
- 1,559 `nonisolated(unsafe)` bindings — one per non-scalar argument, plus handler and resource,
  re-laundered at every trampoline.
- 184 per-request existential casts. Each dispatching interface emits a `handler(_:)` helper whose
  body is `Unmanaged<AnyObject>.fromOpaque(ud).takeUnretainedValue() as? any <Iface>Requests`.
  That is a `swift_dynamicCast` with a protocol-conformance lookup on the path of every single
  request the compositor receives.
- A `@MainActor` global `owners: [UInt: AnyObject]` in `WaylandResource`, keyed by
  `UInt(bitPattern: resource)`, consulted on every object-typed request argument.

Two of these are correctness issues, not just cost. The per-request cast means an owner that fails
to conform silently no-ops every request on that resource for the process lifetime, with no
diagnostic — a latent bug class that install-time binding eliminates outright. And
`MainActor.assumeIsolated` is a runtime assertion hand-written 530 times where the isolation can
instead be part of the entry point's type.

The consumer-facing API does not change. `WaylandBorrowedObject.owner(as:)` keeps its signature
across roughly 40 call sites in 35 compositor files; only its implementation moves.

## Verified toolchain behavior

The design rests on four facts, each confirmed against the Swift 6.4 toolchain in this tree:

- `@MainActor @convention(c)` is accepted for signatures over imported C struct pointers
  (`UnsafeMutablePointer<wl_resource>`, `OpaquePointer`) under `-strict-memory-safety`.
- Inside such a thunk, parameters are used directly. No `nonisolated(unsafe)` rebinding and no
  `assumeIsolated` wrapper are required.
- Assigning an isolated thunk into a plain C function-pointer field is rejected:
  *"converting function value ... loses global actor 'MainActor'"*.
- `__attribute__((swift_attr("@MainActor")))` in the C function-pointer type declarator imports the
  callback as `@MainActor @Sendable @convention(c)`. A field-level attribute isolates field access
  but does not isolate the callback type, while an attributed typedef triggers a Swift 6.4 Clang
  importer assertion because the attributed alias differs from its underlying function type.

`wl_resource_instance_of` is declared at `wayland-server-core.h:617`. `WaylandServerInterface` is
used only as a generic constraint — there are no `any WaylandServerInterface` existentials — so it
can gain an associated type.

## Phase 1 — Annotate the C dispatch surface

Status: complete

`WaylandServerC.h` (655 lines) and `WaylandClientC.h` (5,106 lines) are both emitted by
`SwiftWaylandGen`, so this is a generator change, not a hand-edit.

Emit a `NUCLEUS_WL_MAIN_ACTOR` macro guarded on `__has_attribute(swift_attr)` and place it in every
callback field's function-pointer type declarator in every `swift_wayland_<iface>_requests` struct.
Emit first-party request structs for extension protocols as well as core Wayland; aliases to
scanner-owned interface structs cannot carry the annotation required by phase 2.

The client side needs one structural addition. Client listeners currently install into
`wl_<iface>_listener`, which is wayland-scanner's own type in libwayland's headers and cannot be
annotated. Emit first-party `swift_wayland_<iface>_events` mirror structs into `WaylandClientC.h`,
field-for-field in scanner declaration order with the annotation applied, and guard each with a
`_Static_assert` on `sizeof` against the corresponding `wl_<iface>_listener`. Installation moves
from `<iface>_add_listener` to a first-party façade over `wl_proxy_add_listener`, which takes
`void (**)(void)` and is what the scanner inline does internally anyway.

The generated Swift listener storage uses the mirror type and the new installation façade. Its
storage is `@MainActor` because the imported mirror initializer and callback fields are isolated.

## Phase 2 — Isolated server request trampolines

Status: complete

In the server emission path, emit each `<request>_impl` as
`@MainActor @Sendable @convention(c)`. Delete the `actorBoundaryBindingLines` helper and every
`MainActor.assumeIsolated` wrapper, calling the handler directly on the incoming parameters.

Vtable construction lands alongside. The current emission allocates raw bytes, zero-fills, and
`bindMemory`s to the struct type. With the fields annotated, emit a typed
`UnsafeMutablePointer<swift_wayland_<iface>_requests>.allocate(capacity: 1)` initialized with a
fully populated struct value, which removes the raw-byte dance from all 184 dispatching interfaces.

The existing server isolation and loopback tests invoke the typed request tables and continue to
exercise scalar, pointer, `new_id`, and destructor dispatch through the isolated trampolines.

## Phase 3 — Isolated client event trampolines

Status: complete

Emit each client `<event>_impl` as `@MainActor @Sendable @convention(c)` and install through the
phase 1 mirror structs. Drop the `isolatedArguments` laundering and the `assumeIsolated` wrapper
from the client emission path.

Together with phase 2 this retires all 530 `assumeIsolated` calls and all 1,559
`nonisolated(unsafe)` bindings in generated code.

## Phase 4 — Typed handler box

Status: complete

`WaylandServerInterface` gains `associatedtype Requests`. Each generated `<Iface>Server` declares
`typealias Requests = any <Iface>Requests`; the eight interfaces with no request protocol declare
`AnyObject`.

Add `WaylandDispatchBox<Interface: WaylandServerInterface>`, a `@MainActor final class` holding the
owner and the handler resolved to `Interface.Requests`. The stored handler is optional only for a
destroy-only interface whose generated default implementation intentionally needs no policy
object. The box becomes the resource's `user_data` in place of the directly retained owner. The
shared destroy callback releases it as `AnyObject`, which needs no knowledge of `Interface`.

`WaylandResource.create` (`WaylandResource.swift:190-207`) is the untyped overload and has two
production callers — `WlNewId.swift:43` and `WaylandGlobalRegistration.swift:40` — plus 16 test
sites. Both production callers already sit in contexts generic over `Interface` (`WlNewId<Interface>`
and the global specification), so the overload becomes generic rather than being deleted. The
typed factories bind with the conformance already static: `ownerConstraint` is `<Iface>Requests`
whenever the interface has a non-destructor request (`SwiftWaylandGenerator.swift:1099-1101`), so
those paths cast nothing at all. The generic overload preconditions on conformance at install time,
converting the current silent per-request no-op into a creation-time failure.

The per-interface `handler(_:)` helper (`SwiftWaylandGenerator.swift:808-815`) becomes an
`Unmanaged<WaylandDispatchBox<Interface>>` recovery and a stored-property load, and the 184
existential casts leave the request path.

## Phase 5 — Retire the resource side table

Status: complete

Emit a request vtable for every interface, including the six event-only interfaces we create that
currently have none — `wl_callback`, `wp_presentation_feedback`, `zwp_linux_buffer_release_v1`,
`zwp_fullscreen_shell_mode_feedback_v1`, `wp_image_description_info_v1`, `zwp_input_method_v1`. For
an interface with no requests the vtable is an empty allocation whose only role is to be a unique
process-lifetime address. `wl_display` and `wl_registry` stay vtable-less: libwayland implements
them, we never own them, and an identity check against them must fail.

With a vtable on every owned interface,
`wl_resource_instance_of(resource, Interface.descriptor.nativeInterface, Interface.descriptor.nativeRequestVtable)`
is a total identity test — it matches exactly the resources this runtime created with this
interface's generated vtable. `WaylandBorrowedObject.owner(as:)` (`WaylandRequest.swift:60-64`) and
`WaylandResource.owner(of:as:)` become that check followed by box recovery and the caller's own
concrete downcast, which is the intended policy cast and is no longer on the per-request path.

Delete `WaylandResource.owners` and `resourceWasDestroyed`. This removes the runtime's only global
mutable resource state and its keying by an address the allocator may reuse.

## Phase 6 — Verification

Status: complete

- `collider generate wayland` reproduces the generated tree deterministically. A forced second
  generation produced the identical generated diff.
- `collider build` passes over the workspace, and `collider test wayland` passes
  `WaylandServerTests`,
  `WaylandClientTests`, `WaylandLoopbackTests`, `WaylandProtocolModelTests`,
  `SwiftWaylandGeneratorTests`, and `NucleusCompositorWaylandRuntimeTests`.
- `ServerDispatchIsolationTests` asserts the new contract directly: a resource created
  with a non-conforming owner fails at creation, and an owner bound through the box receives
  requests without the runtime consulting any global table. These are runtime-behavior assertions,
  not declaration-shape assertions.
- `WaylandResourceOwnershipTests` covers identity rejection — a foreign resource, and a
  resource of a different interface, both resolve to `nil` through `owner(as:)`.

## Risk surface

The layout coupling in phase 1 is the one place where a mistake is quiet rather than loud: a mirror
listener struct whose field order drifts from the scanner's would dispatch events to the wrong
handler. The `_Static_assert` on size catches arity and width drift; order is pinned by both structs
being generated from the same protocol XML in the same pass, and by the loopback tests exercising
event delivery end to end.

Phases 4 and 5 change what `user_data` points at. Any code reading `wl_resource_get_user_data` and
assuming it is the owner must move in the same phase. Inside this workspace those readers are the
generated `handler(_:)` helpers and `WaylandResource`; the compositor reaches owners only through
`owner(as:)`, whose signature is unchanged.

The remaining libwayland dependency is unaffected. This plan does not reduce it, and the client
side cannot: `vkCreateWaylandSurfaceKHR` receives a real `wl_display` and `wl_surface`
(`NucleusWindowClientRenderEngine.swift:82-104`), so Mesa's WSI requires genuine `wl_proxy` objects
regardless of how dispatch above them is expressed.
