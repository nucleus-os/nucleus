# Chromium products

The Chromium build has one supported public entry point and one production
configuration:

```sh
tools/nucleus chromium doctor
tools/nucleus chromium bootstrap
tools/nucleus chromium build
tools/nucleus chromium test
tools/nucleus chromium install
```

`bootstrap` installs its initial apt packages, prepares the pinned source
generation, and runs Chromium's upstream host dependency installer. It records
the current swap size but does not require the link-time swap budget. `build`
performs the complete production build and
publishes both products. The scripts below `chromium/` and `cef/` are internal
stages; product selectors, package-only modes, update bypasses, and ad-hoc GN
overrides are not supported workflows.

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

1. verify the host and 32 GiB swap contract;
2. prepare or verify the source generation;
3. build, package, and validate CEF;
4. build, package, and validate Nucleus Browser;
5. apply cache retention and record final disk usage.

Chromium budgets a Linux ThinLTO link at roughly 30 GiB. Independent CEF and
browser link pools therefore never run concurrently. Local Siso work is capped
at 16 jobs, and `vm.max_map_count`, free disk, free inodes, and swap are checked
before source or output mutation.

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

Every command creates:

```text
~/.cache/nucleus/cef/logs/runs/<timestamp>-<pid>-<operation>/
  manifest.json
  run.log
  <stage>.log
  storage.log
~/.cache/nucleus/cef/logs/latest -> runs/<most-recent-run>
```

Signals terminate the active stage process group. Locks prevent concurrent
source preparation, GN-output mutation, and publication.

Publication gates include source/build identity verification, CEF API hashes,
CEF consumer compile/link/load, dynamic-library resolution, browser version and
headless startup, and the focused Ozone/Viz presenter tests. The browser's live
Wayland/120 Hz/media acceptance remains an explicit user-run validation after
installation.
