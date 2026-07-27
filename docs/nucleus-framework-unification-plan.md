# Nucleus Framework and Display Architecture Plan

## Invariant

Within each platform and ABI, Nucleus has one installed implementation artifact for each
capability, one authoritative owner for each piece of mutable system state, and no
duplicated client/server implementations.

Dynamic libraries share implementation code and read-only data across processes. Mutable
graphics state remains process-local. The window-server process exclusively owns global
window, input, composition, output, and physical-display state.

The resulting system obeys these rules:

- Every installed executable is a small composition root over shared libraries.
- A shared library contains a disjoint capability set. No first-party target is absorbed
  into more than one installed shared object.
- `libNucleusFoundation.so` contains the portable value, diagnostics, and host-protocol
  layer. Helpers can use it without loading UI or graphics.
- `libNucleus.so` is the portable application and graphics framework. Skia is linked into
  this shared object once on disk. Every process that renders through Nucleus maps the same
  code pages and creates its own Skia, Graphite, Vulkan, font, and resource-cache state.
- `libNucleusWindowClient.so` contains only the public Linux desktop client stack. It has
  no server implementation and no dependency on DRM, GBM, libinput, libudev, libseat, or
  XCB.
- `libNucleusRenderServer.so` contains the private Wayland server, window manager,
  compositor, input router, DRM/KMS backend, XWayland integration, and physical-display
  presenter. Only `NucleusCompositor` loads it.
- `libNucleusShellKit.so` contains desktop-shell policy and services. Only
  `NucleusShell` loads it.
- Applications rasterize their own backing content. They submit buffers and atomic
  composition transactions to the window server. The window server composes those
  buffers, executes server-owned animations, and presents the final desktop image.
- No Swift object, Skia object, Graphite context, Vulkan instance, or `VkDevice` crosses a
  process boundary. Cross-process contracts carry values, opaque IDs, file descriptors,
  shared buffers, and explicit synchronization primitives.
- The portable framework never imports a Linux client or server module. Linux host
  adapters depend on the portable framework, never the reverse.
- The shell is an ordinary privileged Nucleus application. No shell UI or shell service
  executes in the window-server process.

This is the Apple model at the ownership boundary: frameworks share implementation pages,
applications own local UI and backing-content state, and a render server owns the global
composition tree and display.

## Target process architecture

### Application process

An application owns:

- its `NucleusUI` view tree and layout state;
- its `NucleusLayers` retained content model;
- its local `RendererDevice`, Graphite context, Skia caches, text caches, and Vulkan
  logical device;
- its Wayland connection, surface roles, input state, pasteboard adapters, and client
  presentation objects;
- the exportable buffers containing its rasterized composition-node content.

An application does not own:

- physical outputs or DRM objects;
- desktop-wide focus, stacking, workspace, or window-placement policy;
- global input arbitration;
- scanout selection or page flips;
- composition of other processes' surfaces.

### Window-server process

`NucleusCompositor` owns:

- the `wl_display`, advertised globals, resources, and protocol implementations;
- desktop-wide surface identity, stacking, focus, workspaces, output topology, and
  placement policy;
- libinput, libudev, libseat, XKB server state, cursor position, cursor planes, and input
  routing;
- the DRM primary-node session, GBM allocations, KMS objects, atomic commits, page flips,
  and scanout policy;
- imported client buffers and their release synchronization;
- the authoritative composition tree and server-executable animation timeline;
- XWayland and the mapping between X11 windows and Nucleus surfaces;
- shadows and other composition effects that depend on the global scene;
- the final compositor `RendererDevice` and `DRMScanoutPresenter`.

It does not construct shell views, resolve application icons, talk to UPower on behalf of
the shell, render menus or notifications, or authenticate users.

### Shell process

`NucleusShell` owns:

- bars, taskbar, status surfaces, menus, launchers, notifications, lock-screen views, and
  transient feedback surfaces;
- application indexing, icon-theme lookup, UPower state, shell formatting, and
  notification policy;
- keybinding configuration and action dispatch after the server has arbitrated the
  underlying input;
- cursor-theme preference and other user policy submitted to the server;
- privileged layer-shell, session-lock, foreign-toplevel, screencopy, and data-control
  client capabilities.

