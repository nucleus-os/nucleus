# Nucleus documentation

## Invariant

Architecture and contract documents describe the current system. An implementation plan begins with one lifecycle status: `active`, `deferred`, `complete`, or `superseded by <document>`. Deferred plans are valid future work but do not participate in the current execution sequence. Completed migration diaries are deleted once their durable invariants have moved into an architecture or contract document.

## Current architecture and contracts

- [Runtime architecture](nucleus-runtime-architecture.md)
- [Single-root SwiftPM architecture](single-root-swiftpm-architecture.md)
- [Collider architecture](collider-architecture.md)
- [SwiftPM overlay driver](swiftpm-overlay-driver-architecture.md)
- [NucleusUI API contract](nucleus-ui-api-contract.md)
- [NucleusUI graphics contract](nucleus-ui-graphics-contract.md)
- [Application runtime](app-runtime-roadmap.md)
- [UI authoring model](ui-authoring-model.md)
- [Bounds-origin model](bounds-origin-model.md)
- [Image loading](image-file-loading.md)
- [Configuration system](compositor-configuration-system.md)
- [Session contract](nucleus-session-contract.md)
- [Shell-agnostic compositor boundary](shell-agnostic-compositor-architecture.md)
- [Shell architecture](shell-architecture.md)
- [Direct scanout](direct-scanout.md)
- [Render benchmarking](render-benchmarking.md)
- [DRM color debugging](drm-color-debugging.md)
- [Accessibility](accessibility-architecture.md)
- [Collider build storage](collider-build-storage-architecture.md)
- [NucleusStorage volume](nucleus-storage-volume.md)
- [Swift Wayland architecture](swift-wayland-architecture.md)

## Active execution plans

Execute these phases in the declared order. Production artifact identity,
qualification, packaging, CI, signing, publication, and distribution establish
the contracts that development deployment and independent contributor hosts
reuse.

1. Complete the remaining gates in Phases 4 and 5 of the
   [GitHub Actions self-hosted CI plan](github-actions-self-hosted-runner-plan.md):
   the protected-main host-contract, provenance, build, and test lanes already
   run successfully, and the installed root boot coordinator restores the
   builder-domain container and runner services without an interactive login.
   Prove the corrected local-to-automated warm-state reuse, exercise a real host
   restart, and complete the container-network, quarantine, and recovery gates.
2. Complete the product-execution portions of the
   [placement-independent build plan](placement-independent-build-plan.md) so
   that no delivered-product build tool receives a host path, remove the
   product-side interim corrections, and record the CI cache-hit gate as its
   second-checkout proof. Its macOS host-tool VM phase remains deferred until
   host execution produces a delivered artifact.
3. Extend Phases 6 and 7 of the
   [GitHub Actions self-hosted CI plan](github-actions-self-hosted-runner-plan.md)
   through protected-main Linux-runtime packaging. An actual
   `collider package linux-runtime` execution closes the remaining half of Phase
   5 of the [Android architecture parity plan](android-architecture-parity-plan.md):
   both AOSP products and both complete six-member native package cohorts already
   come from graph-owned inputs. Physical Android qualification remains outside
   this packaging gate.
4. Complete Phases 5 and 6 of the
   [Linux package distribution and update plan](linux-package-distribution-and-update-plan.md)
   to reserve immutable `YYYY.MM.DD.N` nightly versions, finalize and qualify
   the exact version-bearing cohorts, assemble signed repository snapshots
   offline, and remove Collider's remaining product-installation commands.
5. Complete Phases 6 through 8 of the
   [build store retention plan](build-store-retention-plan.md). Phases 1 through
   5 already bound SwiftPM identity contexts on every run and brought the
   container store under collection; the first collecting prune returned 411.9
   GiB. Make interactive inspection read the store directly, declare residency
   for every materialized source root, and report recorded allocation before the
   long-running qualification matrices begin.
6. Complete Phases 1 through 5 of the
   [Android native arm64 host toolchain plan](android-native-arm64-host-toolchain-plan.md).
   Protected-main packaging does not wait for this reliability work. Measure the
   translated host workload against the existing generations, then supply the
   missing native host toolchains and prove both products without translation
   before unattended Android qualification can be accepted.
7. Complete Phase 6 of the
   [Linux distribution portability plan](linux-distribution-portability-plan.md)
   using the signed local repository snapshots: qualify each unchanged artifact
   digest across the declared distribution matrix without rebuilding it.
8. Complete the remaining qualification plans in the order listed below. Their
   agent-runnable gates bind native, physical, security, and product evidence to
   the package cohorts, and complete the qualification portion of the
   protected-main verification graph.
9. Complete Phase 7 of the
   [Linux distribution portability plan](linux-distribution-portability-plan.md)
   on physical arm64 and x86_64 hardware. After the Android application and
   container-security gates are complete, execute Phase 6 of the
   [Android architecture parity plan](android-architecture-parity-plan.md) on
   physical arm64 hardware as part of the same hardware-qualification stage.
10. Complete Phase 7 of the
   [Linux package distribution and update plan](linux-package-distribution-and-update-plan.md)
   to publish qualified repository cohorts through the separated GitHub Release
   and R2 authorities.
11. Complete Phase 8 of the
    [GitHub Actions self-hosted CI plan](github-actions-self-hosted-runner-plan.md)
   against the native package, repository, and qualification pipeline.
12. Complete Phase 8 of the
    [Linux package distribution and update plan](linux-package-distribution-and-update-plan.md)
   to publish and qualify the nightly native update lifecycle.
