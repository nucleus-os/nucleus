# Collider Storage Lifecycle Plan

## Invariant

Collider deletes only generated data that it owns and can prove is inactive.
Validated published outputs remain available until their replacements are fully
validated and atomically activated. Active generations, source checkouts,
signing identities, and current published artifacts are never cleanup
candidates. Expensive incremental build trees remain reusable until the user
explicitly cleans them.

Storage lifecycle behavior uses neither byte quotas, free-space minimums,
automatic cache-size limits, nor Collider-owned schema versions.

Status: active

## Execution Rules

The phases land strictly in the order below. A phase is complete only after its
behavioral verification and exit gate pass. The completed verification foundation
remains recorded here because every later storage workflow relies on those mandatory
Collider lanes.

## Required Outcome

Collider provides one coherent lifecycle for every generated path:

- `collider cache status` inventories all Collider-owned storage and explains
  whether each path is active, reusable, published, or reclaimable.
- `collider cache prune` removes only provably stale candidates, expired
  inactive generations, old successful run records, and downloads that the
  current task graph no longer references.
- `collider clean <component>` explicitly removes that component's incremental
  build state while preserving sources, signing identities, downloads, and
  published outputs.
- Candidate directories are transaction-owned and recoverable after crashes.
- Every generation-producing workflow declares its rollback retention policy.
- Cleanup always acquires the same workflow locks used by the producer.
- Native SDKs have one Collider-owned root resolver, artifact fingerprint, publication
  path, and package-facing metadata boundary.

## Phase 1 — Make Verification Mandatory and Representative

Phase status: complete

### Outcome

The ordinary CI lane uses Collider successfully, loader and headless Graphite behavior
run on every CI worker, and DRM/GBM behavior runs on a declared render-node worker.
Tests never turn a missing capability into a passing test.

### Changes

1. Replace the deleted `tools/nucleus` invocations in `.github/workflows/ci.yml`. A
   fresh worker runs `./collider-setup.sh`, then `collider doctor`, then
   `collider test all`. Setup already performs checkout bootstrap, so CI does not
   schedule a second bootstrap.

2. Add three explicit test capabilities to Collider:

   - `loader` requires the Vulkan loader but creates no device.
   - `gpu-headless` requires the Collider-provisioned Mesa lavapipe ICD and creates a
     non-presenting Graphite device.
   - `gpu-drm` requires a real `/dev/dri/renderD*` node, GBM, the configured Vulkan
     driver, and the complete Linux compositor Vulkan contract.

   `collider test all` includes `loader` and `gpu-headless`. A separate CI job on a
   worker labelled for a render node runs `collider test gpu-drm`.

3. Add `VkRequirements.PresentationMode.headless`. Its contract contains only the API
   version, features, extensions, queues, and entry points required to create and
   submit Graphite work without Wayland WSI, Android WSI, DRM modifiers, DMA-BUF
   import, or external semaphore FDs. Production `.platformDefault` and
   `.waylandClientWSI` contracts remain unchanged.

4. Assign every disabled first-party GPU test by actual resource use:

   - Loader symbol and dispatch tests move to `loader`.
   - Offscreen drawing, paint, texture-registry, backdrop, snapshot, screenshot, and
     submission tests move to `gpu-headless`.
   - Scanout wrapping, GBM allocation, DMA-BUF import, explicit sync, and DRM
     presentation tests move to `gpu-drm`.

   Delete disabled traits and best-effort guard returns. Collider performs lane
   preflight before Swift Testing starts and emits a directed failure when a promised
   capability is absent.

5. Keep developer-host capability absence distinct from CI success. A
   hardware-specific command invoked without its required render node fails preflight;
   its test body is not reported as passed or skipped.

### Behavioral Verification

- A loader-only fixture resolves required globals and reports a deliberately missing
  symbol as a typed failure.
- A headless fixture creates a Graphite context on lavapipe, draws, submits, waits
  through the completion callback, and reads pixels back.
- A DRM fixture allocates a GBM buffer, imports it, submits with explicit sync, and
  observes completion on a real render node.
- Collider task-graph tests cover lane selection and deterministic lavapipe staging.

### Exit Gate

