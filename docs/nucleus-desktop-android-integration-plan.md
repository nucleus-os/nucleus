# Nucleus Desktop OS + Android Integration Plan

## Invariant

Nucleus is an image-based desktop Linux operating system whose compositor is the
only display server. Linux clients, XWayland clients, and Android tasks all enter the
same Wayland scene as ordinary toplevel surface trees and are governed by one window
manager, one seat, and one shell.

Android 17 runs as a project-owned, x86-64 AOSP application runtime inside an
unprivileged LXC container. The runtime remains an application-compatibility layer;
it does not own the host session, kernel, display, input devices, files, audio devices,
or GPU. Nucleus tracks each stable AOSP release and its security branch as a maintained
OS component.

The container never loads a host GPU vendor library and never receives a DRM device
node. Android GLES and Vulkan commands use one cross-vendor command path:

```text
Android GLES application -> system ANGLE -> Nucleus proxy Vulkan ICD
Android Vulkan application ----------------------^          |
                                                             v
                              shared-memory gfxstream transport
                                                             |
                                                             v
             host Nucleus Android GPU broker -> native host Vulkan driver
                                                             |
                                      dma-buf + syncobj timeline
                                                             |
                                                             v
          Android Composer3 Wayland client -> Nucleus Wayland compositor
```

The host broker opens the compositor-selected GPU and loads its native Vulkan driver:
Mesa on AMD and Intel, and the proprietary NVIDIA driver on RTX. It allocates
DRM-format-modifier dma-bufs from the intersection advertised by Nucleus and supported
by the selected device. Android gralloc handles identify those allocations, brokered
GPU work renders directly into them, and the Android Composer3 client commits the same
allocations to Nucleus with `wp_linux_drm_syncobj_manager_v1` acquire and release
points.

This is one graphics architecture for every GPU vendor. There is no direct-Mesa guest
path, NVIDIA-only guest path, SwiftShader fallback, VM, or pixel-streaming path.
"Zero-copy" means rendered pixels remain in the same dma-buf allocation from the host
GPU broker through Nucleus presentation; it does not mean Vulkan and GLES commands are
not serialized across the container boundary.

Each Android task is a Wayland `xdg_toplevel` tree, not one synthetic buffer. Android
layers such as the task content, `SurfaceView`, dialog, input method, video, cursor, and
picture-in-picture surfaces remain distinct dma-buf-backed subsurfaces when
SurfaceFlinger assigns them to device composition. Nucleus applies its existing
Wayland transaction, damage, explicit-synchronization, composition, and direct-scanout
rules without an Android-specific render path.

The Android Composer3 implementation is the Wayland client. It receives ordinary
Wayland input from Nucleus and forwards it through a privileged Android input service;
Nucleus does not gain a second input dispatcher. A dedicated Wayland socket and peer
credentials authenticate the runtime connection, while standard xdg-shell app IDs and
titles carry Android package and task identity.

Host runtime lifecycle, portal, and control I/O use Nucleus's io_uring reactor. AOSP's
internal guest loopers remain an Android implementation detail; they do not introduce
an epoll fallback into the Nucleus host architecture.

The installable OS is a signed `bootc` image based on Fedora, with transactional update
and rollback. The supported hardware matrix is qualified explicitly; Linux having a
driver is not itself a product-support claim.

## Positioning

Nucleus must be a compelling desktop without Android. Its compositor, shell, UI
framework, browser, native application model, and system services remain the product
foundation. Android integration extends that desktop with a useful set of mobile
applications; it does not compensate for an incomplete native experience.

Running Android in a Linux container is not the differentiator. Waydroid already does
that and already supports individual app windows on Mesa GPUs. Nucleus differs in the
parts that follow from owning the complete OS:

- Android tasks participate directly in Nucleus's normal Wayland scene and shell
  policy rather than appearing through a separately managed nested desktop.
- The single host GPU broker keeps Android independent of Bionic-compatible vendor
  drivers and therefore supports the same proprietary NVIDIA stack as the rest of the
  Nucleus desktop.
