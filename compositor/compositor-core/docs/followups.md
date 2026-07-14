# Compositor follow-ups (backlog)

Outstanding work captured at the end of the M2 direct-scanout arc. Grouped by whether it
can be done + verified without hardware, what needs an on-device pass, and what was
deliberately deferred. Companion to `direct-scanout.md` (which covers the landed M2
phases in detail).

## A. Non-hardware follow-ups (actionable + verifiable now)

Ranked roughly by value.

### A1. Implement screencopy capture — DONE (shm + dmabuf)
`RouterRenderDriver.captureImpl` captures the output's composited frame into the client buffer:
- **SHM** — read back the accumulator (`RenderBridge.screencopyCapture` →
  `RendererRuntime.captureOutputBGRA` → `RenderCore.captureOutputBGRA` via `Screenshot.readback`)
  and copy the requested region into the client buffer.
- **dmabuf** — blit the accumulator directly into the client dmabuf render target on the GPU
  (`RenderBridge.screencopyCaptureDmabuf` → `RenderCore.captureOutputToDmabuf`: import the dmabuf
  as a color-attachment image, `ScanoutSurface.wrap` it, `OutputAccumulator.present(onto:)`,
  synchronous `context.submit`). No CPU round-trip.

The `ScreencopyActivity` block forces composition so the accumulator is current. Region dma-buf
captures use a source-rect blit, and `overlay_cursor` composites the hardware-cursor image into
both SHM and dma-buf captures when requested.
On-hardware validation: an actual screenshot / recording has correct pixels + colors.

### A2. Fix the local `NucleusCompositorWaylandRuntimeTests` bundle — DONE
Root cause was mundane: the target has an explicit `sources:` list (the other ~26 files are
stale orphaned fixtures that don't compile against the current API), so newly added tests were
silently excluded → "no matching test cases". Adding a file to that list makes it run.
`CursorShapeNameTests` now runs (3 pass). The `WaylandProtocolConformanceTests` signal-4 crash is
separate and unrelated (it constructs a live router needing a display); pure tests run fine.

### A3. Add the headless tests that A2 unblocks — DONE (cursor repack); scanoutFacts is integration-level
- **`cursorImageFromShm`** — the format gate + stride repack were extracted into pure,
  `nonisolated` helpers (`isReadableCursorShmFormat`, `repackTightARGB`) and covered by
  `CursorShmRepackTests` (6 tests: format acceptance, stride-padding strip, verbatim tight copy,
  undersized-stride rejection, short-source per-row stop, zero dims — the over-read guards).
- **`scanoutFacts` gathering** — NOT unit-tested: the gather reads the live router + window
  model (`RouterHost.shared.runtime.compositor`, `WlSurface`, `WlCompositor.popupCount`), which
  needs a real wl_display/client. The same heavy router fixtures (`WaylandProtocolConformanceTests`) crash
  at startup in the dev shell (need a display). The eligibility *logic* it feeds is already
  covered (`ScanoutCandidateTests`, `DrmScanoutTests`); the gather itself is integration-level
  and validated on hardware. The pure fact→candidate mapping lives in the exe
  (`CompositorRuntime.scanoutCandidates`), which has no test target.

### A4. Execute the `RouterWindowDriver` god-file split — DONE
Landed in commit `36bc636` (predates the M2 arc; this entry was stale). The surface-import /
scene-publish half was extracted into `RouterSurfaceSceneDriver` (owned by `RouterWindowDriver`
via composition — `private let sceneDriver`, constructed in `init`), and the three
`SurfaceSceneDelegate` / `LayerShellDelegate` thunks forward to it (`importCommit`,
`surfaceDestroyed` then `surfaceDestroyedImpl` for the seat unmap, `destroyLayerSurface`). The
file dropped 1004 → 763 lines; `byToplevel` + the configure machine + the other seven delegate
roles stayed. Green build, unchanged tests.

### A5. Narrow direct-scanout buffer retention to candidate roots — DONE
`RendererRuntime.registerSurfaceDmabuf` retention is now gated on
`isScanoutCandidateRoot(iosurfaceID)` — membership in the pushed candidates'
`rootIOSurfaceID`s — instead of firing for every opaque commit. Non-fullscreen opaque windows
no longer dup an fd + build a KMS framebuffer they could never use. The candidate is computed
from the window model each frame, so the frame a surface first becomes fullscreen its commit
precedes the matching push and composites; the next commit retains (a one-frame warm-up for any
continuously-committing client — every real scanout beneficiary is a game/video). Known edge:
a client that commits a fullscreen buffer exactly once and never again stays composited until it
commits again. Behind the GPU-import path, so integration-level; the 142-test RendererLinux suite
stays green.

### A6. Consolidate `direct-scanout.md` — DONE
Rewritten from plan + "LANDED" phase notes into a "how direct scanout works" reference organized
by the runtime pipeline (safety rules → per-frame branch → Stage 1 gather/push/evaluate → Stage 2
candidate-root retention + KMS import + `GemHandleTable` → Stage 3 `tryDirectScanout` gates →
deferred release via `ScanoutSurfaceTracker` front/pending + per-binding generation → cursor plane
→ VRR → fallback → `set_cursor` → tested-vs-hardware). Folds in the audit fixes and the A5
candidate-root gating that superseded the old Phase 3/4 notes; phase history + the hardware
checklist now live here in `followups.md`.

### A7. `set_cursor` serial validation — DONE
`WlSeat.pointerEnter` now records the `(enterSerial, focusClientKey)` pair (cleared on
`pointerLeave` when focus leaves), and `WlPointer.setCursor` is gated on
`acceptsCursorRequest` → the pure `WlSeat.cursorRequestAuthorized(requestClient:requestSerial:
focusClient:enterSerial:)`: a request is honored only from the client that currently holds
pointer focus, carrying the serial of the enter that granted it. The nil-surface (hide) case is
gated too, so a client that lost focus can't hide the new owner's cursor. Covered by
`CursorRequestSerialTests` (4 tests: focused+matching accepted; wrong client, stale serial, and
no-focus all rejected). The seat is crossed into the `set_cursor` main-actor closure as an opaque
bit pattern (like the surface pointer) to avoid sending non-Sendable `self`.

## B. Hardware-validation checklist (on-device only)

Everything in M2 Phases 2–5 + the cursor work is un-headless-testable beyond the logic that
was extracted into pure types. On a real GPU + KMS with a fullscreen dmabuf client, verify:

- **Cursor plane** — visible from the first frame, tracks the pointer, correct hotspot, clears
  off-output, no tear on an image/shape change; the all-or-nothing atomic fallback (retry
  without cursor, disable the plane) never wedges presentation.
- **Client-buffer KMS import** — a fullscreen dmabuf client imports (`drmPrimeFDToHandle` →
  `DrmFramebuffer`), TEST_ONLY passes, and the fb/GEM handle/fds drop on buffer replace + surface
  teardown with no leak (`drm_info`, fd count, `GemHandleTable` refcounts return to empty).
- **Promotion + fallback** — the client scans out with **zero compositor GPU submits** for that
  output; mapping a popup / starting an animation / a screencopy falls back to composition with
  no glitch; no scanned-buffer use-after-free or tearing under `drm.debug` — especially across
  the scanout↔composite and surface-handoff transitions the audit hardened.
- **Deferred release** — an explicit-sync client's buffer is released exactly one flip late (no
  stutter, no early reuse); an implicit-sync fullscreen client correctly stays on the composite
  path (never promoted).
