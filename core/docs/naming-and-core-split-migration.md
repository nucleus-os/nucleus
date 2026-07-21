# Naming Collapse & Core/Compositor Split — Migration Plan

Actionable companion to `docs/app-runtime-roadmap.md` (the strategic north
star). This doc is the surgical "how": every target's new name, which package
it lands in, and the order the moves happen in. Grounded in the current package
layout (root `Package.swift`, `compositor/Package.swift`,
`platform-android/Package.swift`); Phase 2 adds a fourth package,
`compositor-core/`, for the Linux compositor library (see the invariant).

## Invariant (end state)

- **One brand: Nucleus.** Products are **Nucleus** (the app framework you build
  with), **Nucleus Compositor** (the Wayland compositor / WM), and **nucleusOS**
  (the distro). No `Nucleon` or `Valence` names survive anywhere — brand, code,
  C ABI, artifacts, or docs.
- **Three code layers, one uniform brand prefix per module:**
  | Layer | Module prefix | C ABI | Artifact | Package |
  |---|---|---|---|---|
  | Portable core (shared by app + compositor) | `Nucleus*` | `nucleus_*` | `libnucleus-*` | root |
  | App framework (developer surface) | `NucleusApp*`, plus `NucleusUI` for the design-system/component module | `nucleus_app_*` | `libnucleus-app-*` | root |
  | Compositor | `NucleusCompositor*` | `nucleus_compositor_*` | `libnucleus-compositor-*` | `compositor-core/` (library) + `compositor/` (executable) |
- **Four packages, one per role — each platform backend is its own package.**
  `root` (portable core + app framework — the app-runtime product), `compositor-core`
  (the Linux compositor library: Wayland/DRM/input substrate + window/seat policy +
  shell + DRM/KMS presentation, tested, no `swift-system`), `compositor` (the
  `NucleusCompositor` executable + the io_uring composition root over `swift-system`),
  and `platform-android` (the Android backend). This is the roadmap's "every OS is an
  additive backend" architecture made literal: the Linux substrate becomes its own
  package, symmetric with `platform-android`. `compositor-core` is split out from
  `compositor` because a tested, cxx-interop substrate cannot co-habit with
  `swift-system` (`swift test` builds the whole package under the global cxx flag,
  which `swift-system` cannot tolerate) — the same constraint that first carved
  `compositor` out of root.
- **The root package is a pure portable graph** — core + app framework, with
  **zero** `pkg-config` resolution of Wayland / DRM / GBM / xcb / libinput /
  libseat / libudev / libsystemd. All OS substrate lives in `compositor-core/`.
- **No core or app-framework target depends on a compositor target or a
  compositor system library.** Dependency flows one way: `compositor` →
  `compositor-core` → app framework → core. (The compositor shell/overlay is itself
  a Nucleus app, so it consumes the app framework — that direction is correct.)
  Where the compositor needs Nucleon core internals, it consumes them through the
  **`@_spi(NucleusCompositor)`** contract — a first-party privileged surface that
  crosses the package (and, later, repo) boundary without entering the third-party
  public API. This replaces the `package` access that only worked when everything
  lived in one package.
- **`Dynamics` → `Layers`** (it is the Core Animation analog: an animated
  retained-mode layer tree). **`Substrate` text registry → `TextRegistry`**.
  "Substrate" is retired as a concept word; the per-platform app foundation is
  the **platform backend** (roadmap terminology).
- `platform-android` is already clean (`NucleusAndroidC/Core/JNI`, no
  Wayland/DRM) and needs no target moves.

## Swift-idiom rules (govern every name below)

The module is the namespace; names follow from taking that seriously.

1. **Uniform brand prefix on module names.** Every module is `Nucleus…` (the
   Firebase/AWS multi-module-SDK pattern), including the compositor
   (`NucleusCompositor*`). A bare module name (`Compositor`, `Renderer`,
   `Layers`) would collide in the global module namespace; the prefix is only
   seen at `import` lines, so consistency and collision-safety win over brevity.
