# Android Container Security Boundary Plan

## Invariant

Nucleus runs Android inside its LXC container without loading or enforcing the
Android SELinux policy. Every Android component must treat SELinux labels,
process transitions, Binder security identifiers, and SELinux access-vector
checks as unavailable in this product.

The container path preserves every security mechanism that does not depend on
Android SELinux:

- Linux user, PID, mount, IPC, UTS, and network namespaces
- Android UID and GID separation
- filesystem ownership, modes, project quotas, and encryption preparation
- per-process app-data mount isolation
- Binder caller PID and UID identity
- Keystore key ownership and explicit grants
- process capabilities, seccomp, and resource controls where supported
- the host's AppArmor policy and LXC device and mount policy

Missing SELinux state is never represented by fabricated labels. Label-only
operations become explicit container no-ops. Security decisions that previously
used SELinux receive a real non-SELinux authorization implementation.

`ro.nucleus.container` is immutable product identity, not a feature flag. Stock
Android behavior remains unchanged outside the Nucleus product.

## Execution and Validation Order

Phases 1 through 9 land in strict order. Each phase completes its source
changes, focused compilation, host-runnable unit tests, and non-interactive
static verification before the next phase begins.

Container boot, compositor presentation, TTY switching, physical GPU behavior,
and tests that must execute inside the installed Android product are deferred
until Phase 10. Phase 10 performs that hardware and runtime qualification once,
after every implementation phase is complete. A deferred Phase 10 gate does
not block progress from one implementation phase to the next.

## Current State

The current Android 17 runtime already handles several early container
boundaries:

- init skips Android SELinux setup and label-dependent creation work
- Zygote skips process SELinux transitions
- servicemanager uses permissive service discovery and registration in the
  container
- the Binder context manager does not request caller security identifiers
- vold creates its primary device nodes and data directories without labels
- BPF loading does not require `security.selinux` extended attributes

The latest runtime evidence identifies four boot-critical gaps:

1. Zygote terminates app children while reading labels for `/data/user`; the
   captured run contains eight fatal failures across SystemUI,
   PermissionController, and Provision.
2. installd rejects app-data work after `lgetfilecon` returns `ENODATA`; the
   captured run contains 267 failed label reads across 167 paths and 534
   restorecon errors.
3. Binder transactions fail when local services request transaction security
   contexts; the captured run contains 36 small-parcel transaction failures.
4. Keystore2 authorization requires Binder caller SIDs and SELinux access
   checks.

The same run also exposes non-fatal PackageSettings label assumptions and
latent label dependencies in storage lifecycle, ART update paths, `run-as`,
adb, Incremental FS, and other optional services. Its 1,236
`SELinux is disabled, skipping restorecon` messages are mostly successful
libselinux no-ops, but they identify high-volume paths that must call the
repository's container helper directly.

## Target Architecture

Each affected AOSP repository owns one small, cached container-security
capability at the lowest shared layer that can enforce the repository's
contract.

The capability has these semantics:

- Android SELinux is operational on stock products.
- Android SELinux is unavailable in the Nucleus container.
- callers ask the capability whether a label operation or SID transport is
  meaningful; callers do not infer availability from a failed syscall.
- label helpers return success without touching the filesystem in the Nucleus
  container.
- authorization helpers never turn a missing SID into universal access.

Early-init code that cannot read properties uses the existing init container
identity. Ordinary native daemons and libraries use the immutable
`ro.nucleus.container` property. A process reads the identity once and does not
perform property lookups in hot paths.

This is a repository-local implementation contract, not a new cross-repository
runtime library. A shared library would introduce boot-order and APEX-boundary
coupling between init, libbinder, ART, Keystore, and framework code.

Waydroid's Android 13 and Android 16 implementations are an implementation
checklist, not a source of product policy. The Android 16 rebase confirms that
Zygote, installd, Binder, servicemanager, Keystore, vold, PackageSettings, adb,
and legacy HIDL remain the relevant boundaries on a current platform. It also
adds a broad libselinux patch that fabricates a `HACKED` context, turns
`selinux_check_access` into an unconditional grant, and silently succeeds
process and file transitions. Nucleus explicitly rejects that design because
it hides unresolved authorization dependencies and violates this plan's
invariant.

