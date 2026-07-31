# Nucleus Fork and Upstream Commit Migration

## Invariant

`nucleus-os` owns every repository that carries Nucleus-maintained changes to
third-party or AOSP source. The Nucleus monorepo remains the source-control and
release boundary: its submodule gitlinks, package references, Android source
lock, manifest commit, and superproject commit select the complete external
source graph.

No build applies a downstream patch stack after source materialization. Every
maintained third-party change is a normal commit in a `nucleus-os` repository.
Every external checkout resolves to an exact commit. Moving refs are useful for
development but never substitute for a pinned commit in a build input.

Every canonical GitHub repository is a genuine GitHub fork. GrapheneOS is the
direct parent when GrapheneOS actively maintains the project and contains the
frozen AOSP base. Unchanged AOSP projects use an exact-history GitHub mirror.
The Nucleus branch begins at the frozen AOSP base plus the existing Nucleus
commit; GrapheneOS changes land later as explicit reviewed commits.

The migration is a hard cutover. Patch application, patch reconciliation,
forward-patch provenance, and compatibility with the old source layout are
deleted when fork-backed materialization lands.

Status: complete

## Execution State

Organization ownership, transferred-fork verification, AOSP commit
publication, superproject construction, manifest construction, source-lock
cutover, patch-pipeline deletion, consumer repointing, and real-checkout source
materialization are complete. Every canonical repository is now a genuine
GitHub fork with the selected direct parent. The temporary import, migration
backup, and pre-fork staging repositories have been deleted after their
canonical refs were verified. A clean `nucleus_x86_64-user` image build,
release signing pass, and image-provenance validation complete successfully
from the fork-backed source graph.

The selected source graph is:

```text
manifest commit:     549048432a098fea5b3a2a58bea3948ad87def57
superproject commit: ac9631ab62101ae9e4635b4293246e69285ee477
manifest SHA-256:    e77fd22da0e3a9576dde69da2f9cc9ec95bae1387d9e6f4761c0adb926c6778e
branch:              nucleus-android-17.0.0_r1
```

The manifest pins all 22 Nucleus projects by commit, identifies the containing
Nucleus branch for bounded fetches, and shallow-materializes those exact branch
tips. Collider verifies the manifest ref and digest, the superproject ref, and
every resolved project revision against its superproject gitlink.

`platform_frameworks_base` is a direct fork of
`GrapheneOS/platform_frameworks_base`. Its
`nucleus-android-17.0.0_r1` ref resolves to
`2a7c81a620759f8114938689558875da4e40ea42`, whose tree is
`66621a481a00ab4dcdd8c80706e03c99a545a76a`.

## Repository Naming

GitHub organization:

```text
nucleus-os
```

Repository names preserve the upstream project name with `/` replaced by `_`.
They do not add a second `android_` prefix:

```text
platform/frameworks/base  -> nucleus-os/platform_frameworks_base
platform/system/core      -> nucleus-os/platform_system_core
device/generic/goldfish   -> nucleus-os/device_generic_goldfish
```

All repository and submodule push URLs use SSH:

```text
git@github.com:nucleus-os/<repository>.git
```

Read-only automation may use HTTPS. Source-controlled URLs use one canonical
form and never rely on GitHub transfer redirects.

## Agent Execution Conventions

An agent executing this plan uses the GitHub CLI for GitHub authentication,
inventory, repository creation, repository transfer, repository settings, and
remote-state inspection. It uses `git` for commit graph operations, tree
identity, ref publication, submodule gitlinks, and local remote configuration
because `gh` does not replace Git's object and transport operations.

Start every execution by validating the active account and organization
membership:

```sh
gh auth status --hostname github.com
actor=$(gh api user --jq .login)
gh api "orgs/nucleus-os/memberships/$actor" \
  --jq '{state, role}'
```

Require active membership with sufficient organization and repository
administration privileges. Do not attempt a transfer or create a repository
when that check fails.

