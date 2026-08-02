# Nucleus documentation

## Invariant

Architecture and contract documents describe the current system. An implementation plan begins with one lifecycle status: `active`, `complete`, or `superseded by <document>`. Completed migration diaries are deleted once their durable invariants have moved into an architecture or contract document.

## Current architecture and contracts

- [Runtime architecture](nucleus-runtime-architecture-master-plan.md)
- [Single-root SwiftPM architecture](single-root-swiftpm-architecture.md)
- [NucleusUI API contract](nucleus-ui-api-contract.md)
- [NucleusUI graphics contract](nucleus-ui-graphics-contract.md)
- [Apple Silicon virtualization target](apple-silicon-virtualization-target-plan.md)
- [Core and compositor documentation](../core/docs/README.md)
- [Shell architecture](../shell/docs/shell-architecture.md)
- [Direct scanout](../compositor/compositor-core/docs/direct-scanout.md)
- [Render benchmarking](../compositor/docs/render-benchmarking.md)

## Active execution plans

Execute prerequisite work before dependent product work:

1. [Swift target-SDK workspace](swift-toolchain-incremental-workspace-plan.md)
2. [Swift target SDK and Skia fork qualification](swift-toolchain-and-skia-fork-commit-migration-plan.md)
3. [Manifest portability and Swift SDK](manifest-portability-and-swift-sdk-plan.md)
4. [Remote development and build hosts](github-actions-macos-builder-and-self-hosted-runner-plan.md)
5. [Collider kernel, planning, and execution](collider-kernel-boundary-refactor.md)
6. [Collider storage lifecycle](collider-storage-lifecycle-plan.md)
7. [Collider CLI and terminal UX](collider-cli-ux-plan.md)
8. [Collider ratatui TUI](collider-ratatui-tui-plan.md)
9. [Visibility and seam contract](visibility-and-seam-contract-plan.md)
10. [Render value vocabulary](render-value-vocabulary-unification-plan.md)
11. [Wayland dispatch isolation](wayland-dispatch-isolation-and-handler-binding-plan.md)
12. [Wayland compositor hardening](nucleus-wayland-compositor-hardening-plan.md)
13. [Android container security](android-container-security-boundary-plan.md)
14. [Android application integration](android-application-integration-plan.md)
15. [Chromium and CEF fork migration](chromium-cef-fork-commit-migration-plan.md)
16. [Browser engine and presentation](nucleus-browser-plan.md)
17. [Browser custom UI](nucleus-browser-custom-ui-plan.md)

Component-level active plans are indexed in [core/docs/README.md](../core/docs/README.md) and [shell/docs](../shell/docs/shell-architecture.md).

## Research and qualification

- [Apple Silicon virtualization](apple-silicon-virtualization-target-plan.md) defines the macOS 27+ target and its prerequisite investigations.
- [Chromium/CEF](../chromium/README.md), [CEF](../cef/README.md), and [Android runtime](../android-runtime/README.md) contain component qualification commands and current runtime contracts.