- **VRR (M3)** — a `vrr_capable` output actually engages adaptive sync while a client scans out;
  the `ALLOW_MODESET | PAGE_FLIP_EVENT` VRR-enable transition frame commits cleanly; a persistent
  VRR-modeset failure degrades to composite fallback (safe) rather than wedging.
- **`set_cursor` / cursor-shape** — client cursor surfaces (shm) and named shapes render
  correctly with the right hotspot.

## C. Deferred / known-benign (revisit with hardware knowledge)

- **`pauseSession` flip-token leak** (`DrmOutput.cancelPendingPresentation`) — one small
  `DrmPageFlipToken` leaks per VT-switch-with-pending-flip. Intentionally not balanced: whether
  the kernel delivers the completion after a master drop+regain is driver-dependent, and a manual
  balance racing a late completion would be a use-after-free. Revisit only once that driver
  behavior is known on the target hardware.
- **`disableScanout` -EBUSY at teardown** — if a non-blocking flip is in flight when a binding is
  torn down (hot re-enumerate / shutdown), the blank modeset can `-EBUSY` and not actually stop
  scanout before the slots are released. Today it returns its rc and logs; a proper fix drains the
  pending flip (poll + `drmHandleEvent`) then retries the blank. The per-binding generation guard
  already prevents the stale-completion *misrouting* corruption; this is the narrower
  freed-while-scanning risk.
- **Cursor-only NONBLOCK atomic commit** — deferred as unnecessary for correctness (a cursor move
  over a scanned client re-flips the same client buffer with updated cursor-plane state, no
  recomposite). It's an efficiency win: avoid a full primary-plane re-flip per cursor move.
  Consider if cursor-move flip cost shows up on a VRR display's pacing.
- **dmabuf cursor surfaces** — `set_cursor` with a dmabuf-backed cursor surface is left on the
  previous image (only shm cursor buffers are read on the CPU). Needs a GPU readback of the cursor
  surface into the cursor BO.
- **Screencopy during direct-scanout** — once A1 lands, confirm a capture reads correct content
  when an output is direct-scanning (read the scanned client buffer) rather than an empty
  compositor target; the `ScreencopyActivity` block forces composition, but verify the interaction.

## Done — for the record (audit fixes, M2 arc)

The direct-scanout audit findings are fixed (commit `edbd493`): release-timing at transitions
(the `ScanoutSurfaceTracker` rewrite, unit-tested), implicit-sync gating, live VRR capability,
`GemHandleTable` refcounting, per-binding flip-completion generation, and deferred teardown
release. M2 Phases 1–5 + cursor shape + `wl_pointer.set_cursor` are all landed.