The useful libselinux behavior from that rebase is narrower: restorecon already
has valid disabled-mode no-op semantics, and its repeated warning can be
suppressed when SELinux is intentionally absent. Nucleus keeps the stock
failure behavior of label getters, label lookup, process transitions, and
access-vector checks so unexpected dependencies remain observable.

The Android 16 rebase also introduces `/dev/host_binder`, a service-name
allowlist, and host-UID translation for host-provided AIDL HALs. Nucleus does
not use this parallel Binder realm. Its shipped HALs cross explicit
Nucleus-owned service boundaries, and Binder PID and UID identity must not be
rewritten implicitly. Any future host AIDL transport must define its own
authenticated protocol, identity mapping, and authorization policy before it
enters the product.

Nucleus does not adopt Waydroid's unconditional patching, complete removal of
app-data mount isolation, blanket Keystore permission grants, global
libselinux success behavior, host Binder multiplexing, or legacy
hwservicemanager architecture. `SELINUX_IGNORE_NEVERALLOWS` is not part of the
Nucleus build because the product does not compile or load an Android SELinux
policy.

## Phase 1 — Define the Disabled libselinux Contract

Phase 1 makes the platform-wide meaning of intentionally absent SELinux
precise before repository-specific call sites are changed.

### Execution status

- [x] `external/selinux` is part of the Nucleus forward-patch inventory.
- [x] Disabled restorecon is a quiet no-op.
- [x] Disabled access-vector checks fail with `ENOTSUP`.
- [x] Label getters, label writers, process transitions, and enforcement state
  retain truthful unavailable behavior.
- [x] init emits one early diagnostic identifying the absent Android SELinux
  backend.
- [x] The host libselinux suite passes.
- [x] The Nucleus device behavioral suite and `init_second_stage` compile for
  the Android 17 product.
- [x] Phase 1 implementation is complete.

Phase 10 executes `libselinux_nucleus_disabled_test` inside the final updated
container and confirms the runtime log contains the single init diagnostic
without repeated disabled-restorecon warnings.

### Implementation

In `external/selinux`:

1. Add `external/selinux` to `android-runtime/aosp/patches.json` and keep the
   complete Nucleus behavior in one repository patch.
2. Preserve the normal disabled result from `is_selinux_enabled`.
3. Make `selinux_android_restorecon` and
   `selinux_android_restorecon_pkgdir` return success immediately when SELinux
   is disabled, without traversing or modifying the target.
4. Remove the per-call `SELinux is disabled, skipping restorecon` warning.
   Disabled restorecon is expected product behavior, not an error.
5. Keep label getters and selabel lookups unavailable. They must return their
   normal failure and must never allocate or return a fabricated context.
6. Keep `selinux_check_access` unavailable when there is no policy. It must
   never translate missing SELinux state into an authorization grant.
7. Keep file-label writers, process-context writers, and process transitions
   unavailable. Repository-owned container helpers decide which strictly
   label-only operation is safe to bypass.
8. Keep the SELinux mount and enforcement status truthful. Do not synthesize
   an initialized or permissive policy state.
9. Retain a single early product diagnostic that Android SELinux is absent;
   do not emit a message for each successful label no-op.
10. Keep every behavior above unchanged when SELinux is present.

### Phase 10 qualification gates

- disabled restorecon and package-directory restorecon return success without
  walking or relabeling their targets
- label getters never return a synthetic context
- `selinux_check_access` cannot authorize a request without a loaded policy
- raw label and process-transition operations do not silently succeed
- the runtime emits no repeated disabled-restorecon warning
- stock-mode libselinux behavior remains unchanged

Phase 1 implementation is complete when libselinux exposes truthful absence,
quiet restorecon no-ops, and no implicit authorization bypass.

## Phase 2 — Make Binder Transport Independent of SELinux

Phase 2 fixes the common transport layer before changing services that consume
caller identity. Keystore2, StatsD, DRM, AI Seal, and future services must not
each carry their own workaround.

### Execution status

