# Core and compositor documentation

## Current contracts

- [Application runtime](app-runtime-roadmap.md)
- [UI authoring model](ui-authoring-model.md)
- [Bounds-origin model](bounds-origin-model.md)
- [Image loading](image-file-loading.md)
- [Configuration system](compositor-configuration-system.md)
- [Session contract](nucleus-session-contract.md)
- [Shell-agnostic compositor boundary](shell-architecture.md)
- [DRM color debugging](drm-color-debugging.md)
- [Accessibility](accessibility-architecture.md)

## Active plans, in dependency order

1. [RN networking, WebSocket, and Blob modules](rn-networking-and-websocket-plan.md)
2. [Android Swift/Java end-to-end qualification](android-swift-java-qualification.md)
3. [Android render stack](android-render-stack-plan.md)
4. [Native shell completion](../../shell/docs/native-shell-completion-plan.md)
5. [Screen capture and recording](screen_recording_plan.md)
6. [View pixel alignment](view-pixel-alignment-plan.md)
7. [Glyph dilation](text-glyph-dilation-plan.md)

## Superseded and completed plans

- [Bar-first shell work](bar-first-port-order.md) is superseded by the native shell completion plan.
- [AppKit API completion](appkit-api-plan.md) is complete; real-IME and lock-screen
  interaction remains an explicit user qualification handoff.
- [Wayland protocol coverage](wayland_protocol_coverage_plan.md) is complete for
  current consumers; future protocols require a named product consumer.
- [Trackpad gestures](compositor-trackpad-gestures.md) are complete.
- [RN animation backend](rn-animation-backend-plan.md) is complete.

## Research inventories

- [Linux kernel leverage](linux-kernel-leverage.md)
- [RN TurboModule inventory](rn-turbomodule-inventory.md)
- [Nvidia DRM observations](drm-scanout-nvidia.md)

Historical Zig, standalone-package, brand-migration, and completed refactor documents have been removed. The root [AGENTS.md](../../AGENTS.md) and [README.md](../../README.md) are authoritative for the current repository and build graph.