- The project owns the Android product, updates it with AOSP, keeps Android SELinux
  enforcing, and ships it under the same signed update and rollback contract as the
  host OS.
- Files, clipboard, notifications, intents, audio, media, camera, microphone, and
  application lifecycle cross explicit system-service and portal boundaries rather
  than ad hoc shared directories and device mounts.

The initial audience is the prosumer and enthusiast desktop market: users who want a
cohesive Linux system, first-class RTX support, and Android applications integrated
into the same launcher and window manager. Nucleus does not claim universal Android
application compatibility. The initial runtime supports ABI-independent and x86-64
applications; ARM-only native applications, Play-certified applications, and
hardware-attestation-gated applications are outside the product contract.

## Source and ownership boundaries

The monorepo gains an `android-runtime/` owner for the complete runtime integration:

- the AOSP product manifest, product configuration, sepolicy, and forward patches;
- the reproducible Android image build and signed image metadata;
- the Android gralloc/mapper implementation and proxy Vulkan ICD;
- the Android Composer3 Wayland client;
- the Android task, input, clipboard, notification, intent, portal, audio, and media
  services;
- the host Android GPU broker and its gfxstream integration;
- the LXC lifecycle, containment policy, and runtime control daemon;
- runtime protocol definitions and host/guest conformance tests.

Waydroid remains a source reference for container bring-up, Android framework
integration, task-to-layer association, and Wayland multi-window behavior. Nucleus
does not consume an unchanged Waydroid image and does not forward-port Waydroid's
legacy HWC1 implementation. Android 17 uses a project-owned Composer3 AIDL HAL and
stable AIDL services at the seams Nucleus controls.

The compositor retains its existing ownership. `NucleusCompositorWaylandRuntime`
continues to own xdg-shell, subsurfaces, dma-buf, syncobj, input, clipboard, and
presentation protocols. `NucleusCompositorWindowManager` and the shell continue to
own focus, stacking, workspaces, decoration, launcher presentation, and task-switcher
policy. Android integration adds authenticated metadata and lifecycle control around
ordinary Wayland clients; it does not add a parallel scene graph.

The top-level `tools/nucleus` workflow provisions and verifies the Android runtime in
the same staged checkout build as the other first-party packages. AOSP and gfxstream
source remain root-managed third-party inputs; generated images and native build
outputs stay under `android-runtime/`.

## Phase 1 — Cross-vendor graphics contract

Phase 1 proves the load-bearing graphics architecture before the full Android product
is brought up. The host Android GPU broker uses gfxstream's command protocol and a
project-owned allocation/synchronization backend. It opens the render node selected by
Nucleus, creates dma-buf-backed Vulkan images using only compositor-advertised
format/modifier pairs, and exposes opaque buffer IDs to a minimal guest graphics
client.

The broker is the only process that loads vendor graphics userspace. The same binary
and protocol execute on AMD, Intel, and NVIDIA. The NVIDIA implementation uses the
proprietary Vulkan and GBM stack in a normal glibc host process; no NVIDIA library is
loaded by Android/Bionic.

Synchronization is part of the first proof, not a later optimization. The broker owns
DRM syncobj timelines, exports their FDs to the Wayland client, associates every
submitted buffer with ordered acquire and release points, and materializes Android
`sync_file` fences from those points where the Android HAL contract requires them.
The Android-side client never waits for GPU completion on the CPU. Nucleus signals the
release point only after rendering and scanout have stopped reading the allocation.

Components:

- host Vulkan broker and compositor-device selection;
- shared-memory gfxstream transport and guest test ICD;
- dma-buf allocation, modifier negotiation, and buffer identity;
- syncobj timeline ownership and Android `sync_file` conversion;
- Nucleus dma-buf import and release integration exercised by the broker;
- graphics tracing that proves the selected hardware driver and allocation lifecycle.

Acceptance gates:

- the same guest Vulkan test renders through the broker on a qualified AMD GPU, Intel
  GPU, and RTX GPU;
- the exact broker allocation is imported and presented by Nucleus without CPU upload,
  readback, or intermediate image copy;