- [x] libbinder exposes one cached process-wide transaction-security-context
  capability derived from `ro.nucleus.container`.
- [x] `Parcel::flattenBinder` suppresses
  `FLAT_BINDER_FLAG_TXN_SECURITY_CTX` when that capability is unavailable.
- [x] Binder context-manager registration uses the same capability.
- [x] The Nucleus-specific `becomeContextManager(bool)` API is removed;
  servicemanager retains its stock `setRequestingSid(true)` declaration.
- [x] The platform and Binder NDK paths share the same libbinder policy.
- [x] No host Binder realm, service-name routing, or caller-UID translation is
  introduced.
- [x] `binderUnitTest` and servicemanager compile for the Android 17 product.
- [x] The complete host `binderUnitTest` suite passes: 99 tests from 12 suites.
- [x] Phase 2 implementation is complete.

Phase 10 verifies the device-side no-SID result, unchanged caller PID and UID,
normal context-manager registration, and absence of small-parcel failures in
the final integrated runtime.

### Implementation

In `frameworks/native`:

1. Add a cached process-wide Binder transport capability that reports whether
   transaction security contexts are available.
2. Initialize it from `ro.nucleus.container` for every Android process using
   libbinder.
3. Make `Parcel::flattenBinder` omit
   `FLAT_BINDER_FLAG_TXN_SECURITY_CTX` whenever that capability is unavailable,
   even when a local `BBinder` requested a SID.
4. Make context-manager registration use the same capability.
5. Replace the Nucleus-specific `becomeContextManager(bool requestSid)` API
   with the process-wide policy. There must be one decision point for normal
   Binder objects and the context manager.
6. Keep `setRequestingSid(true)` as a service's declaration of stock Android
   intent. Container transport suppresses the unsupported wire behavior
   centrally.
7. Keep servicemanager's Nucleus access policy and empty debug SID behavior.
8. Keep all Android services on the normal container Binder driver. Do not add
   `/dev/host_binder`, service-name routing, or caller-UID translation.
9. Expose each host integration through its existing explicit Nucleus service
   boundary instead of making a host service appear to be a local Android
   service.

The same rule applies to the platform Binder and Binder NDK paths because both
ultimately flatten local Binder objects through libbinder.

### Phase 10 qualification gates

- A local Binder service that requests caller SIDs accepts a transaction in
  Nucleus container mode.
- `getCallingSid` and `AIBinder_getCallingSid` return no SID for that
  transaction.
- Caller PID and UID remain correct.
- Calls cannot acquire system UID identity through host-UID translation.
- A stock-mode Binder test still transports the requested SID.
- The Android runtime log contains no small-parcel transaction failures from
  Keystore2, StatsD, DRM, or AI Seal.
- servicemanager becomes the Binder context manager and completes normal
  service registration.

Phase 2 implementation is complete when the common Binder transport no longer
requires service-specific SID transport changes.

## Phase 3 — Preserve Zygote Isolation Without Filesystem Labels

Phase 3 removes SELinux from app specialization while preserving the
mount-based app-data isolation that Waydroid disables.

### Execution status

- [x] Zygote uses one cached specialization security mode derived from
  `ro.nucleus.container`.
- [x] App and SDK sandbox specialization always preserve tmpfs setup,
  per-process mount namespaces, and package-data bind mounts.
- [x] Zygote skips only SELinux context acquisition, relabeling, process
  transitions, and seapp context initialization in the Nucleus container.
- [x] PackageManager preserves MMAC and `seInfo` metadata.
- [x] PackageSettings writes `packages.list` without a filesystem-label
  lookup or FS-create context when SELinux is unavailable.
- [x] PackageInstaller and `am` guard their direct label-dependent fallback
  and access-check paths with the platform SELinux availability contract.
- [x] Remaining PackageManager label operations use disabled-mode restorecon
  no-ops and contain no unguarded direct label sequence.
- [x] The consolidated `frameworks/base` patch materializes into a clean AOSP
  source tree.
- [x] `libandroid_runtime`, `services.core.unboosted`, and `am` compile for
  the Android 17 product after clean materialization.
- [x] Phase 3 implementation is complete.

