# Chromium products

The Chromium build has one supported public entry point and one production
configuration:

```sh
tools/collider browser doctor
tools/collider browser bootstrap
tools/collider browser build
tools/collider browser test
tools/collider browser install
```

`bootstrap` reports missing packages from `../cef/apt-deps.txt`, including the
exact `sudo apt-get install` command the user may run, then prepares the pinned
source generation. It never mutates the host package database. `build`
performs the complete production build and publishes both products. Product
selectors, package-only modes, update bypasses, and ad-hoc GN overrides are
not supported workflows.

## Fixed architecture

CEF and Nucleus Browser share one content-addressed prepared source generation.
The generation identity covers the exact CEF commit, Chromium version and
commit, depot_tools commit, exact-commit `automate-git.py`, and every common,
CEF, browser, and Dawn patch. Preparation starts from a pristine checkout and
never reverses patches in an existing generation.

The products retain separate GN outputs because their allocator contracts are
different. CEF embeds `libcef.so` into another process and disables Chromium's
allocator shim and BackupRefPtr support. The standalone browser retains
PartitionAlloc, the allocator shim, and BackupRefPtr. Both outputs are official
PGO/ThinLTO builds using LLD, Siso, native Wayland, Graphite/Dawn/Vulkan, and no
SwiftShader compositor fallback.

The build order is strictly sequential:

1. verify required executables and declared package dependencies;
2. prepare or verify the source generation;
3. build, package, and validate CEF;
4. build, package, and validate Nucleus Browser;
5. apply cache retention.

Independent CEF and browser link pools never run concurrently. Local Siso work
is capped at 16 jobs. Collider does not impose swap, disk-space, inode, or
`vm.max_map_count` policy; failures from the actual build and filesystem remain
authoritative.

## Identities and publication

Each successful output contains `.nucleus-built-build.json`. It binds the
source-generation manifest, resolved `args.gn`, Chromium clang, and exact PGO
profiles. Packaging and installation recompute that identity and reject stale
outputs.

CEF publishes complete SDK and tarball generations beneath
`~/.cache/nucleus/cef/dist/`. Nucleus Browser publishes validated artifact
generations beneath `~/.cache/nucleus/cef/browser-dist/`. Prepared directories,
tarballs, checksums, and stable `current` links are switched only after their
validation gates pass.

The installed browser uses versioned generations under
`~/.local/lib/nucleus-browser/generations/`. A single atomic `current` symlink
switches the runtime, launcher, desktop entry, icons, Widevine payload, and
recorded sandbox identity together. The active and immediately preceding
installed generations are retained; older recognized generations are removed.

## Logs and validation

Every command uses Collider's shared run registry:

```text
<workspace>/.nucleus/runs/<run-id>/
  manifest.json
  run.log
  stages/<task>.log
<workspace>/.nucleus/latest -> runs/<most-recent-run>
```

Signals terminate the active stage process group. Locks prevent concurrent
source preparation, GN-output mutation, and publication.

Publication gates include source/build identity verification, CEF API hashes,
CEF consumer compile/link/load, dynamic-library resolution, launcher syntax,
and the focused Ozone/Viz presenter tests. Browser startup and live
Wayland/120 Hz/media acceptance remain explicit user-run validation after
installation.
