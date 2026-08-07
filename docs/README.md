# Nucleus documentation

## Invariant

Architecture and contract documents describe the current system. An implementation plan begins with one lifecycle status: `active`, `deferred`, `complete`, or `superseded by <document>`. Deferred plans are valid future work but do not participate in the current execution sequence. Completed migration diaries are deleted once their durable invariants have moved into an architecture or contract document.

## Current architecture and contracts

- [Runtime architecture](nucleus-runtime-architecture.md)
- [Single-root SwiftPM architecture](single-root-swiftpm-architecture.md)
- [NucleusUI API contract](nucleus-ui-api-contract.md)
- [NucleusUI graphics contract](nucleus-ui-graphics-contract.md)
- [Core and compositor documentation](../core/docs/README.md)
- [Shell architecture](../shell/docs/shell-architecture.md)
- [Direct scanout](../compositor/compositor-core/docs/direct-scanout.md)
- [Render benchmarking](../compositor/docs/render-benchmarking.md)

## Active execution plans

Execute the implementation plans in this order:

1. [Manifest portability](manifest-portability-plan.md)
2. [Linux distribution portability](linux-distribution-portability-plan.md)
3. [Wayland dispatch isolation](wayland-dispatch-isolation-and-handler-binding-plan.md)
4. [Collider storage lifecycle](collider-storage-lifecycle-plan.md)
5. [Collider CLI and terminal UX](collider-cli-ux-plan.md)
6. [Android application integration](android-application-integration-plan.md)

Component implementation plans continue in the dependency order in
[core/docs/README.md](../core/docs/README.md).

Complete the remaining qualification plans after their corresponding
implementation inputs are available:

1. [Swift target SDK and Skia](swift-sdk-and-skia-qualification-plan.md)
2. [Visibility and native linking](visibility-and-native-link-qualification-plan.md)
3. [Wayland compositor residual behavior](wayland-compositor-residual-qualification-plan.md)
4. [Android container security](android-container-security-qualification-plan.md)
5. [Chromium and CEF products](chromium-cef-product-qualification-plan.md)
6. [Nucleus Browser](nucleus-browser-qualification-plan.md)

## Deferred product plans

- [Remote development and build hosts](github-actions-macos-builder-and-self-hosted-runner-plan.md)
- [Collider ratatui TUI](collider-ratatui-tui-plan.md)
- [Browser custom UI](nucleus-browser-custom-ui-plan.md)

## Research and qualification

- [Apple Silicon virtualization](apple-silicon-virtualization-target-plan.md) defines the macOS 27+ target and its prerequisite investigations. It is not part of the current implementation sequence.
- [Chromium/CEF](../chromium/README.md), [CEF](../cef/README.md), and [Android runtime](../android-runtime/README.md) contain component qualification commands and current runtime contracts.