Phase 10 validates specialization, mount visibility, PackageSettings behavior,
and unchanged stock-mode transitions inside the final integrated runtime.

### Implementation

In `frameworks/base`:

1. Extend the existing Zygote container support into a single cached
   specialization security mode.
2. Keep the existing skips for `selinux_android_setcontext` and the
   system-server `setcon`.
3. Split `isolateAppData` into:
   - mount-namespace and tmpfs setup
   - package and allowlist bind mounts
   - SELinux context acquisition and relabeling
4. Always execute the mount and bind-mount work.
5. Execute `getfilecon`, `setfilecon`, and `lsetfilecon` work only when Android
   SELinux is operational.
6. Apply the same split to `isolateSdkSandboxData`, including its device
   encrypted user and SDK sandbox paths.
7. Preserve JIT profile isolation unchanged.
8. Skip Zygote's seapp context initialization in the Nucleus container because
   the container never performs a seapp process transition.
9. Keep PackageManager's SELinux MMAC parsing and `seInfo` metadata. Other
   Android interfaces still carry this metadata, and stock behavior continues
   to use it.
10. Guard the `/data/system/packages.list` file-context lookup,
    `setFSCreateContext`, and cleanup in `Settings.writePackageListLPr` with
    `SELinux.isSELinuxEnabled()`.
11. Audit the remaining Java `SELinux` calls in PackageManager, installer,
    backup, wallpaper, settings, biometrics, and shortcut services. Calls
    through `SELinux.restorecon` already succeed as no-ops when disabled.
    Direct label lookup or write sequences receive the same explicit enabled
    guard.

### Phase 10 qualification gates

- SystemUI, PermissionController, Provision, and a normal application process
  specialize successfully.
- Each process sees only its intended app-data bind mounts.
- A process cannot traverse another application's credential-encrypted or
  device-encrypted data through the isolated mount namespace.
- SDK sandbox specialization completes and exposes only its intended sandbox
  data.
- Zygote emits no `Unable to getfilecon` fatal errors.
- PackageSettings writes `packages.list` without a WTF report.
- Stock-mode Zygote still performs its normal transitions and relabeling.

Phase 3 implementation is complete when every specialization path preserves
mount isolation without requiring filesystem labels.

## Phase 4 — Make installd Label-Neutral

Phase 4 makes installd own one complete container path instead of fixing each
new restorecon failure after it appears.

### Implementation

In `frameworks/native/cmds/installd`:

1. Add a cached `IsNucleusContainer` decision sourced from
   `ro.nucleus.container`.
2. Add installd-owned label helpers for:
   - ordinary restorecon
   - package-directory restorecon
   - lazy app-data restorecon
   - label reads
   - label copies to symlinks
3. Make restore helpers return success without label access in the Nucleus
   container.
4. Remove before-and-after `lgetfilecon` bookkeeping from the container path.
5. Cover every Android 17 call site, including:
   - credential-encrypted and device-encrypted app-data creation
   - cache and code-cache creation
   - SDK sandbox data
   - profile directories
   - app moves and data migration
   - native-library directory links
   - oat directory creation
   - secondary-dex output
   - app-data restore, snapshot, and rollback paths
   - post-install and post-OTA artifact directories
6. Preserve all non-label work:
   - path validation
   - mkdir and symlink operations
   - UID, GID, and mode changes
   - project IDs and quotas
   - fscrypt preparation
   - cache accounting
   - dex ownership and visibility
7. Keep failures for real filesystem, ownership, quota, encryption, or dex
   errors. Container mode suppresses only operations whose sole purpose is
   Android SELinux labeling.
8. Consolidate these changes into one coherent frameworks/native container
   patch set alongside the Binder and servicemanager work.

### Phase 10 qualification gates

- First boot creates app data for every preinstalled package.
- installd reports no `lgetfilecon`, `lsetfilecon`, or restorecon failure.
- App directory ownership and modes match the package UID and Android storage
  contract.
- Cache and code-cache directories remain distinct and correctly owned.
- Native-library links, profile preparation, and first-boot dex compilation
  succeed.
- An invalid path, UID, project ID, or filesystem operation still fails.
- Stock-mode installd continues to label all corresponding paths.