`collider doctor`, `collider test all`, and `collider test gpu-drm` pass on their
declared workers. No first-party Vulkan, Graphite, GBM, or DRM test remains disabled.

## Storage Classes

| Class | Examples | Automatic behavior |
|---|---|---|
| Source | AOSP checkout, Chromium checkout, submodules | Never deleted by cache pruning |
| Identity | Android signing keys, trusted source locks | Never deleted by cache pruning or component clean |
| Published | Signed Android images, active browser/CEF artifacts | Atomically replaced only after validation |
| Generation | Desktop runtime, browser, CEF, Swift platform, Boost | Active generation plus declared rollback generations are retained |
| Candidate | `.candidate-*`, `.prepared`, temporary publication trees | Removed after success, failure, or proven-abandoned recovery |
| Incremental | SwiftPM `.build`, AOSP `out`, Skia, RN, CMake/Ninja output | Reused by default; removed only by explicit component clean |
| Download | Pinned archives and tool downloads | Removed only when unreferenced by the current task graph |
| Run record | `.nucleus/runs/*` | Existing successful-run retention remains configurable |

## Phase 2 — Declare Storage Ownership

Add first-class storage declarations to `ColliderCore` and make them part of
the resolved task graph.

Each declaration contains:

- component identity;
- canonical owned root;
- storage class;
- safety root;
- producer task identities;
- required workflow lock;
- current-generation link when applicable;
- rollback generation count when applicable;
- clean eligibility;
- prune eligibility.

The declaration model rejects:

- `/`, the workspace root, the home directory, or a cache root as a directly
  removable target;
- paths outside the declared safety root;
- overlapping declarations with conflicting ownership;
- generation declarations without an active link;
- removable paths that contain a source or identity declaration;
- cleanup operations without the producer's workflow lock.

Move the existing browser and runtime retention descriptions into this model.
Delete the separate ad hoc retention construction once all callers use the
shared declaration.

Phase 2 is complete when task-graph validation can enumerate every declared
path and behavioral tests prove that unsafe or conflicting declarations are
rejected.

## Phase 3 — Give Native SDK Configuration One Owner

### Outcome

Consumer manifests contain no native-SDK path resolution, symlink provisioning,
archive inventory, or duplicated include/link flags. Collider resolves, provisions,
and fingerprints the SDK; the owning Swift package exposes it to every consumer.

### Changes

1. Make Collider the only native-SDK root resolver with this precedence:

   1. `NUCLEUS_NATIVE_SDK_ROOT`
   2. `$XDG_CACHE_HOME/nucleus/nucleus-native-sdk`
   3. `$HOME/.cache/nucleus/nucleus-native-sdk`

   If none produces an absolute root, `collider doctor` fails with a directed
   diagnostic. There is no `/tmp` or `/.cache` fallback.

2. During bootstrap, combine each cyclic native archive set into one deterministic
   aggregate archive with the provisioned LLVM `ar` and `ranlib`, then generate
   versioned pkg-config metadata inside the SDK:

   - `nucleus-render-native-sdk.pc` is owned by `core/` and exports the render include
     roots, library root, aggregate render library, and required platform libraries.
   - `nucleus-rn-native-sdk.pc` is owned by `react-native/` and exports RN,
     ReactCommon, Hermes, folly, and associated native inputs through an aggregate RN
     library.

   A regular aggregate archive makes cyclic resolution an SDK construction concern.
   Consumers no longer carry `--start-group`, absolute archive arguments, or linker
   ordering that pkg-config cannot express through SwiftPM. Aggregate archives
   preserve every input object rather than partially linking them. SDK fingerprints
   cover include and library paths, archive inventory, build options, toolchain
   identity, and source revisions.

3. Add `NucleusRenderNativeSDK` as a system-library target and product in
   root `Package.swift`. Its checked-in module map and umbrella header expose the
   render SDK, and its `pkgConfig` entry names `nucleus-render-native-sdk`. Every core,
   compositor, shell, and React Native target consuming Skia or render-native headers
   depends on this product.

4. Add `NucleusRNNativeSDK` as the equivalent carrier in
   root `Package.swift`. RN C++ targets depend on it directly, and the RN
   carrier depends on the render carrier when it needs the shared render SDK without
   restating render flags.

