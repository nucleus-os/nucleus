# Swift Wayland Architecture

## Invariant

`swift-wayland` provides generated, statically `MainActor`-isolated Wayland
server request dispatch and client event dispatch over real libwayland objects.
Every owned server resource binds one typed handler box at creation. Dispatch
performs no isolation laundering, dynamic handler cast, or global resource-table
lookup.

## Generated Surface

`SwiftWaylandGen` generates the server request structures, client listener
mirror structures, Swift descriptors, trampolines, and request vtables from the
vendored protocol XML. Generated C callback fields carry the Swift
`@MainActor` attribute, so their Swift function types preserve actor isolation.
Generated Swift trampolines are `@MainActor @Sendable @convention(c)` functions
and use incoming arguments directly.

Client listener mirrors are generated in the same protocol order as
wayland-scanner's listener structures. Compile-time size assertions and
end-to-end loopback tests protect their ABI agreement. Generated output is
committed and reproduced with:

```sh
collider generate wayland
```

## Resource and Handler Ownership

Every generated server interface has a unique process-lifetime request-vtable
address, including interfaces with no requests. `WaylandDispatchBox<Interface>`
holds the resource owner and the statically resolved request handler. The box is
installed as `wl_resource` user data and released by the resource's single
destroy callback.

Resource identity is established with `wl_resource_instance_of` using the
interface descriptor and that interface's request vtable. A borrowed object can
recover an owner only after this identity check succeeds. Foreign resources,
resources of another interface, and libwayland-owned objects cannot be mistaken
for first-party resources.

Handler conformance is established at resource creation. A non-conforming owner
fails immediately instead of silently dropping every future request. The
runtime maintains no global dictionary keyed by resource addresses, and request
dispatch performs no existential cast.

## Isolation Boundary

Wayland routing and resource ownership are main-actor state. Isolation is part
of generated callback types rather than asserted dynamically in every callback.
Generated dispatch contains no `MainActor.assumeIsolated` wrapper and no
`nonisolated(unsafe)` argument rebinding.

The compositor continues to use real `wl_display`, `wl_surface`, `wl_resource`,
and `wl_proxy` objects. This dispatch architecture does not replace libwayland;
Mesa Wayland WSI and Vulkan presentation require those native identities.

## Verification

`collider test wayland` covers generator determinism, server and client
dispatch, loopback delivery, creation-time handler rejection, interface
identity rejection, resource destruction, and owner recovery. Tests exercise
runtime behavior rather than declaration shape.