The session supervisor creates an unforgeable shell capability as a kernel object and
passes one endpoint to the compositor and the other to the shell. The shell presents the
capability FD through the Wayland privilege protocol. The server verifies the capability
and the connection's `SO_PEERCRED`, binds the resulting privileges to that exact Wayland
client, consumes the one-shot capability, and revokes access on disconnect. Merely
importing a module, sharing a UID, or knowing a token string never grants a capability.

### Helper processes

`NucleusShellPamHelper` remains the only process that loads PAM modules.
`NucleusSessionSupervisor` remains the session-lifecycle owner. Helpers link only their
wire types and required system libraries; they do not load the UI, graphics, window-client,
or render-server frameworks.

## Target artifact graph

The installed dependency graph is:

```text
libNucleusFoundation.so
    portable types, diagnostics, and app-host protocol seams

libNucleus.so
    layers, UI, app model, render model, renderer, text stack,
    Skia Graphite bridge
    └── libNucleusFoundation.so

libNucleusLinux.so
    Linux primitives, reactor, D-Bus, environment, accessibility,
    theme asset I/O
    ├── libNucleusFoundation.so
    └── libNucleus.so

libNucleusWindowClient.so
    Wayland client connection and dispatch, surface roles, input,
    pasteboard, screencopy, DMA-BUF client presenter, desktop host adapter
    ├── libNucleus.so
    └── libNucleusLinux.so

libNucleusRenderServer.so
    Wayland server, window policy, input devices, XWayland,
    global composition, DRM/GBM/KMS presentation
    ├── libNucleus.so
    └── libNucleusLinux.so

libNucleusShellKit.so
    shell policy, desktop services, shell product controller and views
    ├── libNucleus.so
    ├── libNucleusLinux.so
    └── libNucleusWindowClient.so

NucleusCompositor
    └── libNucleusRenderServer.so

NucleusShell
    └── libNucleusShellKit.so

NucleusShellPamHelper
    └── NucleusShellAuthWire only

NucleusSessionSupervisor
    ├── libNucleusFoundation.so
    └── NucleusSessionProtocol
```

`swift-wayland`, `swift-vulkan`, `swift-tracy`, and the session protocol remain
lower-level packages and produce disjoint runtime artifacts where they contain compiled
code:

- `libSwiftWaylandProtocolRuntime.so` owns `WaylandProtocolTypes`,
  `WaylandProtocolsC`, and the shared generated interface descriptors. These targets move
  to `swift-wayland/protocol-runtime/Package.swift` so the role-specific client and server
  products form cross-package dynamic edges instead of absorbing the common objects.
- `libSwiftVulkan.so` owns the compiled generated Swift Vulkan bindings. `VulkanC`
  remains a header module over the system Vulkan loader.
- `libSwiftTracy.so` owns the Tracy Swift/C++ bridge and the single compiled Tracy client
  implementation used by Nucleus libraries in a process.
- `libNucleusSessionProtocol.so` owns the installed supervisor/compositor session wire
  implementation.

Role-specific Wayland client dispatch is absorbed only by
`libNucleusWindowClient.so`. Role-specific server dispatch is absorbed only by
`libNucleusRenderServer.so`. Lower runtime code is never copied independently into an
executable and one of its shared-library dependencies.

The public import surface is separate from the ELF artifact boundary:

- `Nucleus` re-exports the portable application framework modules.
- `NucleusDesktop` re-exports `Nucleus` and the public desktop client API on Linux.
- Submodules remain real Swift compilation units and retain narrow dependency edges.
- `@_exported import` is confined to the two umbrella targets. Internal implementation
  targets use explicit imports.
- `NucleusRenderServer` is not re-exported by either public umbrella.

Android continues to consume the portable modules through its existing Android host
product. The Android host shared object becomes a thin JNI and platform composition root
that depends on the Android builds of `libNucleusFoundation.so` and `libNucleus.so`; it
does not absorb their target objects. `NucleusDesktop` is Linux-only and never appears in
the Android graph.

## Ownership map

