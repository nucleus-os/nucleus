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
- `NucleusConfigService` is the sole reader, writer, watcher, and publisher of session
  configuration. The compositor, shell, and control CLI never maintain independent
  interpretations of the configuration file.
- `libNucleusConfig.so` contains resolved configuration values and their stable snapshot
  codec. `libNucleusConfigIO.so` contains source parsing and filesystem I/O and is not
  loaded by the compositor or shell.
- `libNucleusIPCTransport.so` is the sole first-party Unix packet transport. Session,
  configuration, control, and Android broker protocols use it instead of defining their
  own socket, credential, descriptor-transfer, or packet-lifetime implementations.
- `NucleusControlService` owns the user-facing control socket and routes typed requests to
  the process that owns the requested state. The compositor never accepts or blocks on a
  control client connection.
- Wayland display traffic, internal session traffic, public operator control, and Android
  broker traffic retain separate protocol vocabularies. Sharing transport does not merge
  their object models or authority.
- Applications rasterize their own backing content. They submit buffers through
  standard `wl_surface` state and group independently backed content with synchronized
  `wl_subsurface` trees. The window server composes those surfaces, executes
  window-manager animations, and presents the final desktop image.
- No Swift object, Skia object, Graphite context, Vulkan instance, or `VkDevice` crosses a
  process boundary. Cross-process contracts carry values, opaque IDs, file descriptors,
  shared buffers, and explicit synchronization primitives.
- The portable framework never imports a Linux client or server module. Linux host
  adapters depend on the portable framework, never the reverse.
- The shell is an ordinary Nucleus desktop application. The compositor does not identify,
  retain, authenticate, or authorize a shell `wl_client`. No shell UI or shell service
  executes in the window-server process.
- Standard desktop globals are advertised through the normal Wayland registry. Sensitive
  operations are accepted or denied by their protocol mechanism and compositor policy;
  future sandbox mediation uses standard security contexts and portals rather than shell
  process identity. Component-private protocols such as `xwayland_shell_v1` remain limited
  to the exact component connection required by their specification.

This is the Apple model at the ownership boundary: frameworks share implementation pages,
applications own local UI and backing-content state, and a render server owns the global
composition tree and display.

## Implementation progress

Updated 2026-07-28. A phase becomes complete only after every listed landing gate passes.

| Phase | Status | Current evidence |
| --- | --- | --- |
| 1 — Role-neutral contracts | Complete | `NucleusTypes` owns the stable host values and `NucleusAppHostProtocols` owns the five cross-platform application-host seams. `NucleusShellWayland` emits `ApplicationInputEvent`; `ShellInputRouter` is the desktop `ApplicationEventSink`, and its 23 behavioral tests pass. The privileged group is `NucleusRenderServer`. Linux, Android, loader, headless-GPU, production stress, and the complete `collider test all` graph pass. Collider’s shared SwiftPM invocation preserves executable arguments for lane probes. |
| 2 — Dynamic framework artifacts | Complete | The lower runtime graph is split into dynamic `NucleusFoundation`, `Nucleus`, `NucleusLinux`, `NucleusLinuxDesktop`, `NucleusConfig`, `NucleusConfigIO`, `NucleusIPCTransport`, `NucleusControlProtocol`, `NucleusControlClient`, `NucleusSessionProtocol`, `SwiftWaylandProtocolRuntime`, `SwiftVulkan`, and `SwiftTracy` products with real ELF dependency edges. Session launch and configuration-subscription traffic use the shared packet transport. Linux base, desktop, and session code live in disjoint packages. Every Linux runtime consumer requests the single `Nucleus` product; downstream Skia archive lists are gone. Collider emits a normalized dynamic-symbol ownership manifest and enforces SONAME, `$ORIGIN`, `NEEDED`, headless-isolation, sole Skia ownership, and sole packet-transport ownership on every shell build. Config, IPC, Linux, session, compositor, shell, and complete lower-runtime gates pass. |
| 3 — Desktop client framework | Complete | `window-client/` produces `libNucleusWindowClient.so` with disjoint contracts, reactor integration, ordinary toplevel/popup and desktop Wayland roles, input, pasteboard, presentation, and a capability-only `NucleusDesktop` umbrella. `NucleusDesktopHost` owns the process-local connection, reactor, retained store, application host, text system, and renderer. Generated Wayland layer-policy values and native proxies are confined to the implementation SPI. The shell contains no generic client implementation and has no direct swift-wayland, swift-vulkan, or compositor-core dependency. The dedicated client/server conformance package passes 56 input, lifecycle, output-removal, reconnect, pasteboard, drag/drop, and window-role tests; deterministic server fixtures cover buffer replacement/release, and all 123 shell product/service/runtime tests pass. The dynamic artifact gate enforces the forbidden server-native dependency set. |
| 4 — Render-server framework | Complete | `libNucleusRenderServer.so` owns the narrow server module closure, process bring-up, render session, signal façade, and the Wayland-server, DRM/GBM, input, seat, udev, XCB, and XKB dependency set. `NucleusCompositor` is a launch-only stub over `runRenderServer`. Collider normalizes SwiftPM-propagated native linker entries, then the ELF ownership gate, complete compositor-core suite, 56 client/server conformance tests, and 123 shell tests pass. Collider's complete ThreadSanitizer lane passes all six core, Linux, Android, render-server, shell, and React Native harnesses; the relocated render-server harness executes against the real framework runtime. |
| 5 — Process-local presenters | Complete | Server KMS ownership is consolidated in `DRMScanoutPresenter`; the former `RendererRuntime` and `GbmScanoutBuffer` identities are gone. The client WSI path, raw native-surface escape, `WaylandVulkanSurface`, `VK_KHR_wayland_surface`, and client swapchain state are gone. `WaylandBackingStorePresenter` owns a three-image DMA-BUF generation, typed `wl_buffer` commits, one exported Vulkan/DRM-syncobj timeline, acquire/release points, frame callbacks, presentation feedback, release-gated reuse, resize retirement, and client-local device-loss termination. Vulkan requirements hard-require the backing-store export/sync entry points and no client WSI extension. Both presenters pass the same acquire/submit/completion/replacement/pause/removal contract suite. Allocation, feedback parsing, explicit sync, resize, pacing/occlusion, output removal, server device loss, and direct-scanout replacement release have behavioral coverage. All 168 renderer-linux tests, `collider test compositor`, and `collider test shell` pass. Collider treats the launch-only compositor package as build-only after compositor-core tests instead of invoking an empty test package. |
| 6 — Configuration authority | Complete | `NucleusConfigService` is the sole active-file reader, watcher, writer, generation owner, and projection publisher. The supervisor starts it first, authenticates capability-scoped render-server and shell subscribers, and gates both consumers on their typed initial projections. Invalid startup, invalid reload, removal, directory recreation, atomic replacement, duplicate-event coalescing, service epoch changes, stale-message rejection, shell absence, and connected/future input-device application have behavioral coverage. The compositor and shell no longer depend on `NucleusConfigIO`; the runtime ELF gate proves the service's direct dynamic model/IO/Linux/session edges and forbidden UI, Skia, Wayland, DRM, render-server, window-client, and shell edges. Config, session, compositor, shell, and runtime ownership gates pass. |
| 7 — Session control service | Complete | `NucleusControlService` is a standalone broker composition root over `libNucleusControlService.so`; the compositor owns only its private typed owner endpoint and has no public listener, JSON codec, control-client dependency, or socket path. The configuration service and render server publish version/readiness, owner identity, configured/applied generations, outputs, bindings, and typed results over supervisor capability channels. The supervisor preserves one mode-`0600` public socket across configuration-service, compositor, and shell restarts, returns typed owner-unavailable responses during owner absence, reattaches replacements without stale-HUP races, and revokes public access before stopping the broker. Same-owner socket replacement is inode-safe; peer credentials, packet bounds, descriptor cardinality, protocol versions, and elevated one-shot capabilities are enforced before routing. The CLI is presentation-only over the dynamic control client and obtains canonical configuration from the service. `collider test ipc` owns and passes transport, protocol, client, routing, authorization, CLI, hostile-packet, generation, and all 16 restart/session fixtures; `collider test compositor`, `collider test shell`, and runtime ELF ownership pass. |
| 8 — Out-of-process shell | Complete | `NucleusShellKit` is a real dynamic product and the executable is launch-only. The in-process compositor overlay modules and shell service graph are deleted; server mechanisms live in `NucleusCompositorPolicy`, while application discovery, launching, and accepted-action dispatch live in ShellKit. The shell connects through the normal session `WAYLAND_DISPLAY`; the compositor stores no shell client identity or client object. Each shell generation receives only a supervisor-created typed `NucleusSessionProtocol` policy channel for accepted actions and Nucleus policy without a standard Wayland vocabulary. Standard desktop globals remain available to ordinary clients, with only the specification-mandated `xwayland_shell_v1` connection filter retained. No custom shell-authentication Wayland protocol exists. Policy descriptor-cardinality, codec, version, restart, shell-surface, cursor/idle, public pasteboard/drag-drop, managed-client lifetime, configuration, compositor-policy, supervisor-acceptance, runtime ELF, and full `collider test ipc`, `collider test compositor`, and `collider test shell` gates pass. |
| 9 — Standard atomic surface trees | Complete | Standard `wl_surface` and synchronized `wl_subsurface` state is the sole application-composition boundary. Repeated child commits accumulate cached buffer and adjacent state until the parent commit. The public desktop client constructs nested surface trees and uses `wp_alpha_modifier_v1`; the server latches alpha with core state and excludes modified surfaces from direct scanout. Raw-wire alpha uniqueness/reset, cached-buffer preservation, topology, registry, hostile protocol, direct-scanout, client/server lifecycle, full SwiftWayland, compositor-core, `collider test compositor`, and `collider test shell` gates pass. |
| 10 — Public umbrellas | Complete | `Nucleus` re-exports only `NucleusApp`, `NucleusDiagnostics`, and `NucleusUI`; lower-level host, layer, render-model, and embedder modules remain explicit integrator imports. `NucleusDesktop` adds only the public window-client contracts and host. Dedicated umbrella tests prove unambiguous application names and public host construction. Portable core, Android production/AAR/APK verification, compositor, shell, runtime ELF ownership, and public client/server integration gates pass. |
| 11 — Install and validation | Complete | `collider install session` builds and publishes one content-addressed runtime generation containing the exact executable, libexec, first-party shared-library, Swift/Foundation/Dispatch, libc++, and unwind closure. Every executable and helper uses `$ORIGIN/../lib`; every shared library uses `$ORIGIN`. Staging validates exact contents, SONAMEs, ownership, forbidden dependency edges, Skia and IPC symbol ownership, unresolved relocations, and absence of development paths, then moves the candidate to a different directory and repeats validation before publication. The final generation is `sha256:cfeb4b1fa502753e3ad1d3ef9775b3692824deb8a5daf556dbceaaadfd08f05f`. Runtime doctor, the complete `collider test all` graph, release publication/lifecycle/editor/collection/Wayland transport/compositor stress suites, and the relocated install gate pass. |