Phase 4 implementation is complete when every installd operation has a
label-neutral Nucleus path that preserves its non-label contracts.

## Phase 5 — Replace Keystore2 SELinux Authorization

Phase 5 starts only after Phase 2 Binder transport succeeds. It replaces
authorization rather than copying Waydroid's blanket `Ok(())` behavior.

### Implementation

In `system/security/keystore2`:

1. Introduce an authorization backend selected once at process startup:
   - the stock backend uses Binder caller SID, `getcon`, selabel lookup, and
     `selinux_check_access`
   - the Nucleus backend uses Binder caller UID, key ownership, explicit grants,
     and an explicit platform namespace policy
2. Route `check_keystore_permission`, `check_grant_permission`, and
   `check_key_permission` through that backend.
3. Preserve `Domain::APP` ownership:
   - a caller can access its own namespace
   - a different app UID cannot access that namespace without an explicit grant
4. Preserve `Domain::GRANT` access vectors and reject operations absent from
   the vector.
5. Inventory every platform `Domain::SELINUX` and `Domain::BLOB` namespace
   included in the Nucleus product.
6. Replace each required SELinux namespace mapping with an explicit tuple of:
   - namespace
   - owning Android AID or small set of AIDs
   - allowed Keystore operations
7. Deny unmapped SELinux and blob namespaces.
8. Define administrative Keystore permissions through explicit platform AIDs.
   Root, system_server, vold, lock settings, and other platform services receive
   only the operations their shipped call paths require.
9. Apply the backend to operation, security-level, authorization, maintenance,
   metrics, compatibility, and confirmation interfaces. No returned Binder
   object may reintroduce a SID requirement.
10. Preserve the Keystore database, KeyMint calls, key characteristics,
    authentication tokens, grants, operation limits, and cryptographic
    behavior.
11. Emit a concise denial containing caller UID, requested operation, and
    namespace. Never log key material or sensitive parameters.

### Phase 10 qualification gates

- Keystore2 registers and remains alive through completed Android boot.
- system_server creates and retrieves lock-settings synthetic-password keys.
- a normal app creates, uses, and deletes a key in its own namespace.
- another app UID cannot use that key.
- an explicit grant permits only its recorded operations.
- an unmapped platform namespace is denied.
- StatsD and other SID-requesting services also remain reachable, confirming
  that Phase 2 fixed the shared transport layer.
- Stock-mode Keystore2 continues to use SELinux authorization.

Phase 5 implementation is complete when Keystore authorization no longer
depends on a Binder SID or process context and retains explicit cross-UID
isolation.

## Phase 6 — Complete the Storage Lifecycle Boundary

Phase 6 removes the remaining label assumptions from vold without replacing
them with process-name or UID guesses.

### Implementation

In `system/vold`:

1. Consolidate the existing container checks for device-node creation,
   directory preparation, and user subdirectory preparation behind one cached
   storage security mode.
2. Verify that every `setfscreatecon`, `lgetfilecon`, and `lsetfilecon` path is
   unreachable in Nucleus mode.
3. Replace `IsFuseDaemon`, which identifies MediaProvider through the SELinux
   label of `/proc/<pid>/mounts`.
4. Track FUSE daemon PIDs explicitly as part of the mount lifecycle:
   - register the PID when the daemon is accepted for a user mount
   - associate it with the user and mount
   - remove it on daemon death or unmount
   - reject stale PID reuse by retaining the process start time or pidfd
5. Make open-file cleanup consult that registry when deciding whether to spare
   a FUSE daemon.
6. Keep `killFuseDaemon` as the explicit override.
7. Keep restorecon property requests out of the container path where their only
   effect is labeling.

### Phase 10 qualification gates

- User storage preparation completes without label access.
- MediaProvider-backed emulated storage mounts and unmounts normally.
- cleanup spares the registered live FUSE daemon when requested.
- cleanup does not spare an unrelated process with a reused PID.
- the explicit kill override terminates the registered daemon.
- ordinary processes holding files under an unmounted prefix remain eligible
  for termination.
- Stock-mode vold retains its SELinux-based setup where applicable.