5. Inject the generated pkg-config directory into every SwiftPM child environment.
   `tools/host-env.sh` exports the same path for direct host builds and tests. Missing
   or fingerprint-mismatched metadata fails doctor/bootstrap.

6. Delete from every consumer manifest:

   - `provisionSDK` and every filesystem mutation;
   - local `HOME`, `XDG_CACHE_HOME`, and `NUCLEUS_NATIVE_SDK_ROOT` resolution;
   - per-package SDK symlink handling;
   - copied render archive lists and parallel Android copies;
   - duplicated SDK include and library search paths;
   - the unused `pkgConfig` helper in the root `Package.swift`.

   SwiftPM compiles only `Package.swift`; do not attempt manifest-adjacent Swift source
   inclusion. SDK paths leave consumer manifest evaluation entirely.

7. Produce host and Android aggregate render libraries in their owning SDK variants.
   Collider selects the target-appropriate pkg-config directory and keeps one archive
   inventory per SDK build rather than one per consuming manifest.

8. Declare native SDK roots, active links, metadata, aggregate archives, and
   intermediate construction paths through the Phase 2 storage model. Published SDK
   artifacts are protected; obsolete candidates and generations use the shared
   lifecycle instead of SDK-specific cleanup.

### Behavioral Verification

- Resolver tests cover the override, XDG, HOME, and no-root cases with isolated roots.
- Bootstrap tests reject or replace stale directories and symlinks through the
  artifact workflow.
- Every consuming package manifest evaluates on a read-only checkout without writes.
- Core, React Native, compositor-core, compositor, and shell build against two
  isolated SDK roots without manifest edits.
- Facade smoke executables exercise symbols from archives that previously required
  cyclic linker groups.
- Removing required pkg-config metadata makes `collider doctor` identify the missing
  SDK component and remediation command.

### Exit Gate

All first-party native consumers build through the two SDK carrier products. Consumer
manifests contain no SDK-root resolver, provisioning symlink, or copied Skia archive
group, and all SDK storage participates in the shared ownership model.

## Phase 4 — Build a Complete Storage Inventory

Replace the hand-maintained root list in `RepositoryCache` with the resolved
storage declarations.

`collider cache status` reports:

- component;
- storage class;
- canonical path;
- allocated bytes;
- active or inactive state;
- reclaimable or protected state;
- the reason for that state.

The human-readable output groups paths by component and storage class. JSON
output carries the same facts without introducing a version field.

Inventory traversal does not follow symbolic links. Missing optional roots
report zero bytes. Permission errors identify the affected root and do not
silently produce an incorrect total.

Declare at least these roots:

- every first-party SwiftPM `.build` directory;
- `core/.skia-build`;
- `react-native/.rn-build` and `react-native/.cxx-build`;
- `android-runtime/.aosp-build`, its published images, and its incremental
  subtrees;
- Android source and signing roots as protected storage;
- Chromium source, CEF, browser artifact, and browser installation roots;
- Swift source, build, platform, and toolchain generation roots;
- Nucleus native SDK links;
- download caches;
- `.nucleus/runs`;
- desktop runtime installation generations.

Phase 4 is complete when `collider cache status` accounts for all generated
roots used by the complete build graph and labels each root's lifecycle
correctly.

## Phase 5 — Unify Candidate Transactions and Crash Recovery

Introduce one candidate-directory API in `ColliderRuntime`. Replace direct
candidate creation and cleanup in Android, browser, CEF, toolchain, download,
installation, and directory-publication workflows.

Each candidate:

- is created beside its final destination when atomic rename requires it;
- records the Collider run and task that own it;
- holds an advisory lease for the candidate's lifetime;
- is removed by structured cleanup when its task fails;
- is consumed or removed when publication succeeds.

Recovery acquires the owning workflow lock and then attempts the candidate
lease non-blockingly. A candidate is abandoned only when the lease is
available and its owning run is no longer active. PID values or file age alone
never prove abandonment.

Unknown directories and files that do not carry Collider ownership metadata
remain untouched.

Phase 5 is complete when interrupted publication tests prove that active
candidates survive, abandoned candidates are reclaimed, and the last valid
published artifact remains active across every interruption boundary.

## Phase 6 — Make Generation Retention Complete

