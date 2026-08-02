# Compositor hardware qualification

The direct-scanout, cursor, screencopy, retirement, and synchronization implementations have agent-runnable behavioral coverage. The remaining work requires an explicitly user-run DRM session on supported hardware.

Verify in this order:

1. Cursor-plane visibility, hotspot, movement, image replacement, output crossing, and atomic fallback.
2. Fullscreen DMA-BUF import, TEST_ONLY acceptance, framebuffer/GEM lifetime, and descriptor cleanup.
3. Promotion with zero compositor GPU submits, followed by glitch-free fallback for popups, animation, capture, and surface handoff.
4. Explicit-sync release exactly after retirement and permanent rejection of implicit-sync direct scanout.
5. VRR enablement, modeset transition, pacing, and safe fallback after a persistent failure.
6. Screencopy correctness while direct scanout would otherwise be eligible.
7. VT switch, hot-unplug, device loss, late completion, and shutdown without leaks or use-after-free.

Potential optimizations remain deliberately unimplemented until profiles justify them: cursor-only atomic commits and GPU readback for DMA-BUF cursor surfaces. They are not correctness fallbacks.