| Capability | Sole implementation owner | Runtime state owner |
| --- | --- | --- |
| Values, diagnostics, host protocols | `libNucleusFoundation.so` | each loading process |
| UI, layout, application model | `libNucleus.so` | each application process |
| Text shaping and backing-content rasterization | `libNucleus.so` | each rendering process |
| Wayland client connection and roles | `libNucleusWindowClient.so` | each client process |
| Wayland server and protocol policy | `libNucleusRenderServer.so` | window-server process |
| Client backing-store presentation | `libNucleusWindowClient.so` | each client process |
| Desktop composition and DRM scanout | `libNucleusRenderServer.so` | window-server process |
| Physical input devices and global focus | `libNucleusRenderServer.so` | window-server process |
| UI event dispatch | `libNucleus.so` plus desktop host adapter | destination application |
| Desktop shell policy and services | `libNucleusShellKit.so` | shell process |
| Authentication | `NucleusShellAuthWire` and PAM helper | PAM helper process |

## Cross-process rendering contract

The client/server boundary carries two related streams.

### Backing-content stream

Nucleus clients rasterize content locally into exportable backing stores. A composition
node attaches a `wl_buffer` created from Linux DMA-BUF metadata. The root `wl_surface`
retains window identity and its ordinary Wayland role; it does not force the complete
Nucleus layer tree into one WSI swapchain image.

The normal Nucleus path requires:

- `zwp_linux_dmabuf_v1` feedback and buffer creation;
- `wp_linux_drm_syncobj_manager_v1` timeline synchronization;
- `VK_KHR_external_memory_fd`;
- `VK_EXT_external_memory_dma_buf`;
- `VK_EXT_image_drm_format_modifier`;
- `VK_KHR_external_semaphore_fd`;
- `VK_KHR_timeline_semaphore`;
- `VK_KHR_synchronization2`;
- format, modifier, plane, offset, and stride metadata;
- explicit acquire and release timeline points;
- buffer-age and damage information;
- color-space, alpha-mode, content-scale, and protected-content metadata.

The client device requirement declaration includes these Vulkan extensions. Registry and
device bring-up fail when the required protocol or device features are absent. There is
no hidden WSI fallback for a Nucleus application.

Shared-memory `wl_buffer` objects remain supported for deterministic fixtures and simple
non-accelerated Wayland clients. Ordinary Wayland clients continue attaching one buffer
to each `wl_surface`.

The server imports and composites these buffers. It never dereferences a client pointer or
assumes that a client Vulkan device is related to the server Vulkan device.

### Composition-transaction stream

A generated `nucleus_composition_v1` Wayland protocol carries the retained composition
state that belongs in the render server rather than in an application's raster backing.
One transaction atomically describes:

- stable surface and composition-node IDs;
- parent/child relationships and z-order;
- position, transform, clip, opacity, corner geometry, and visibility;
- attached `wl_buffer`, backing-store generation, and damage;
- input and opaque regions;
- server-executable animation curves, start values, target values, and presentation
  deadlines;
- transaction sequence and acknowledgement IDs.

The protocol contains composition primitives, not `NucleusUI` view types and not Swift
memory layouts. `NucleusLayers` lowers its retained model into versioned wire values
through a protocol seam in `NucleusAppHostProtocols`. The Linux desktop host implements
that seam in `libNucleusWindowClient.so`.

The server validates every object ID, enum, range, buffer reference, and parent
relationship before mutating the scene. Disconnect destroys all state owned by that
client. Protocol errors cannot leave partially applied transactions.

Ordinary Wayland clients continue to work through `wl_surface` without the Nucleus
extension. They receive correct window management and composition but do not get the
Nucleus-specific atomic layer-tree and server-animation path.

## Presenter model

`PresentationBackend` in the portable renderer is the shared source-level abstraction.
It does not imply shared runtime state.

- `WaylandBackingStorePresenter` lives in `libNucleusWindowClient.so`. It owns
  client-local exportable Vulkan images, Linux DMA-BUF and DRM syncobj timeline FDs,
  `wl_buffer` creation, backing-store reuse, submission synchronization, and
  composition-node buffer attachment. It does not create a Vulkan Wayland surface or WSI
  swapchain.
- `DRMScanoutPresenter` lives in `libNucleusRenderServer.so`. It owns GBM buffers, DRM
  framebuffers, atomic KMS state, page flips, direct-scanout decisions, and output
  retirement.
- `AndroidVulkanPresenter` remains the Android conformer.