Use `gh repo view` before every create or transfer target:

```sh
gh repo view "nucleus-os/$repository" \
  --json nameWithOwner,url,visibility,isPrivate,defaultBranchRef
```

An existing destination is never overwritten or assumed equivalent. Inspect
its refs and ancestry first. If the destination does not exist,
`gh repo view` exits unsuccessfully and the phase may create or transfer it.

Use `gh api` for GitHub operations not exposed as a first-class `gh repo`
subcommand. Repository transfer uses the GitHub REST endpoint through `gh api`;
the migration does not depend on an extension or interactive web UI.

Record every command and resolved object ID in a durable migration log under
the run diagnostics directory. Never write credentials, tokens, or complete
`gh auth` output into the repository.

## Phase 1: Establish Organization Ownership

Grant the required repository creation, transfer, administration, and SSH push
permissions in `nucleus-os`. Configure the organization security policy,
required maintainers, default visibility, and protected development refs before
moving source.

Transfer the existing GitHub forks currently consumed from `maddythewisp` into
`nucleus-os` without rewriting their histories:

| Current repository | Destination repository | Current consumer |
| --- | --- | --- |
| `maddythewisp/skia` | `nucleus-os/skia` | `core/third-party/skia` |
| `maddythewisp/swift-system` | `nucleus-os/swift-system` | `third-party/swift-system` |
| `maddythewisp/swift-java` | `nucleus-os/swift-java` | `third-party/swift-java` |
| `maddythewisp/swift-java-jni-core` | `nucleus-os/swift-java-jni-core` | SwiftPM and `third-party/swift-java-jni-core` |
| `maddythewisp/swift-subprocess` | `nucleus-os/swift-subprocess` | `third-party/swift-subprocess` |
| `maddythewisp/platform_hardware_google_gfxstream` | `nucleus-os/platform_hardware_google_gfxstream` | `third-party/gfxstream` |
| `maddythewisp/platform_external_mesa3d` | `nucleus-os/platform_external_mesa3d` | `third-party/mesa` and the AOSP source graph |
| `maddythewisp/nvidia-vaapi-driver` | `nucleus-os/nvidia-vaapi-driver` | Browser image integration |

Before each transfer, record:

- the repository object ID at every Nucleus-maintained ref;
- the default ref;
- repository visibility;
- protected-ref rules;
- deploy keys, automation credentials, and required teams;
- open issues and any repository-specific build integration.

After each transfer, resolve the same refs from `nucleus-os` and require
identical object IDs. Recreate organization-owned teams, protection rules,
deploy keys, and automation access before changing consumers.

Enumerate all repositories owned by `maddythewisp` through the hosting provider
and compare that inventory with every URL in the monorepo. Any additional
Nucleus-maintained fork consumed by the build, packaging, documentation, or
deployment flow lands in `nucleus-os` as part of this phase. Personal
repositories that are not Nucleus dependencies remain personal.

Build the provider-side inventory with `gh`:

```sh
gh repo list maddythewisp \
  --limit 1000 \
  --json name,nameWithOwner,url,visibility,isFork,isArchived \
  >"$migration_diagnostics/personal-repositories.json"

gh repo list nucleus-os \
  --limit 1000 \
  --json name,nameWithOwner,url,visibility,isFork,isArchived \
  >"$migration_diagnostics/organization-repositories.json"
```

Inspect each known source repository before transfer:

```sh
gh repo view "maddythewisp/$repository" \
  --json \
nameWithOwner,url,visibility,isPrivate,isFork,parent,defaultBranchRef

gh api --paginate \
  "repos/maddythewisp/$repository/branches?per_page=100" \
  --jq '.[] | {name, sha: .commit.sha, protected}'

gh api --paginate \
  "repos/maddythewisp/$repository/releases?per_page=100" \
  --jq '.[] | {id, tag_name, draft, prerelease}'
```

Record every ref, not only the default branch:

```sh
git ls-remote \
  "git@github.com:maddythewisp/$repository.git" \
  >"$migration_diagnostics/$repository.before.refs"
```

Transfer a repository through the GitHub API:

```sh
gh api \
  --method POST \
  "repos/maddythewisp/$repository/transfer" \
  -f new_owner=nucleus-os \
  -f new_name="$repository" \
  --jq '{name, full_name, owner: .owner.login}'
```

Repository transfer completes asynchronously. On the next execution boundary,
query the destination until GitHub returns its metadata:

```sh
gh repo view "nucleus-os/$repository" \
  --json nameWithOwner,url,visibility,isPrivate,defaultBranchRef
```

Do not proceed for that repository until the destination resolves. Then compare
all refs:

```sh
git ls-remote \
  "git@github.com:nucleus-os/$repository.git" \
  >"$migration_diagnostics/$repository.after.refs"

diff -u \
  "$migration_diagnostics/$repository.before.refs" \
  "$migration_diagnostics/$repository.after.refs"
```

Restore or enforce repository settings with `gh repo edit` and `gh api`:

```sh
gh repo edit "nucleus-os/$repository" \
  --enable-issues=false \
  --enable-wiki=false

gh api \
  --method PUT \
  "repos/nucleus-os/$repository/branches/$protected_branch/protection" \
  --input "$branch_protection_payload"
```

The exact visibility and feature settings come from the recorded pre-transfer
metadata and the `nucleus-os` organization policy. Never make a private
repository public as an incidental part of transfer.

Update every existing consumer in the same phase:

- `.gitmodules`;
- nested repository remotes used for Nucleus pushes;
- `third-party/swift-java/Package.swift`;
- package lockfiles containing source URLs;
- provisioning and bootstrap scripts;
- `AGENTS.md`;
- browser and networking plans that name a personal fork;
- CI, deploy keys, and repository allowlists.

The known source-controlled personal references that must disappear are:

```text
git@github.com:maddythewisp/skia.git
git@github.com:maddythewisp/swift-system.git
git@github.com:maddythewisp/swift-java.git
git@github.com:maddythewisp/swift-java-jni-core.git
git@github.com:maddythewisp/swift-subprocess.git
git@github.com:maddythewisp/platform_hardware_google_gfxstream.git
git@github.com:maddythewisp/platform_external_mesa3d.git
maddythewisp/nvidia-vaapi-driver
```

Finish the phase by searching the tracked checkout for `maddythewisp`. No
source, configuration, plan, package dependency, or agent instruction may
still direct Nucleus development to a personal namespace. Historical commit
author email addresses and local Git reflogs are not migrated or rewritten.

Update each local push remote after transfer:

```sh
git -C "$checkout" remote set-url \
  "$nucleus_remote" \
  "git@github.com:nucleus-os/$repository.git"

git -C "$checkout" remote get-url --all "$nucleus_remote"
git -C "$checkout" ls-remote "$nucleus_remote" HEAD
```

Edit tracked `.gitmodules`, Swift package declarations, documentation, and
`AGENTS.md` with the repository's normal patch-editing workflow, then apply:

```sh
git submodule sync --recursive
git submodule foreach --recursive 'git remote -v'
```

The resulting output contains no active `maddythewisp` fetch or push URL.

## Phase 2: Freeze the AOSP Patch Source

Complete the in-progress Android host-display architecture before freezing the
patch source. Capture these authoritative inputs:

```text
android-runtime/aosp.lock.json
android-runtime/aosp/patches.json
android-runtime/aosp/patches/
android-runtime/.aosp-source/.nucleus/base-resolved-manifest.xml
android-runtime/.aosp-source/.nucleus/patched-resolved-manifest.xml
```

For every repository in `patches.json`, record:

- checkout path;
- upstream project name;
- base commit from `base-resolved-manifest.xml`;
- ordered patch filenames;
- patched head commit;
- patched tree ID.