- acquire and release ordering survives sustained buffer reuse without a CPU fence
  wait, implicit-sync dependency, tearing, stale content, or use-after-release;
- unsupported formats, modifiers, devices, and Vulkan requirements fail startup with a
  precise diagnostic; there is no software renderer fallback;
- compositor device selection, broker Vulkan adapter selection, GBM device selection,
  and dma-buf feedback identify the same physical GPU, including hybrid systems.

Risk surface: critical. This phase retires the producer-side NVIDIA problem, the
cross-process Vulkan transport, and the end-to-end buffer synchronization contract.
No later phase begins on an unproven graphics path.

## Phase 2 — Android 17 runtime and containment

Phase 2 builds the complete x86-64 Android 17 product around the Phase 1 graphics
contract. The product boots a current AOSP framework inside LXC with binderfs,
project-owned HALs, current WebView, and the runtime services required by later phases.

The container is unprivileged and user-namespaced. Android SELinux remains enforcing.
The host exposes no DRM node, input node, arbitrary PipeWire socket, home directory, or
host system bus. Binder devices, mounts, network interfaces, cgroups, capabilities,
seccomp policy, and idmapped storage are created per runtime instance. The only initial
host interfaces are the authenticated runtime-control socket, graphics transport, and
dedicated Wayland socket.

Android gralloc and mapper wrap dma-buf allocations owned by the host broker. The proxy
Vulkan ICD sends Vulkan work over the Phase 1 transport, and system ANGLE implements
OpenGL ES over that ICD. Android never selects a different rendering implementation by
vendor.

The image build is reproducible and produces signed system, vendor, product, and
metadata artifacts. Runtime data remains separate from the immutable image. Updates
replace the image atomically, migrate data through explicit versioned steps, and retain
the previous bootable runtime until the new image passes health checks.

Components:

- `android-runtime/` AOSP manifest, product definition, patches, and sepolicy;
- Android 17 x86-64 system/vendor/product image build;
- LXC manager, binderfs setup, namespaces, cgroups, seccomp, and storage ownership;
- gralloc/mapper, proxy Vulkan ICD, system ANGLE, and broker connection;
- signed runtime image metadata, migration ledger, health check, and rollback;
- crash, audit, logcat, broker, and container diagnostics surfaced to the host.

Acceptance gates:

- Android boots to a stable framework with enforcing SELinux and no host device-node
  access beyond the declared contract;
- a normal application renders GLES and Vulkan content only through the Phase 1 broker;
- package installation, ART, WebView, storage, networking, suspend, resume, shutdown,
  update, failed-update rollback, and data migration pass runtime tests;
- container escape tests verify mounts, devices, host IPC, credentials, ptrace,
  capabilities, networking, and broker protocol validation;
- an AOSP security update rebuild changes only declared inputs and produces a signed,
  auditable image provenance record.

Risk surface: high and ongoing. Owning a current Android product includes framework,
HAL, sepolicy, image, migration, and security-update maintenance; it is not only an LXC
configuration exercise.

## Phase 3 — Composer3 Wayland client and input

Phase 3 turns Android tasks into normal Nucleus Wayland windows. A project-owned
Composer3 AIDL HAL replaces Waydroid's legacy HWC1 path. It connects to the dedicated
Nucleus Wayland socket and implements xdg-shell, subsurfaces, viewporter, fractional
scale, presentation feedback, linux-dmabuf feedback, and
`wp_linux_drm_syncobj_manager_v1`.

An Android task service owns the authoritative mapping from task IDs and package names
to SurfaceFlinger layers. The mapping is transmitted as typed metadata to Composer3;
layer names are not parsed as an API. Composer3 creates one `xdg_toplevel` per task and
preserves the ordered subsurface tree for device-composed child layers. Standard xdg
app IDs use an `android.<package>` namespace. The dedicated socket marks the client as
Android-owned, so an arbitrary Wayland client cannot spoof that provenance.