Each conformer receives a `RendererDevice` created inside its own process. Shared model
types describe capabilities, formats, synchronization, damage, and presentation results.
They never contain live Vulkan or native-window handles from another process.

Direct scanout is a server decision over an imported client buffer. It does not transfer
the server device or DRM ownership to the client.

---

## Phase 1 — Establish role-neutral contracts

The first phase makes the dependency direction correct while preserving current runtime
behavior.

Add the value types needed by every host to `NucleusTypes`:

- output identity, logical geometry, scale, transform, refresh information, and color
  description;
- pointer, keyboard, touch, tablet, focus, and text-input event values;
- surface, seat, device, buffer, and transaction IDs;
- presentation timestamps, damage regions, synchronization descriptors, and capability
  sets.

Move host-facing protocols into `NucleusAppHostProtocols`:

- `ApplicationEventSink`;
- `WindowLifecycleSink`;
- `CompositionTransactionSink`;
- `RenderUploadSink`;
- `PasteboardHost`;
- `OutputTopologyProvider`.

The protocols carry only Swift value types, opaque integer IDs, byte buffers, and explicit
lifetime callbacks. File descriptors terminate inside the Linux client or server
transport implementation and are represented at the portable seam by resource IDs. The
protocols do not import Wayland, Vulkan C modules, Skia C++ modules, DRM, Linux primitives,
or NucleusUI.

Move every data-transfer object referenced by these protocols into `NucleusTypes`.
Higher-level `NucleusLayers` and renderer model objects lower into those values; the
foundation package never depends upward on their defining modules.

Replace `NucleusShellInput`'s direct translation into NucleusUI objects with two layers:

1. a role-neutral Wayland seat state machine that emits `NucleusTypes` input values;
2. a desktop host adapter that delivers those values through `ApplicationEventSink`.

Move `RenderPresenter` responsibilities into the existing portable
`PresentationBackend` seam rather than introducing a second presenter abstraction.
Complete the shared acquire/submit/present result vocabulary there.

Rename the privileged SPI group from `NucleusCompositor` to `NucleusRenderServer`.
Only server-facing extensions in portable render and layer modules use that SPI. Client
host adapters use public protocols and never import the SPI.

Phase 1 lands when:

- portable packages build for Linux and Android without a dependency on
  `swift-wayland`, `platform-linux`, or a compositor package;
- the shell input tests exercise raw Wayland state and UI delivery as separate behavioral
  contracts;
- the compositor and shell still render through their existing backends;
- all current package tests pass through Collider.

## Phase 2 — Produce disjoint dynamic framework artifacts

Replace the flat set of installable first-party library products with explicit dynamic
artifact products.

Create `foundation/Package.swift` and move `NucleusTypes`, `NucleusDiagnostics`, and
`NucleusAppHostProtocols` into it. The package vends the dynamic
`NucleusFoundation` product. Move the targets rather than wrapping or forwarding them;
update every package dependency and source import in the same phase.

This package split is required by SwiftPM's link model. Two dynamic products in the same
package do not create a reliable dynamic edge when one target directly depends on the
other target; SwiftPM can absorb the lower target objects into the higher product.
Cross-package product dependencies force `libNucleus.so` to record
`libNucleusFoundation.so` as a runtime dependency.

In `core/Package.swift`, add one dynamic `Nucleus` product containing the remaining
portable application, layers, renderer, text, and graphics targets and depending on the
new `NucleusFoundation` package product.

Add a thin `Nucleus` umbrella target that re-exports the public modules. Keep the
underlying targets as compilation units, but stop vending them as independent installed
libraries.

Add dynamic runtime products to `swift-wayland`, `swift-vulkan`, and `swift-tracy` for the
compiled target closures named in the artifact graph. Update higher packages to consume
those products. Header-only system-library targets remain import-only and do not create
empty ELF artifacts.

Move the shared Wayland protocol runtime to its own nested package before creating its
dynamic product. Convert `NucleusSessionProtocol` into a dynamic product consumed by the
installed session endpoints. These package boundaries prevent SwiftPM from absorbing a
lower runtime target into multiple higher dynamic products.

`NucleusSkiaGraphiteBridge` becomes the sole owner of the Linux Skia archive list.
`libNucleus.so` is the only installed ELF object that links those archives. Remove
`skiaLinkFlags` and the final-link Skia archive lists from:

- `shell/Package.swift`;
- `compositor/compositor/Package.swift`;
- `compositor/compositor-core/Package.swift`;
- Linux executable and sanitizer-harness targets;
- Linux integration-test targets that consume the installed framework.

Link the archive closure with:

- position-independent code in every native archive;
- `--exclude-libs,ALL` so archive implementation symbols do not enter `.dynsym`;
- `--no-undefined` so the framework cannot defer accidental archive requirements to an
  executable;
- an explicit SONAME;
- RELRO and immediate binding for the installed image.

Do not use `-Bsymbolic-functions` as a substitute for correct symbol ownership. It changes
ELF interposition semantics and is unnecessary once archive symbols are hidden and
defined exactly once.

Create equivalent disjoint dynamic products for `NucleusLinux`,
`NucleusWindowClient`, `NucleusRenderServer`, and `NucleusShellKit` as their phases land.
A higher library depends on a lower dynamic product; it does not absorb a second copy of
the lower product's target objects.

Tests inside an implementation package may continue to link testable target code into
ephemeral test binaries. Installed binaries and end-to-end linkage fixtures must consume
the dynamic products. The installation invariant applies to shipped processes, not to
instrumented unit-test images.

Phase 2 adds artifact checks that fail when:

- `NucleusCompositor`, `NucleusShell`, or a shipped helper defines a Skia symbol;
- an installed shared object other than `libNucleus.so` contains Skia archive members;
- `libNucleus.so` exports Skia implementation symbols;
- a shipped executable contains first-party Swift implementation sections that belong in
  a framework;
- two installed shared objects contain the same first-party target object;
- an installed dependency cannot be resolved from the staged rpath.

Collider emits a linker map for every installed ELF object and records a normalized
ownership manifest keyed by Swift target object, C/C++ object, and static-archive member.
The validation intersects those manifests to detect duplicate ownership. Dynamic
dependencies appear only as `NEEDED` edges and never as copied members in the consuming
artifact's ownership set.

Phase 2 lands when the existing compositor and shell use `libNucleus.so`, both render
successfully in automated fixtures, and their ELF dependency and symbol tables satisfy
the checks above.

## Phase 3 — Extract the public desktop client framework

Create the Linux-only `NucleusWindowClient` package and dynamic library. Move generic
client functionality out of `shell/`:

- `NucleusShellWayland` becomes `NucleusWindowClientWayland`;
- `NucleusShellInputC` becomes `NucleusWindowClientXkbC`;
- the role-neutral portion of `NucleusShellInput` becomes
  `NucleusWindowClientInput`;
- `NucleusShellPasteboard` becomes `NucleusWindowClientPasteboard`;
- `NucleusShellRender` becomes `NucleusWindowClientRender` without changing presentation
  behavior in this phase;
- `NucleusShellLoop` is replaced by `NucleusLinuxReactor` integration owned by
  `NucleusWindowClientRuntime`.

Add `NucleusDesktopHost`, the adapter that composes:

- the portable app and render host protocols;
- the Wayland connection and registry;
- ordinary toplevel and popup roles;
- privileged layer-shell, session-lock, foreign-toplevel, screencopy, and data-control
  roles when the server grants them;
- input delivery, pasteboard, output topology, frame callbacks, and presentation.

The public API exposes capability objects returned by registry negotiation. It does not
expose raw `wl_*` pointers. Loss of a global invalidates the corresponding capability and
produces a typed lifecycle event.

`NucleusDesktop` becomes the Linux application umbrella. A normal Linux application
depends on `NucleusDesktop` and does not depend on `swift-wayland`, `swift-vulkan`,
`platform-linux`, `shell`, or a compositor package directly.

Rename the existing `NucleusCompositorWaylandTestSupport` product to
`NucleusRenderServerTestSupport` and move client/server conformance support out of the
production dependency graph. A dedicated integration-test package depends on both
`NucleusWindowClient` and `NucleusRenderServerTestSupport`; the production shell package
depends only on `NucleusWindowClient`.

Phase 3 lands when:

- the shell contains no generic Wayland client, input translation, pasteboard transport,
  or backing-store presenter implementation;
- a minimal fixture application creates a window, receives input, exchanges pasteboard
  data, reacts to output changes, and presents frames through `NucleusDesktopHost`;
