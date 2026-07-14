# Nucleus Shell — Architecture (built: skeleton + bar vertical slice)

## Invariant

`nucleus-shell` is an out-of-process **Wayland layer-shell client**, built as a React Native
app on the Nucleus RN platform, that renders with the shared render core (Skia/Vulkan) onto
client-owned surfaces and drives windows over **standard protocols** (`wlr-layer-shell`,
`wlr-foreign-toplevel-management`, `ext-session-lock`, `wlr-screencopy`). It has **no
build-time relationship** with the compositor — they meet only at runtime over those
protocols, so the compositor is swappable under the shell and vice-versa. `nucleus-shell` is
one of potentially several shells (Noctalia and other layer-shell clients are equally served);
it is intended to become the recommended shell as it matures.

## Module graph

```
NucleusShell (exe)
  └─ NucleusShellRuntime  ── the composition root: host bundle install, RN boot, frame loop
        ├─ NucleusShellWayland   ── wl_display connect, registry, layer-shell / foreign-toplevel
        │     │                      / session-lock / screencopy client drivers
        │     └─ NucleusShellWaylandC(+Protocols)  ── generated <wayland-client.h> façade
        ├─ NucleusShellRender    ── VK_KHR_wayland_surface swapchain presenter (PresentationBackend)
        │     └─ RenderCore (shared core, VkDevice) + Skia Graphite
        ├─ NucleusShellRuntimeC  ── C++: native TurboModule registration + Swift action table
        └─ NucleusReactRuntime.Host (facade)  ── boots RN, evaluates the .hbc, mounts the surface
  └─ NucleusTextBackend  ── the shared Skia text backend (same sources the compositor links)
```

The client Wayland bindings are the **client twin** of the compositor's server-side codegen:
`swift-wayland` supplies committed client bindings generated with `wayland-scanner` from its
vendored protocol XMLs, including the aggregating header and interface accessors used here.

## The render path (the novel infrastructure)

`WaylandVulkanPresenter` is the client analog of the Android WSI presenter
(`AndroidVulkanPresenter`) and the compositor's DRM scanout backend: it conforms to the core's
`PresentationBackend`, so `RenderCore.renderReady(backend:)` drives it unchanged — acquire the
next swapchain image → hand it to the core as `AcquiredFrameTarget(kind: .swapchainColor,
waitSemaphore:, signalSemaphore:)` (the core records the layer tree via Skia Graphite and
submits with the WSI semaphores + PRESENT_SRC transition) → `vkQueuePresentKHR`. The only
platform difference from Android is surface creation (`vkCreateWaylandSurfaceKHR` with
`wl_display` + `wl_surface`) and premultiplied composite alpha for a translucent panel.

`ShellRenderEngine` owns the shared `RenderCore` plus one presenter per shell surface (each a
presentable output with its own swapchain), so the same core drives many panels.
Bring-up uses the core's fail-closed Vulkan 1.4 contract and qualifies the selected
graphics queue with `vkGetPhysicalDeviceWaylandPresentationSupportKHR` for the
connected `wl_display`; an incompatible loader, driver, device, or queue cannot
construct the shell renderer.

## Core enablement (dependency on the shared render core)

The shell requires three small, **additive** capabilities in the `nucleus` render core (made in
the canonical checkout; must land in nucleus-priv main and propagate to embeddings):

1. `NucleusVulkanC.h` — a `#include <vulkan/vulkan_wayland.h>` guarded on
   `VK_USE_PLATFORM_WAYLAND_KHR` (defined only by `NucleusShellRender`), leaving the compositor
   and Android unchanged.
2. `VkRequirements` — a `PresentationMode` enum with a `.waylandClientWSI` case selecting the
   `VK_KHR_surface + VK_KHR_wayland_surface` (instance) / `VK_KHR_swapchain` (device) extension
   set instead of the Linux DRM/dmabuf set. Existing callers default to `.platformDefault`.
3. `RenderCore.create(presentation:)` — threads the mode through (defaulted, so the compositor
   and Android call sites are unchanged).

These are the only core changes; everything else is the shell's own code.

## What is built vs. scaffolded

**Fleshed (the bar vertical slice), end-to-end reasoned:**
- Wayland client: connection, registry/global binding, output tracking; the layer-shell surface
  driver (anchor / exclusive zone / configure handshake); the foreign-toplevel taskbar model.
- The Vulkan-WSI render backend + multi-surface engine.
- The RN boot via the `NucleusReactRuntime.Host` facade (the same path the deleted compositor
  overlay used) + the host-bundle install.
- The bar RN component (clock + foreign-toplevel taskbar) and its native module + the Swift
  action routing.

**Scaffolded (real shapes, additive fleshing):** the session-lock and screencopy client drivers;
the native TurboModule bodies (their shipping form consumes generated codegen specs from the
`.ts` in `js/`); the desktop-services sort (notification daemon, launcher + `.desktop` index,
appearance portal, D-Bus relays) that moves from the compositor's `NucleusCompositorShell` —
these are the breadth beyond the one-surface slice.

## Integration seams (where the exact NucleusUI/RenderHost API applies)

`ShellHost.setupRenderContext` / `bootReactBar` establish the root render context the RN surface
attaches into: a `RenderCommitSink` feeding `RetainedTreeStore.shared`, a root `Context` + root
`Layer`, and `Host.attachSurface(rootView:parentLayer:…)`. The precise constructors
(`RenderCommitSink` resource-host handle, the root-layer creation, `Host.rootView`) are the
integration points against the live NucleusUI/NucleusRenderHost API; the shape is the same one
the compositor overlay used, retargeted from the overlay scene to a shell-owned root layer.

## Verification status

The full package graph parses and resolves (`swift package dump-package`) across all nine
`NucleusShell*` targets. Runtime behaviour (the bar rendering onto a real compositor, the
swapchain present, the taskbar wiring) is **compositor/hardware-gated** — it is exercised once
the shell runs against a live `nucleus-compositor` (or any compositor serving the shell-facing
protocols) on hardware, the same deferral the render-relight and locked-scanout work carry.

## Next surfaces (beyond the slice)

Dock, launcher, notifications, control center, and the lock screen are additional layer-shell
surfaces on the same infrastructure (`ShellRenderEngine.addSurface` + a new `.hbc` component +,
where needed, a client driver already scaffolded here). The desktop-services sort moves the
compositor's out-of-policy services (notifications, launcher index, appearance portal, D-Bus
relays) into shell-side native modules.