The xdg configure loop updates the bounds of the corresponding Android freeform task
through the task service. It does not resize or hotplug a single global Android display
for every host-window change. Android remains responsible for application layout,
orientation, configuration changes, dialogs, input methods, picture-in-picture, and
SurfaceView lifecycle inside the configured task bounds.

Composer3 receives keyboard, pointer, touch, tablet, relative-pointer, and focus events
through the normal Wayland seat. A privileged Android input service translates those
events into Android input coordinates and focus state for the synthetic display. No
Android condition is added to Nucleus's libinput or seat dispatch path.

Components:

- Composer3 AIDL HAL and Wayland protocol client;
- typed task/layer metadata service;
- per-task xdg-toplevel and subsurface-tree lifecycle;
- configure-to-freeform-task bounds and scale mapping;
- syncobj acquire/release integration with the Phase 1 broker;
- Wayland-seat to Android-input service;
- runtime provenance, app ID, title, and diagnostic metadata.

Acceptance gates:

- multiple Android tasks open as independent Nucleus toplevels and retain correct
  stacking, damage, opacity, clipping, scale, and presentation feedback;
- resizing, maximizing, fullscreen, output moves, fractional scaling, rotation,
  dialogs, IME, `SurfaceView`, video layers, and picture-in-picture preserve Android
  lifecycle and geometry contracts;
- keyboard, pointer, touch, scroll, tablet, relative pointer, grabs, focus transitions,
  and close requests reach only the correct task;
- every committed dma-buf carries valid acquire and release points and returns a valid
  release fence to SurfaceFlinger without blocking a framework, Wayland, render, or
  compositor thread;
- runtime crash and restart remove stale windows and never leave Nucleus-owned focus,
  grabs, buffers, or syncobj handles behind.

Risk surface: high. Android's task/layer model and Wayland's toplevel/surface model are
not isomorphic; this phase owns the mapping instead of hiding it behind "one buffer per
app."

## Phase 4 — Unified application and window lifecycle

Phase 4 integrates Android application identity and task control into the existing
Nucleus shell. The runtime control daemon publishes a typed application inventory from
Android PackageManager, including package, activity, label, icon, categories, launch
intent, and current task identity. The shell merges that inventory with Linux desktop
entries without introducing a second launcher or task model.

Launch, activate, close, minimize, maximize, fullscreen, move-to-workspace, and restore
requests flow through explicit host/runtime control messages. Nucleus remains the
authority for host window policy; Android remains the authority for activity and task
lifecycle. Stable task tokens correlate control replies, Wayland toplevels, shell
entries, and diagnostics.

Android windows use the same `NucleusCompositorWindowManager` records, workspace rules,
decorations, switcher, launcher, focus policy, and scene construction as any xdg
toplevel. Android provenance adds application actions and runtime health metadata; it
does not fork the window manager or scene graph.

Components:

- Android PackageManager inventory service and icon export;
- host runtime-control daemon and versioned protocol;
- shell application catalog unifying `.desktop` and Android activities;
- stable task-token correlation and lifecycle commands;
- runtime readiness, crash, restart, and per-app failure presentation;
- Android app settings, permissions, uninstall, and force-stop actions.

Acceptance gates:

- launcher search, launch, activation, switcher, taskbar, workspace, close, and restore
  behavior is identical for Android and Linux applications where their lifecycle
  contracts overlap;
- duplicate launches, multiple activities from one package, multiple tasks from one
  activity, transient dialogs, and task recreation retain stable shell identity;
- runtime startup is demand-driven, concurrent launch requests are serialized, and a
  failed runtime produces actionable UI rather than an orphaned launcher entry;
- uninstall and package updates remove or refresh shell metadata atomically.

Risk surface: medium-to-high. The shell work is straightforward only after stable task
identity and lifecycle ownership exist.

## Phase 5 — Application compatibility and distribution

Phase 5 defines and verifies the application contract Nucleus actually ships. The
runtime supports applications without native code and applications containing x86-64
native libraries. PackageManager reports x86-64 as the supported ABI and rejects
ARM-only packages with a clear compatibility diagnostic. Nucleus does not redistribute
Houdini, `libndk_translation`, or another proprietary native bridge, and it does not
claim ARM application compatibility.