2. **Bare type names inside modules.** The module namespaces the type — do not
   echo the module or brand in the type name. Inside `NucleusLayers`,
   `LayerTransaction` → `Transaction`, `NucleonDynamicsHost` → `Host`,
   `DynamicsGeometry` → `Geometry`, `DynamicsSettings` → `Settings`,
   `NucleonDirectBridge` → `DirectBridge`. Call sites read `Layers.Transaction`,
   not `NucleonDynamicsLayerTransaction`.
3. **Stdlib-collision exception.** Keep a light qualifier only where a bare name
   collides with the standard library or a common type: `DynamicsError` →
   `LayerError` (not bare `Error`); likewise avoid bare `Task`, `Result`,
   `Notification`.
4. **One front door.** The primary module re-exports the common surface with
   `@_exported import`, so `import NucleusUI` gets the 90% case (the SwiftUI
   ergonomic) and granular modules remain available for advanced use.
5. **Mirror the platform idiom per side** (per CLAUDE.md): the app framework
   rhymes with SwiftUI (`App`, `Scene`, `WindowGroup`-shaped entry vocabulary);
   the compositor's bare types rhyme with the macOS window server (`Window`,
   `Surface`, `Space`, `Connection`).
6. **Swift casing for acronyms.** `UI`, `IPC`, `JNI`, `URL` stay uppercased in
   type and module names (`NucleusUI`, not `NucleusUi`).

## Naming decisions (settled)

- App-framework host layer is `NucleusApp*`, not bare `Nucleus*` — the core
  already owns `Nucleus*`, running the prefix across the real members
  (`HostBundle`, `HostProtocols`) reads correctly as "App", and `NucleusApp` is
  the natural home for the SwiftUI-shaped `App`/`Scene` entry vocabulary.
- The single design-system/component module keeps the `UI` name (`NucleusUI`),
  the SwiftUI-within-the-app-framework analog and the front-door module.
- Compositor modules are `NucleusCompositor*` (not bare `Compositor*`). The
  uniform-prefix Swift-SDK idiom (rule 1) beats the shorter local prefix; the
  prefix is only seen at import sites since inner types stay bare, and it removes
  the Swift-vs-C-ABI mismatch. The product is still "Nucleus Compositor".

## Target disposition

### A. Core renames (stay in root, `Nucleus*`)

| Current | New | Notes |
|---|---|---|
| `NucleonDynamics` | `NucleusLayers` | + strip type prefixes (rule 2): `LayerTransaction`→`Transaction`, `DynamicsGeometry`→`Geometry`, `DynamicsSettings`→`Settings`, `NucleonDynamicsHost`→`Host`, `DynamicsError`→`LayerError`; `NUCLEON_DYNAMICS_PUBLIC_NAMES`→`NUCLEUS_LAYERS_PUBLIC_NAMES` |
| `NucleonTypes` | `NucleusTypes` | **keep as its own module** (grounded) — it is the cycle-breaker between `NucleonHostProtocols` and `NucleonDynamics`, and the shared value-type vocabulary for ~20 modules across core/app/compositor; folding it into Layers would cycle |
| `NucleonTextCxxBridge` | `NucleusTextCxxBridge` | |
| `NucleonRenderModel` | `NucleusRenderModel` | |
| `NucleonRenderHost` | `NucleusRenderHost` | |
| `NucleonRenderer` | `NucleusRenderer` | keystone; already backend-abstracted, proven cross-platform via Android. It already contains `RenderCore` — the portable render-runtime owner (no DRM/GBM/swapchain) |
| `NucleusSubstrateTextRegistry` | `NucleusTextRegistry` | + `SubstrateTextRegistry.cpp/.hpp` → `TextRegistry.*`, `registerParagraphForSubstrate` → `registerParagraph` |

