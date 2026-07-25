# Nucleus Plans

This index records the lifecycle of every implementation plan in `docs/`.
`Status:` inside each plan is authoritative.

## Active

- [Collider CLI, Terminal UX, and TUI Foundations](collider-cli-ux-plan.md) —
  Collider exposes one typed execution, event, observation, control, and terminal
  presentation model.
- [Collider Ratatui TUI](collider-ratatui-tui-plan.md) — `collider-ui` remains a
  presentation-only client of Collider's external observation and control protocol.
- [Collider Storage Lifecycle](collider-storage-lifecycle-plan.md) — Collider
  deletes only generated storage whose ownership and inactivity it can prove.
- [Correctness and Maintainability Remediation](correctness-and-maintainability-remediation-plan.md) —
  every cross-language lifetime, persistent bound, hardware-loss state, and mandatory
  verification lane has one enforceable contract.
- [Nucleus Browser Custom UI](nucleus-browser-custom-ui-plan.md) — NucleusUI owns
  browser chrome while Chromium remains the authoritative web engine and process
  boundary.
- [Nucleus Browser](nucleus-browser-plan.md) — the browser presents Chromium's
  Graphite/Dawn/Vulkan output natively through Wayland without a fallback rendering
  path.
- [Nucleus Desktop OS and Android Integration](nucleus-desktop-android-integration-plan.md) —
  contained Android tasks enter the same compositor-owned Wayland scene through one
  brokered graphics and service architecture.
- [Nucleus Wayland Compositor Hardening](nucleus-wayland-compositor-hardening-plan.md) —
  every observable compositor boundary derives from one coherent topology,
  transaction, presentation, and lifecycle state.
- [Swift Toolchain Official Distribution Parity](swift-toolchain-official-distribution-parity-plan.md) —
  a published Nucleus toolchain contains the complete corresponding Swift.org product
  surface plus required Nucleus extensions.
- [Typed Wayland Code Generation](wayland-typed-codegen-plan.md) — Wayland XML is the
  sole source of mechanical protocol identity, typing, dispatch, creation, and event
  translation.

## Complete

- [Collider Repository CLI](collider-cli-plan.md) — Collider is the sole public
  repository workflow and artifact-control entry point.
- [Nucleus Foundation Follow-up](nucleus-foundation-follow-up-plan.md) — every
  retained UI host uses explicit context, service, publication, input, accessibility,
  and teardown ownership.
- [Nucleus Runtime Architecture Master Plan](nucleus-runtime-architecture-master-plan.md) —
  every mutable runtime subsystem has one explicit ownership, synchronization, and
  type boundary.
- [Nucleus Runtime Hardening](nucleus-runtime-hardening-plan.md) — runtime graphs,
  verification, sanitizers, deterministic time, and headless performance evidence have
  explicit owners and gates.
- [Nucleus UI Foundation Hardening](nucleus-ui-foundation-hardening-plan.md) — each
  semantic UI mutation has one authoritative retained-visual publication path.
- [Runtime Correctness and Simplification](runtime-correctness-and-simplification-plan.md) —
  render ownership, frame demand, transaction publication, and module seams have one
  authoritative implementation.
- [Swift 6.3 and 6.4 Modernization](swift-6-4-modernization-plan.md) — Swift 6.4,
  audited unsafe boundaries, narrow imports, and strict language settings form one
  repository baseline.
- [Wayland Main-Actor Isolation](wayland-main-actor-isolation-plan.md) — all mutable
  compositor-owned Wayland protocol state is synchronously isolated to `MainActor`.

## Superseded

No plan is currently superseded.