The base runtime ships microG and F-Droid. It does not ship Google Mobile Services,
Google Play, or GApps. The product does not enable a hidden user-selectable GApps image
or make uncertified Play access part of the support contract. Apps that depend on
unsupported Google APIs fail a declared compatibility gate rather than receiving an
untracked compatibility patch.

A maintained application corpus covers ABI-independent productivity, messaging,
media, drawing, WebView, GLES, Vulkan, accessibility, storage, background work, and
multi-window applications across supported target SDK levels. Tests assert behavior,
not package-name allowlists or source shape.

Components:

- supported-ABI policy and PackageManager diagnostics;
- microG and F-Droid product integration;
- current WebView and certificate trust configuration;
- application compatibility corpus and automated launch/interaction probes;
- permission, background-work, network, storage, notification, and lifecycle policy;
- user-visible compatibility reporting and per-app diagnostic export.

Acceptance gates:

- every application in the supported corpus installs, launches, renders, receives
  input, backgrounds, resumes, updates, and uninstalls under automated tests;
- x86-64 native libraries load with the advertised ABI while ARM-only packages fail
  installation with an actionable explanation;
- microG and F-Droid are reproducibly built, updated through the signed runtime image,
  and do not require disabling Android signature or SELinux policy globally;
- unsupported Play Integrity, Widevine L1, GMS, ABI, hardware, and feature requirements
  are reported consistently in the launcher and runtime diagnostics.

Risk surface: high in product terms. The supported Android application set is defined
by ABI, service, certification, graphics, media, and hardware contracts, not only by the
Android API level.

## Phase 6 — Desktop integration services

Phase 6 replaces the remaining runtime seam with explicit services and portals.
Clipboard uses Android ClipboardManager on one side and the Wayland data-device model
on the other. File exchange uses document and content-provider portals with URI grants;
the host home directory is never bind-mounted into Android and Android paths are never
presented as host paths. Drag-and-drop uses the same MIME and portal model.

Android notifications become native Nucleus notifications with action, reply, dismiss,
progress, grouping, and application identity preserved. URL, share, and open-with
requests cross a bidirectional intent router whose policy and defaults are owned by the
shell.

Audio uses a dedicated PipeWire client identity and nodes created by the host portal.
Microphone, camera, and screen-capture access require host portal grants and expose only
the granted stream to Android. A host media service maps supported Android codec work to
VA-API or the qualified vendor decode stack and returns dma-buf-backed frames; Android
software codecs remain available for formats required by the Android compatibility
contract, but software GPU rendering does not.

Text input, accessibility, keyboard layout, locale, timezone, network state, battery,
and power state cross typed services with one authority for each datum. Android does
not infer host state by mounting host files or joining host buses.

Components:

- clipboard and drag-and-drop bridge;
- document/content-provider file portal and cross-runtime open-with service;
- notification bridge with actions and inline replies;
- bidirectional URL, share, and intent routing;
- PipeWire audio, microphone, camera, and capture portals;
- hardware media-codec service and dma-buf video frames;
- text-input, accessibility, locale, network, battery, and power-state services;
- per-service authorization, revocation, audit, and failure UI.

Acceptance gates:

- clipboard, drag-and-drop, files, URLs, share targets, notifications, and replies work
  bidirectionally without exposing undeclared host paths or IPC endpoints;
- revoking a file, microphone, camera, capture, or audio grant immediately removes
  Android access and survives runtime restart;
- audio/video synchronization, hardware decode, suspend/resume, device removal, and
  route changes recover without restarting the compositor or losing unrelated apps;
- accessibility focus, text entry, keyboard layout, locale, and timezone remain
  coherent across Linux and Android windows;
- every bridge has protocol-version skew tests, malformed-message tests, and a visible
  degraded state.

Risk surface: high. These services define the system's privacy boundary and much of the
perceived product cohesion.

## Phase 7 — Installable OS and hardware qualification