`NucleonRenderRuntime` is **not** in this table. Grounding showed it is
DRM/seat/session-coupled (imports `NucleonRendererLinux` + `NucleusDrmC`), not
core — it **splits in Phase 1** (the `DrmSession` leaf cleaves out to the
`compositor/` executable package) and its render-runtime remainder **relocates to
`compositor-core/` in Phase 2** with its dependency cluster (disposition D). No
`NucleusRenderRuntime` core target results;
the portable owner already exists as `RenderCore`.

Already `Nucleus*` core, unchanged: `Tracy`, `TracyBridge`,
`VulkanC`, `Vulkan`, `NucleusSkiaGraphiteBridge`, `NucleusReactNativeCxxBridge`,
`NucleusReactRuntimeCxx`, `NucleusReactRuntimeHostCxx`, `NucleusReactRuntime`,
`NucleusReactFabricSmokeC`, `VulkanGen`, and the RN/Skia build plugins.

### B. App-framework renames (stay in root, `NucleusApp*` / `NucleusUI`)

| Current | New | Notes |
|---|---|---|
| `Nucleon` | `NucleusUI` | the design-system / component surface; the front-door module (`@_exported import` of the common authoring surface, rule 4) |
| `NucleonHostBundle` | `NucleusAppHostBundle` | drop its dependency on the deleted `NucleonHostBundleTypes` |
| `NucleonHostBundleTypes` | **DELETE** | **dead code** (grounded): its two types (`SwiftExistentialPair`, `HostBundleProductionInputs`) are unreferenced and the Zig existential-pair bridge it served was removed. It has no deps and imports nothing — the "app→compositor leak" an earlier draft assumed does not exist |
| `NucleonHostProtocols` | `NucleusAppHostProtocols` | |

The app-entry surface in `NucleusApp` mirrors SwiftUI's `App`/`Scene` vocabulary
(rule 5).

### C. Compositor relocate (root → `compositor-core/`); rename deferred

The **New** column is the eventual `NucleusCompositor*` name (the deferred-rename
end state); Phase 2 relocates these targets under their **current** names, and the
rename lands later (Phases 3–6).

| Current | New | Class |
|---|---|---|
| `ValenceServer` | `NucleusCompositorServer` | window/seat policy |
| `ValenceServerTypes` | `NucleusCompositorServerTypes` | keep (grounded: breaks the `ValenceServer`↔`ValenceWindowManager` cycle and carries the `@c` wire records) |
| `ValenceOverlay` | `NucleusCompositorOverlay` | shell overlay UI (consumes `NucleusUI`) |
| `ValenceOverlayTypes` | `NucleusCompositorOverlayTypes` | |
| `ValenceOverlayReactRuntime` | `NucleusCompositorOverlayReactRuntime` | |
| `ValenceOverlayScene` | `NucleusCompositorOverlayScene` | |
| `ValenceShell` | `NucleusCompositorShell` | consumes shared `NucleusLinuxDBus` |
| `ValenceShellSurface` | `NucleusCompositorShellSurface` | |
| `ValenceWindowManager` | `NucleusCompositorWindowManager` | |
| `ValenceWindowScene` | `NucleusCompositorWindowScene` | |
| `NucleusWaylandRuntime` | `NucleusCompositorWaylandRuntime` | Wayland/xcb/input substrate |
| `NucleusWaylandC` | `NucleusCompositorWaylandC` | `pkgConfig: wayland-server` |
| `NucleusWaylandCProtocols` | `NucleusCompositorWaylandCProtocols` | |
| `NucleusXcbC` | `NucleusCompositorXcbC` | `pkgConfig: xcb-ewmh` |
| `NucleusInputC` | `NucleusCompositorInputC` | libinput/libseat/libudev/xkb |
| `NucleusDrmC` | `NucleusCompositorDrmC` | `pkgConfig: libdrm` |
| `NucleonRendererLinux` | `NucleusCompositorRendererLinux` | DRM/KMS presentation backend |
| `NucleusSystemdC` | `NucleusLinuxDBusC` | shared `platform-linux` façade; `pkgConfig: libsystemd` |
| `WaylandGen` | `NucleusCompositorWaylandGen` | codegen tool |
| `GenerateWaylandC` | `NucleusCompositorGenerateWaylandC` | codegen plugin |

