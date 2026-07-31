# Chromium and CEF Fork-Commit Migration

## Invariant

Every source change used by Nucleus Browser and embedded CEF is an ordinary
commit in a genuine `nucleus-os` fork. Browser source materialization selects
exact commits and trees from one lock. It never applies a Nucleus patch, runs
CEF's Chromium patcher, accepts a dirty checkout, or repairs an existing source
generation.

CEF and Nucleus Browser build from one source provenance and separate GN output
directories. The CEF allocator contract and standalone-browser allocator
contract remain distinct. There is one source path and no patch fallback.

## Selected Source

`chromium/source.lock.json` selects the complete source graph:

| Checkout | Genuine fork | Parent | Selected commit | Selected tree |
| --- | --- | --- | --- | --- |
| `chromium/src` | `nucleus-os/chromium` | `chromium/chromium` | `3bdd6908edfb2cd047ba1d6fe61ea6217a4bc9e7` | `95ad3bdbb0645db77287053cb4b372044512abcb` |
| `chromium/src/cef` | `nucleus-os/cef` | `chromiumembedded/cef` | `fed714e8a7c0cf6168720d489cbff4af0e4884a9` | `c7d2bba57546e529a9725016a652ee002077ae29` |
| `chromium/src/third_party/angle` | `nucleus-os/angle` | `google/angle` | `48910f210ec32f22ec21e48936afd4a2c547514a` | `3a46f5ef58e547f3a35349a35043c24a0a78c804` |
| `chromium/src/third_party/skia` | `nucleus-os/skia` | `google/skia` | `fdc1f06fc4bf1721fbb8b36891c192a73be6c2e1` | `231be80a1506ba228e7492af26c9202f5d1faeb1` |
| `chromium/src/v8` | `nucleus-os/v8` | `v8/v8` | `a5423b52e73a9d651ec9aeefa1cad55c9213e1af` | `e1ce86ae1bcc32893dfaef1d649c96aa6e0315e0` |
| `chromium/src/third_party/dawn` | `nucleus-os/dawn` | `google/dawn` | `46e228a52427554281e0eda17230a913babca4cb` | `ea5b6983bdb89e9a9720156446310a78d47a6ee2` |

The frozen product inputs are:

```text
CEF branch:          7922
Chromium version:    151.0.7922.19
depot_tools commit:  35892a9e24190cc5f3a511d3954319c93445926c
```

Chromium contains the precomposed CEF integration changes and Nucleus
Chromium-wide/browser behavior. CEF contains its OSR and generated API changes.
ANGLE, Skia, V8, and Dawn contain their owned downstream source changes.
Chromium's DEPS file retains canonical upstream revision identities so upstream
hooks and PGO revision checks remain valid; gclient `custom_deps` selects the
exact fork commits from the source lock.

The lock contains no format version. A source update replaces the complete
lock atomically. Hard migration or cache reset is the response to an
incompatible lock shape.

## Phase 1: Capture the Qualified Trees — Complete

The previously qualified patch-backed generation was captured before cutover.
The capture recorded:

1. upstream and final commits for Chromium, CEF, ANGLE, Skia, V8, and Dawn;
2. final tracked trees after CEF integration, translation, and all Nucleus
   changes;
3. Chromium DEPS and resolved dependency revisions;
4. CEF generated API output and hashes;
5. `depot_tools` and PGO identities;
6. the previous source and product build metadata.

Path ownership was resolved before creating source commits. The unused
`depot_tools` source-tarball change was intentionally dropped because Nucleus
does not produce Chromium source tarballs.

## Phase 2: Establish Commit-Backed Trees — Complete

The qualified changes now exist in the six genuine forks listed above. Every
selected commit has its frozen upstream commit as an ancestor. Each selected
tree is clean, remotely resolvable, and bounded by the
`nucleus-cef-151.0.7922.19` development ref.

Chromium's selected source graph points at the selected ANGLE, Skia, V8, and
Dawn commits. CEF translation and version generation are idempotent at the
selected CEF commit. Dawn includes stable version metadata required by Chromium
hooks.

## Phase 3: Make the Source Lock Authoritative — Complete

`chromium/source.lock.json` is the sole browser source-selection input. It
records:

1. product branch and Chromium version;
2. exact fork and canonical-upstream remotes;
3. frozen upstream commits;
4. selected commits and trees;
5. exact checkout ownership;
6. the pinned canonical `depot_tools` commit.

Collider validates the complete repository set, fixed checkout paths, expected
`nucleus-os` remotes, canonical upstream remotes, and full lowercase object
identifiers. The source-generation identifier is the first 24 hexadecimal
characters of the lock's SHA-256 digest.

## Phase 4: Materialize Exact Clean Source — Complete

Collider now performs this sequence:

1. verify or create bounded bare Chromium and CEF object caches under
   `~/.cache/nucleus/cef/repository-cache`;
2. create a private source-generation candidate;
3. check out the exact locked Chromium commit using the persistent object
   cache;
4. configure unmanaged gclient source with exact ANGLE, Skia, V8, and Dawn
   fork overrides;
5. synchronize the upstream Chromium dependency graph without hooks or
   history;
6. check out the exact locked CEF commit using its persistent object cache;
7. run Chromium hooks and acquire the locked Chromium and V8 PGO profiles;
8. run CEF translation and version checks;
9. verify all six commits, trees, and clean worktrees;
10. write and recompute `source-provenance.json`;
11. publish the generation and switch `current` atomically.

`source-provenance.json` binds the source-lock digest, six selected repositories,
`depot_tools`, Chromium DEPS, resolved gclient graph, Chromium PGO profile, and
V8 builtins PGO profile.

The persistent bare caches own objects referenced by generation checkout
alternates and therefore are not generation-retention targets. Source
generations remain bounded independently.

## Phase 5: Package CEF In Tree — Complete

CEF packaging directly invokes the selected checkout:

```text
cef/tools/make_distrib.py
  --output-dir=<private candidate>
  --allow-partial
  --ninja-build
  --x64-build
  --minimal
  --no-archive
```

Collider owns the final SDK layout, tarball, checksum, build manifest, external
consumer compile/link/load check, and atomic publication. Downloaded
`automate-git.py` is not a source or packaging input.

## Phase 6: Delete the Patch Architecture — Complete

The workspace patch directories and patch-bearing Chromium recipe types are
removed. Collider no longer hashes, discovers, applies, reverses, or diagnoses
browser patch files. Product builds consume `source-provenance.json`.

Behavioral tests cover:

1. exact clean source-provenance validation and atomic activation;
2. lock-derived source identity;
3. ordered CEF and browser task ownership;
4. in-tree CEF distribution and validated publication;
5. GN metadata and product-build identity;
6. package-list parsing and diagnostics.

## Phase 7: Verify the Hard Cutover — Complete

Acceptance proceeds in this order:

1. verify every remote fork relationship and locked object;
2. materialize a cold generation;
3. repeat bootstrap and reuse the verified generation;
4. run all Collider tests;
5. build and validate CEF;
6. build and validate Nucleus Browser;
7. run focused Ozone and Viz presenter tests;
8. audit the workspace for deleted patch-path and automation references;
9. inspect both published artifact manifests against the shared provenance.

Cold materialization and repeat-bootstrap reuse passed. The first product
compile exposed and corrected a missing ANGLE half of Chromium's
DRM-render-node device-selection contract. A subsequent full compile exposed
and corrected the missing Skia half of Chromium's backdrop-replacement
contract. The final production source tree built and published both CEF and
Nucleus Browser from shared provenance. The final Chromium commit adds only a
test-fixture initialization correction; that delta compiled independently and
all eight OutputPresenterOzone tests passed.

Both Collider test suites, browser doctor, deterministic repeat CEF
publication, the focused Ozone suite, and the focused Viz presenter suite
passed. All six selected repositories remain clean, remotely resolvable,
strictly ahead of their frozen upstream commits, and genuine GitHub forks of
their canonical parents.

## Final State

The monorepo owns browser orchestration, product configuration, source lock,
packaging, validation, launchers, and publication. It owns no downstream
Chromium-family patch files.

The six `nucleus-os` forks own all downstream source changes. Collider
materializes exact clean commits, builds both products sequentially, and
publishes immutable validated artifacts from one source provenance.