Require every patched checkout to be clean and require its base commit to be an
ancestor of its patched head. Do not begin repository publication while a patch
or generated patched checkout is changing.

The frozen Android base is:

```text
release:             Android 17.0.0 Release 1
platform revision:   refs/tags/android-17.0.0_r1
manifest commit:     5bc9a7ce1cd78dd53613bbfd0ebf506e1e4adb0f
superproject commit: 28f0bbddc24d56c8ec5a8df5342ac7a292184039
```

## Phase 3: Create the AOSP Repository Set

Create or reuse the following repositories in `nucleus-os`:

| AOSP project | Checkout path | `nucleus-os` repository |
| --- | --- | --- |
| `platform/manifest` | manifest metadata | `platform_manifest` |
| `platform/superproject` | superproject metadata | `platform_superproject` |
| `platform/build/soong` | `build/soong` | `platform_build_soong` |
| `platform/build` | `build/make` | `platform_build` |
| `device/generic/goldfish` | `device/generic/goldfish` | `device_generic_goldfish` |
| `platform/external/selinux` | `external/selinux` | `platform_external_selinux` |
| `platform/art` | `art` | `platform_art` |
| `platform/frameworks/base` | `frameworks/base` | `platform_frameworks_base` |
| `platform/hardware/interfaces` | `hardware/interfaces` | `platform_hardware_interfaces` |
| `platform/system/core` | `system/core` | `platform_system_core` |
| `platform/system/apex` | `system/apex` | `platform_system_apex` |
| `platform/system/security` | `system/security` | `platform_system_security` |
| `platform/system/libartpalette` | `system/libartpalette` | `platform_system_libartpalette` |
| `platform/system/libvintf` | `system/libvintf` | `platform_system_libvintf` |
| `platform/frameworks/native` | `frameworks/native` | `platform_frameworks_native` |
| `platform/system/vold` | `system/vold` | `platform_system_vold` |
| `platform/system/netd` | `system/netd` | `platform_system_netd` |
| `platform/packages/providers/MediaProvider` | `packages/providers/MediaProvider` | `platform_packages_providers_MediaProvider` |
| `platform/packages/apps/Launcher3` | `packages/apps/Launcher3` | `platform_packages_apps_Launcher3` |
| `platform/packages/modules/adb` | `packages/modules/adb` | `platform_packages_modules_adb` |
| `platform/packages/modules/Connectivity` | `packages/modules/Connectivity` | `platform_packages_modules_Connectivity` |
| `platform/packages/modules/UprobeStats` | `packages/modules/UprobeStats` | `platform_packages_modules_UprobeStats` |
| `platform/system/bpf` | `system/bpf` | `platform_system_bpf` |
| `platform/external/mesa3d` | `external/mesa3d` | `platform_external_mesa3d` |

`platform_external_mesa3d` is the repository transferred in Phase 1. Reuse it;
do not create a competing Android-only Mesa fork. Its canonical repository is
a GitHub fork of `aosp-mirror-neo/platform_external_mesa3d` and carries both
Nucleus Android source lines.

Create each canonical repository through GitHub's fork operation:

```sh
gh repo fork "$parent" \
  --org nucleus-os \
  --fork-name "$repository" \
  --default-branch-only

gh repo view "nucleus-os/$repository" \
  --json nameWithOwner,url,visibility,isPrivate,isFork,parent
```

Require `isFork` and the intended direct parent before publishing a Nucleus
ref. Connectivity uses `LineageOS/android_packages_modules_Connectivity`
because GrapheneOS publishes that maintained project on GitLab rather than
GitHub. Record GrapheneOS's GitLab repository as an additional fetch-only
upstream for future security adoption.

## Phase 4: Publish the Materialized Patch Commits

Collider already materializes each patch as a normal commit in
`android-runtime/.aosp-source`. Publish those commits directly. Do not recreate,
squash, or reorder them.

Process repositories in the exact order declared by `patches.json`. For each
repository:

1. Verify that `HEAD` is the recorded patched head.
2. Verify that `HEAD^{tree}` is the recorded patched tree.
3. Verify that the recorded base is an ancestor of `HEAD`.
4. Add the `nucleus-os` repository as the push destination.
5. Publish `HEAD` at `refs/heads/nucleus-android-17.0.0_r1`.
6. Resolve the published commit from GitHub.
7. Require the remote commit and tree IDs to equal the recorded local IDs.

The operation for one project is:

```sh
source_path=android-runtime/.aosp-source/frameworks/base
base_commit=94b4c163b7dfe5ce3607f7bb8456f9573f7de57d
destination=git@github.com:nucleus-os/platform_frameworks_base.git

test -z "$(git -C "$source_path" status --short)"
git -C "$source_path" merge-base --is-ancestor "$base_commit" HEAD
git -C "$source_path" push \
  "$destination" \
  HEAD:refs/heads/nucleus-android-17.0.0_r1
```

Then compare the published object:

```sh
local_commit=$(git -C "$source_path" rev-parse HEAD)
local_tree=$(git -C "$source_path" rev-parse 'HEAD^{tree}')
remote_commit=$(git ls-remote \
  "$destination" \
  refs/heads/nucleus-android-17.0.0_r1 | awk '{print $1}')

test "$local_commit" = "$remote_commit"
git -C "$source_path" fetch "$destination" "$remote_commit"
remote_tree=$(git -C "$source_path" rev-parse "${remote_commit}^{tree}")
test "$local_tree" = "$remote_tree"
```

No patch file is deleted during this phase. The frozen patch source remains the
independent equivalence oracle until fork-backed materialization passes.

Before publishing each project, use `gh` to verify the destination identity:

```sh
gh repo view "nucleus-os/$repository" \
  --json nameWithOwner,url,visibility,isPrivate
```

After publication, verify the ref through GitHub as well as Git transport:

```sh
gh api \
  "repos/nucleus-os/$repository/git/ref/heads/nucleus-android-17.0.0_r1" \
  --jq '.object.sha'
```

## Phase 5: Construct the Nucleus Superproject

Seed `nucleus-os/platform_superproject` from the exact upstream superproject
commit:

```text
28f0bbddc24d56c8ec5a8df5342ac7a292184039
```

Update only the gitlinks for the 22 patched projects. Each changed gitlink
points to the exact commit published in Phase 4. Every unmodified AOSP gitlink
remains identical to the upstream superproject.

Set a gitlink without depending on a populated submodule checkout:

```sh
git update-index \
  --cacheinfo \
  160000,<published-project-commit>,<checkout-path>
```

Verify all changed paths with `git ls-tree`, then publish the resulting
superproject at:

```text
refs/heads/nucleus-android-17.0.0_r1
```

Record the exact resulting superproject commit. That commit is the
authoritative complete AOSP project graph.

Create and inspect the superproject repository with:

```sh
gh repo create nucleus-os/platform_superproject \
  --public \
  --description "Nucleus Android superproject" \
  --disable-issues \
  --disable-wiki

gh repo view nucleus-os/platform_superproject \
  --json nameWithOwner,url,visibility,isPrivate
```

If Phase 3 already created it, skip creation and require the existing repository
to be the previously verified empty or seeded destination.

## Phase 6: Construct the Nucleus Manifest

Seed `nucleus-os/platform_manifest` from the exact upstream manifest commit:

```text
5bc9a7ce1cd78dd53613bbfd0ebf506e1e4adb0f
```

Add the organization remote:

```xml
<remote
    name="nucleus"
    fetch="ssh://git@github.com/nucleus-os/" />
```

For every patched project, preserve its checkout `path` and replace its
repository `name`, remote, and revision. Revisions are exact 40-character
commits:

```xml
<project
    path="frameworks/base"
    name="platform_frameworks_base"
    remote="nucleus"
    clone-depth="1"
    upstream="refs/heads/nucleus-android-17.0.0_r1"
    revision="<exact-project-commit>" />
```