Inner types stay bare and macOS-window-server-flavored (`Window`, `Surface`,
`Space`, `Connection`), per rule 5.

Already inside `compositor/`, rename in place: `ValenceCompositorRuntime` →
`NucleusCompositorRuntime`; `NucleusCompositor` (the executable) stays as-is (it
is the "Nucleus Compositor" product); `NucleusRuntimeEntry` /
`NucleusCompositorLoop` → `NucleusCompositorRuntimeEntry` /
`NucleusCompositorLoop`. `NucleusReactor` → `NucleusCompositor*` (grounded:
compositor-only — it is now just the `NucleusReactorCompletion` io_uring
completion DTO coupled to the compositor loop, not a standalone reactor).
`NucleusTextBackend` is portable Skia/text infra, **not** substrate — give it a
render-infra name (not `*Substrate*`); it stays here only because the executable
links it, and is a candidate to hoist to core when a Linux app-runtime needs text.

### D. Split and deletion

- **`NucleonRenderRuntime` splits, and by the end of Phase 2 nothing
  render-runtime-shaped stays in root.** Grounding showed the portable owner it
  was meant to leave behind already exists as `RenderCore` in `NucleonRenderer`.
  So:
  - the clean `DrmSession` (+ the libseat open/close and session-generation
    shims — it references no renderer, importing only `Glibc`) →
    **`NucleusCompositorRenderSession`**, a leaf target in `compositor/` with **no
    package dependencies** (the seat is still injected as closures at bring-up, so
    it does not link `NucleusCompositorDrmC`). *This is Phase 1 — done.*
  - the remainder (the `RenderRuntime` facade over `RendererRuntime`, and the
    dmabuf / syncobj-timeline / DRM-node glue) **stays in the root
    `NucleonRenderRuntime` target through Phase 1** and **relocates to
    `compositor-core/` in Phase 2** under a `NucleusCompositor*` name, moving with
    its dependency cluster (`NucleonRendererLinux` + the render-graph internals it
    imports) — it is Linux glue, not a core owner, but it is product-coupled to
    root internals until that cluster moves.
- **`NucleonHostBundleTypes` → delete** (disposition B). No record extraction:
  the app→compositor leak an earlier draft assumed does not exist in source.

## Phases

Strict sequential. Each phase leaves the tree building. (Structure — Phases 1–2 —
is rename-independent and is the enabling work the roadmap's Phase 1 depends on;
the rename — Phases 3–6 — is high-blast-radius, zero-new-capability, and can be
deferred behind a trigger: a second contributor, a public release, or a docs
site. Consider running 1–2 now and 3–6 later.)

### Phase 1 — Split `NucleonRenderRuntime` *(done)*

Cleave `DrmSession` (+ the seat open/close and session-generation shims) out into
**`NucleusCompositorRenderSession`**, a new target in the `compositor/` package.
This half imports **only `Glibc`** — it references no renderer — so it is the one
piece that can relocate immediately without dragging the cxx-interop render graph.
Its sources live in the compositor source tree (`valence/render/swift`), symlinked
into the package like the other composition-root sources.