Express retention as active generations plus rollback generations. The active
link is always protected even when it is not the newest directory by
modification time.

Use these policies:

- desktop runtime installation: active plus two rollback generations;
- Chromium source: active generation only;
- CEF artifacts: active plus one rollback generation;
- browser artifacts: active plus one rollback generation;
- browser installation: active plus one rollback generation;
- Swift platform/toolchain: active plus one rollback generation;
- Boost source: active generation only.

Run generation pruning only after the new generation validates and the active
link is durably replaced. Pruning sorts inactive generations deterministically
and ignores directories that do not match the workflow's content-identity
naming contract.

Delete the old retention-count semantics that can retain the active generation
in addition to an ambiguous number of newest directories.

Phase 6 is complete when every generation producer has a policy and behavioral
tests prove that active generations cannot be pruned.

## Phase 7 — Expand Safe Cache Pruning

Make `collider cache prune` operate from the Phase 4 inventory.

The default prune operation handles:

1. abandoned candidates proven stale by Phase 5;
2. inactive generations beyond Phase 6 retention;
3. successful run records beyond `--keep-runs`;
4. pinned downloads that no task in the current resolved graph references.

The command supports:

- `--dry-run`;
- `--json`;
- `--component <component>`;
- `--keep-runs <count>`.

Every reported action includes the path, storage class, reason, and reclaimable
allocated bytes. Dry-run and real execution use the same resolved action list.

Pruning never removes incremental build trees. Failed run records remain
available unless the user explicitly targets them in a later dedicated log
cleanup design.

Phase 7 is complete when a dry run exactly predicts the paths and bytes removed
by the corresponding real run.

## Phase 8 — Add Explicit Component Cleaning

Add:

```sh
collider clean <component>
collider clean all
```

Both forms support `--dry-run` and `--json`.

Component clean removes only storage declared as incremental and cleanable. It
acquires the producer locks, refuses to run while the component is active, and
prints every target before removal.

Required preservation contracts include:

- Android clean removes `.aosp-build/out`, `dist`, and `unsigned` while
  preserving `.aosp-source`, `.aosp-signing`, signed archives, and current
  published images.
- Core clean removes SwiftPM and Skia intermediates while preserving sources
  and downloads.
- React Native clean removes SwiftPM, RN, and C++ intermediates while
  preserving sources and downloads.
- Browser clean removes the current source generation's build output while
  preserving source, downloads, and published browser/CEF generations.
- Toolchain clean removes inactive build workspaces and validation work while
  preserving the active platform generation and SDK discovery link.

`clean all` resolves the union of component-clean targets and applies the same
safety validation to every path. It does not widen any component's ownership.

Phase 8 is complete when each component can rebuild successfully after its
clean operation and all preservation contracts remain intact.

## Phase 9 — Integrate, Validate, and Remove Old Paths

Update component recipes to declare their storage through the Phase 2 model.
Delete replaced cache-root lists, candidate helpers, and retention call sites.
Do not preserve parallel lifecycle pipelines or compatibility wrappers.

Add behavioral tests using isolated temporary directories for:

- ownership and overlap rejection;
- symlink-safe inventory;
- allocated-byte accounting;
- candidate success, failure, and crash recovery;
- atomic activation interruption boundaries;
- active-generation protection;
- deterministic rollback retention;
- prune dry-run equivalence;
- component-clean preservation contracts;
- concurrent build, prune, and clean lock exclusion.

Run the complete Collider test suite, then exercise:

```sh
collider cache status
collider cache prune --dry-run
collider clean android-runtime --dry-run
collider clean core --dry-run
collider clean rn --dry-run
collider clean browser --dry-run
collider clean toolchain --dry-run
```

Inspect every proposed target before allowing a real prune or clean against the
working checkout.

Phase 9 is complete when all generated storage is declared, all old lifecycle
implementations are removed, the full build remains incremental by default,
and cleanup cannot reach an undeclared or active path.

## Deliberately Preserved Contracts

- SwiftPM 6.4 includes the current cachable process environment in its manifest cache
  key. `Context.environment` versus `ProcessInfo.processInfo.environment` does not
  create the alleged invalidation difference. Phase 3 removes SDK resolution from
  consumer manifests for ownership and purity, not to repair that nonexistent
  distinction.
