# Nucleus Plans

## Invariant

Every implementation plan has one root lifecycle status: `active`, `complete`,
or `superseded by <kebab-case.md>`. The status inside the plan is authoritative.
This index covers first-party plans under `docs/`, `core/docs/`, and
`shell/docs/`; generated, vendored, and materialized upstream plans are outside
the Nucleus documentation lifecycle.

An active plan may be implementation-ready, blocked on a named prerequisite,
or require a current-tree rebase. The sections below make that distinction
without inventing additional lifecycle values.

## Active and Current

- [Android Application Integration](android-application-integration-plan.md) —
  production runtime and bridge work has landed; native application
  publication, per-application presentation, lifecycle, clipboard, and
  notifications remain.
- [Android Container Security Boundary](android-container-security-boundary-plan.md) —
  implementation Phases 1–9 are complete; Phase 10 end-to-end qualification
  remains.
- [Chromium and CEF Fork-Commit Migration](chromium-cef-fork-commit-migration-plan.md) —
  source and container cutovers have landed; optimized product and live
  qualification remain.
- [Collider Storage Lifecycle](collider-storage-lifecycle-plan.md) — storage
  ownership, inventory, transactions, retention, pruning, and component
  cleaning remain after the verification foundation.
- [Correctness and Maintainability Remediation](correctness-and-maintainability-remediation-plan.md) —
  Phases 1–9 are complete; Phase 10 owns documentation lifecycle closure.
- [Remote Development, macOS Builder, and Self-Hosted Runner](github-actions-macos-builder-and-self-hosted-runner-plan.md) —
  trust routing and backend-neutral OCI foundations have landed; M2 host,
  remote development, resource admission, qualification, and publication
  remain.
- [Manifest Portability and Swift SDK](manifest-portability-and-swift-sdk-plan.md) —
  the root manifest still requires a provisioned environment to evaluate; target
  settings collapse, host Swift SDK bundling, guard deletion, package-graph
  settling, and bootstrap closure all remain.
- [Render Value Vocabulary Unification](render-value-vocabulary-unification-plan.md) —
  canonical shared values, direct Swift transaction batches, and explicit
  renderer lowering have landed; final build and behavior qualification remains.
- [Visibility and Seam Contract](visibility-and-seam-contract-plan.md) — five
  `@_spi` groups describe boundaries a single root package already expresses;
  contract statement, group removal, `package` conversion, product-API
  reduction, and shim deletion all remain.
- [Nucleus Browser](nucleus-browser-plan.md) — fork-backed source,
  Graphite/Dawn/Vulkan presentation, and packaging are advanced; optimized
  builds and live hardware acceptance remain.
- [Swift Toolchain and Skia Fork-Commit Migration](swift-toolchain-and-skia-fork-commit-migration-plan.md) —
  fork-backed source and builder foundations have landed; Swift, SwiftAndroid,
  and Skia qualification plus obsolete pipeline deletion remain.
- [Swift Toolchain Official Distribution Parity](swift-toolchain-official-distribution-parity-plan.md) —
  the product surface is implemented; fresh Linux and macOS qualification
  remains.

## Active but Blocked on a Prerequisite

- [RN Networking, WebSocket, and Blob Native Modules](../core/docs/rn-networking-and-websocket-plan.md) —
  starts with the async JS-dispatch foundation; the planned native networking
  modules have not landed.
- [Collider Ratatui TUI](collider-ratatui-tui-plan.md) — blocked on completion
  of the Collider external observation and control protocol.
- [Nucleus Browser Custom UI](nucleus-browser-custom-ui-plan.md) — follows the
  authoritative browser engine/presentation plan and required NucleusUI
  authoring capabilities.
- [Wayland Dispatch Isolation and Handler Binding](wayland-dispatch-isolation-and-handler-binding-plan.md) —
  the selected dispatch refactor is planned but not implemented.

## Active and Requiring a Current-Tree Rebase

- [Android Render Stack](../core/docs/android-render-stack-plan.md) — Phases
  1–4 are historical completion evidence; Phases 5–6 require current `core/`,
  React Native, SwiftAndroid, and Collider ownership.
- [AppKit API](../core/docs/appkit-api-plan.md) — Phases 0–9 are complete,
  Phase 10 remains, and Phases 11–12 are superseded by
  `core/docs/ui-authoring-model.md`.