The `RenderRuntime` remainder (the facade over `RendererRuntime` plus the dmabuf /
syncobj / DRM-node glue) **stays in the root `NucleonRenderRuntime` target for
now.** It imports root-internal targets that are not exported as products
(`NucleonRenderHost`, `NucleonDynamics`, `NucleusDrmC`, `NucleusSkiaGraphiteBridge`)
and the cxx-interop `NucleonRenderer` graph, so a compositor-package target cannot
depend on it until that whole cluster relocates. That relocation is Phase 2, where
the remainder moves alongside `NucleonRendererLinux` and takes a `NucleusCompositor*`
name — nothing render-runtime-shaped stays in root at the end of Phase 2. (The
portable owner it was meant to leave behind already exists as `RenderCore` in
`NucleonRenderer`, grounded.) This split **precedes** relocation precisely because
the monolith has one dependency-clean half that can move now and one cluster-bound
half that must move with its dependencies — they cannot move as one piece.

Consumers (`CompositorBringup`, `CompositorRuntime`) now import both
`NucleusCompositorRenderSession` (for `DrmSession`) and `NucleonRenderRuntime` (for
`RenderRuntime`); `DisplayFrameDemand` imports only the latter. Both packages build.

### Phase 2 — Stand up `compositor-core/` and relocate the OS substrate into it *(done)*

Create a new **`compositor-core/`** library package — the Linux compositor library,
symmetric with `platform-android`. It is a library (not the app): tested via
`swift test` under the global cxx flag, and — critically — it takes **no
`swift-system` dependency**, so those tests can run (the reason it is a separate
package from `compositor/`, whose io_uring composition root pulls `swift-system`,
which cannot tolerate the global cxx test flag).

Move every target in disposition **C** (plus the `NucleonRenderRuntime` remainder
from Phase 1) from the root package into `compositor-core/`, **including their test
targets** (`NucleonRendererTests`, `NucleusWaylandCTests`, `ValenceServerTests`,
`ValenceWindowManagerTests`) — the tests move with the modules they cover, which is
only possible because this package excludes `swift-system`. **Preserve module names
during the move** — a `ValenceServer` module simply relocates into `compositor-core`,
its `import` sites unchanged. The structural relocation is deliberately kept
*separate* from the cosmetic `Valence*` / `NucleusWayland*` / `NucleonRendererLinux`
→ `NucleusCompositor*` rename, to de-risk a ~24-target move (each step build-verifies
on its own). That rename — like the core `Nucleon*`→`Nucleus*` rename — is deferred
to the rename phases (3–6) behind their trigger; once everything is in
`compositor-core`, it is a contained pass touching only `compositor-core` +
`compositor` (root is never involved, since the compositor substrate has zero root
consumers — the app→compositor leak is confirmed absent).

Move the `pkgConfig` helper and the `drmGbm*` / `waylandRuntime*` flag blocks out of
the root manifest into `compositor-core/Package.swift`. Product-ify the core targets
the remainder needs but root does not yet export (`NucleonRenderHost`,
`NucleonDynamics`, `NucleusSkiaGraphiteBridge`) so `compositor-core` can consume them;
move the substrate C shims (`NucleusDrmC`, `NucleusWaylandC`, `NucleusXcbC`,
`NucleusInputC`, `NucleusSystemdC`) into `compositor-core`. Repoint `compositor/`
(the executable package) from the relocated root products to `compositor-core`
products, and add `compositor-core` as a package dependency. Drop the relocated
targets and their product exports from root.

Exit condition (met): the root package builds with **zero** Wayland / DRM / xcb /
libinput / libseat / libudev / libsystemd `pkg-config` resolution — the pure-core
probe from the roadmap's Phase 1 — and `compositor-core`'s **128 tests pass** under
`swift test -Xswiftc -cxx-interoperability-mode=default`.

**How it landed (executed).** Two things the graph-level plan didn't foresee shaped
the work:

- **Sources relocate by directory symlink, not physical move.** SwiftPM accepts a
  directory-symlink target `path:` pointing outside the package, so each moving
  target is one symlink under `compositor-core/Sources` (or `Tests`) into its
  existing home (`valence/`, `swift/Sources`, `swiftpm/`) — matching how
  `compositor/` already references `valence/`. Nothing physically moved; every
  internal relative symlink keeps resolving. (Caveat learned: `sed -i` through a
  symlink chain replaces the symlink with a regular file — edit the real source
  path, not the symlinked view.)
