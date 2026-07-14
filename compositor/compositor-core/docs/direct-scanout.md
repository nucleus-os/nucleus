# Direct scanout — how it works

A fullscreen, opaque, dmabuf-backed client surface whose geometry exactly matches its output is
flipped **directly** onto the CRTC's primary plane: the client's buffer becomes the scanout
framebuffer with **zero compositor GPU work**, the cursor renders on the hardware cursor plane, and
the client is throttled by real vblank through the normal frame-callback path. The instant
eligibility fails — a popup or subsurface maps, an animation runs, the session locks, a screencopy
starts, the surface stops matching the output, or the buffer's format/modifier is unscannable — the
output falls back to full composition **within the same frame**, with no visible glitch.

This is the reference for the landed pipeline. For the phase-by-phase history, the direct-scanout
audit, and the remaining hardware-validation checklist, see `followups.md`.

## Two absolute safety rules

Everything below exists to uphold these:

1. **A scanned client buffer is never released** (`wl_buffer.release` / release syncobj) until the
   page flip that *replaces* it on the plane completes. The kernel scans it until then.
2. **An imported client GEM handle is never destroyed while a flip that references its framebuffer
   is in flight**, and every imported handle/framebuffer/fd is dropped when the surface's buffer is
   replaced or the surface is torn down. No leak, no scan-after-free.

## The per-frame pipeline

The composition root drives one pass per output per frame. Direct scanout inserts as a branch
*before* compositing:

```
gather live facts ──▶ setScanoutCandidates ──▶ renderReadyOutputs
                                                     │  (RenderCore.renderReady, per output)
                                                     ├─▶ tryDirectScanout(output) == true ──▶ flip client buffer, done
                                                     └─▶ false ──▶ acquireTarget ▸ record ▸ present (composite)
```

The DRM backend must not depend on the window model, so the composition root **gathers** per-output
facts and **pushes** them down as Sendable value types (mirroring `setLockComposition`). The backend
holds them and runs the pure evaluator during the render loop.

### Stage 1 — Eligibility: gather → push → evaluate

- **Gather** (`CompositorRuntime`, exe): each frame, for every output, build a `ScanoutCandidate`
  from the live window model via the `WaylandRuntime` facade getters — the fullscreen owner's root
  IOSurface id, layout rect, animated origin, current width/height, viewport-transform flag,
  opaque-region-covers-surface flag, and dmabuf attrs (format/modifier/width/height); plus the
  block-reason inputs: `popupCount` and subsurface count (must be 0), layer-shell-mapped-on-output,
  toplevel-animation-active-on-output, session-locked (`SessionLockGate.isActive`),
  screencopy-capture-active (`ScreencopyActivity.liveFrames > 0`), notification/hotkey overlay
  content folded into `notificationCount` (scoped to `isShellOutput`), and `isShellOutput`.
- **Push**: `RendererRuntime.setScanoutCandidates([UInt64: ScanoutCandidate])`, called before
  `renderReadyOutputs`. It stores the map and logs each output's decision on transition.