- registry removal, compositor disconnect, buffer release, and reconnect behavior are
  covered by deterministic client/server fixtures;
- `libNucleusWindowClient.so` has no `NEEDED` entry for DRM, GBM, libinput, libudev,
  libseat, XCB, or `libwayland-server`;
- all client and shell tests pass through Collider.

## Phase 4 — Consolidate the private render-server framework

Create the dynamic `NucleusRenderServer` product in `compositor/compositor-core`. It
absorbs the server-owned targets and sources:

- `NucleusCompositorWaylandRuntime`;
- `NucleusCompositorServer`;
- `NucleusCompositorServerTypes`;
- `NucleusCompositorWindowManager`;
- `NucleusCompositorWindowScene`;
- `NucleusCompositorRendererLinux`;
- `NucleusCompositorRenderRuntime`;
- `NucleusCompositorRenderSession`;
- `NucleusCompositorDrmC`;
- `NucleusCompositorInputC`;
- `NucleusCompositorXcbC`;
- server-owned cursor, shadow, idle, and global-input policy;
- the existing `NucleusCompositorShell`, compositor overlay, and hosted-surface targets as
  explicitly transitional inputs removed in phase 6.

The Swift targets remain narrow compilation units inside the product. The product exports
one server entry point:

```swift
@_spi(NucleusRenderServer)
public func runRenderServer(
    configuration: RenderServerConfiguration
) async throws
```

`NucleusCompositor` constructs configuration from the session supervisor, signal source,
diagnostics, and environment, then calls this entry point. It contains no renderer,
Wayland, DRM, input, window-manager, or shell policy.

Delete the server-side duplicates of client responsibilities. The server keeps data-device
and input protocol resource management and policy; it does not keep a client pasteboard
adapter, UI event model, or client presentation implementation.

Expand `NucleusRenderServerTestSupport` to supply socket-pair setup, deterministic clocks,
fake seat/device injection, fake output topology, and headless presentation sinks. It is
a test-support product and is not staged for installation.

Phase 4 lands when:

- `NucleusCompositor` is a composition-root stub;
- the server library alone depends on DRM, GBM, libinput, libudev, libseat, XCB, and
  `libwayland-server`;
- lifecycle, focus, placement, input routing, XWayland mapping, buffer import, composition,
  and output-retirement tests run against the real server runtime;
- a client protocol error destroys only the offending client;
- loss and reacquisition of the DRM session do not invalidate client-owned state;
- all compositor tests and sanitizer harnesses pass through Collider.

## Phase 5 — Complete process-local presenter ownership

Refactor the two Linux presentation backends onto the completed
`PresentationBackend` contract.

`WaylandBackingStorePresenter` replaces `WaylandVulkanSurface` and the client WSI path. It
absorbs:

- exportable Vulkan image allocation for the compositor-advertised format/modifier set;
- DMA-BUF plane export and `wl_buffer` creation;
- DRM syncobj timeline export and monotonically increasing acquire/release points;
- per-node buffer attachment, damage, frame callbacks, and presentation feedback;
- release-driven backing-store reuse;
- backing-store replacement when size, format, modifier, scale, or protection changes.

Delete `WaylandVulkanSurface`, `VK_KHR_wayland_surface` enablement, and client swapchain
state after the backing-store presenter passes the shared contract suite.

`DRMScanoutPresenter` absorbs:

- `GbmScanoutBuffer`;
- DRM framebuffer registration;
- renderer/output binding;
- atomic KMS state and page-flip completion;
- direct-scanout eligibility and fallback composition;
- output generation and retirement.

`RendererDevice`, `RendererSubmission`, and `RendererTopology` remain portable model and
implementation types in `libNucleus.so`, but every process constructs independent
instances. Remove any singleton, static registry, or API that implies a device can be
shared between the shell and compositor.

Make synchronization ownership explicit:

- a client owns a buffer until it commits it;
- the client publishes the acquire timeline point that completes its rendering;
- the server waits for the acquire point before sampling;
- the server signals the release timeline point when it no longer reads the buffer;
- the client cannot recycle the image before the release point is signaled;
- direct scanout and composed scanout follow the same release contract.

Phase 5 lands when:

- the Wayland backing-store and DRM presenters pass the same backend contract suite;
- device loss in a client terminates or rebuilds only that client's renderer;
- server device loss rebuilds server presentation without pretending client Vulkan
  objects survive in the server;
- explicit-sync, resize, output-removal, occlusion, buffer-release, and direct-scanout
  transitions have behavioral coverage;
- no cross-process contract contains a Vulkan handle or pointer.

## Phase 6 — Move all desktop shell UI and policy out of the server

Create `shell/shell-kit/Package.swift` with the dynamic `NucleusShellKit` product. Keep
the `NucleusShell` executable target in `shell/Package.swift` and make it depend on the
new package product. The package split forces a real `NEEDED` edge; a dynamic library and
its executable cannot remain target-dependent siblings in one SwiftPM package.

Move shell-owned services into the shell-kit package:

- `BezelService`;
- `DesktopApplicationIndex`;
- `IdlePolicy` preferences and timeout configuration;
- `KeybindService` configuration and accepted-action dispatch;
- `LauncherService`;
- `NotificationService`;
- `ShellPolicyService`;
- `ShellServices`;
- `IconThemeResolver`;
- `ShellIconSourceResolver`;
- `ShellFormatting`;
- `UPowerService`;
- `CursorTheme` as a preference model;
- `CursorThemeHost` as the window-server client adapter.

Keep authoritative mechanism in the server:

- physical key and pointer processing;
- focus and shortcut arbitration;
- the idle clock and session-lock enforcement;
- `XCursor` loading, cursor image validation, cursor-plane state, and cursor rendering;
- window shadows and global composition effects.

The shell sends policy through authenticated protocol requests. The server emits
privileged events such as an accepted global shortcut or idle-state transition. Neither
side imports the other's implementation module.

Add the shell privilege protocol before moving the first privileged surface. The session
supervisor issues a new one-shot capability for every shell launch. The server grants
layer-shell control, session lock, foreign-toplevel control, screencopy, data control, and
shell-policy requests only after capability verification. Authentication failure is a
protocol error and creates no privileged object.

Delete the in-process overlay UI:

- `ShellOverlayController`;
- `ShellOverlayScene`;
- `ShellOverlayTypes`;
- `ShellOverlayHotkeyView`;
- `ShellOverlayMenuView`;
- `ShellOverlayNotificationView`;
- `NucleusCompositorOverlayScene`;
- `NucleusCompositorOverlayTypes`;
- the hosted-surface bridge used only to place shell UI inside the compositor.

Reimplement hotkey feedback, menus, notifications, bars, taskbar, status surfaces, and
the lock screen as shell-owned Wayland surfaces. `ShellShadow` becomes a server
composition effect and is not exposed as shell UI.

Keep `NucleusShellAuth`, `NucleusShellAuthWire`, and `NucleusShellPamHelper` separate.
The lock-screen view runs in the shell; PAM conversation and module loading remain in the
helper.

Phase 6 lands when:

- the compositor links neither `libNucleusShellKit.so` nor a shell product module;
- no shell view is created in the compositor process;
- shell restart does not restart the compositor or destroy ordinary application surfaces;
- shell disconnect removes its privileged surfaces and revokes its capabilities;
- lock, unlock, notification, launcher, global-shortcut, cursor-theme, and idle flows pass
  deterministic integration tests;
- shell service and product tests pass through Collider.

## Phase 7 — Add atomic composition transactions

Generate `nucleus_composition_v1` client and server bindings through
`swift-wayland`. Keep the XML and generated Swift/C bindings in the protocol package with
the other committed Wayland protocol artifacts.

Add a `NucleusLayers` encoder that converts committed retained-layer state into immutable
composition transaction values. Add the Linux transport implementation in
`libNucleusWindowClient.so` and the validated scene-application implementation in
`libNucleusRenderServer.so`.

Migrate one semantic at a time in this fixed order:

1. surface identity, parentage, geometry, visibility, and atomic commit;
2. damage, clip, opacity, transform, and content scale;
3. input and opaque regions;
4. server-owned animation timelines;
5. presentation acknowledgements and retirement.

The client continues rasterizing visual content. The transaction protocol never sends
view objects, arbitrary Swift values, closures, Skia display lists, or GPU command
buffers.

Server-side animation operates only on composition properties. An animation that changes
the raster content remains client-driven and produces new backing buffers.

