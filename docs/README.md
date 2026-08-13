# Nucleus documentation

## Invariant

Architecture and contract documents describe the current system. An implementation plan begins with one lifecycle status: `active`, `deferred`, `complete`, or `superseded by <document>`. Deferred plans are valid future work but do not participate in the current execution sequence. Completed migration diaries are deleted once their durable invariants have moved into an architecture or contract document.

## Current architecture and contracts

- [Runtime architecture](nucleus-runtime-architecture.md)
- [Single-root SwiftPM architecture](single-root-swiftpm-architecture.md)
- [Collider architecture](collider-architecture.md)
- [NucleusUI API contract](nucleus-ui-api-contract.md)
- [NucleusUI graphics contract](nucleus-ui-graphics-contract.md)
- [Core and compositor documentation](../core/docs/README.md)
- [Shell architecture](../shell/docs/shell-architecture.md)
- [Direct scanout](../compositor/compositor-core/docs/direct-scanout.md)
- [Render benchmarking](../compositor/docs/render-benchmarking.md)
- [Collider build storage](collider-build-storage-architecture.md)
- [NucleusStorage volume](nucleus-storage-volume.md)
- [Swift Wayland architecture](../swift-wayland/ARCHITECTURE.md)

## Active execution plans

Execute the implementation plans in this order:

1. Complete Phases 2 through 4 of
   [macOS remote development](macos-remote-development-plan.md).
2. Execute the
   [Linux package distribution and update plan](linux-package-distribution-and-update-plan.md)
   in order. Its Phase 2 satisfies Phase 5 of the remote-development plan;
   complete remote-development Phase 6 immediately afterward, then continue the
   package plan at Phase 3.
3. Execute the
   [Linux x86_64 development host plan](linux-x86-64-development-host-plan.md)
   in order. It adds an independent contributor workflow without replacing the
   M2 Ultra development, CI, or publication roles.

Component implementation plans continue in the dependency order in
[core/docs/README.md](../core/docs/README.md).

Complete the remaining qualification plans after their corresponding
implementation inputs are available:

1. [Swift target SDK and Skia](swift-sdk-and-skia-qualification-plan.md)
2. [Visibility and native linking](visibility-and-native-link-qualification-plan.md)
3. [Wayland compositor residual behavior](wayland-compositor-residual-qualification-plan.md)
4. [Android application integration](android-application-integration-plan.md)
5. [Android container security](android-container-security-qualification-plan.md)
6. [Chromium and CEF products](chromium-cef-product-qualification-plan.md)
7. [Nucleus Browser](nucleus-browser-qualification-plan.md)

## Completed architecture consolidation

- [Runtime test seam consolidation](runtime-test-seam-consolidation-plan.md)
  removed alternate runtime invariants, silent in-memory defaults, production
  test factories and hooks, injected native allocators, and test support from
  production source trees.
- [macOS host storage consolidation](macos-host-storage-consolidation-plan.md)
  established the conventional per-user host layout and removed custom APFS
  volume policy.

## Deferred product plans

- [Linux distribution portability qualification](linux-distribution-portability-plan.md)
- [GitHub Actions self-hosted CI](github-actions-self-hosted-runner-plan.md)
- [Collider ratatui TUI](collider-ratatui-tui-plan.md)
- [Browser custom UI](nucleus-browser-custom-ui-plan.md)

## Research and qualification

- [Apple Silicon virtualization](apple-silicon-virtualization-target-plan.md) defines the macOS 27+ target and its prerequisite investigations. It is not part of the current implementation sequence.
- [Chromium/CEF](../chromium/README.md), [CEF](../cef/README.md), and [Android runtime](../android-runtime/README.md) contain component qualification commands and current runtime contracts.