- **The real work was an `@_spi(NucleusCompositor)` contract, not target relocation.**
  The compositor's shell/overlay/scene modules reach into Nucleon core via Swift
  `package` access, which is per-SwiftPM-package — so a separate package can't use
  it. The fix (and the thing that makes a separate **repo** possible at all, since
  cross-repo has no `package` access either) is to promote the exact core surface
  the compositor consumes from `package` → `@_spi(NucleusCompositor) public`, and
  `@_spi`-import it on the compositor side. Scoped iteratively to what's actually
  used, this is a **small, precise 24-member surface** (23 in `Nucleon`, 1 in
  `NucleonDynamics`); the other ~178 `package` decls stay `package` (intra-core).
  `@_spi` (a pre-existing group in this tree — `NucleusReactRuntimeCxx` already used
  it) keeps the surface out of the third-party public API. Root still builds — the
  promoted members weren't reached cross-module inside root.

**Repo-split readiness.** The `@_spi` contract makes the *API* boundary repo-ready:
no `package` access crosses the compositor↔core line, so a separate repo consuming
core as a versioned dependency will compile. What remains before an actual extraction
is the *physical* consolidation — the compositor sources are now real files under
`compositor-core/Sources` (the target-level symlinks are gone) except the
Wayland-runtime target, which still farms per-file symlinks into `valence/`. Full
consolidation of that farm + moving the tree to its own repo (and flipping
`.package(path:)` → `.package(url:)`) is the extraction step.

### Phase 3 — Rename core targets *(module renames done; NucleusLayers type-strip done)*

Applied disposition **A** module renames: the `Nucleon*` core targets → `Nucleus*`,
including `NucleonDynamics` → `NucleusLayers` and `NucleusSubstrateTextRegistry` →
`NucleusTextRegistry` (+ `SubstrateTextRegistry.*` → `TextRegistry.*`,
`registerParagraphForSubstrate` → `registerParagraph`). `NucleonTypes` →
`NucleusTypes` stays standalone (cycle-breaker). Build define
`NUCLEON_DYNAMICS_PUBLIC_NAMES` → `NUCLEUS_LAYERS_PUBLIC_NAMES`. The **`NucleusLayers`
type-strip is now done**: `DynamicsHost`→`Host`, `DynamicsSettings`→`Settings`,
`DynamicsGeometry`→`Geometry`, `DynamicsError`→`LayerError` (rule-3 qualifier),
`DynamicsLayerTests`→`LayerTests`; call sites read `Layers.Host`/`Layers.Settings`.
**Deviation:** `LayerTransaction` is *not* stripped to bare `Transaction` — `NucleusUI`
already owns a `Transaction` (the CATransaction-shaped developer API) that consumes it, so
rule 3 keeps the qualifier (this supersedes the line-101 table entry). **Still deferred:** the
compositor-side inner-type stripping (`ValenceLogicalRect`→`LogicalRect`, etc.) and any
wire-record generator emitting prefixed names; plus the lowercase-`dynamics` concept word +
core-repo Zig archaeology.

### Phase 4 — Rename app-framework targets, delete dead code *(done — renames + App/Scene front door)*

Applied disposition **B** module renames: `Nucleon` → `NucleusUI`; the `Host*`
targets → `NucleusApp*`; **deleted** the dead `NucleonHostBundleTypes` target + its
product, the four `compositor-core` dependency edges, the `NucleusAppHostBundle` edge,
and the source dir. **The App/Scene front door is now built** (additive, not mechanical):
the `NucleusApp` module ships the SwiftUI-shaped `App`/`Scene`/`WindowGroup`/`@SceneBuilder`
vocabulary (rule 5) and the `@_exported import` front door (rule 4), with the
run-loop-ownership fork resolved as a `PlatformAppHost` seam the backend installs. The
collision audit resolved cleanly: the
front door is `@_exported import NucleusUI` and does **not** re-export `NucleusLayers` —
`NucleusUI` already surfaces the developer-facing versions of the shared bare names
(`Color`, `Rect`, `Transaction`, `Shadow`, `Size`, `ActionPolicy`, `LayerRole`,
`CommitSink`, …), and `NucleusLayers` stays a granular import for advanced direct-layer
authoring, so the ambiguity never arises. Rule 4 landed **with** rule 5, as predicted.

