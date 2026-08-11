# Nucleus Browser qualification plan

Status: active.

## Invariant

Nucleus Browser is a native Linux/Wayland Chromium product. Blink and Viz render
through Skia Graphite, Dawn Vulkan, GBM/DMA-BUF SharedImages, explicit GPU
fences, and Ozone Wayland presentation. Chromium retains its ordinary browser,
GPU, renderer, network, and utility process boundaries, sandbox, and site
isolation.

The browser never selects X11/XWayland, Ganesh, OpenGL compositor rendering,
software compositing, SwiftShader, CPU readback, implicit synchronization, or an
in-process GPU process as a fallback. The browser process owns the Wayland
connection and surfaces; the sandboxed GPU process submits buffer metadata and
fences through Chromium's existing Ozone IPC boundary.

The backend-neutral Wayland presenter, Ozone Viz adapter, Graphite/Dawn
SharedImage path, explicit synchronization, GPU selection, color metadata,
product packaging, immutable installation, and focused source tests are
implemented in the selected fork commits. This plan owns final product
qualification only.

## Phase 1 — Consume the qualified browser artifact

Complete the Chromium/CEF product qualification plan and consume its validated
Nucleus Browser generation through the package cohort defined by the
[Linux package distribution and update plan](linux-package-distribution-and-update-plan.md).
Verify the launcher, desktop entry, profile/cache isolation, sandbox helper
ownership, runtime libraries, Widevine payload, and immutable product metadata.

Gate: the installed generation is complete, self-consistent, and traceable to
the selected source and build identities.

## Phase 2 — Qualify mandatory startup capabilities

Start on the target Wayland compositor and require Vulkan, Graphite, Dawn,
DMA-BUF modifiers, explicit synchronization, fractional scale, presentation
feedback, and the compositor's authoritative DRM device identity. Confirm every
missing requirement produces a named startup failure.

Gate: the GPU process selects the compositor-presenting physical device and no
unsupported renderer or synchronization path can start.

## Phase 3 — Qualify presentation and lifecycle

Exercise ordinary and popup surfaces, resize, fractional scaling, output
changes, damage, transforms, color metadata, HDR metadata, buffer release,
occlusion, monitor-off, GPU-process restart, renderer crash, browser restart,
and clean shutdown.

Gate: callbacks are exactly once, stale epochs cannot present, and all buffers,
fences, Wayland objects, processes, and installed-generation leases retire.

## Phase 4 — Qualify browser workloads

Exercise accelerated video decode, AAC/H.264, Widevine, WebGL, WebGPU, downloads,
printing, DevTools, extensions, media capture, and sustained 120 Hz interaction.
Capture frame pacing, queue depth, copies, memory, idle wakeups, and crash
recovery.

Gate: the browser remains on its mandatory Graphite/Dawn/Vulkan path and meets
the declared stability and performance thresholds.

## Phase 5 — Make the reference engine authoritative

Record the qualified browser generation and compositor prerequisites in the
browser component contract. Remove this plan after the reference browser is the
sole engine qualification target for the later custom NucleusUI shell.