## Target process architecture

### Application process

An application owns:

- its `NucleusUI` view tree and layout state;
- its `NucleusLayers` retained content model;
- its local `RendererDevice`, Graphite context, Skia caches, text caches, and Vulkan
  logical device;
- its Wayland connection, surface roles, input state, pasteboard adapters, and client
  presentation objects;
- the exportable buffers containing its rasterized surface content;
- its internal layer graph and application-content animation timelines.

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
- the authoritative desktop surface tree and window-manager animation timeline;
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
- displayed keybinding state and accepted-action dispatch after the server has arbitrated
  the underlying input;
- cursor-theme preference and other persistent user policy submitted through the
  configuration service;
- layer-shell, session-lock, foreign-toplevel, screencopy, workspace, data-control, and
  idle-notification capability objects negotiated through the standard registry.

The session supervisor selects the session `WAYLAND_DISPLAY` name before it starts the
render server. The shell connects to that ordinary listener exactly like another desktop
client. The compositor does not record which `wl_client` belongs to the shell and performs
no shell authentication during registry enumeration or global binding. Every shell
generation receives a fresh typed shell-policy channel for accepted shortcuts, window-menu
selection, and other Nucleus semantics that have no standard protocol. Replacing the shell
closes that policy channel; libwayland performs ordinary resource teardown when the shell's
Wayland connection closes.

Session lock remains exclusive and request-time policy decides whether a lock request is
accepted. Data control and capture follow the session's current same-user trust model.
When application sandboxing lands, standard Wayland security contexts and portal-mediated
consent become the authorization boundary. Shell identity never becomes that boundary.

### Helper processes

`NucleusShellPamHelper` remains the only process that loads PAM modules.
`NucleusSessionSupervisor` remains the session-lifecycle owner.

`NucleusConfigService` owns the active configuration snapshot. It starts before the
compositor, watches and atomically persists the configuration file, and publishes
owner-specific resolved projections over supervisor-provided capability channels. It
loads no UI, graphics, Wayland, DRM, shell, or render-server framework.

`NucleusControlService` owns the session's operator-control endpoint. It authenticates
local peers, decodes the public control protocol, and forwards typed operations over
supervisor-provided channels to the configuration service or render server. It retains no
configuration, window, output, focus, or shell state of its own and survives compositor
and shell restarts.

Other helpers link only their wire types and required system libraries; they do not load
the UI, graphics, window-client, render-server, shell, or configuration-I/O frameworks.

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
    Linux primitives, reactor, D-Bus, file watching, theme asset I/O