Point the manifest's superproject entry at the pinned branch:

```xml
<superproject
    name="platform_superproject"
    remote="nucleus"
    revision="nucleus-android-17.0.0_r1" />
```

Repo requires a named superproject revision to fetch the object before
`ls-tree`. The source lock independently requires that branch to resolve to the
exact Phase 5 commit, so the build graph remains commit-pinned.

Unmodified projects continue to use the AOSP remote and Android 17 revision.
Publish the resulting manifest at:

```text
refs/heads/nucleus-android-17.0.0_r1
```

Record the exact manifest commit and SHA-256 digest of `default.xml`. Collider
verifies both values and never accepts the branch tip without the lock match.

Create and inspect the manifest repository with:

```sh
gh repo create nucleus-os/platform_manifest \
  --public \
  --description "Nucleus Android source manifest" \
  --disable-issues \
  --disable-wiki

gh repo view nucleus-os/platform_manifest \
  --json nameWithOwner,url,visibility,isPrivate
```

If Phase 3 already created it, skip creation and validate the existing
destination before publication.

## Phase 7: Make the Android Source Lock Select the Fork Graph

Replace the single upstream-oriented platform record in
`android-runtime/aosp.lock.json` with separate ancestry and materialization
records:

```json
{
  "upstream": {
    "release": "Android 17.0.0 Release 1",
    "revision": "refs/tags/android-17.0.0_r1",
    "manifestCommit": "5bc9a7ce1cd78dd53613bbfd0ebf506e1e4adb0f",
    "superprojectCommit": "28f0bbddc24d56c8ec5a8df5342ac7a292184039"
  },
  "source": {
    "manifestURL": "ssh://git@github.com/nucleus-os/platform_manifest.git",
    "manifestRevision": "refs/heads/nucleus-android-17.0.0_r1",
    "manifestCommit": "<exact-manifest-commit>",
    "defaultManifestSHA256": "<default-xml-sha256>",
    "superprojectURL": "ssh://git@github.com/nucleus-os/platform_superproject.git",
    "superprojectRevision": "refs/heads/nucleus-android-17.0.0_r1",
    "superprojectCommit": "<exact-superproject-commit>"
  },
  "repo": {
    "...": "the existing pinned Repo launcher provenance"
  }
}
```

Do not add a lock schema version. The lock and Collider implementation move
together. A schema change is a hard migration.

`upstream` records auditable Android ancestry. Only `source` controls the
checkout that Nucleus builds.

## Phase 8: Replace Collider Patch Materialization

Change the Android source workflow in one cutover:

1. Verify the exact `nucleus-os` manifest ref and commit.
2. Verify the exact `default.xml` digest.
3. Verify the exact `nucleus-os` superproject ref and commit.
4. Initialize Repo from the `nucleus-os` manifest.
5. Sync the exact fork-backed project graph with superproject acceleration.
6. Generate one resolved manifest.
7. Verify every resolved project revision against the superproject gitlink.
8. Record the upstream base, Nucleus manifest commit, Nucleus superproject
   commit, and resolved-manifest digest in source provenance.

Delete these concepts from Collider:

- `AOSPSourcePatchManifest`;
- `AOSPSourcePatchStack`;
- `AOSPSourcePatch`;
- patch-manifest loading;
- patch application;
- patch reconciliation;
- forward-patch provenance;
- base-versus-patched checkout identity;
- `base-resolved-manifest.xml`;
- `patched-resolved-manifest.xml`.

The source workflow emits only:

```text
android-runtime/.aosp-source/.nucleus/resolved-manifest.xml
android-runtime/.aosp-source/.nucleus/source-provenance.json
```

Nucleus-owned product files under `android-runtime/aosp/device/nucleus` and
`android-runtime/aosp/packages/apps/NucleusRuntimeBridge` remain monorepo
sources staged into the materialized checkout. They are original Nucleus
projects, not upstream patch stacks, and do not move into separate repositories.