- [Native Screen Capture and Recording](../core/docs/screen_recording_plan.md) —
  typed screencopy exists, but the remaining Zig-era engine and package map
  must be rewritten for the Swift/C++ compositor and current portal/media
  boundaries.
- [Wayland Protocol Coverage](../core/docs/wayland_protocol_coverage_plan.md) —
  regenerate its implemented/pending inventory from the selected XML and
  registered globals before starting another batch.
- [Collider CLI, Terminal UX, and TUI Foundations](collider-cli-ux-plan.md) —
  existing run/task/log infrastructure is prerequisite work; phase completion
  and the external observation/control protocol remain unproven.
- [Collider Task Engine and Package Root](collider-task-engine-and-package-root-plan.md) —
  re-audit package topology after framework unification and OCI execution;
  undeclared-input verification, recoverable outputs, and capacity scheduling
  remain valid work.
- [Nucleus Wayland Compositor Hardening](nucleus-wayland-compositor-hardening-plan.md) —
  remove findings already satisfied by framework unification, then execute the
  remaining protocol, KMS, redraw, and hostile-client gates.
- [Noctalia-to-Nucleus Shell Migration](../shell/docs/noctalia-migration-plan.md) —
  rebuild the responsibility ledger against the current shell and services
  before transferring another product surface.
- [RN Shared Animated Backend](../core/docs/rn-animation-backend-plan.md) —
  rebase the unimplemented choreographer design onto the current Fabric host
  and desktop/Android presentation clocks.
- [Luminance-Based Glyph Dilation](../core/docs/text-glyph-dilation-plan.md) —
  re-audit the current text, Graphite, glyph-cache, and color ownership before
  selecting the retained custom-atlas design.
- [View Pixel Alignment](../core/docs/view-pixel-alignment-plan.md) — rebase
  the valid per-window backing-space contract onto current NucleusUI geometry,
  window scale, text, and shell call sites.

## Complete

- [Collider Repository CLI](collider-cli-plan.md) — Collider is the sole public
  repository workflow and artifact-control entry point.
- [Nucleus Foundation Follow-up](nucleus-foundation-follow-up-plan.md) — UI
  context, service, publication, input, accessibility, and teardown ownership
  are complete.
- [Nucleus Framework and Display Architecture](nucleus-framework-unification-plan.md) —
  all 11 framework, process, presentation, shell, and installation phases are
  complete.
- [Nucleus Fork and Upstream Commit Migration](nucleus-os-fork-commit-migration-plan.md) —
  AOSP source is selected through genuine fork commits with no patch
  materialization path.
- [Nucleus Runtime Architecture Master Plan](nucleus-runtime-architecture-master-plan.md) —
  all 11 ownership and runtime phases are complete.
- [Nucleus Runtime Hardening](nucleus-runtime-hardening-plan.md) — runtime
  ownership, verification, sanitizer, deterministic-time, and performance
  contracts are complete.
- [Nucleus UI Foundation Hardening](nucleus-ui-foundation-hardening-plan.md) —
  retained UI and publication foundations are complete.
- [Runtime Correctness and Simplification](runtime-correctness-and-simplification-plan.md) —
  runtime correctness and authoritative-path cleanup are complete.
- [Swift 6.3 and 6.4 Modernization](swift-6-4-modernization-plan.md) — Swift
  6.4, strict language features, and audited unsafe boundaries are the current
  baseline.
- [Wayland Client Proxy and Resource Safety](wayland-client-proxy-and-resource-safety-plan.md) —
  all 11 client/resource safety phases are complete.
- [Wayland Main-Actor Isolation](wayland-main-actor-isolation-plan.md) — all
  mutable compositor-owned Wayland state follows the selected isolation model.
- [Typed Wayland Code Generation](wayland-typed-codegen-plan.md) — all 10 typed
  protocol model, dispatch, creation, and event-generation phases are complete.

## Superseded

- [Nucleus Toolchain and SDK CI/CD](../core/docs/toolchain-sdk-ci-cd-plan.md) —
  superseded by the GitHub Actions, M2 builder, and remote-development plan;
  retained only for historical release-contract analysis.
- [Android Runtime Production Security](android-runtime-production-security-plan.md) —
  superseded by the label-neutral Android container security plan; its threat
  model and broker/build-boundary analysis remain reference material.
- [Nucleus Desktop OS and Android Integration](nucleus-desktop-android-integration-plan.md) —
  superseded by Android Application Integration; its completed graphics and
  initial bring-up evidence remains historical reference material.