Phase 7 produces the Nucleus OS image. A Fedora `bootc` base carries the Nucleus
compositor session, shell, browser, portals, Android runtime, GPU broker, firmware,
installer, recovery environment, and signed update policy as one versioned image.
Host and Android runtime artifacts advance together under an explicit compatibility
manifest.

Updates use signed OCI images, transactional deployment, health checks, and rollback.
The boot chain, kernel, initramfs, NVIDIA kernel modules, and recovery image are signed.
NVIDIA kernel and userspace versions are pinned as one tested unit; failure to load the
qualified driver fails the session instead of selecting a software renderer.

Hardware support is a qualification matrix beginning with RTX 4000-class NVIDIA,
current AMD RDNA, and current Intel Xe systems. The matrix records display outputs,
multi-monitor, HDR where supported, VRR, suspend/resume, hotplug, input, audio, Wi-Fi,
Bluetooth, camera, storage, power management, and hybrid-GPU topology. A machine is
supported only after its relevant matrix passes. Mainline kernel support and a
distribution package are prerequisites, not qualification.

Components:

- Fedora `bootc` image definition and signed build provenance;
- installer, disk layout, encryption, recovery, factory reset, and first boot;
- greeter and Nucleus session selection;
- coordinated host/runtime compatibility manifest and update channel;
- Secure Boot keys, signed kernel/initramfs/modules, health checks, and rollback;
- firmware and vendor-driver composition;
- automated hardware qualification harness and published support matrix;
- system diagnostics, crash collection, repair, and support-bundle export.

Acceptance gates:

- a clean machine can install, encrypt, boot, create a user, launch Linux and Android
  applications, update, fail an update health check, roll back, and recover without a
  development checkout;
- Secure Boot verifies the complete boot chain and rejects unsigned kernels, modules,
  runtime images, and OS updates;
- every qualified GPU passes the Phase 1 graphics gates from the installed image;
- suspend/resume, display hotplug, hybrid-GPU selection, audio routing, network changes,
  runtime restart, and OS rollback preserve user data and restore a coherent session;
- the support bundle identifies exact OS, kernel, firmware, Vulkan driver, GPU broker,
  Android image, protocol, and application compatibility versions.

Risk surface: high and broad. Installer, update, recovery, security, firmware, laptop
behavior, and vendor-driver qualification are first-class product engineering rather
than a packaging epilogue.

## Non-goals

- **Android does not become the host operating system.** Nucleus remains Linux-native;
  Android is an application runtime.
- **Phone convergence is deferred.** Telephony, secure element, mobile modem, AVF,
  libhybris, phone boot chains, and per-device Android hardware enablement are absent.
- **There is no unchanged Waydroid image or legacy HWC1 compatibility layer.** Waydroid
  is a reference; Nucleus owns an Android 17 product and a Composer3 AIDL HAL.
- **There is no Android-specific scene or input pipeline in Nucleus.** Android uses the
  existing Wayland surface, window-management, and seat contracts.
- **There is no direct guest GPU access or vendor-specific guest GPU path.** The host
  broker is the only GPU authority for Android on every vendor.
- **There is no software GPU fallback.** Missing Vulkan, external-memory, modifier,
  syncobj, or qualified-driver support fails runtime startup.
- **There is no host epoll compatibility reactor.** New host runtime services use the
  existing io_uring architecture.
- **ARM-only Android applications are unsupported.** The product does not redistribute
  a proprietary native bridge or describe incomplete binary translation as app
  compatibility.
- **Google Play certification and GApps are not shipped.** Play Integrity,
  hardware-backed attestation, Widevine L1, banking applications that require a
  certified device, and other certification-gated software are outside the contract.
- **Arbitrary Linux hardware is not implicitly supported.** Nucleus publishes and owns
  a qualification matrix.
- **The native React Native Android host** in `core/platform-android` remains an
  independent target and is not implemented through this runtime.
- **Touch-first mobile shell work is separate.** This plan integrates Android apps into
  the desktop shell; it does not turn the desktop shell into a phone UI.