libNucleusLinuxDesktop.so
    Linux environment and accessibility adapters
    ├── libNucleusFoundation.so
    ├── libNucleus.so
    └── libNucleusLinux.so

libNucleusConfig.so
    resolved configuration model, defaults, validation,
    owner projections, stable snapshot codec

libNucleusConfigIO.so
    JSON syntax preparation, source diagnostics, load, export,
    file discovery and atomic persistence
    └── libNucleusConfig.so

libNucleusConfigService.so
    active snapshot authority, file watching, generation publication,
    subscriber lifecycle
    ├── libNucleusConfigIO.so
    ├── libNucleusIPCTransport.so
    ├── libNucleusLinux.so
    └── libNucleusSessionProtocol.so

libNucleusIPCTransport.so
    Unix SOCK_SEQPACKET, socket pairs, peer credentials,
    SCM_RIGHTS, owned descriptors, bounded packet send/receive

libNucleusControlProtocol.so
    versioned public control requests, responses, DTOs,
    JSON packet payload codec
    ├── libNucleusFoundation.so
    └── libNucleusConfig.so

libNucleusControlClient.so
    control endpoint discovery, one-shot request client,
    response and request-ID validation
    ├── libNucleusIPCTransport.so
    └── libNucleusControlProtocol.so

libNucleusControlService.so
    authenticated public control endpoint and owner routing
    ├── libNucleusIPCTransport.so
    ├── libNucleusControlProtocol.so
    ├── libNucleusLinux.so
    └── libNucleusSessionProtocol.so

libNucleusWindowClient.so
    Wayland client connection and dispatch, surface roles, input,
    pasteboard, screencopy, DMA-BUF client presenter, desktop host adapter
    ├── libNucleus.so
    └── libNucleusLinux.so

libNucleusRenderServer.so
    Wayland server, window policy, input devices, XWayland,
    global composition, DRM/GBM/KMS presentation
    ├── libNucleus.so
    ├── libNucleusConfig.so
    ├── libNucleusLinux.so
    └── libNucleusSessionProtocol.so

libNucleusShellKit.so
    shell policy, desktop services, shell product controller and views
    ├── libNucleus.so
    ├── libNucleusLinux.so
    ├── libNucleusLinuxDesktop.so
    ├── libNucleusConfig.so
    ├── libNucleusSessionProtocol.so
    └── libNucleusWindowClient.so

NucleusCompositor
    └── libNucleusRenderServer.so

NucleusShell
    └── libNucleusShellKit.so

NucleusConfigService
    └── libNucleusConfigService.so

NucleusControlService
    └── libNucleusControlService.so

nucleus
    └── libNucleusControlClient.so

NucleusShellPamHelper
    └── NucleusShellAuthWire only

NucleusSessionSupervisor
    ├── libNucleusFoundation.so
    └── libNucleusSessionProtocol.so
