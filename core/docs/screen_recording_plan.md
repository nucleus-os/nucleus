# Screen capture and recording plan

**Status: active.**

**Invariant: one compositor-owned capture engine produces output and toplevel frames from the composed GPU-resident scene. Wayland capture protocols, portals, PipeWire, screenshots, and recording are adapters over that engine, never separate readback pipelines.**

## Phase 1 — Consolidate capture ownership

Establish the implementation boundary: capture sources, sessions, frame requests, damage, cursor policy, and cancellation live in compositor-core. Delete duplicate screenshot-specific scheduling.

Gate: unit tests cover source removal, output resize, cancellation, damage accumulation, and consumer backpressure.

## Phase 2 — Add the renderer capture target

Render a requested output or toplevel into an exportable Vulkan image after scene composition and before presentation. Suppress direct scanout only for the affected output while a composed capture is active. Preserve explicit synchronization and avoid CPU readback for DMA-BUF consumers.

Gate: capture matches the presented scene across subsurfaces, decorations, transforms, color state, cursor inclusion, and resize.

## Phase 3 — Complete Wayland protocol adapters

Drive the implemented typed screencopy protocol from the engine, then add the modern image-capture/copy family. Validate formats, dimensions, object state, and buffers before import; isolate each client failure.

Gate: wire tests cover SHM, DMA-BUF, damage, cursor modes, malformed clients, and teardown.

## Phase 4 — Add PipeWire and portal publication

Publish DMA-BUF-backed PipeWire streams and implement the xdg-desktop-portal backend with user-visible source selection in the shell. The compositor provides capture authority; the shell provides UI; the portal owns application mediation.

Gate: a portal consumer receives frames without CPU copies and loses access immediately when the session is revoked.

## Phase 5 — Add screenshot and recording consumers

Implement screenshots as bounded asynchronous readback/encoding consumers. Implement recording through hardware Vulkan Video where qualified, with an explicit unsupported result otherwise; do not add an unbounded software fallback. Audio enters through PipeWire and is synchronized at mux time.

Gate: sustained recording preserves frame pacing, bounds memory, handles dropped consumers, and produces timestamp-correct media.

## Phase 6 — Qualify hardware and security

Exercise multi-output capture, direct-scanout transitions, protected-content policy, hotplug, suspend, consumer crashes, and long recordings on the supported GPU matrix.
