# Shared Infrastructure — De-duplication & Structure

## Invariant

Code shared across the four repos (core, RN platform, compositor, shell) is shared through
**one of two explicit mechanisms**, never a filesystem symlink:

- **Shared Swift/C** is a real SwiftPM package product, consumed via `.package(url:)` — a
  versioned, explicit dependency.
- **Shared C++** is compiled **once** into a prebuilt library staged in the native SDK and
  **linked** by consumers — not recompiled per consumer from a symlinked `.cpp`.

Platform variation (Vulkan WSI on Android vs. Wayland, Wayland client vs. server) is a **thin
seam over one shared implementation**, not a copied implementation per platform. No two
targets carry the same logic differing only by a platform call.

Symlinks-into-another-tree are a SwiftPM-limitation workaround (a target's sources must live
inside its package). They make the dependency implicit and fragile — editing through the
symlink silently replaces it, and the coupling isn't visible in the manifest. Every symlink
farm is technical debt that resolves to one of the two mechanisms above.

## What the shell build revealed

Standing up `nucleus-shell` (a Wayland *client* rendering with the shared core) forced three
near-verbatim copies of existing code:

1. **The WSI swapchain presenter.** `WaylandVulkanPresenter` is ~90% identical to
   `AndroidVulkanPresenter`: the same shared-device handshake, swapchain create/acquire/
   present/recreate, and semaphore handling. The only real differences are the platform
   surface-creation call (`vkCreateAndroidSurfaceKHR` vs `vkCreateWaylandSurfaceKHR`) and the
   composite-alpha (opaque vs premultiplied). This is one backend with a copied 15-line seam.
2. **The Wayland codegen.** `NucleusShellWaylandGen` + its plugin differ from the compositor's
   `NucleusCompositorWaylandGen` only by `<wayland-client.h>`/`client-header` vs
   `<wayland-server.h>`/`server-header`. The protocol XML list overlaps and the
   `*-protocol.c` marshalling tables are byte-identical between client and server.
3. **The text backend.** `skia_text_backend.cpp` + `TextRegistry.cpp` are symlinked into the
   compositor *and* the shell (and recompiled by the RN platform + Android) — the symlink
   duplication made literal.

`Package.swift` boilerplate (`provisionSDK`, `pkgConfig`, the skia/rn flag blocks) is also
copied across every package, but that is a SwiftPM limitation (manifests cannot share code),
not a design failure — it is out of scope here.

## Deliberate non-goals

- **No `nucleus-vulkan` repo.** `Vulkan`/`VulkanC` are already properly shared
  core modules with no symlinks; every consumer imports them cleanly. The duplication was
  presenter *logic*, not bindings — fixed in-core (Phase 1). Splitting well-factored core
  modules into a repo adds submodule/versioning overhead for no gain.
- **No shared `nucleus-wayland` runtime-bindings repo.** Client and server *usages* genuinely
  diverge (proxy calls vs resource vtables), and a shared build dependency would couple
  `nucleus-compositor` and `nucleus-shell`, which the decomposition deliberately keeps
  build-independent (a compositor and a shell meet only at runtime over the wire). The only
  shared surface is the codegen *tool* + the XML, addressed in Phase 3 as a dev tool, not a
  runtime coupling.

## Phases

### Phase 1 — One WSI swapchain presenter in the render core *(landed)*

`SwapchainPresenter` is in `NucleusRenderer` (`render/SwapchainPresenter.swift`) and both
consumers collapse onto it: `AndroidVulkanPresenter` (~490 lines → ~85) and the shell's render
engine are now thin adapters supplying an owned `VulkanSurface` + `hasAlpha`. The
`NucleusRenderer` target **builds** (`swift build --target NucleusRenderer` — the presenter
compiles against the real Vulkan dispatch API). Original design below.

Vulkan bring-up is one fail-closed capability contract with a 1.4 loader/device
floor. Instance and device extensions, required features, entry points, and the
graphics+presentation queue are qualified before `RenderCore` is constructed;
there is no reduced contract or alternate renderer.

Add `SwapchainPresenter` to `NucleusRenderer` (`render/`): the generic
`PresentationBackend` — shared-device handshake, `configure`/swapchain create + recreate,
`acquireTarget`/`present`, bounded frame slots, per-image presentation synchronization,
generational recreation, acquired-image release, and ordered teardown — with a staged
`VulkanBootstrap` and one owned `VulkanSurface` factory path for every WSI platform, plus an
explicit `hasAlpha` (premultiplied when the surface supports it, else opaque). Both consumers
collapse onto it: `platform-android`'s render engine and `nucleus-shell`'s render engine each
create an owned surface through that factory path before constructing the presenter; the duplicated `AndroidVulkanPresenter` /
`WaylandVulkanPresenter` implementations are deleted. The compositor's DRM/KMS backend stays
separate — it presents via a KMS page-flip, not the Vulkan WSI, so it is a genuinely different
implementation, not a copy.

### Phase 2 — The text backend un-shares to one core product *(landed)*

Relocated the core text-layout sources (`TextLayoutBuilder.hpp`, `TextRegistry.hpp`,
`TextRegistry.cpp`) out of the RN platform tree into the core
(`render-cxx/skia/include/nucleus/text` + `render-cxx/skia`, beside `skia_text_backend.cpp`
which already implements `TextLayoutService`), and repointed the includes to `<nucleus/text/…>`.

