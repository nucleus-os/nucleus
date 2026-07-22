# Nucleus Desktop OS + Android Integration Plan

This plan delivers Nucleus as a general-purpose **desktop Linux operating system**
whose compositor presents Android apps and Linux apps as first-class peers in one
unified scene — GPU-accelerated on NVIDIA/RTX as well as AMD and Intel, and running
a **current Android** rather than a years-old one. It targets desktop and laptop
users who want the openness of a real Linux desktop with the app breadth of
Android: the convergence ChromeOS proves people want, on hardware you own and a
system you control. It supersedes the phone-convergence plan, which carried the
AVF/GPU gate, deep AOSP display surgery, libhybris, and per-device flashing; none
of that applies here.

Nucleus already runs as a bare-metal desktop compositor — real DRM/KMS, native
Vulkan (RTX 4000-class NVIDIA as a first-class target), XWayland, window management,
and the shell. That is the existing foundation. The new work is a **project-owned
Android runtime**, a **hardware-accelerated integration layer**, and **OS
productization**; the compositor's render path changes little, because an Android
app window is just one more dma-buf surface source that the existing explicit-sync
import already knows how to present.

## Invariant

Nucleus is a **desktop Linux OS** whose compositor is the single display server for
both worlds. **Android runs in an LXC container** — a project-owned runtime kept
**current (Android 17 at inception, tracking upstream thereafter)**, a pure
app-compatibility layer, not the system — rendering headless; each Android app
surface is a gralloc dma-buf that Nucleus imports **zero-copy** and manages as an
ordinary toplevel, indistinguishable at the scanout layer from a native Wayland or
XWayland window.

**NVIDIA/RTX is a first-class target, not an afterthought.** Android surfaces are
imported into the RTX Vulkan compositor with the **explicit sync and DRM format
modifiers Nucleus's compositor already implements** — precisely the capability whose
absence forces Waydroid to fall back to software rendering on NVIDIA. Owning the
compositor is what makes GPU-accelerated Android on NVIDIA possible here.

Because Android and Nucleus share one kernel and one GPU, cross-runtime buffers are
zero-copy dma-bufs — there is no VM, no gfxstream, no copy. The container model is
correct here precisely because Android is *only* an app runtime on the desktop:
there is no telephony, secure element, or system service to lose by containerizing
it, so the objection that ruled it out on a phone does not apply. Native Vulkan on
the real Linux driver and the io_uring reactor are hard requirements, already
satisfied on desktop hardware. Distribution is an **installable Linux image** — no
phone hardware, no AOSP fork of the *host*, no bootloader unlock, no per-device
porting.

Owning the Android runtime — keeping it current and making it NVIDIA-accelerated —
is a deliberate commitment. It accepts the maintenance of a forward-ported Android
container as a first-order cost, because that cost buys the two things reusing an
off-the-shelf runtime cannot: a current Android and hardware acceleration on every
desktop GPU vendor. Convergence to a phone remains a future north star built on the
same engine; this plan proves that engine where it is strongest and least contested
first.

## Positioning

Nucleus's value proposition is **a desktop OS worth using in its own right**;
first-class Android integration is a differentiating feature of that OS, not the
thesis. Running Android apps on Linux is not itself the differentiator — upstream
Waydroid already does that on AMD and Intel desktops, with individual app windows.

The advantage over simply running Waydroid on an existing desktop is **structural**:
Waydroid is a component on a compositor it does not own, so Android apps are
second-class, and its capabilities are capped by what a generic desktop offers. Two
of those caps are exactly what a purpose-built, first-party integration removes, and
both are concrete rather than aspirational:

- **NVIDIA/RTX hardware acceleration.** Waydroid recommends *software rendering* on
  NVIDIA. The root cause is historical (NVIDIA's driver is not part of Mesa, which
  Android's passthrough relies on) but the operative modern blocker is that
  **Waydroid's integration does not do explicit sync**, which caps NVIDIA
  acceleration even now that NVIDIA's driver has GBM and dma-buf support. Nucleus's
  compositor **already implements explicit sync and DRM-modifier import**, so it can
  deliver GPU-accelerated Android apps on RTX where Waydroid cannot. This is the
  single most concrete instance of "owning the compositor beats a bolt-on."
- **Current Android.** Waydroid is stuck on Android 13 because forward-porting its
  container and passthrough integration to each new Android is a maintenance
  treadmill. Nucleus **owns the runtime and keeps it current** (Android 17 and
  forward), so app compatibility and security track upstream instead of falling
  years behind.

Beyond those, first-party ownership makes Android apps genuine peers of Linux apps —
one window manager, one launcher, one notification and clipboard model, no seam.
ChromeOS's Android runtime is the existence proof that first-party compositor
integration is *categorically* better than a bolt-on, and that gap is what this plan
captures.

That advantage is **downstream of the OS being cohesive and well-built**. It exists
only because Nucleus is a from-scratch, designed compositor and shell, not a theme
over an existing desktop. The discipline this imposes is explicit: **the Nucleus
desktop must stand on its own without Android apps.** It has to be compelling as a
compositor and shell first; the Android integration then makes it uniquely capable.

The audience is prosumer and enthusiast — Linux desktop users who want first-class,
GPU-accelerated Android apps, and people who want ChromeOS-style convergence on an
open, self-controlled, NVIDIA-capable system. This is a focused niche, not a
mass-market play: the Linux desktop is small and crowded, and the product wins by
being a cohesive, opinionated OS for that audience rather than by breadth of reach.

## Scope and preconditions

This plan scopes the **project-owned Android runtime, the hardware-accelerated
integration layer, and OS productization**. It does not re-scope the standalone
quality of the Nucleus desktop — the compositor, UI framework, and shell that the
Positioning section names as the moat. That quality is a **precondition** of this
product and is the subject of the existing compositor, UI-foundation, and shell
hardening plans; this plan builds on a desktop that is already compelling on its own.
If that desktop is not compelling, nothing here compensates.

The runtime-ownership decision is resolved deliberately: **own the Android runtime,
do not reuse an off-the-shelf image unchanged.** The runtime is an Android 17 image
derived from Waydroid's container and passthrough *mechanisms* — the LXC
integration, gralloc/host-GPU passthrough approach, per-app surface export, and input
injection — forward-ported and maintained by the project. Waydroid is the reference
and starting point for those mechanisms, not a runtime consumed as-is. This accepts
the container-fork maintenance treadmill as a first-order, ongoing cost, because it
is the only way to deliver a current Android and NVIDIA acceleration, neither of
which the stock runtime provides.

NVIDIA acceleration divides cleanly into an owned half and a risk half. The
**compositor side — explicit sync and DRM-modifier dma-buf import — is already
implemented in Nucleus** (`Dmabuf.swift`, `Syncobj.swift`, `DrmSync.swift`,
`RendererClientBuffers.swift`, `NucleusVulkanDmaBuf.swift`) and is what Waydroid
lacks. The **guest side — the Android 17 image producing RTX-importable, accelerated
buffers** — is the real engineering unknown and is tracked as the first-order risk of
Phase 2.

## Architecture

- **The Nucleus desktop** is the existing compositor + shell + render core, running
  natively on desktop Linux. It owns DRM/KMS, the GPU (AMD, Intel, and NVIDIA/RTX),
  input, and the scene. This is the foundation, not new work.
- **The Android runtime** is a project-maintained **Android 17** LXC image, derived
  from Waydroid's container and passthrough integration and forward-ported. GPU
  passthrough uses the host driver — Mesa for AMD/Intel, the NVIDIA driver's GBM/dma-buf
  path for RTX — with gralloc allocating buffers importable by the host compositor.
- **The integration layer** is the new work: accelerated, explicit-sync buffer sharing
  (NVIDIA-first); a surface bridge that exports per-app Android surfaces and metadata to
  Nucleus; an input bridge; unified window management; and the desktop-integration
  services (clipboard, files, notifications, audio, intents).
- **The base OS** is a mainstream Linux base (a rolling or immutable image) with the
  Nucleus session as the desktop and the Android runtime preinstalled.

The load-bearing reuse on the Nucleus side is the existing dma-buf and explicit-sync
machinery: the `importDmaBufImage` path that already imports Wayland client buffers
with explicit sync imports Android gralloc buffers, and the existing window scene
presents them. The compositor does not learn "Android"; it learns one more surface
source — and it already has the sync discipline NVIDIA needs.

## Phase 1 — Android 17 runtime

Phase 1 stands up a **current Android** as a containerized app runtime on the Nucleus
host, sharing the kernel and the GPU, rendering headless. This is the foundation every
later phase builds on and the phase that accepts the ownership commitment: the runtime
is not a reused image but an Android 17 build carrying Waydroid's container and
passthrough integration forward-ported to it.

The work: take an Android 17 (AOSP/LineageOS-class) base and forward-port the container
integration — the LXC lifecycle, the container HALs, gralloc/host-GPU passthrough,
binder plumbing, sensors, and the surface/input export hooks — so Android 17 boots to a
running framework with no display of its own and its app surfaces are GPU-resident
dma-bufs available for export. Google services are provisioned by choice (microG or
GApps).

Components: the Android 17 image build and its forward-ported container/passthrough
patches (the ongoing-maintenance core of the product); the LXC container manager;
gralloc host-GPU sharing; the Nucleus session's hooks to start/stop the runtime.

Risk surface: high and ongoing — this is the maintenance treadmill made explicit, and
Android 17 is current AOSP, so the forward-port is against a recent, moving base. It is
accepted as the deliberate cost of a current runtime. No Nucleus compositor changes
here.

## Phase 2 — Accelerated cross-vendor buffer sharing (NVIDIA/RTX first-class)

Phase 2 makes Android render GPU-accelerated and its buffers import zero-copy into the
Nucleus compositor on **every desktop GPU vendor, NVIDIA included** — the capability
that most sharply separates this product from Waydroid.

The Android 17 runtime produces GPU-accelerated gralloc dma-bufs; Nucleus imports them
zero-copy into its Vulkan scene through the existing explicit-sync + DRM-modifier import
path (`NucleusVulkanDmaBuf.swift`, `Dmabuf.swift`, `Syncobj.swift`,
`RendererClientBuffers.swift`). AMD and Intel work through Mesa on both sides, as
Waydroid already does. **NVIDIA/RTX is the differentiator:** the compositor-side explicit
sync and modifier handling that Waydroid lacks — and that Nucleus already has — is what
lets RTX-imported Android buffers present correctly under load instead of tearing or
falling back to software. The guest-side path that produces RTX-importable accelerated
buffers (the NVIDIA driver's GBM/dma-buf path integrated into the Android 17 image) is
built and validated here.

Components: the Nucleus explicit-sync + modifier import (existing, exercised against
Android buffers); the Android 17 image's per-vendor GPU integration, with the NVIDIA
path as the primary target.

Risk surface: high on the guest side, and it is the load-bearing GPU unknown of the
plan. The compositor half is owned and already implemented; the guest half — producing
NVIDIA-accelerated, importable buffers from inside the Android 17 container — is where
the risk concentrates and is validated before the windowing work builds on it. Builds
on Phase 1.

## Phase 3 — Per-app surface bridge

Phase 3 puts individual Android app windows into the Nucleus scene. Each Android app is
projected to its own surface; the bridge exports that surface's (now accelerated) gralloc
dma-buf and window metadata — title, geometry, focus intent — to Nucleus, which presents
it as a toplevel window through the Phase 2 import path.

This is where the product becomes visible: an Android app window and a Linux Wayland
window are two dma-buf-backed surfaces the same RTX compositor composites. The bridge
adapts Waydroid's per-app (multi-window) export mechanism, retargeting its
compositor-facing side to a Nucleus surface source.

Components: the Android-side per-app surface export (forward-ported Waydroid platform
service); a Nucleus-side surface source wrapping exported gralloc dma-bufs as scene
toplevels (`NucleusCompositorWindowScene`/`NucleusCompositorWaylandRuntime`).

Risk surface: medium — the buffer lifecycle and metadata across the bridge are the novel
part; the pixel path is proven by Phase 2. Builds on Phase 2.

## Phase 4 — Cross-runtime input routing

Phase 4 makes input work across both worlds from Nucleus's single seat. Nucleus owns
input and routes to the focused window; when it is a Linux client, delivery is unchanged,
and when it is an Android-backed toplevel, the bridge injects the event into Android's
input for that app with correct coordinate mapping and focus bookkeeping.

Components: the Android-side input injection (forward-ported from Waydroid), and the
Nucleus input dispatch routing to the bridge for Android toplevels
(`InputDispatch*.swift`, `WlSeat.swift`), sharing the focus model with Phase 5.

Risk surface: low-to-medium. Input injection is proven; the work is unifying it with
Nucleus's existing focus/grab model. Builds on Phase 3.

## Phase 5 — Unified window management and the shell

Phase 5 unifies management: Android app windows and Linux client windows live under one
window manager, one launcher, one taskbar/switcher, one focus and stacking model. The
desktop shell (`shell/`, `NucleusCompositorOverlay`, `NucleusCompositorWindowManager`)
treats an Android-backed toplevel and a Wayland/XWayland-backed toplevel identically. App
launching spans both worlds — a Linux `.desktop` entry and an Android activity both open
windows in the same scene, listed together in one launcher.

Components: the window manager and shell toplevel model generalized over both surface
sources; the launcher/task model reading both Linux desktop entries and the Android app
inventory.

Risk surface: low-to-medium, mostly Nucleus-side design. Builds on Phases 3–4.

## Phase 6 — Desktop integration services

Phase 6 makes the two worlds feel like one system. Clipboard is shared bidirectionally;
files open across runtimes through a shared path mapping and MIME/default-app routing;
Android notifications surface in the Nucleus shell; audio routes from the Android runtime
into PipeWire; and URL/intent handling crosses the boundary so links and share targets
resolve to the right app in either world.

Components: the clipboard relay; the file-sharing/open-with mapping; the Android
notification → shell bridge; the Android audio → PipeWire route; the intent/URL handler.

Risk surface: low-to-medium. Each is a discrete, well-trodden bridge. Builds on the
runtime and window integration being live.

## Phase 7 — The installable OS

Phase 7 turns the working desktop into a distributable operating system. A mainstream
Linux base composes with the Nucleus session as the desktop and the Android 17 runtime
preinstalled and provisioned, packaged as an installable image with an installer and an
update mechanism that ships both the OS and the maintained Android runtime. Desktop and
laptop hardware support — AMD, Intel, and NVIDIA/RTX — comes from the mainline Linux
stack; no per-device porting.

Components: the base system and image composition; the installer; the Nucleus
session/greeter; the preinstalled, first-run-provisioned Android runtime; the update
channel that carries Android-runtime updates as the project tracks upstream Android.

Risk surface: low-to-medium and standard distro engineering, plus the standing cost of
shipping Android-runtime updates as part of the ownership commitment. Builds on
everything above.

## Non-goals

- **The phone / convergence OS is deferred, not abandoned.** The same engine grows
  toward a converged phone later; this plan does not carry the AVF, gfxstream, libhybris,
  GrapheneOS-fork, or AOSP-display work that path required.
- **Reusing an off-the-shelf Android runtime unchanged is not the approach.** The product
  owns and forward-ports its Android 17 runtime to deliver current Android and NVIDIA
  acceleration; Waydroid supplies mechanisms, not a consumed image.
- **Android is a containerized app runtime, not the system.** There is no attempt to
  preserve Android telephony, secure element, or system services — on a desktop there is
  nothing there to want.
- **Hardware-attestation-gated Android apps are out of reach.** A containerized,
  uncertified Android fails Play Integrity / hardware attestation, so apps that demand
  it — many banking apps, high-quality DRM streaming, some games — will not run. The value
  proposition is the breadth of ordinary Android apps, not universal compatibility.
- **The native Android app host** (`core/platform-android`) remains a supported,
  independent target and is unrelated to this desktop product.
- **A Vulkan software/compatibility fallback and an epoll reactor** are excluded; native
  Vulkan and the io_uring reactor are hard requirements, already met on desktop.
- **The general mobile UI toolkit** in NucleusUI is a separate effort; this plan is a
  desktop product and does not scope touch-first mobile UX.