```

`swift-wayland`, `swift-vulkan`, `swift-tracy`, the IPC transport, and the session
protocol remain lower-level packages and produce disjoint runtime artifacts where they
contain compiled code:

- `libSwiftWaylandProtocolRuntime.so` owns `WaylandProtocolTypes`,
  `WaylandProtocolsC`, and the shared generated interface descriptors. These targets move
  to `swift-wayland/protocol-runtime/Package.swift` so the role-specific client and server
  products form cross-package dynamic edges instead of absorbing the common objects.
- `libSwiftVulkan.so` owns the compiled generated Swift Vulkan bindings. `VulkanC`
  remains a header module over the system Vulkan loader.
- `libSwiftTracy.so` owns the Tracy Swift/C++ bridge and the single compiled Tracy client
  implementation used by Nucleus libraries in a process.
- `libNucleusSessionProtocol.so` owns the installed supervisor/compositor session wire
  implementation, including configuration subscription envelopes. It depends dynamically
  on `libNucleusConfig.so` for resolved projection values and snapshot decoding, and on
  `libNucleusIPCTransport.so` for packet and descriptor transport.

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
- `NucleusConfig`, `NucleusConfigIO`, and configuration service APIs are not re-exported
  by either public umbrella. They are internal system frameworks.
- IPC transport, control protocol, control client, and control service modules are not
  re-exported by either application umbrella.

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
| Resolved configuration vocabulary | `libNucleusConfig.so` | each subscribing process |
| Configuration source parsing and persistence | `libNucleusConfigIO.so` | config-service process |
| Active configuration and reload generation | `libNucleusConfigService.so` | config-service process |
| Unix packet and descriptor transport | `libNucleusIPCTransport.so` | each channel endpoint |
| Public control vocabulary | `libNucleusControlProtocol.so` | control client and broker processes |
| Public control socket and request routing | `libNucleusControlService.so` | control-service process |
| Authentication | `NucleusShellAuthWire` and PAM helper | PAM helper process |

## IPC architecture

Nucleus separates transport from protocol and protocol from runtime ownership.

| Domain | Protocol owner | Endpoint owner |
| --- | --- | --- |
| Application display and shell surfaces | `swift-wayland` plus Nucleus Wayland extensions | window client and render server |
| Session lifecycle and inherited capabilities | `NucleusSessionProtocol` | session supervisor and child services |
| Private shell policy and accepted-action events | `NucleusSessionProtocol` | shell and render server |
| Configuration publication | `NucleusSessionProtocol` plus `NucleusConfig` projections | configuration service and subscribers |
| Operator and CLI control | `NucleusControlProtocol` | control service |
| Android GPU and container brokering | Android graphics contracts | Android host and broker |

Wayland remains independent of the first-party packet transport. Its generated object
lifecycle, event-loop integration, and protocol semantics are not wrapped in
`NucleusIPCTransport`.

### Packet transport

`NucleusIPCTransport` provides:

- `AF_UNIX` `SOCK_SEQPACKET` listeners, connections, and socket pairs;
- close-on-exec and nonblocking creation;
- `SO_PEERCRED` peer identity;
- `SCM_RIGHTS` descriptor transfer;
- `MSG_CMSG_CLOEXEC`, payload truncation, and control truncation handling;
- configured maximum payload and descriptor counts;
- automatic closure of every received descriptor that is not explicitly taken;
- explicit EOF, peer-reset, authorization, oversize, and system-call failures;
- reactor-ready descriptors without embedding a concurrency or actor policy.

One packet is one protocol message. Stream delimiters and partial-line state machines do
not exist in internal or control transports.

`NucleusIPCTransportC` owns the unsafe POSIX operations. The Swift layer owns descriptor
lifetime, peer validation, packet limits, and typed errors. Platform-specific socket paths,
SELinux labels, message codecs, and authorization policy remain in the consuming
protocol.

The generic implementation currently under `NucleusAndroidIPCC` moves into this package.
`NucleusAndroidIPC` retains Android graphics envelopes, descriptor-count validation,
broker authorization, and platform path policy. Its duplicated connect, listen,
socket-pair, credential, `sendmsg`, and `recvmsg` implementations are deleted.
Parent-death signaling moves to the Linux/Android process-lifecycle layer because it is
not a transport responsibility.

### Public control protocol

The public control payload remains deterministic JSON, but each JSON document occupies
one `SOCK_SEQPACKET` packet. Every request contains:

- protocol version;
- request ID;
- request kind;
- declared capability-descriptor count and role;
- request payload.

Every response contains:

- protocol version;
- matching request ID;
- `completed`, `accepted`, or `rejected` disposition;
- typed error code and optional human-readable detail;
- response payload.

`accepted` means that the authoritative owner accepted asynchronous work.
`completed` means the requested state transition or query finished before the response.
The CLI does not equate transport success with operation completion.

The protocol declares a maximum packet size below the transport maximum. Unknown protocol
versions, request kinds, fields that change semantics, invalid enum values, and excess
descriptors produce typed rejection responses. The service closes the connection after a
malformed or unauthorized request.

Control DTOs are wire contracts, not serialized render-server or shell object layouts.
The broker maps owner values into `ControlOutput`, configuration status, and other
versioned DTOs. `BindAction` remains the shared configured/action intent vocabulary from
`NucleusConfig`; the control protocol does not define a second action enum.

Configuration export responses carry canonical UTF-8 source produced by the configuration
service. The CLI prints that source and does not link `NucleusConfigIO` or run a second
exporter.

### Control endpoint and routing

The session supervisor launches `NucleusControlService` and passes it authenticated
internal channels to the configuration service and render server. The control service
routes:

- configuration query, reload, validate, replace, and export to
  `NucleusConfigService`;
- output, focus, active-binding, tiling, workspace, and window actions to
  `NucleusRenderServer`;
- shell-owned actions to the render server, which performs the single action-owner
  classification and forwards accepted shell actions over the private shell policy
  channel.

The broker translates public control DTOs into internal owner operations. The
configuration service and render server do not import or decode the public control
protocol. The broker never caches an authoritative answer.

Configuration queries report the config-service epoch and configured generation plus the
applied generation of each runtime owner. Active-binding queries report the render
server's applied generation. This distinguishes desired configuration from policy
actually in force.

### Control socket and authorization

The control endpoint is:

```text
$XDG_RUNTIME_DIR/nucleus/<session-id>/control.sock
```

The supervisor exports its exact path as `NUCLEUS_CONTROL_SOCKET`. Display names are not
used as authority or as the sole session identity.

The control service:

- verifies that the runtime directory belongs to the session UID;
- creates the session directory with mode `0700` and the socket with mode `0600`;
- uses `lstat` before removing a stale entry and refuses to replace a non-socket or an
  entry owned by another UID;
- validates every accepted peer with `SO_PEERCRED`;
- applies connection, packet, descriptor, and request-rate limits;
- applies the supervisor-provided peer authorization policy before routing;
- keeps listener, accepted, and received descriptors close-on-exec.

The session UID receives read, ordinary-action, and user-configuration authority because
it already owns the session and configuration file. Future session-administration or
security-sensitive operations require a one-shot capability FD transferred in the
control packet. Sharing a UID alone never grants those elevated operations.

## Configuration contract

`NucleusConfiguration` is the complete resolved session model. The source file remains a
human-authored partial overlay over built-in defaults. Parsing, layering, migration, and
source diagnostics occur once in `NucleusConfigService`, never independently in each
consumer.

The configuration model produces explicit owner projections:

- `RenderServerConfiguration` contains libinput settings, XKB rules, key repeat, global
  binding chords, window-management actions, output and workspace policy, cursor
  mechanism, idle enforcement, and render policy.
- `ShellConfiguration` contains application-launch actions, displayed binding
  descriptions, notifications, overlays, bars, launcher, lock-screen, theme, and
  cursor-preference policy.

Every configuration field has exactly one runtime owner. A setting that appears in more
than one projection has one authoritative owner and read-only descriptive copies
elsewhere. The shell's displayed binding list is a copy of server-owned binding policy;
the shell never performs a second raw-key match.

The server is the sole global binding resolver. It executes server-owned actions such as
close, tile, workspace activation, and composition changes. It sends an accepted typed
action over the supervisor-provisioned shell policy channel for launcher, menu,
notification, and other shell-owned behavior.

### Configuration modules

`NucleusConfig` contains:

- `NucleusConfiguration` and partial overlay value types;
- input, binding, and future resolved policy values;
- built-in defaults;
- source-independent semantic issues;
- the authoritative server-versus-shell owner classification for every `BindAction`;
- `RenderServerConfiguration` and `ShellConfiguration` projection functions;
- the stable binary codec for resolved snapshots.

`NucleusConfigIO` contains:

- `NucleusConfigSyntax`;
- JSON decoding and unknown-key auditing;
- schema migration;
- source-located diagnostics;
- XDG path resolution;
- load and export;
- atomic persistence.

`ConfigDiagnostic` splits into a source-independent `ConfigurationIssue` in
`NucleusConfig` and a source-located `ConfigDiagnostic` in `NucleusConfigIO`. Runtime
consumers can reject an invalid resolved snapshot without loading source parsing or file
I/O.

`NucleusConfigSyntax` remains a narrow compilation target but is not an installed public
product. It is absorbed only by `libNucleusConfigIO.so`.

### Snapshot publication

Every published projection carries:

- a service epoch generated at config-service startup;
- a monotonically increasing generation within that epoch;
- the configuration schema version;
- the projection kind;
- the encoded resolved projection;
- diagnostics relevant to that publication.

Consumers reject an older generation from the same epoch. A new epoch invalidates the
old generation space and causes the current projection to be adopted. Repeated delivery
of the same epoch and generation is idempotent.

The config service publishes projections independently. A stopped shell never prevents
the server from adopting input or window-policy changes. A reconnecting consumer receives
the current projection before it becomes ready.

A malformed file costs only the attempted update. The service retains the last valid
snapshot and generation and publishes diagnostics. Removing the file resolves built-in
defaults and publishes them as a new generation.

### Persistence and control

The config service is the only process that writes the active file. It writes a temporary
file in the destination directory, flushes file contents, atomically renames it, and
flushes the directory before publishing the resulting snapshot.

The control CLI submits validate, replace, and export requests to the control service,
which routes them to the config service. It does not modify the active file directly. An
offline validation command may load `libNucleusConfigIO.so`, but it has no authority to
publish or persist a live session configuration.

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

### Atomic surface-tree stream

Nucleus uses the standard Wayland surface model as its cross-process composition
contract. A root `wl_surface` owns window identity and its ordinary role. Content that
benefits from independent backing, placement, or scanout becomes a child `wl_surface`
with a `wl_subsurface` role. Nucleus does not mirror its application-local
`NucleusLayers` graph into the compositor.

Every surface accumulates pending buffer, damage, input region, opaque region, buffer
scale, buffer transform, viewport, alpha modifier, and explicit synchronization state.
`wl_surface.commit` captures those fields into one immutable latch. A synchronized
subsurface caches its latch; committing the root or nearest desynchronized ancestor
applies the complete synchronized subtree. Position and stacking requests follow the
same parent-commit boundary.

The standard protocol set is:

- `wl_compositor`, `wl_subcompositor`, and `wl_surface` for identity, hierarchy,
  ordering, state, and atomic subtree commits;
- `zwp_linux_dmabuf_v1` and `wp_linux_drm_syncobj_manager_v1` for backing stores and
  explicit acquire/release synchronization;
- `wp_viewporter`, `wp_fractional_scale_manager_v1`, `wl_surface.set_buffer_scale`,
  and `wl_surface.set_buffer_transform` for projection;
- `wp_alpha_modifier_v1` for compositor-side surface opacity;
- `wp_presentation` and frame callbacks for acknowledgement, pacing, and retirement.

Clip paths, corner geometry, shadows inside application content, and application
animations remain in the client renderer. The compositor owns only desktop-global and
window-manager animations. Destroying a client destroys its Wayland resource graph and
retires its imported buffers without a second identity or cleanup protocol.

There is no Nucleus composition protocol and no generic IPC side channel for application
scene state. Ordinary Wayland clients use the same surface machinery as Nucleus clients.

## Presenter model

`PresentationBackend` in the portable renderer is the shared source-level abstraction.
It does not imply shared runtime state.

- `WaylandBackingStorePresenter` lives in `libNucleusWindowClient.so`. It owns
  client-local exportable Vulkan images, Linux DMA-BUF and DRM syncobj timeline FDs,
  `wl_buffer` creation, backing-store reuse, submission synchronization, and
  standard `wl_surface` buffer attachment. It does not create a Vulkan Wayland surface or WSI
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
- surface, seat, device, buffer, and presentation IDs;
- presentation timestamps, damage regions, synchronization descriptors, and capability
  sets.

Move host-facing protocols into `NucleusAppHostProtocols`:

- `ApplicationEventSink`;
- `WindowLifecycleSink`;
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

Split the Linux platform package by dependency level:

- `platform-linux/Package.swift` vends dynamic `NucleusLinux` containing primitives,
  reactor, D-Bus, file watching, and theme asset I/O. It has no dependency on
  `libNucleus.so`.
- `platform-linux/desktop/Package.swift` vends dynamic `NucleusLinuxDesktop` containing
  environment and accessibility adapters and depending on the base Linux and Nucleus
  products.
- `platform-linux/session/Package.swift` owns the session supervisor executable and
  depends on the base Linux and session-protocol products through cross-package dynamic
  edges.

Move the existing targets and callers directly. Do not leave forwarding products in the
old package graph.

Split configuration by runtime privilege:

- `config/model/Package.swift` vends dynamic `NucleusConfig`. Move
  `NucleusConfiguration`, input and binding values, defaults, semantic validation,
  projection functions, and the resolved snapshot codec into it.
- `config/Package.swift` vends dynamic `NucleusConfigIO` and depends on the model package.
  Move syntax preparation, JSON loading, source diagnostics, migrations, file discovery,
  atomic persistence, and export into it.
- `NucleusConfigSyntax` remains an internal target in the IO product and is no longer a
  separately installed product.

Move `ConfigColliderRecipe` alongside `NucleusConfigIO`; it is build tooling and is not
part of the installed runtime.

Split IPC by transport and control role:

- `ipc/transport/Package.swift` vends dynamic `NucleusIPCTransport` and owns
  `NucleusIPCTransportC`.
- `ipc/control-protocol/Package.swift` vends dynamic `NucleusControlProtocol`. Move
  `ControlRequest`, `ControlResponse`, control DTOs, versioned envelopes, typed control
  errors, and deterministic JSON payload coding into it.
- `ipc/control-client/Package.swift` vends dynamic `NucleusControlClient`. Move control
  endpoint discovery, connection, one-shot exchange, and response correlation into it.
- `ipc/Package.swift` keeps `IPCColliderRecipe` and the `nucleus` executable, which
  depends on the control-client product through a cross-package dynamic edge.

Delete the generic `NucleusIPC` module name after moving all callers to the role-specific
products. Do not add a compatibility wrapper.

Move the POSIX transport implementation from `NucleusAndroidIPCC` into
`NucleusIPCTransportC`. Migrate `NucleusAndroidIPC`, `NucleusSessionProtocol`, and the
temporary compositor-hosted control server to the shared packet transport. Delete the
Android transport duplicate and move parent-death signaling into the platform
process-lifecycle module.

Add dynamic runtime products to `swift-wayland`, `swift-vulkan`, and `swift-tracy` for the
compiled target closures named in the artifact graph. Update higher packages to consume
those products. Header-only system-library targets remain import-only and do not create
empty ELF artifacts.

Move the shared Wayland protocol runtime to its own nested package before creating its
dynamic product. Convert `NucleusSessionProtocol` into a dynamic product consumed by the
installed session endpoints and make it depend on `NucleusIPCTransport`. These package
boundaries prevent SwiftPM from absorbing a lower runtime target into multiple higher
dynamic products.

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

Create equivalent disjoint dynamic products for `NucleusWindowClient`,
`NucleusRenderServer`, `NucleusConfigService`, `NucleusControlService`, and
`NucleusShellKit` as their phases land. A higher library depends on a lower dynamic
product; it does not absorb a second copy of the lower product's target objects.

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
- a headless session, configuration, or control process resolves `libNucleus.so`, Skia,
  or a desktop-UI library;
- an installed process contains a private copy of the Unix packet transport;
- an installed dependency cannot be resolved from the staged rpath.

Collider emits a linker map for every installed ELF object and records a normalized
ownership manifest keyed by Swift target object, C/C++ object, and static-archive member.
The validation intersects those manifests to detect duplicate ownership. Dynamic
dependencies appear only as `NEEDED` edges and never as copied members in the consuming
artifact's ownership set.

Phase 2 lands when the existing compositor and shell use `libNucleus.so`, configuration
model and IO tests pass through their new package boundary, headless Linux consumers use
only the base Linux artifact, Linux session/control and Android broker fixtures use the
shared packet transport, both render successfully in automated fixtures, and their ELF
dependency and symbol tables satisfy the checks above.

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
- layer-shell, session-lock, foreign-toplevel, screencopy, workspace, and data-control
  roles negotiated from the standard registry;
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
  explicitly transitional inputs removed in phase 8.

The Swift targets remain narrow compilation units inside the product. The product exports
one server entry point:

```swift
@_spi(NucleusRenderServer)
public func runRenderServer(
    configuration: RenderServerLaunchConfiguration
) async throws
```

`NucleusCompositor` constructs launch configuration from the session supervisor,
configuration-service channel, signal source, diagnostics, and environment, then calls
this entry point. It contains no renderer, Wayland, DRM, input, window-manager, or shell
policy. `RenderServerLaunchConfiguration` is process bring-up state;
`NucleusConfig.RenderServerConfiguration` is the resolved live policy projection.

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

## Phase 6 — Establish one configuration authority

Create `config/config-service-core/Package.swift` with the dynamic
`NucleusConfigService` product. Create `config/config-service/Package.swift` with only
the `NucleusConfigService` executable entry point and a product dependency on the service
core. The service library depends on `NucleusConfigIO`, base `NucleusLinux`, and
`NucleusSessionProtocol`. It does not depend on `Nucleus`, `NucleusLinuxDesktop`,
`NucleusWindowClient`, `NucleusRenderServer`, or `NucleusShellKit`.

Extend `NucleusSessionProtocol` with:

- config-service readiness and epoch identity;
- role-authenticated subscriber registration;
- current-snapshot request and response;
- projection publication;
- generation acknowledgement and rejection;
- diagnostic publication;
- validate, replace, and export control requests.

The session supervisor creates connected capability channels for the configuration
service, compositor, and shell over `NucleusIPCTransport`. Subscriber capabilities permit
only projection reads and acknowledgements. Shell-settings capabilities enumerate the
mutation operations they permit. The service rejects operations not granted by the
presented channel; sharing a UID does not grant write authority. Phase 7 adds the
control-service mutation channel without changing the configuration protocol.

The supervisor starts the configuration service first and waits for an initial resolved
snapshot before starting the compositor. The compositor receives its channel at launch
and adopts `RenderServerConfiguration` before opening the seat. The shell receives its
channel at launch and adopts `ShellConfiguration` before publishing shell surfaces.

Move `ConfigReloadCoordinator` out of `NucleusCompositorRuntime`. Rebuild its behavior as
the config service's state machine:

1. locate and load the active file;
2. prepare syntax while preserving source offsets;
3. decode the partial overlay;
4. migrate the declared schema version;
5. resolve defaults and layers;
6. validate the complete model;
7. derive owner projections;
8. assign the next generation;
9. publish each projection independently;
10. retain the snapshot and diagnostics for reconnecting subscribers.

Watch the configuration directory rather than one file inode so atomic replacement,
creation after startup, deletion, and directory recreation are observable. Rearm watches
after move and invalidation events. Treat only `ENOENT` as an absent configuration;
permission, decoding, and other I/O failures produce diagnostics and preserve the last
valid snapshot.

Delete the compositor coordinator and every direct `ConfigFile` or `ConfigLoader` use
from compositor and shell targets. Remove `NucleusConfigIO` from their package
dependencies. They depend only on `NucleusConfig`, normally through the dynamic session
protocol edge.

Split the current compositor `KeybindService`:

- `GlobalBindingResolver` moves under `NucleusRenderServer`, owns chord capture and
  key-up balancing, receives the server projection, and remains the only raw global-key
  matcher.
- the existing action executor remains a transitional in-process sink until phase 8.
  Server-owned actions execute directly; shell-owned actions already cross a typed
  `ShellActionSink` seam.

Keep `InputDeviceSettings` in `NucleusRenderServer`. It translates the resolved input
projection into libinput and XKB operations. A new projection replaces the active
settings atomically, reapplies settings to connected devices, and becomes the initial
settings for devices added later.

The shell stores its current projection and generation even before phase 8 moves the
remaining services out of the compositor. This proves startup, reconnect, and update
delivery without adding an interim compositor-to-shell configuration path.

Implement persistence only in the service. A replace request validates the proposed
source before touching the active file, writes a same-directory temporary file, flushes
it, renames it over the destination, flushes the directory, and publishes exactly one
new generation. File-watcher events caused by the service's own rename coalesce with that
publication and do not produce a duplicate generation.

Phase 6 lands when:

- `NucleusConfigService` is a small composition root over
  `libNucleusConfigService.so`;
- only the config service opens, watches, or writes the active configuration file;
- the compositor and shell load `libNucleusConfig.so` but not
  `libNucleusConfigIO.so`;
- the config service loads no UI, Skia, Wayland, DRM, render-server, window-client, or
  shell library;
- invalid startup input resolves to defaults with diagnostics;
- invalid reloads retain the last valid epoch and generation;
- file removal publishes defaults as a new generation;
- service-originated atomic writes publish one generation;
- reconnecting consumers receive the current projection before readiness;
- shell absence does not block server configuration updates;
- a service restart creates a new epoch and stale messages from the previous epoch are
  rejected;
- input changes affect connected and subsequently added devices;
- global binding resolution has one runtime owner;
- every built-in and decoded binding action resolves to exactly one execution owner;
- configuration service, session distribution, compositor application, shell
  subscription, and control-request tests pass through Collider.

## Phase 7 — Establish the session control service

Create `ipc/control-service-core/Package.swift` with the dynamic
`NucleusControlService` product. Create `ipc/control-service/Package.swift` with only
the `NucleusControlService` executable entry point and a product dependency on the
service core.

The service core depends on `NucleusIPCTransport`, `NucleusControlProtocol`, base
`NucleusLinux`, and `NucleusSessionProtocol`. It does not depend on `Nucleus`,
`NucleusLinuxDesktop`, `NucleusWindowClient`, `NucleusRenderServer`,
`NucleusConfigIO`, or `NucleusShellKit`.

Extend the internal session protocol with owner-facing control operations:

- render-server version and readiness;
- output and active-binding snapshots;
- focused-window, tiling, workspace, and typed action requests;
- accepted, completed, unavailable, and rejected results;
- owner epoch and applied-configuration generation.

Reuse the phase 6 configuration-control messages for configuration query, reload,
validation, replacement, and export. These internal messages are binary session
protocol values over `NucleusIPCTransport`; they are not public JSON control packets.

The session supervisor:

1. creates the control service's private configuration and render-server channels;
2. assigns the public peer authorization policy and the broker's internal owner-channel
   capabilities;
3. starts the control service after the configuration service has published its initial
   snapshot;
4. passes the stable public socket directory and session identity;
5. attaches each restarted configuration service or render server to the existing
   control service;
6. stops the control service during session teardown after public access is revoked.

Move the public socket listener, peer handling, payload decoding, request limits, and
response encoding out of `NucleusCompositorRuntime` and into
`libNucleusControlService.so`. Delete `ControlServer`,
`CompositorRuntime+Control`, their direct reactor integration, and the compositor's
dependency on the public control protocol.

The control service routes without owning state:

- `.version` reports control-protocol version and availability/version information
  obtained from current owners;
- `.configuration`, `.reloadConfiguration`, validate, replace, and export requests go to
  the configuration service;
- `.outputs`, `.binds`, and focus-dependent actions go to the render server;
- shell-owned actions still enter through the render server and its single
  `BindAction` owner classification.

Map owner-unavailable, stale-generation, unauthorized, invalid-request, and internal
transport failures to stable `ControlErrorCode` values. Do not expose raw errno values,
Swift error descriptions, or internal type names as the protocol contract.

Replace newline stream framing with one deterministic JSON envelope per packet. The
listener drains nonblocking `SOCK_SEQPACKET` connections through `NucleusLinuxReactor`;
no accepted peer can block the service reactor or any compositor actor. Reject truncated,
oversized, multi-message, version-incompatible, and unexpectedly descriptor-bearing
control packets before dispatch. A request kind that requires elevation accepts exactly
the declared one-shot capability descriptor and consumes it during authorization.

Replace `NUCLEUS_SOCKET` with `NUCLEUS_CONTROL_SOCKET`. The supervisor creates
`$XDG_RUNTIME_DIR/nucleus/<session-id>` with mode `0700`. The service safely replaces
only a same-owner socket entry, binds `control.sock` with mode `0600`, and verifies
`SO_PEERCRED` before decoding a request.

Move the `nucleus` CLI onto `libNucleusControlClient.so`. The executable contains argument
parsing and presentation only. It sends one versioned request, validates the response
version and request ID, treats `accepted` separately from `completed`, renders typed
errors, and exits. Replace its direct `ConfigExport` use with the configuration service's
canonical export response.

Phase 7 lands when:

- `NucleusControlService` is a small composition root over
  `libNucleusControlService.so`;
- the compositor has no public listener, socket path, control JSON codec, or control-client
  dependency;
- configuration and render-server processes do not import the public control protocol;
- the control service owns no authoritative configuration, output, focus, binding, or
  shell state;
- the public socket persists across configuration-service, compositor, and shell restart
  and returns a typed owner-unavailable response while an owner is absent;
- peer policy and elevated capability FDs enforce distinct request sets;
- peer credentials are checked before request decoding and routing;
- malformed, oversized, truncated, unexpectedly descriptor-bearing, and unauthorized
  packets are rejected without blocking or terminating the service;
- configuration queries report configured and per-owner applied generations;
- active-binding queries report the render server's applied generation;
- the CLI links the dynamic control client and contains no copied protocol or transport
  objects;
- control protocol, client, service, routing, restart, authorization, and CLI fixtures pass
  through Collider.

## Phase 8 — Move all desktop shell UI and policy out of the server

Create `shell/shell-kit/Package.swift` with the dynamic `NucleusShellKit` product. Keep
the `NucleusShell` executable target in `shell/Package.swift` and make it depend on the
new package product. The package split forces a real `NEEDED` edge; a dynamic library and
its executable cannot remain target-dependent siblings in one SwiftPM package.

Move shell-owned services into the shell-kit package:

- `BezelService`;
- `DesktopApplicationIndex`;
- `IdlePolicy` preferences and timeout configuration;
- `ShellActionDispatcher`, replacing the shell-owned half of `KeybindService`;
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
- focus and shortcut arbitration through `GlobalBindingResolver`;
- the idle clock and session-lock enforcement;
- `XCursor` loading, cursor image validation, cursor-plane state, and cursor rendering;
- window shadows and global composition effects.

The shell sends transient policy actions through its supervisor-provisioned typed IPC
channel and persists configuration changes through the configuration service. The server
emits accepted global shortcuts through that channel. Idle state uses the standard
`ext_idle_notifier_v1` global: the shell submits its configured timeout through the
standard request, while the server remains the authoritative input clock and inhibitor
mechanism. Accepted shell actions carry the typed action and active configuration
generation; the shell does not repeat chord matching. Neither side imports the other's
implementation module.

Establish the ordinary session connection and private policy channel before moving the
first shell surface. The supervisor selects `WAYLAND_DISPLAY` before launching the render
server, and the shell connects to the normal listener through `NucleusWindowClient`.
For every shell launch, the supervisor creates a `NucleusSessionProtocol` shell-policy
channel, transfers the server endpoint to the compositor, and inherits the client endpoint
into the shell. The compositor records only the policy endpoint. It never records,
authenticates, or authorizes the shell's `wl_client`.

Advertise standard desktop globals through the ordinary registry. Enforce session-lock
exclusivity and other semantic constraints when requests execute. Keep data-control and
capture consistent with the current same-user session trust model. Introduce standard
Wayland security contexts and portal mediation when application sandboxing lands; do not
invent a Nucleus authentication protocol and do not use shell identity as a substitute
for system security policy. Restrict only component-specific protocols whose specification
requires an exact client, including `xwayland_shell_v1`.

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

Phase 8 lands when:

- the compositor links neither `libNucleusShellKit.so` nor a shell product module;
- no shell view is created in the compositor process;
- shell restart does not restart the compositor or destroy ordinary application surfaces;
- shell disconnect removes all of its Wayland resources through normal client teardown
  and closes its policy generation;
- a shell configuration update changes shell-owned behavior without rebuilding server
  input state;
- accepted shell actions preserve the server's configuration generation and are never
  rematched from raw keys in the shell;
- lock, unlock, notification, launcher, global-shortcut, cursor-theme, and idle flows pass
  deterministic integration tests;
- shell service and product tests pass through Collider.

## Phase 9 — Finish standard Wayland atomic surface trees

Keep `NucleusLayers`, view identity, application layout, paint recordings, and
application animation timelines inside the client process. Do not generate a Nucleus
composition protocol and do not add an application scene channel to
`NucleusSessionProtocol` or `NucleusIPCTransport`.

Complete the standard surface path in this fixed order:

1. Make `wl_surface.commit` capture all core and adjacent pending state into one immutable
   latch. A synchronized subsurface caches that latch, and the parent commit applies every
   cached descendant together with pending position and stacking changes.
2. Bind `wl_subcompositor` in `libNucleusWindowClient.so` and expose typed synchronized
   subsurface construction, positioning, ordering, commit, and teardown through
   `NucleusDesktopHost`.
3. Apply damage, input and opaque regions, viewport, fractional scale, buffer scale,
   buffer transform, and `wp_alpha_modifier_v1` state through the same surface commit.
   Alpha modifies the client backing layer, while window-manager opacity remains on the
   server-owned window root so the two values compose.
4. Keep DMA-BUF import, DRM syncobj acquire/release points, frame callbacks,
   `wp_presentation` feedback, buffer-generation replacement, and renderer/KMS retirement
   correlated with the exact committed surface state.
5. Keep compositor animation authority limited to window placement, workspaces,
   minimize/close transitions, focus effects, and other desktop-global policy.
   Application-content animation remains client-driven and publishes new buffers.

Keep the portable host contracts free of composition-transaction placeholders. The
standard Wayland resource graph is the only cross-process
application-composition contract.

Phase 9 lands when:

- synchronized child commits, position changes, and stacking changes remain invisible
  until the parent commit and then appear as one subtree update;
- invalid roles, parent cycles, sibling references, viewport values, buffer scales,
  buffer transforms, and explicit-sync combinations fail without partial scene mutation;
- alpha, damage, input regions, opaque regions, scale, transform, and viewport state are
  latched with the matching buffer generation;
- client death reclaims all surfaces and buffers without disturbing another client;
- application animations continue locally while server-owned window transitions continue
  when the client main thread is blocked;
- ordinary non-Nucleus Wayland clients remain fully functional;
- standard surface-tree conformance, lifecycle, and hostile-wire fixtures pass through
  Collider.

## Phase 10 — Collapse public imports without collapsing ownership

Finish the two umbrella modules after the runtime boundaries are stable.

`Nucleus` re-exports:

- `NucleusDiagnostics`;
- `NucleusUI`;
- `NucleusApp`;
- the developer-facing text, render-description, and resource APIs already owned by
  `NucleusUI` and `NucleusApp`.

It does not re-export `NucleusTypes`, `NucleusAppHostProtocols`, `NucleusLayers`,
`NucleusAppHostBundle`, `NucleusRenderHost`, `NucleusRenderModel`, or
`NucleusUIEmbedder`. Those modules remain directly importable by framework integrators
but do not inject their lower-level `Rect`, `Color`, `Transaction`, `LayerRole`, and
`ActionPolicy` names into ordinary application source. It also does not re-export C++
bridge modules, renderer internals, test support, Android host internals, Linux modules,
or server SPI.

`NucleusDesktop` re-exports:

- `Nucleus`;
- public desktop window, input, pasteboard, output, and presentation APIs;
- the Linux desktop application host.

It does not re-export raw Wayland modules, Linux implementation modules, shell services,
render-server modules, configuration modules, configuration service APIs, IPC transport,
control protocol, or control service APIs.

Remove the old flat public library products after all callers use the umbrellas or an
explicit internal product. Delete replaced imports and compatibility wrappers in the same
phase.

Phase 10 lands when:

- a normal desktop application imports only `NucleusDesktop`;
- a portable library imports only `Nucleus`;
- server and shell implementation packages use explicit narrow modules;
- Android builds without resolving `NucleusDesktop`;
- API documentation exposes no server SPI, raw Wayland pointer, Skia C++ type, or Vulkan
  handle.

## Phase 11 — Install, relocate, and validate the runtime

Collider stages:

```text
bin/
    NucleusCompositor
    NucleusShell
    nucleus

