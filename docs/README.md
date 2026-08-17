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

Execute these phases in the declared order. Production artifact identity,
qualification, packaging, CI, signing, publication, and distribution establish
the contracts that development deployment and independent contributor hosts
reuse.

1. Complete Phases 2 through 5 of the
   [GitHub Actions self-hosted CI plan](github-actions-self-hosted-runner-plan.md):
   establish the protected main-only workflow boundary, provision the
   `nucleus-builder` account on the M2 Ultra, move automated `main` and locally
   initiated clean, branch, dirty, debug, and release builds onto its shared
   persistent Collider cache, and enforce source, account, credential, network,
   and recovery boundaries.
2. Complete the four phases of the
   [Apple Swift package adoption plan](swift-package-adoption-plan.md): replace
   the exposed complete-span byte readers with `swift-binary-parsing`, replace
   parallel keyed and ordering state with ordered collections, move residual
   manual locks onto standard-library synchronization, and replace the Collider
   progress side task with one explicitly terminating merged sequence.
3. Complete Phases 5 and 6 of the
   [Linux package distribution and update plan](linux-package-distribution-and-update-plan.md)
   to assemble signed repository snapshots offline and remove Collider's
   remaining product-installation commands.
4. Complete Phases 6 and 7 of the
   [Linux distribution portability plan](linux-distribution-portability-plan.md)
   using the exact native package cohorts: first qualify one unchanged artifact
   across distributions, then qualify both architectures on physical hardware.
5. Complete the remaining qualification plans in the order listed below. Their
   agent-runnable gates bind native, physical, security, and product evidence to
   the package cohorts before CI cutover.
6. Complete Phases 6 and 7 of the
   [GitHub Actions self-hosted CI plan](github-actions-self-hosted-runner-plan.md)
   to bind the complete verification graph to immutable artifacts and cut over
   main-only verification and delivery inputs.
7. Complete Phase 7 of the
   [Linux package distribution and update plan](linux-package-distribution-and-update-plan.md)
   to publish qualified repository cohorts through the separated GitHub Release
   and R2 authorities.
8. Complete Phase 8 of the
   [GitHub Actions self-hosted CI plan](github-actions-self-hosted-runner-plan.md)
   against the native package, repository, and qualification pipeline.
9. Complete Phase 8 of the
   [Linux package distribution and update plan](linux-package-distribution-and-update-plan.md)
   to publish and qualify native update lifecycles.
10. Complete Phase 9 of the
   [Linux package distribution and update plan](linux-package-distribution-and-update-plan.md)
   to add non-installed remote development generations over the established
   product-artifact contract.
11. Complete Phases 2 through 6 of
    [macOS remote development](macos-remote-development-plan.md), including the
    private-host, session-continuity, admission, presentation-target, and final
    cutover gates.
12. Complete Phases 3 through 10 of the
    [Linux x86_64 development host plan](linux-x86-64-development-host-plan.md).
    The contributor-input contract reuses portable identity primitives without
    becoming a product package, CI cache, release object, or publication path.

Component implementation plans continue in the dependency order in
[core/docs/README.md](../core/docs/README.md).

Step 5 executes these qualification plans after their corresponding
implementation inputs are available:

1. [Swift target SDK and Skia](swift-sdk-and-skia-qualification-plan.md)
2. [Visibility and native linking](visibility-and-native-link-qualification-plan.md)
3. [Wayland compositor residual behavior](wayland-compositor-residual-qualification-plan.md)
4. [Android application integration](android-application-integration-plan.md)
5. [Android container security](android-container-security-qualification-plan.md)
6. [Chromium and CEF products](chromium-cef-product-qualification-plan.md)
7. [Nucleus Browser](nucleus-browser-qualification-plan.md)

## Completed architecture consolidation

- [Collider throughput optimization](collider-throughput-optimization-plan.md)
  established concurrent architecture packaging, single-materialization
  payloads, independently cached family adapters, bounded control-only batches,
  deterministic fast compression, narrow packaging-tool relinking, measured
  package stages, and zero-write product-store reuse.
- [Runtime test seam consolidation](runtime-test-seam-consolidation-plan.md)
  removed alternate runtime invariants, silent in-memory defaults, production
  test factories and hooks, injected native allocators, and test support from
  production source trees.
- [macOS host storage consolidation](macos-host-storage-consolidation-plan.md)
  established the conventional per-user host layout and removed custom APFS
  volume policy.

## Deferred product plans

- [Collider ratatui TUI](collider-ratatui-tui-plan.md)
- [Browser custom UI](nucleus-browser-custom-ui-plan.md)

## Research and qualification

- [Apple Silicon virtualization](apple-silicon-virtualization-target-plan.md) defines the macOS 27+ target and its prerequisite investigations. It is not part of the current implementation sequence.
- [Chromium/CEF](../chromium/README.md), [CEF](../cef/README.md), and [Android runtime](../android-runtime/README.md) contain component qualification commands and current runtime contracts.