Phase 7 lands when:

- a transaction becomes visible entirely or not at all;
- malformed graphs, stale IDs, cycles, invalid buffer generations, and oversized
  transactions are rejected before scene mutation;
- client death reclaims all nodes and buffers without disturbing another client;
- server-side transform and opacity animations continue when the client main thread is
  blocked;
- ordinary non-Nucleus Wayland clients remain fully functional;
- transaction conformance and fuzz fixtures pass through Collider.

## Phase 8 — Collapse public imports without collapsing ownership

Finish the two umbrella modules after the runtime boundaries are stable.

`Nucleus` re-exports:

- `NucleusTypes`;
- `NucleusDiagnostics`;
- `NucleusAppHostProtocols`;
- `NucleusLayers`;
- `NucleusUI`;
- `NucleusApp`;
- public render and text model APIs required by applications.

It does not re-export C++ bridge modules, renderer internals, test support, Android host
internals, Linux modules, or server SPI.

`NucleusDesktop` re-exports:

- `Nucleus`;
- public desktop window, input, pasteboard, output, and presentation APIs;
- the Linux desktop application host.

It does not re-export raw Wayland modules, Linux implementation modules, shell services,
or render-server modules.

Remove the old flat public library products after all callers use the umbrellas or an
explicit internal product. Delete replaced imports and compatibility wrappers in the same
phase.

Phase 8 lands when:

- a normal desktop application imports only `NucleusDesktop`;
- a portable library imports only `Nucleus`;
- server and shell implementation packages use explicit narrow modules;
- Android builds without resolving `NucleusDesktop`;
- API documentation exposes no server SPI, raw Wayland pointer, Skia C++ type, or Vulkan
  handle.

## Phase 9 — Install, relocate, and validate the runtime

Collider stages:

```text
bin/
    NucleusCompositor
    NucleusShell

lib/
    libNucleusFoundation.so
    libNucleus.so
    libNucleusLinux.so
    libNucleusWindowClient.so
    libNucleusRenderServer.so
    libNucleusShellKit.so
    libSwiftWaylandProtocolRuntime.so
    libSwiftVulkan.so
    libSwiftTracy.so
    libNucleusSessionProtocol.so

libexec/
    NucleusShellPamHelper
    NucleusSessionSupervisor
```

Executables in `bin/` and `libexec/` use `$ORIGIN/../lib`. Shared libraries use
`$ORIGIN` for sibling dependencies. No installed binary depends on Collider's scratch
directory, the source checkout, `NUCLEUS_NATIVE_SDK_ROOT`, or an absolute development
path.

Collider's install validation checks:

- every `NEEDED` entry resolves inside the staged tree or to an approved host system
  library;
- SONAMEs and rpaths match the staged layout;
- `NucleusShell` does not load the render-server library or server-only native libraries;
- `NucleusCompositor` does not load the window-client or shell library;
- helpers load none of the UI, graphics, client, server, or shell libraries;
- a helper that needs diagnostics loads `libNucleusFoundation.so` without pulling in
  `libNucleus.so`;
- Skia archive symbols occur only in `libNucleus.so` and are absent from its dynamic
  exports;
- no first-party target implementation appears in two installed objects;
- stripping preserves the required Swift runtime metadata and public entry points;
- the complete staged tree relocates and passes headless client/server smoke fixtures.

The installed artifacts are rebuilt and upgraded as one unit. Nucleus does not enable
library evolution and does not promise independent ABI compatibility between these
private shared objects.

## Final state

The work is complete when all of the following are simultaneously true:

- `NucleusCompositor` and `NucleusShell` are small composition roots.
- Applications share one installed Nucleus implementation but retain isolated mutable
  graphics state.
- The compositor is the only owner of global scene state, physical input, DRM/KMS, and
  scanout.
- The shell is fully out of process and owns all desktop UI.
- Client and server use one generated protocol vocabulary and do not duplicate runtime
  implementations.
- The client library has no server or hardware dependency.
- The server library has no shell UI or shell-service dependency.
- Cross-process rendering uses buffers, value transactions, and explicit synchronization.
- The staged dependency graph and symbol tables mechanically enforce the ownership rules.
- Linux desktop, Android, compositor, shell, helper, integration, and sanitizer gates all
  pass through Collider.
