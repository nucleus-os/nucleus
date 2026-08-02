# Screen capture and recording plan

Status: active.

## Invariant

One compositor-owned capture engine produces output and toplevel frames from
the composed GPU-resident scene. Wayland capture protocols, portals, PipeWire,
screenshots, and recording are adapters over that engine, never separate
readback pipelines.

## Current disposition

Compositor-owned capture scheduling, renderer capture work, damage tracking,
direct-scanout suppression, GPU-backed frame production, and the
`wlr-screencopy` adapter are implemented with focused tests. The plan resumes
at the modern image-capture protocol family and external publication. Do not
create another capture owner or renderer readback pipeline.

## Phase 1 — Complete modern Wayland capture adapters

Audit the existing capture engine and `wlr-screencopy` adapter against current
ownership, cancellation, source-removal, resize, cursor, damage, SHM, DMA-BUF,
and teardown contracts. Add the current image-capture-source and
image-copy-capture family over the same engine.

Gate: wire and behavior tests cover output and toplevel sources, malformed
clients, source replacement, backpressure, cancellation, and teardown.

## Phase 2 — Add PipeWire and portal publication

Publish DMA-BUF-backed PipeWire streams and implement the
xdg-desktop-portal backend with user-visible source selection in the shell. The
compositor provides capture authority; the shell provides UI; the portal owns
application mediation.

Gate: a portal consumer receives frames without CPU copies and loses access
immediately when the session is revoked.

## Phase 3 — Add screenshot and recording consumers

Implement screenshots as bounded asynchronous readback and encoding consumers.
Implement recording through hardware Vulkan Video where qualified, with an
explicit unsupported result otherwise. Audio enters through PipeWire and is
synchronized at mux time.

Gate: sustained recording preserves frame pacing, bounds memory, handles
dropped consumers, and produces timestamp-correct media.

## Phase 4 — Qualify hardware and security

Exercise multi-output capture, direct-scanout transitions, protected-content
policy, hotplug, suspend, consumer crashes, revocation, and long recordings on
the supported GPU matrix.