13. Complete the
    [Collider architecture simplification plan](collider-architecture-simplification-plan.md)
    after the nightly lifecycle fixes the build, packaging, qualification, and
    publication contracts. Decompose catalog construction, storage policy,
    package assembly, recipe ownership, and command execution policy before
    adding new development-host execution surfaces.
14. Complete Phase 9 of the
    [Linux package distribution and update plan](linux-package-distribution-and-update-plan.md)
   to add non-installed remote development generations over the established
   product-artifact contract.
15. Complete Phases 2 through 6 of
    [macOS remote development](macos-remote-development-plan.md), including the
    private-host, session-continuity, admission, presentation-target, and final
    cutover gates.
16. Complete Phases 3 through 10 of the
    [Linux x86_64 development host plan](linux-x86-64-development-host-plan.md).
    The contributor-input contract reuses portable identity primitives without
    becoming a product package, CI cache, release object, or publication path.

### Component implementation plans

After the product and host foundations above, execute these component plans in
dependency order:

1. [RN networking, WebSocket, and Blob modules](rn-networking-and-websocket-plan.md)
2. [Android Swift/Java end-to-end qualification](android-swift-java-qualification.md)
3. [Android render stack](android-render-stack-plan.md)
4. [Render concurrency and presentation pipeline](render-concurrency-and-presentation-pipeline-plan.md)
5. [GPU driver capability adoption](gpu-driver-capability-adoption-plan.md)
6. [Native shell completion](native-shell-completion-plan.md)
7. [Screen capture and recording](screen-recording-plan.md)
8. [View pixel alignment](view-pixel-alignment-plan.md)
9. [Glyph dilation](text-glyph-dilation-plan.md)

### Qualification sequence

Step 8 executes these qualification plans after their corresponding
implementation inputs are available:

17. [Swift target SDK and Skia](swift-sdk-and-skia-qualification-plan.md)
18. [Visibility and native linking](visibility-and-native-link-qualification-plan.md)
19. [Wayland compositor residual behavior](wayland-compositor-residual-qualification-plan.md)
20. [Android application integration](android-application-integration-plan.md)
21. [Android container security](android-container-security-qualification-plan.md)
22. [Chromium and CEF products](chromium-cef-product-qualification-plan.md)
23. [Nucleus Browser](nucleus-browser-qualification-plan.md)

Step 9 consumes the completed Android application-integration and
container-security gates before accepting Android architecture parity Phase 6;
cross-architecture inspection and translated execution never substitute for
that physical arm64 result.

## Completed architecture consolidation

- [Container mount scope](container-mount-scope-plan.md) gave every container
  the mounts its task declares rather than the checkout root, taking a complete
  packaging run from exhausting the host open-file table to ten percent of it;
  made a run superseded only by a change to source it read rather than by any
  change in the checkout; and made an execution that reaches what its action
  did not declare fail before it starts.
- [Swift target SDK Ubuntu rebase](swift-target-sdk-ubuntu-rebase-plan.md)
  built the Linux target sysroot from the release the builder image runs, moved
  the ABI baseline to the glibc that sysroot carries, and closed the sysroot
  over both graphs that decide what a product may link: the pkg-config graph a
  `.pc` file's `Requires.private` declares, and the transitive dynamic closure
  payload assembly walks.
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
- [Collider process execution](collider-process-execution-plan.md) put every
  child process on one concurrently drained mechanism, made the source-identity
  path async so planning no longer blocks a cooperative thread, gave the
  persistence and command layers an execution entry point, and left one
  definition of what environment a child may inherit.
- [Apple Swift package adoption](swift-package-adoption-plan.md) moved the
  exposed complete-span byte readers onto `swift-binary-parsing` and generated
  `SwiftProtobuf` types, replaced parallel keyed and ordering state with ordered
  collections and a deque, moved every residual manual lock onto
  standard-library `Mutex`, and replaced the Collider progress side task with
  one explicitly terminating merged sequence.
- [Bar-first shell work](bar-first-port-order.md) is superseded by the native
  shell completion plan.
- [AppKit API completion](appkit-api-plan.md) is complete; real-IME and
  lock-screen interaction remains an explicit user qualification handoff.
- [Wayland protocol coverage](wayland-protocol-coverage-plan.md) is complete for
  current consumers; future protocols require a named product consumer.
- [Trackpad gestures](compositor-trackpad-gestures.md) are complete.
- [RN animation backend](rn-animation-backend-plan.md) is complete.

## Deferred product plans

- [Collider ratatui TUI](collider-ratatui-tui-plan.md)
- [Browser custom UI](nucleus-browser-custom-ui-plan.md)
- [Multi-channel release promotion](multi-channel-release-promotion-plan.md)

## Research and qualification

- [Apple Silicon virtualization](apple-silicon-virtualization-target-plan.md) defines the macOS 27+ target and its prerequisite investigations. It is not part of the current implementation sequence.
- [Linux kernel leverage](linux-kernel-leverage.md)
- [RN TurboModule inventory](rn-turbomodule-inventory.md)
- [Nvidia DRM observations](drm-scanout-nvidia.md)
- [Compositor hardware qualification](compositor-followups.md)
- [WWDC26 Swift what's new transcript](wwdc26-swift-whatsnew.txt)
- [Chromium/CEF](../chromium/README.md), [CEF](../cef/README.md), and [Android runtime](../android-runtime/README.md) contain component qualification commands and current runtime contracts.