**The mechanism landed as a SwiftPM product, not a hand-built SDK lib** — cleaner and native.
`skia_text_backend.cpp` was only ever "downstream-provided" because it `#include`d RN-tree
headers the core lacked; once those moved into the core, the core compiles the text backend
into a `NucleusTextBackend` product (public headers export the `nucleus::text` vocabulary). The
compositor, shell, and RN platform now **link that one product** — the local symlink targets
(compositor/shell `Sources/NucleusTextBackend`, the RN `NucleusTextRegistry`) are deleted. No
custom lib-staging plugin was needed; SwiftPM compiles the product once per consuming build and
links it, which build-verifies (`swift build --target NucleusTextBackend`, and the RN host-cxx
compiles against the core vocabulary). The cross-repo text `.cpp` symlinks are gone.

Two facts surfaced and are recorded here: (1) the RN facade's `TextLayoutManager.hpp` is a
transitive consumer, so RN-importing packages (the shell) add the core text-header path to
their RN include set, read **repo-relative from the nested nucleus** — because (2) the render
SDK's shared `include/skia-text` symlink is a *first-provisioner-wins cache* pointing at
whichever checkout provisioned first, so it cannot be relied on for freshly-relocated headers.
`skia_render_bridge.*` turned out to be **dead code, now deleted** — the old `void *` C
Skia API (80 functions) that the `nucleus::skia` Graphite façade (`Graphite.cpp`/`Graphite.hpp`)
explicitly replaced; it was compiled by no target, symlinked by no consumer, and referenced
nowhere. (An earlier note here mistook it for a downstream-provided source awaiting the same
un-share; it was orphaned, not shared.)

### Phase 3 — One Wayland generator with client/server modes *(landed)*

`SwiftWaylandGen` is an executable product invoked by the ordered
`tools/collider generate wayland` task. The local
`NucleusCompositorWaylandGen` / `NucleusShellWaylandGen` twins are deleted. No
compositor↔shell coupling remains in generation.
Build- and run-verified (the tool emits the correct server vtable-typedef / client-proxy
headers). Original design below.

**Dependency-closure resolution** *(landed)*: the generator resolves the transitive
interface-dependency closure. It parses each protocol's referenced interfaces
(`<arg interface="…">`), indexes every XML under the `--search-dir` roots by the interfaces it
defines, and pulls in the defining protocol for any referenced-but-undefined interface
(cursor-shape references `zwp_tablet_tool_v2`, so tablet is pulled in) — transitively; core
`wl_*` are defined by `wayland.xml`/libwayland and add nothing. It writes the resolved set to
`generated-protocols.tsv`, and Collider drives `wayland-scanner` over that manifest, so
the aggregating header's `#include`s and the compiled marshalling `.c` always match. This fixes
at the codegen root the class of undefined `*_interface` link errors that arises when a selected
protocol references another protocol's interface without that protocol being generated — a
feature, not a dropped protocol.



Merge `NucleusCompositorWaylandGen` and `NucleusShellWaylandGen` into one generator with
`--client`/`--server` modes (selecting the header include and the
`wayland-scanner` header kind) over one protocol-XML manifest sourced from the core's
`third-party/`. It is a build-time dev tool, so both the compositor and the shell can vendor or
reference it without a runtime dependency between them — the marshalling `.c` and the XML are
shared inputs, the emitted client vs server headers stay per-consumer. Lowest priority: the
generator is ~100 lines and the divergence is small, so this lands after 1–2.

### Phase 4 — The shell embeds the RN runtime through the facade, not the dead `cpp/` *(landed)*

Standing up the shell's React bar revealed that the render core still carried `nucleus/cpp/` —
the full React Native native host (host, modules, Fabric, the cbindgen Rust FFI, and the "Rust
supervisor owns `main`" entry points) — as **268 files of dead code**: compiled by no manifest,
plugin, or CMake, referenced by nothing outside itself, and a standing violation of the core's
zero-React-Native invariant. It was residue left when React Native was extracted to
`nucleus-react-native` (repo-decomposition Phase 2). It is **deleted wholesale**, which also
removes the entire Rust FFI seam (Rust is confirmed not on the roadmap) and makes the core
actually React-agnostic.

The real, built RN host is the **facade** (`nucleus-react-native`'s `ReactRuntimeHost.cpp` →
`libNucleusReactRuntimeHostCxx.a`), and the shell embeds the runtime through the facade's stable
public API (`NucleusReactRuntime.Host`: boot, surface lifecycle, `attachSurface`), never by
reaching into the RN platform's internal C++. The one gap the bar needed — bidirectional
native↔JS for the taskbar — is closed by two symmetric facade seams, not a custom native-module
registration:

- **native→JS**: `Host.emitDeviceEvent(name, payloadJson)` — the window list is pushed as a
  `"nucleusShellWindows"` device event; the bar subscribes via `DeviceEventEmitter`.
- **JS→native**: a `NucleusHostCommand` TurboModule whose `invoke(command, argsJson)` forwards
  to `Host.setCommandHandler` (a C callback + opaque context, so a Swift closure bridges without
  a C++ vtable) — the taskbar's activate/close, marshaled from the JS thread onto the shell's
  main-actor frame loop.

Both are general host-embedding seams (any embedder uses them), added to the facade and staged
in the prebuilt host-cxx archive via Collider's typed staging task — the same "compile the C++ once, link
it downstream" mechanism the invariant requires. The shell links; no host reaches into RN
internals, and no dead code remains to mislead the next reader.

## End state

Zero source symlinks across the repos: shared C++ is an SDK-linked prebuilt lib, shared
Swift/C is a package product, and platform variation is a closure/mode over one implementation.
The presenter is one type; the text backend is one lib; the Wayland generator is one tool (with
its dependency closure); the RN runtime is embedded through the facade's stable native↔JS seams,
not by reaching into internals — and the core's dead RN-host `cpp/` residue is gone.