lib/
    libNucleusFoundation.so
    libNucleus.so
    libNucleusLinux.so
    libNucleusLinuxDesktop.so
    libNucleusConfig.so
    libNucleusConfigIO.so
    libNucleusConfigService.so
    libNucleusIPCTransport.so
    libNucleusControlProtocol.so
    libNucleusControlClient.so
    libNucleusControlService.so
    libNucleusWindowClient.so
    libNucleusRenderServer.so
    libNucleusShellKit.so
    libSwiftWaylandProtocolRuntime.so
    libSwiftVulkan.so
    libSwiftTracy.so
    libNucleusSessionProtocol.so

libexec/
    NucleusConfigService
    NucleusControlService
    NucleusShellPamHelper
    NucleusSessionSupervisor
```

Executables in `bin/` and `libexec/` use `$ORIGIN/../lib`. Shared libraries use
`$ORIGIN` for sibling dependencies. No installed binary depends on Collider's scratch
directory, the source checkout, `NUCLEUS_NATIVE_SDK_ROOT`, or an absolute development
path.

The `lib/` directory also contains the transitive Swift, Foundation, Dispatch, libc++,
and unwind runtime closure selected by the repository toolchain. Collider discovers that
closure from the staged ELF graph; it does not rely on a compatible Swift installation
being present on the target host.

Collider's install validation checks:

- every `NEEDED` entry resolves inside the staged tree or to an approved host system
  library;
- SONAMEs and rpaths match the staged layout;
- `NucleusShell` does not load the render-server library or server-only native libraries;
- `NucleusCompositor` does not load the window-client or shell library;
- `NucleusCompositor` does not load the public control protocol or own a public socket;
- compositor and shell load `libNucleusConfig.so` without loading
  `libNucleusConfigIO.so` or `libNucleusConfigService.so`;
- `NucleusConfigService` loads the configuration model, configuration IO, base Linux, and
  session-protocol libraries without loading Nucleus UI/graphics, Linux desktop,
  Wayland, DRM, window-client, render-server, shell, or public control libraries;
- `NucleusControlService` loads IPC transport, control protocol, session protocol, and
  base Linux without loading Nucleus UI/graphics, configuration IO, Linux desktop,
  Wayland, DRM, window-client, render-server, or shell libraries;
- `nucleus` loads the dynamic control client and protocol without containing copied
  transport or protocol target objects;
- Linux session/config/control and Android broker artifacts use
  `libNucleusIPCTransport.so` for Unix packet transport and contain no duplicate
  sendmsg/recvmsg/credential implementation;
- helpers load none of the UI, graphics, client, server, or shell libraries;
- a helper that needs diagnostics loads `libNucleusFoundation.so` without pulling in
  `libNucleus.so`;
- Skia archive symbols occur only in `libNucleus.so` and are absent from its dynamic
  exports;
- no first-party target implementation appears in two installed objects;
- stripping preserves the required Swift runtime metadata and public entry points;
- the complete staged tree relocates and passes headless client/server,
  configuration-service, and control-service smoke fixtures.

The installed artifacts are rebuilt and upgraded as one unit. Nucleus does not enable
library evolution and does not promise independent ABI compatibility between these
private shared objects.

## Final state

The work is complete when all of the following are simultaneously true:

- `NucleusCompositor`, `NucleusShell`, `NucleusConfigService`, and
  `NucleusControlService` are small composition roots.
- Applications share one installed Nucleus implementation but retain isolated mutable
  graphics state.
- The compositor is the only owner of global scene state, physical input, DRM/KMS, and
  scanout.
- The shell is fully out of process and owns all desktop UI.
- Client and server use one generated protocol vocabulary and do not duplicate runtime
  implementations.
- The client library has no server or hardware dependency.
- The server library has no shell UI or shell-service dependency.
- The configuration service is the sole authority for the active configuration file and
  publishes resolved owner projections by epoch and generation.
- The compositor and shell never parse or watch the active configuration file.
- The control service is the sole owner of the public control socket and routes every
  request to its authoritative runtime owner.
- Session, control, configuration, and Android protocols share one packet transport
  without merging their wire vocabularies.
- The compositor never performs public control-client I/O on its actor or event loop.
- Global binding resolution has one server-side runtime owner.
- Cross-process rendering uses standard Wayland surface commits, shared buffers, and
  explicit synchronization.
- The staged dependency graph and symbol tables mechanically enforce the ownership rules.
- Linux desktop, Android, IPC, configuration, compositor, shell, helper, integration, and
  sanitizer gates all pass through Collider.