Phase 6 implementation is complete when storage lifecycle decisions use
explicit runtime identity instead of filesystem labels.

## Phase 7 — Cover ART and Package Artifact Lifecycles

Phase 7 handles update and recompilation paths that do not execute during every
boot.

### Implementation

In `art` and `system/libartpalette`:

1. Give ART's platform integration a cached Nucleus container security mode.
2. Make `ArtdInjector::Restorecon` return success without label access in
   Nucleus mode while preserving all directory and artifact work.
3. Skip the direct `setfilecon` on odrefresh staging directories in both
   odrefresh and libartpalette.
4. Preserve creation mode, ownership, cleanup, atomic staging, file flush,
   rename, and rollback behavior.
5. Cover app-specific oat directories as well as the global dalvik cache.
6. Cover pre-reboot dexopt and ART APEX update flows.
7. Keep stock restorecon and staging labels unchanged outside Nucleus.

In PackageManager and installd:

8. Exercise application install, update, move, rollback, and uninstall paths
   after the Phase 4 wrappers are in place.
9. Verify that no artifact path silently relies on inheriting an SELinux label
   for its ordinary DAC accessibility.

### Phase 10 qualification gates

- First-boot dex compilation completes.
- An app-specific oat directory is compiled and atomically installed.
- odrefresh creates and atomically installs its staging output.
- failed compilation cleans temporary output without removing prior valid
  artifacts.
- package install, update, rollback, and uninstall complete without label
  errors.
- resulting files retain correct UID, GID, and modes.

Phase 7 implementation is complete when boot-time and update-time artifact
production have complete label-neutral paths.

## Phase 8 — Complete Developer and Optional Service Surfaces

Phase 8 removes remaining product-visible assumptions after the core runtime is
stable.

### `run-as` and adb

1. Make `run-as` skip `selinux_android_setcontext` in Nucleus mode.
2. Preserve package debuggability checks, UID/GID transition, supplementary
   groups, data-directory validation, and environment setup.
3. Keep adb restorecon calls as successful label no-ops.
4. Skip adb root and recovery `setcon` transitions in Nucleus mode.
5. Preserve adb privilege dropping and authentication.

### Incremental FS

6. Make IncFS control-file restorecon a label no-op in Nucleus mode.
7. Preserve mount validation, control-file discovery, and failure handling.
8. Exercise this path only when the Nucleus product enables and supports IncFS.

### Remaining services

9. Audit the final production call-site inventory for direct:
   - `getfilecon`, `lgetfilecon`, and `fgetfilecon`
   - `setfilecon`, `lsetfilecon`, and `setfscreatecon`
   - `getcon`, `getpidcon`, and `setcon`
   - `selinux_check_access`
   - `selinux_android_setcontext`
   - restorecon variants
   - `FLAT_BINDER_FLAG_TXN_SECURITY_CTX`
10. Classify each call as:
    - already safe because the public wrapper succeeds or bypasses while
      SELinux is disabled
    - unreachable in the Nucleus product
    - requiring the repository's container-security capability
11. Cover shipped DRM and AI Seal services through the Binder transport policy.
12. Leave hwservicemanager and legacy HIDL-specific patches out of the Nucleus
    product while HIDL service management remains unsupported and unused.
13. Leave recovery, DSU, virtualization guests, and host-only tools unchanged
    unless they enter the Nucleus product dependency graph.

### Phase 10 qualification gates

- `adb shell` remains authenticated and usable.
- `run-as` succeeds for a debuggable package and rejects a non-debuggable
  package.
- shipped SID-requesting services accept Binder transactions.
- optional enabled storage and installation features complete without label
  failures.
- no excluded component is added merely to satisfy this audit.

Phase 8 implementation is complete when every shipped production SELinux call
has an explicit classification and every reachable hard dependency has been
removed.

## Phase 9 — Normalize Diagnostics and Runtime Health Gates

Phase 9 makes regressions visible without adding source-shape or
configuration-inspection tests.

### Implementation

1. Keep component diagnostics focused on failed operations, not routine
   container no-ops.