### Phase 5 — Sweep the C ABI and artifact names *(done)*

Renamed the C-ABI symbols across every `@c`/`@_cdecl` decl, C/C++ header, and caller:
`valence_*` → `nucleus_compositor_*` (279 symbols), `nucleon_host_bundle_*` →
`nucleus_app_host_bundle_*`, the rest of `nucleon_*` → `nucleus_*` (core-owned), and
the one `NUCLEON_SWIFT_H` guard. No `libnucleon-*`/`libvalence-*` artifacts existed,
so nothing to rename there. No `nucleon`/`valence` identifier survives in code,
module names, or the C ABI.

### Phase 6 — Rewrite the docs *(done)*

Updated the `AGENTS.md`/`CLAUDE.md` build-system paragraph to the four-package
topology + the `@_spi(NucleusCompositor)` contract, and fixed the stale brand words
in the root/`compositor-core` manifests and `skia_text_backend.cpp`. The curate-not-sed
prose sweep of the `docs/` files then followed: stale *current-state* references (dead
`nucleon/` paths → `swift/Sources/` + `render-cxx/`; retired `Dynamics*` type names →
the bare `Layers` API; `Nucleon`/`Zig` used as present-tense) were corrected across the
technical/design/plan docs, while historical narration (the Zig→Swift and Nucleon→Nucleus
migration "from" states) was preserved. The old `source-tree-organization.md` — which
described the pre-split Zig-era monorepo layout — was removed as superseded; `CLAUDE.md`
+ `repo-decomposition.md` are the authoritative current-tree reference.

## Resolved decisions (grounded against source)

The earlier draft's four open decisions are settled by reading the current targets:

- **`NucleonTypes` → its own `NucleusTypes` module, not folded.** It is the
  cycle-breaker between `NucleonHostProtocols` and `NucleonDynamics` and the shared
  value-type vocabulary for ~20 modules across core, app, and compositor.
- **`*Types` audit:** keep `NucleusTypes` (cycle-breaker), `NucleusCompositorServerTypes`
  and `NucleusCompositorOverlayTypes` (both no-dep `@c` wire-record boundaries with
  many importers). `NucleonHostBundleTypes` is **dead** — delete it (two unreferenced
  types; its Zig existential-pair purpose is gone).
- **`NucleusReactor` → `NucleusCompositor*` (compositor-only).** No longer a reactor
  — the io_uring loop is `SystemPackage.IORing` in the compositor runtime;
  `NucleusReactor` is just the `NucleusReactorCompletion` DTO, coupled to the
  compositor loop's token encoding.
- **`NucleusTextBackend` is portable Skia/text infra, not OS substrate.** No
  Wayland/DRM/seat; its registry is already shared with a root test target. Stays in
  `compositor/` for now (that is where the executable links it) but takes a
  render-infra name, and is a candidate to hoist to core when a Linux app-runtime
  needs text.
- **App→compositor leak: none.** No `Nucleon*` app/core target imports any
  `Valence*`/compositor module. The end-state invariant "no core or app-framework
  target depends on a compositor target" already holds today; only the OS-substrate
  *relocation* (Phase 2) remains to make the root package pure.
- **`NucleusCompositorRenderSession` surface:** the cleanly-separable piece is
  `DrmSession` + the seat/session shims (they reference no renderer); everything
  else in `NucleonRenderRuntime` is DRM glue that moves to compositor as-is.