## Phase 9: Prove Source Equivalence

Use two disposable source directories for the one-time migration gate:

1. Materialize the frozen Android 17 base and apply the frozen patch stack.
2. Materialize the new `nucleus-os` manifest and superproject without patch
   application.

For every patched project, require identical tree IDs:

```sh
old_tree=$(git -C "$old_source/$path" rev-parse 'HEAD^{tree}')
new_tree=$(git -C "$new_source/$path" rev-parse 'HEAD^{tree}')
test "$old_tree" = "$new_tree"
```

For every unmodified project, require identical commit and tree IDs. Also
require:

- the resolved manifest contains the expected exact commits;
- every resolved revision equals its superproject gitlink;
- both source checkouts are clean;
- no project fetches from `maddythewisp`;
- no project depends on an unpinned moving ref;
- a fresh Android image builds from the fork-backed source;
- image signing, AVB assembly, package validation, and runtime-focused tests
  pass.

This is a one-time migration comparison. It does not become a maintained dual
source pipeline.

## Phase 10: Delete the Patch Source

After Phase 9 passes, delete:

```text
android-runtime/aosp/patches.json
android-runtime/aosp/patches/
```

Delete all patch-related implementation and tests in the same change. A
missing repository, unreachable commit, manifest mismatch, superproject
mismatch, or dirty checkout fails source provisioning. There is no fallback
that reconstructs the old patch stack.

Update Android runtime documentation to identify the manifest commit and
superproject commit as the source boundary.

## Phase 11: Establish the Ongoing Update Sequence

Every future third-party or AOSP change follows this order:

1. Change the affected `nucleus-os` repository.
2. Publish the new exact project commit.
3. Update the corresponding gitlink in `platform_superproject`.
4. Publish the new exact superproject commit.
5. Update the project revision and superproject revision in
   `platform_manifest`.
6. Publish the new exact manifest commit.
7. Update the manifest commit, manifest digest, and superproject commit in the
   monorepo source lock.
8. Verify the source lock against the remote refs.
9. Materialize a fresh source checkout.
10. Build and validate the complete dependent product.
11. Land the monorepo gitlink or source-lock selection alongside any dependent
    Nucleus code.

For ordinary SwiftPM or submodule forks, steps 3 through 7 reduce to updating
the monorepo package pin or submodule gitlink. The monorepo selection always
lands after the external commit it names is durable in `nucleus-os`.

## Completion Evidence

The migration is complete only when all of the following are true:

- every Nucleus-maintained external repository is owned by `nucleus-os`;
- every transferred ref resolves to the same object as before transfer;
- tracked source contains no active `maddythewisp` repository URL or ownership
  instruction;
- `.gitmodules` and package dependencies use canonical `nucleus-os` URLs;
- every submodule gitlink resolves from its declared remote;
- the 22 patched AOSP projects resolve from `nucleus-os` at exact commits;
- the Nucleus manifest and superproject agree for every project;
- Collider materializes AOSP without reading or applying patch files;
- `patches.json`, the patch directory, and patch-engine code no longer exist;
- a fresh fork-backed Android image passes the full build and validation
  pipeline;
- source provenance contains the upstream Android ancestry and exact Nucleus
  manifest, superproject, and resolved-manifest identities.

Run the final GitHub inventory and URL audit with:

```sh
gh repo list nucleus-os \
  --limit 1000 \
  --json name,nameWithOwner,url,visibility,isFork,isArchived \
  >"$migration_diagnostics/final-organization-repositories.json"

git grep -n 'maddythewisp' -- \
  ':!docs/nucleus-os-fork-commit-migration-plan.md'

git submodule foreach --recursive 'git remote -v'
```

The `git grep` exclusion applies only because this plan records the retired
namespace as migration history. No other tracked file may contain an active
personal-namespace dependency or ownership instruction.
