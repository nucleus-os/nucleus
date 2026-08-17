# Android container security qualification plan

Status: active.

## Invariant

The optional `nucleus-android` native package runs Android 17 in one rootless LXC runtime whose host
boundary is enforced by user namespaces, cgroups, AppArmor, seccomp, mount
ownership, bounded device access, and explicit broker protocols. Android UID,
package, mount, Binder, storage, Keystore, ART, and application-data isolation
remain mandatory inside that boundary.

The product does not run Android SELinux. It does not fabricate labels, grant an
operation because a security context is absent, rewrite Binder callers to
impersonate an Android application ID, or disable Android's independent
UID/ownership checks. Stock Android behavior outside the Nucleus product remains
unchanged.

AOSP source is selected by the exact Repo manifest recorded in
`android-runtime/aosp.lock.json`. Modified projects are commits in genuine
`nucleus-os` forks; unchanged projects retain canonical upstream remotes. There
is no AOSP patch manifest or patch-materialization path.

The source changes and host-side security architecture are implemented. This
plan owns the remaining complete-runtime qualification.

## Phase 1 — Validate source and product provenance

Materialize the exact Repo graph, verify every modified project commit and tree,
build the selected Android product in the declared Apple-container execution
environment, sign it with the declared identity, and publish one immutable
artifact generation.

Gate: the source tree is clean, every selected revision is remotely resolvable,
and the product provenance binds the exact manifest, compiler inputs, native
Nucleus artifacts, configuration, and signing identity.

## Phase 2 — Validate the host isolation boundary

Validate the user namespace, UID/GID maps, cgroup delegation, AppArmor profile,
seccomp policy, capabilities, mount graph, APEX ownership, Binder devices,
graphics broker descriptors, input devices, audio endpoints, runtime directory,
network policy, and teardown ordering before booting Android.

Gate: excess devices, mounts, capabilities, descriptors, paths, and broker
operations are rejected; a failed preflight leaves no child process, mount,
cgroup, socket, or publication candidate.

## Phase 3 — Complete cold boot and framework qualification

Boot without retained application data. Require servicemanager context-manager
ownership, stable system_server, `sys.boot_completed=1`, SystemUI or the
configured home activity, Settings, and a normal application. Confirm no shipped
process requires an SELinux label or Binder transaction security context.

Gate: Android reaches a stable interactive boot without fabricated security
state, small-parcel failures, or system_server restart.

## Phase 4 — Exercise application isolation and platform services

Use two distinct application UIDs to verify application-data separation,
Keystore ownership and grants, install/update/rollback/uninstall, dex
compilation, ART staging, emulated-storage mount/unmount, adb shell, and
`run-as`.

Gate: every operation retains Android ownership and authorization semantics
without SELinux and without host-side identity impersonation.

## Phase 5 — Exercise graphics and lifecycle failure paths

Render an Android surface through Composer3 and the Nucleus compositor, exit
normally through the session lifecycle, force an Android boot failure, and
exercise compositor/session shutdown. Only after both paths pass, exercise VT
switch away and return.

Gate: normal and failed runs remove every Android process, mount, cgroup,
descriptor, socket, graphics resource, and runtime declaration.

## Phase 6 — Close the security migration

Record the qualified product/run identities in the Android runtime contract and
remove this qualification plan. Future Android SELinux support is a separate
hard migration, not a second concurrent runtime path.