2. Stop invoking restorecon in high-volume container paths once their
   repository-level wrapper exists. Do not emit thousands of
   `SELinux is disabled, skipping restorecon` messages.
3. Retain one startup message per affected daemon describing its selected
   security backend.
4. Extend Collider's Android boot health evaluation to identify:
   - Zygote specialization death
   - system_server restart
   - failed small-parcel Binder transactions
   - installd app-data failure
   - Keystore unavailability
   - repeated Android framework reboot
5. Treat those conditions as boot failure and preserve the existing clean
   compositor and container shutdown behavior.
6. Keep host AppArmor denials, capability failures, BPF failures, protected
   sysctl writes, and ptrace restrictions in separate diagnostic categories.
   They are not reported as Android SELinux failures.

### Phase 10 qualification gates

- A healthy run produces no:
  - `Unable to getfilecon`
  - installd label failure
  - PackageSettings SELinux WTF
  - failed Binder transaction caused by security-context transport
  - Keystore disconnect
  - Zygote specialization loop
- A deliberately induced app-specialization failure causes Collider to stop the
  Android container and compositor cleanly.
- Interrupting log following remains a successful user cancellation.
- Diagnostics identify the failing subsystem and retain its complete logs.

Phase 9 implementation is complete when Collider's health model classifies and
terminates every defined security-boundary failure.

## Phase 10 — End-to-End Qualification

Phase 10 validates the complete non-SELinux product contract in strict order.

1. Provision a fresh modern Nucleus Android runtime.
2. Execute `libselinux_nucleus_disabled_test` inside the installed container.
3. Confirm the runtime emits the single absent-SELinux init diagnostic and no
   repeated disabled-restorecon warning.
4. Confirm a SID-requesting local Binder service accepts transactions without
   a transported SID.
5. Confirm Binder caller PID and UID remain unchanged and cannot acquire an
   Android AID through host-UID translation.
6. Confirm servicemanager becomes context manager and the runtime contains no
   security-context-related small-parcel failures.
7. Complete cold boot without retained app data.
8. Reach `sys.boot_completed=1` without system_server restart.
9. Launch SystemUI, Provision or the configured home activity, Settings, and a
   normal application.
10. Confirm the Android surface renders through Composer3 in the Nucleus
   compositor.
11. Verify per-app data isolation with two distinct application UIDs.
12. Verify Keystore ownership and grant behavior with those UIDs.
13. Install, update, rollback, and uninstall an application.
14. Exercise app-specific dex compilation and ART staging.
15. Exercise emulated storage mount and unmount.
16. Exercise adb shell and `run-as`.
17. Exit normally through the compositor shortcut.
18. Exercise a forced Android boot failure and confirm complete session
    shutdown.
19. Switch away from and back to the compositor TTY only after the normal and
    failed shutdown gates pass.

Phase 10 is complete when the entire runtime operates without Android SELinux,
retains its independent isolation contracts, and shuts down cleanly on both
success and failure.

## Deferred Security Hardening

Running Android's own SELinux policy inside a compatible host environment
remains a later security-hardening project. It does not block this plan and
does not introduce a dual runtime path now.

That later work may replace the Nucleus authorization backends and label no-ops
with real Android SELinux enforcement. Until then, the product contract is
explicit: Android SELinux is absent, host AppArmor confines the container, and
Android's UID, mount, ownership, Binder UID, and explicit authorization
boundaries remain mandatory.

## Completion Criteria

This plan is complete when all of the following are true:

- no shipped Android process requires a SELinux filesystem label
- no shipped Binder service requires a transaction security context
- no security decision grants access merely because a SID or label is absent
- libselinux never fabricates a label, policy state, or successful access check
- Binder caller PID and UID are never rewritten to impersonate an Android AID
- Zygote preserves per-process app-data and SDK-sandbox mount isolation
- installd preserves ownership, modes, quota, encryption, and artifact
  contracts
- Keystore preserves key ownership, grants, and explicit platform permissions
- storage identifies protected daemon processes through explicit lifecycle
  identity
- ART and package update paths operate without labels
- Collider rejects and cleanly terminates unhealthy Android sessions
- stock Android behavior remains unchanged outside the Nucleus product