- **Evaluate** (`drm/DrmScanout.swift`, pure + unit-tested): `ScanoutCandidate.evaluate(
  primaryPlaneFormats:)` runs `scanoutBlockReason` (output-level gates) then
  `evaluateDirectScanout` (single-surface: fullscreen match, opaque, no viewport transform, dmabuf
  present, format+modifier in the plane's `FormatSet`). Result is `.eligible(rootIOSurfaceID:)` or a
  block reason. The output's primary-plane `FormatSet` is cached at attach
  (`collectPlaneFormats` over the primary plane, parsing the IN_FORMATS blob).

`RendererRuntime.evaluateScanout(outputID)` re-runs this against the cached formats; it is the
single source of the eligibility decision that Stage 3 and VRR both consume.

### Stage 2 — Client-buffer retention and KMS import

Only a surface that is a pushed candidate's root ever reaches a plane, so retention is **gated on
candidate-root membership**, not on every opaque commit:

- On each `registerSurfaceDmabuf`, if the imported buffer is opaque **and**
  `isScanoutCandidateRoot(iosurfaceID)` (its id is some output candidate's `rootIOSurfaceID`), the
  runtime retains a `ClientScanoutBuffer` for it. Non-fullscreen opaque windows pay no dup/import
  cost. (Tradeoff: the frame a surface first becomes fullscreen, its commit precedes the matching
  candidate push, so that frame composites and the next commit retains — a one-frame warm-up for any
  continuously-committing client. A client that commits a fullscreen buffer exactly once and never
  again stays composited until it commits again.)
- `ClientScanoutBuffer` (`drm/DrmClientScanout.swift`): `retain` dups the client dmabuf fds (planes
  sharing a source fd share one dup) and holds the layout; `framebufferId()` lazily imports on first
  scanout need (`drmPrimeFDToHandle` per unique fd → `DrmFramebuffer`, modifier-explicit or
  implicit); `destroy`/`deinit` removes the fb → releases the GEM handles → closes the dup'd fds, in
  that order, once (idempotent).
- **`GemHandleTable`** (per-device, refcounted): `drmPrimeFDToHandle` returns the *same* GEM handle
  for the same underlying dmabuf, so a raw `drmCloseBufferHandle` per buffer would double-close a
  handle another buffer still uses. The table refcounts handles per device fd and closes only at
  zero.
- `clientScanoutFramebuffer(iosurfaceID:validateWith:)` imports on demand and gates through
  `DrmOutput.testScanoutCommit` (atomic TEST_ONLY) — the promotion seam. Returns 0 (→ composite) if
  there's no retained buffer or the buffer can't be scanned by this output.

### Stage 3 — Promotion: `tryDirectScanout`

`RenderCore.renderReady` calls the agnostic `PresentationBackend.tryDirectScanout(output)` before
`acquireTarget`; on `true` it marks the output presented and skips record/composite entirely. The
WSI/Android backend defaults it to `false` (always composites). `RendererRuntime.tryDirectScanout`
returns true only when **all** hold:

1. the output has no page flip pending (`isReadyToPresent`);
2. `evaluateScanout(output) == .eligible(iosurfaceID)` with a nonzero id;
3. the surface uses **explicit sync** — a release syncobj is registered
   (`pendingSurfaceReleaseSync[iosurfaceID] != nil`). An implicit-sync client's
   `wl_buffer.release` is sent in the surface layer at commit time regardless of scanout, so
   promoting it would let it reuse a still-scanned buffer and tear; implicit clients composite;
4. the retained buffer imports + TEST_ONLY-validates (`clientScanoutFramebuffer != 0`);
5. `commitScanout(retaining: clientBuffer, fbId:, requestedVrr:, modeset: false, cursor:)` is
   accepted. Its retain-across-flip rotation now holds the *client* buffer for the flip's duration.

On success the tracker records the scanout and the frame is done with no GPU submit. Any miss returns
false and the core composites the output normally.

### Buffer lifetime and deferred release (safety rule 1)

`ScanoutSurfaceTracker` is the authority on which surface each output is scanning. It keeps a
**front + pending** map per output:

- `submitScanout(output:iosurfaceID:)` sets the pending surface at flip submit;
- `flipCompleted(output:)` rotates pending → front at flip-completion;
- `submitComposite(output:)` clears both when an output composites;
- `isScannedOut(iosurfaceID)` is `front || pending` across all outputs — true while a buffer is
  latched on, or in flight to, any plane.

This front/pending split is what makes release timing correct *across transitions* (a naive
"currently scanned" flag released buffers a frame too early at the scanout↔composite boundary). The
release path keys on it:

- **Buffer replace** (`registerSurfaceDmabuf`): if the surface is scanned out and has a pending
  release syncobj, the old `ClientScanoutBuffer.onDestroy` takes over firing that release — so it
  fires when the *replacing* flip drops the retained buffer, never while the kernel still scans it.
  On the composite path the client already has our GPU copy, so release is immediate.
- **Surface teardown** (`releaseSurfaceTexture`): same deferral — a still-latched buffer's release
  rides its `onDestroy`; nothing else will re-trigger it since no more commits arrive.
- The retained `ClientScanoutBuffer` is never destroyed on a map replacement: dropping the map
  reference leaves it alive (ARC) while a flip holds it, and its `deinit` tears down fb → GEM handles
  → fds (and fires any deferred release) only once the flip drops it.

A **per-binding generation** id guards flip completions: a hot re-enumerate replaces an output's
binding under the same output id, and a stale page-flip completion for the old binding is rejected
rather than misrouted.

## Hardware cursor plane

A scanned client buffer carries no cursor, so the cursor lives on a dedicated KMS plane (it is also
the *only* cursor path — there is no software cursor):

- **`drm/DrmCursorPlane.swift`**: a per-output double-buffered GBM cursor BO (ARGB8888,
  `GBM_BO_USE_CURSOR | GBM_BO_USE_WRITE`) with a `DrmFramebuffer` over each; `packCursorPixels` →
  `gbm_bo_write` into the back buffer, swap to front (an image change never tears the scanned BO).
  BO sized from `DrmCaps.cursorWidth/Height` (default 64×64).
- **Pure geometry** (`drm/DrmColorCursor.swift`, unit-tested): `cursorPlanePlacement`,
  `packCursorPixels`, `CursorPlaneProps`.
- **Commit**: a `CursorCommitState` (front fb + placement) is folded into every
  `assembleScanoutCommit` — including the direct-scanout flip, so a cursor move over a scanned client
  re-flips the same client buffer with updated cursor-plane state and no recomposite. The plane is
  cleared when the pointer is off the output and in `disableScanout`.
- **Present demand**: a pure cursor move has no tree damage, so `PresentationBackend.wantsPresent(
  output)` (default false, DRM overrides) pushes the output through `RenderCore`'s damage gate on
  movement.
- **Robustness**: the atomic commit is all-or-nothing, so a rejected cursor-plane state would wedge
  presentation — `present` retries once without the cursor and disables the hardware cursor for that
  output if the retry is needed.

## VRR coupling (M3)

`tryDirectScanout` passes `binding.drm.requestedVrr(directScanoutEligible: true)` into
`commitScanout`, so a fullscreen scanned-out client on a `vrr_capable` output drives an adaptive-sync
flip. The `VrrState.flagsForCommit`/`applyAfterCommit` machinery handles the enable modeset on the
transition frame; the composite path passes `requestedVrr: false`, disabling it symmetrically on
fallback. VRR capability is read live from the connector's `vrr_capable` property (a persistent
VRR-modeset failure degrades to composite fallback rather than wedging).

## Fallback and transitions

Composite→scanout and scanout→composite need no special casing beyond the deferred release and the
tracker: `tryDirectScanout` returning false routes the output straight into the normal
`acquireTarget ▸ record ▸ present` path, and `submitComposite` clears the tracker so the next buffer
replace/teardown releases immediately. Any eligibility change (popup maps, animation starts,
screencopy begins, lock engages) flips the decision on the very next frame's gather.

## `wl_pointer.set_cursor` (adjacent)

Client cursor *surfaces* feed the same cursor model: `set_cursor` binds the surface + hotspot
(`PointerCursorSurface`), and its committed SHM buffer is read (repacked to tight ARGB) into the
cursor model on the initial call and on every later commit (animated cursors) via a hook in
`importCommit`; a nil surface hides the cursor. The request is honored only from the client that
holds pointer focus carrying the matching enter serial (`WlSeat.cursorRequestAuthorized`), and the
binding is cleared when focus leaves. dmabuf cursor surfaces (needing a GPU readback) are left on the
previous image. The theme/shape and client-image paths share a `CursorServer.themeName` marker so
they don't dedup against each other.

## What is tested vs. hardware-only

Headless unit tests cover the pure logic: `evaluateDirectScanout`/`scanoutBlockReason` and the
candidate→eligibility mapping (`ScanoutCandidateTests`), the `ScanoutSurfaceTracker` front/pending
rotation (`ScanoutSurfaceTrackerTests`), the `ClientScanoutBuffer`/`GemHandleTable` fd bookkeeping
(`DrmClientScanoutTests`), cursor geometry/packing, the cursor SHM repack (`CursorShmRepackTests`),
and `set_cursor` authorization (`CursorRequestSerialTests`).

The KMS import, the plane substitution, the cursor plane programming, the deferred-release timing,
and VRR are validated only on real hardware with a real fullscreen client — see the
hardware-validation checklist in `followups.md`.
