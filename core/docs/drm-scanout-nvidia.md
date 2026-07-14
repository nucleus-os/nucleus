# DRM Scanout on Nvidia Proprietary

Nvidia's proprietary driver (tested on 590.48, RTX 3090) has shown KMS-side scanout quirks that don't appear on AMD or Intel. This doc captures historical findings and current hypotheses; it is not a hard policy source for presentation-mode eligibility.

## Multi-buffer FB_ID flicker

Changing `FB_ID` in DRM atomic commits between different GBM BOs causes every-other-frame flicker on Nvidia. Single-buffer mode (same `FB_ID` every frame) eliminates it. Double-buffer with blocking wait after commit shows reduced but non-zero flicker.

### Current conservative approach

**Single-buffer mode with blocking wait** has been the conservative path and matches gamescope's "one frame in flight" pattern. See `src/compositor/drm/output.zig` `PresentationCompletion` enum (`.page_flip_event` is force-enabled on Nvidia).

This does not block `NUCLEUS_PRESENT_MODE=mailbox_latest_wins`. Mailbox/latest-wins is allowed on Nvidia so current driver behavior can be measured directly. Treat the notes below as things to verify in logs and profiles, not as a reason to refuse the mode before running it.

### KWin's multi-buffer pattern (for future reference)

If multi-buffer becomes necessary on Nvidia, KWin's recipe (from `drm_commit.cpp:80–82`) is the working reference:

- Disable `IN_FENCE_FD` on Nvidia (`!plane->gpu()->isNVidia()` gate).
- Buffer-readability check via sync-fd poll before atomic commit.
- `glFinish()` on older Nvidia when native fence sync is unavailable.
- Dedicated commit thread with safety margins relative to vblank.
- Triple-buffered GBM with changing `FB_IDs` works under those conditions.

### Gamescope pattern

Blocks after every commit (`uPendingFlipCount.wait`), uses always-signalled `IN_FENCE_FD`, one frame in flight.

## When to revisit

The Nvidia detection in `drm/output.zig` (`is_nvidia` flag) still controls specific low-level quirks such as explicit fence handling. It does not decide whether mailbox/latest-wins is eligible. When revisiting multi-buffer scanout behavior on Nvidia, compare the measured Nucleus path against the KWin recipe above and update this document from fresh profile data.
