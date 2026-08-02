# Chromium products

The Chromium build has one supported public entry point and one production
configuration:

```sh
collider browser doctor
collider browser bootstrap
collider browser build
collider browser test
collider install browser
```

`bootstrap` reports missing host-side source and packaging tools from
`../cef/apt-deps.txt`, including the exact `sudo apt-get install` command the
user may run, then materializes the source lock. It never mutates the host
package database. Chromium compilation dependencies live only in the pinned
rootless builder image. `build` performs the complete production build and
publishes both products. Product selectors, package-only modes, update
bypasses, and ad-hoc GN overrides are unsupported.

## Source architecture

`source.lock.json` is the sole browser source-selection input. It selects exact
commits and trees in the genuine `nucleus-os` Chromium, CEF, ANGLE, Skia, V8,
and Dawn forks, plus the exact canonical `depot_tools` commit. It has no format
version: source updates replace the complete lock atomically.

Collider maintains bounded bare object caches under
`~/.cache/nucleus/cef/repository-cache/`. A private candidate generation checks
out the locked Chromium commit, synchronizes the upstream DEPS graph, overrides
ANGLE, Skia, V8, and Dawn with their exact fork commits, checks out CEF, runs
Chromium hooks, resolves PGO profiles, and verifies CEF translation and API hashes.
Publication requires every selected repository to have the locked commit and
tree with a clean worktree.

The resulting `source-provenance.json` binds the lock digest, all six commit
and tree identities, `depot_tools`, Chromium DEPS, the resolved gclient graph,
and both PGO profiles. Existing source directories are verified against that
provenance and are never repaired or adopted. Nucleus source preparation does
not run CEF's patcher, apply patches, or use `automate-git.py`.

CEF and Nucleus Browser share this one content-addressed source generation,
mounted read-only at compile time. Their separate writable GN outputs live
under `~/.cache/nucleus/cef/build/<source-id>/` because their allocator
contracts differ. CEF
embeds `libcef.so` into another process and disables Chromium's allocator shim
and BackupRefPtr support. The standalone browser retains PartitionAlloc, the
allocator shim, and BackupRefPtr. Both are official PGO/ThinLTO builds using
LLD, Siso, native Wayland, Graphite/Dawn/Vulkan, and no SwiftShader compositor
fallback.

The build order is strictly sequential:

1. verify declared host tools and prepare the pinned Chromium builder;
2. materialize or verify the source generation;
3. build, package, and validate CEF;
4. build, package, and validate Nucleus Browser;
5. apply cache retention.

Independent CEF and browser link pools never run concurrently. Local Siso work
is capped at 16 jobs. GN and Ninja run in the rootless builder with networking
disabled; packaging, artifact execution, sandbox checks, and GPU/Wayland tests
run on the host.

## Identities and publication

Each successful output contains `.nucleus-built-build.json`. It binds source
provenance, resolved `args.gn`, Chromium clang, and exact PGO profiles.
Packaging and installation recompute that identity and reject stale outputs.

CEF publishes complete SDK and tarball generations beneath
`~/.cache/nucleus/cef/dist/`. Nucleus Browser publishes validated artifact
generations beneath `~/.cache/nucleus/cef/browser-dist/`. Stable `current`
links switch only after validation.

The installed browser uses versioned generations under
`~/.local/lib/nucleus-browser/generations/`. A single atomic `current` symlink
switches the runtime, launcher, desktop entry, icons, Widevine payload, and
recorded sandbox identity together.

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
and focused Ozone/Viz presenter tests. Browser startup and live
Wayland/120 Hz/media acceptance remain explicit user-run validation after
installation.
