# Linux Package Distribution and Update Plan

Status: active

## Invariant

Collider builds, tests, stages private development generations, and produces
Linux package and repository artifacts. Collider never installs, upgrades,
rolls back, or removes the Nucleus product on a user system.

APT, DNF, and pacman are the only authorities that install, activate, upgrade,
roll back, or remove system-owned Nucleus files and optional capabilities.
Nucleus does not ship a parallel installer, generation store, updater,
background package client, or distribution-independent replacement for the
host package manager.

Every distribution package consumes the same immutable Nucleus runtime payload
for its architecture. Distribution adapters add dependency metadata and native
host integration; they do not rebuild, patch, or select a different runtime.
Repository metadata is published atomically, package versions are immutable,
and ordinary system upgrades keep Nucleus current after one explicit repository
enrollment.

`https://packages.nucleus-os.org` is the repository and trust origin. A
Cloudflare Worker serves that origin from
[strongly consistent R2](https://developers.cloudflare.com/r2/reference/consistency/)
repository snapshots and routes package-object requests. Immutable GitHub
Releases in `nucleus-os/nucleus` are the initial package-object backend. Release
automation uploads complete native package objects there before repository
metadata can reference them. Repository and package signatures authenticate
content independently of its download location; GitHub release attestations
are supplemental provenance, not a replacement for package-manager
verification.

## Product and Tool Boundaries

The macOS development host owns official source orchestration, dual-architecture
Linux artifact production, signing, and publication through Collider and Apple
containers. It does not model a Linux installation prefix as a product
deployment.

The independent
[Linux x86_64 development host](linux-x86-64-development-host-plan.md) may build
and run local x86_64 development artifacts. Its GHCR contributor inputs are
build-time OCI artifacts, not native packages, repository objects, release
channels, or an alternate product updater. This plan does not publish or resolve
them.

The boundaries are:

- `collider build` produces immutable architecture artifacts;
- `collider run` builds or reuses a checkout-private development generation on
  a Linux development host;
- `collider dev-deploy linux-runtime` transfers that generation from the macOS build
  host to a declared Linux development target without installing it;
- `collider package` produces native packages and repository snapshots;
- protected release automation signs a validated cohort, publishes its package
  objects to the active immutable backend, then publishes its repository
  metadata;
- APT, DNF, or pacman installs and updates Nucleus on Linux; and
- installing or removing an optional native package activates or deactivates
  its capability declaration as part of the package-manager transaction.

`collider-setup.sh` remains the one-time developer-tool bootstrap. Its Collider
launcher installation is not Nucleus product installation and is outside this
plan's package-manager boundary.

## Current State

Collider retains one transitional product installation surface:
`collider install session` assembles a generation below the checkout-local
`.install` prefix. Android has no Nucleus- or Collider-owned installation,
activation, generation-store, compatibility-document, or publisher-signature
surface. `nucleus-android` is an exact-cohort native package; package-manager
ownership activates its capability declaration, while Android Verified Boot
authenticates its image chain.

`collider run` now publishes or reuses the requested checkout-private development
generation directly. Its active generation lives below
`.nucleus/runtime/development-runtime`; no run workflow calls the transitional
session install command. The shell recipe and runtime assembler describe runtime
publication rather than installation.

The Linux distribution portability work provides the common relocatable runtime
payload, explicit host dependency contract, content-addressed generations, and
host-integration templates. The root `collider package linux-runtime` operation,
typed Debian, RPM, and Arch adapters, exact browser package input, native archive
assemblers, and product-artifact envelopes are implemented and qualified for
both architectures. The root SwiftPM closure resolves Swift System through one
pinned `nucleus-os` source identity. Every package and family cohort publishes
through the local product store, isolated APT/RPM/pacman roots exercise the full
install/upgrade/downgrade/remove lifecycle, and unchanged invocations reuse the
published cohorts. Package storage retains the active and one rollback cohort
per architecture and prunes product-store objects by exact retained-manifest
reachability. Repository snapshots remain pending.

`collider build browser` publishes validated arm64 and x86_64 browser payloads
under their exact tree digests. A separate typed package-input publication binds
each selected payload digest, target architecture, immutable generation, and
build-manifest digest. Collider has no browser installation task, component
entrypoint, prefix policy, or command.

Immutable releases are enabled for `nucleus-os/nucleus`. Existing browser
runtime publications and the signed Android image archive fit below GitHub's
per-asset limit. Final native package assembly must enforce that limit for every
architecture and package family rather than relying on those preliminary
measurements.

## Package Cohort

One release publishes a version-matched package cohort:

- `nucleus-runtime` contains the architecture-specific immutable runtime;
- `nucleus-session` contains systemd, PAM, Wayland-session, and host-integration
  policy;
- `nucleus-browser` contains the architecture-specific Chromium/CEF product;
- `nucleus-android` contains the optional architecture-specific Android
  capability, its AVB-authenticated images, and its session declaration;
- `nucleus-development-host` contains only the host capability dependencies
  needed to run user-owned development generations;
- `nucleus` is the complete-installation meta-package; and
- the family-specific Nucleus repository and keyring package enrolls the machine
  and carries signing-key transitions.

Packages whose runtime contracts cannot drift require the exact matching Nucleus
release. Architecture-neutral integration and enrollment packages are `all` or
`noarch`; runtime, browser, and Android payloads are published for arm64 and
x86_64.

## Repository Contract

The authoritative repository origin is `https://packages.nucleus-os.org`.
Nightly is the only repository channel. Its enrollment package configures one
machine for the nightly repository, and ordinary package-manager operations keep
that machine current. Nightly packages remain qualified, signed, immutable
cohorts; the channel name does not weaken any production artifact, security, or
rollback gate. Nightly is not a substitute for deploying an uncommitted
development generation. Beta and stable channels, enrollment packages, channel
objects, promotion operations, and support promises are deferred to the
[multi-channel release promotion plan](multi-channel-release-promotion-plan.md).

The origin is a narrowly scoped Cloudflare Worker with
[read-only R2 bindings](https://developers.cloudflare.com/r2/api/workers/workers-api-reference/)
to a repository-metadata R2 bucket and a future package-object R2 bucket. The Worker
serves immutable signed repository snapshots from the metadata bucket. It
routes immutable package-object paths by the release index: initially with an HTTPS
redirect to a versioned asset in an immutable GitHub Release, and after the
object-store cutover by streaming the content-addressed R2 object. It performs
no signing, publication, package selection, or mutation.

Nightly state is one small R2 object per package family and architecture. It
names an immutable repository snapshot by digest. Publication uploads and
verifies the complete snapshot before replacing that nightly object with one
atomic write. The Worker reads nightly state through its R2 binding
without edge caching. Immutable snapshot responses use cache keys containing
the snapshot digest and may be cached indefinitely. A client therefore observes
one complete old or new snapshot, never a partially uploaded directory or a
stale cached nightly mapping.

Package asset names include package family, version, and architecture and are
never reused. The GitHub release tag identifies the immutable Nucleus version
and build, never the mutable nightly pointer. A release is created as a draft,
receives the complete cohort, passes digest and size verification, and is
published only after every asset is present. Publication locks the assets and
associated tag.

Each natural native package is one release asset and must be smaller than 2
GiB. Assembly warns at 1.75 GiB and publication rejects an asset at or above 2
GiB before upload. Nucleus does not split one package into transport fragments
to evade the backend limit.

The first cohort containing a natural package at or above 2 GiB performs one
hard package-object cutover. That complete cohort and every subsequent cohort
stores all package objects in the dedicated R2 object bucket under
content-addressed, write-once keys. Earlier cohorts remain in their immutable
GitHub Releases. The origin paths, repository signatures, package signatures,
release-index digests, nightly-state model, and package-manager configuration do
not change. The R2 publisher refuses to overwrite an existing digest key; signature
and digest verification turn any storage substitution into a loud failure.

Repository paths are family- and architecture-aware beneath the one nightly
channel:

```text
packages.nucleus-os.org/apt/nightly/
packages.nucleus-os.org/rpm/nightly/
packages.nucleus-os.org/arch/nightly/$arch/
```

## Publication Backend Matrix

| Payload | Backend | Mutation authority |
|---|---|---|
| Package and repository signatures | Protected signing environment | Release signer only |
| Repository HTTP origin | Cloudflare Worker at `packages.nucleus-os.org` | Infrastructure deployment only |
| Signed APT, RPM, and pacman snapshots and nightly state objects | Repository-metadata R2 bucket | Repository-metadata publisher only |
| Package objects before object-store cutover | Immutable GitHub Releases | GitHub release-object publisher only |
| Package objects from the cutover cohort onward | Package-object R2 bucket | R2 package-object publisher only |
| Contributor builder images and declared build inputs | GHCR OCI artifacts | Contributor-input publisher only |
| Build intermediates and compiler caches | Local Collider storage | Owning build identity only |

The release signer receives only the constrained signing subkey and has no
network publication credential. The release-object publisher receives GitHub
`contents:write` and no signing, R2, or GHCR credential. The
repository-metadata publisher receives
[bucket-scoped R2 Object Read & Write access](https://developers.cloudflare.com/r2/api/tokens/)
to the metadata bucket and no signing or GitHub write permission. The
contributor-input publisher receives GitHub `packages:write` and no release or
R2 credential. After object-store cutover, the R2 package-object publisher
receives Object Read & Write access only to the object bucket and no signing
credential. Build and qualification runners receive none of these authorities.
Worker deployment uses a separate infrastructure identity and its runtime
bucket bindings are read-only.

APT receives deb822 source configuration, a repository-scoped `Signed-By`
keyring, and signed `InRelease` metadata. It never uses `apt-key` or a globally
trusted third-party key.

DNF receives a `nucleus-release` RPM that installs the repository configuration
and public key. Package signature checking and repository-metadata signature
checking are both mandatory. RPM-family dependency wrappers may differ between
Fedora, RHEL-compatible, and openSUSE environments while carrying the same
runtime payload.

Pacman receives a Nucleus keyring, mirror configuration, signed packages, and a
signed repository database generated by `repo-add`. Its repository requires
trusted package and database signatures. Each architecture has a separate
repository database.

The release root key remains offline. A constrained release-signing subkey signs
packages and metadata. A replacement key lands in the already trusted keyring
package before repository metadata begins using it. Compromise recovery revokes
the affected subkey through that same established trust path.

## Phase 1: Separate Development Staging from Installation

Status: complete.

Replace checkout-local product-installation terminology with a development
runtime publication boundary. Give the staged generation a checkout-private
path that does not imply a system prefix. Rename internal configuration and
actions where they describe staging, publication, or generation activation
rather than package installation.

Make `collider run` build or reuse this private generation directly. Preserve
content-addressed reuse, runtime validation, profiling, sanitizer selection, and
`--no-build` semantics without routing through a public install command.

Gate: every developer launch uses a validated private generation and no
developer workflow invokes `collider install session`.

## Phase 2: Make the Browser a Package Input

Status: complete.

Both browser architectures are ordinary immutable outputs of `collider build
browser`. Each validated payload generation is named by its complete tree
digest. A separate content-addressed package-input manifest binds the selected
payload digest, target architecture, immutable generation, and build-manifest
digest for the common Linux package graph.

The special x86_64 installation action, task, storage generation, component
entrypoint, checkout prefix, macOS command, and installation tests are deleted.
Development diagnostics consume the validated build publication directly and
do not simulate a system installation on macOS.

Gate satisfied: behavioral graph coverage proves that each architecture's
package-input task consumes only its matching browser publication, while
artifact coverage proves that the manifest resolves the exact immutable payload
and rejects substituted bytes. CLI composition and grammar coverage prove that
no browser installation surface remains.

## Phase 3: Emit Native Distribution Packages

Status: complete.

`collider package linux-runtime` emits real `.deb`, `.rpm`, and `.pkg.tar.zst`
cohorts for arm64 and x86_64 from exact runtime and browser publications. Each
package and family cohort is an immutable `ProductArtifactEnvelope` published
through `LocalProductArtifactStore`. Arch metadata, archive entry ownership and
mode, sandbox setuid identity, path containment, dependency closure, maintainer
scripts, and clean removal are validated from the package bytes.

The SwiftPM closure resolves the canonical Swift System identity through the
pinned `nucleus-os` mirror without a duplicate identity. RPM disables every
`__os_install_post` transformation, so the native package adapter never strips
or mutates an already-built cross-architecture payload. Package publication is
incremental. A final retention task runs on every package invocation after both
architecture qualifications, keeps the active and one rollback generation for
each lane, and prunes only known product and archive objects not referenced by
those retained cohort manifests; unknown store entries survive.

Gate evidence: the corrected dual-architecture native package, lifecycle, and
retention graph succeeded in run `2026-08-16T17-27-41.466Z-39675` without an RPM
strip attempt; unchanged run `2026-08-16T17-45-01.664Z-43818` reused every
package cohort and qualification while still running reachability retention;
empty-cache dependency resolution selected the pinned forks without an identity
warning; and retention reduced package/product storage to two generations per
architecture with zero interrupted candidates.

## Phase 4: Make Android an Ordinary Native Package

Status: complete.

Emit `nucleus-android` as an architecture-specific member of every native
package cohort. The package owns one immutable Android payload path and
`/usr/share/nucleus/session-capabilities/android.json`. Installation activates
the capability by installing that declaration; removal deactivates it by
removing the declaration. Exact-cohort dependency on `nucleus-runtime` prevents
the Android host binaries and base runtime from drifting.

Keep `/var/lib/nucleus/android` outside package ownership so upgrades,
downgrades, and removal retain persistent Android state. Package signatures
authenticate the native package, and the packaged AVB public key verifies the
Android image chain at runtime. Do not add lifecycle hooks when ordinary file
ownership provides the required transaction.

Delete the separate add-on manager, generation store, compatibility document,
publisher key and signature, installed `nucleus addon` commands,
`collider install android-addon`, and the downloadable-directory packaging
surface. An offline artifact is installed through the host package manager's
local-package operation; it is not a second product format.

Gate: APT, DNF, and pacman installation, upgrade, downgrade, removal, and
reinstallation activate the exact packaged Android capability while retaining
persistent state; malformed payload or AVB provenance fails package
qualification; neither Nucleus nor Collider exposes a parallel add-on
installation or activation system.

Achieved state: `nucleus-android` is the sixth member of each architecture and
package-family cohort, owns an immutable package payload plus the Android
capability declaration, depends exactly on `nucleus-runtime`, and leaves
`/var/lib/nucleus/android` outside package ownership. The custom manager,
generation store, compatibility and publisher-signature inputs, installed
`nucleus addon` grammar, and `collider install android-addon` grammar are gone.
The package input and runtime contract use package terminology and contain no
independent schema-version, installer, updater, or trust root.

Gate evidence: Collider run `2026-08-17T08-43-25.628Z-3959` passed the complete
Collider suite, including exact package-input payload/provenance acceptance and
malformed identity and unsigned-provenance rejection. Run
`2026-08-17T08-26-34.228Z-95006` assembled arm64 and x86_64 Debian, RPM, and Arch
cohorts, qualified install, upgrade, downgrade, removal, reinstallation, and
final removal for every package, retained Android persistent state, and
completed product-store retention.

## Phase 5: Assemble Signed Repository Snapshots

Add deterministic repository assembly after native package production. Produce:

- APT `Packages`, `Release`, and `InRelease` metadata;
- RPM `repodata` plus package and metadata signatures;
- pacman database, files database, package signatures, and database signature;
- enrollment packages, public key material, checksums, and provenance; and
- a machine-readable release index tying every file to the source, toolchain,
  architecture artifact, package cohort, and nightly publication state.

Repository assembly accepts explicit signing identities and an immutable package
set. It performs no upload and no source or package download. Unsigned local test
snapshots are a distinct test fixture and cannot satisfy a release gate.

Use the same repository signing identity and metadata path for
`nucleus-android` as every other native package. Do not introduce an Android-only
publisher key, enrollment flow, repository, or update channel; AVB remains the
independent integrity boundary only for the packaged Android image chain.

Generate the family-specific repository enrollment and keyring packages here,
from the public half of the explicit signing identity. They carry repository
configuration, the active public key, and the key-transition contract and are
themselves members of the signed snapshot.

Gate: each package manager resolves and verifies the complete signed cohort from
a local copy of the generated snapshot; independently repeated assembly over the
same package set and signing inputs produces the same release index and
repository contents; and assembly performs no network access or publication.

## Phase 6: Remove Collider Product Installation

Move every remaining caller to development staging, native packaging, or the
installed native-package boundary. Then delete, in one cutover:

- `collider install session`;
- the root `collider install` command group;
- component install entrypoints and checkout installation-prefix policy; and
- obsolete parser, capability, action, and installation tests.

Regenerate the repository-scoped Collider skill from the reduced grammar.
Collider help and documentation describe only build, test, development run,
package, and inspection responsibilities.

Gate: no public Collider grammar, component entrypoint, workspace path, or test
models product installation, and the macOS and Linux Collider command trees
share that invariant.

## Phase 7: Publish Qualified Repository Cohorts

Protected publication consumes only trusted-`main` package bundles and
digest-bound qualification records accepted by the self-hosted CI contract. It
rejects PR-owned, missing, stale, translated, wrong-platform, or
wrong-capability evidence and performs no compilation, package assembly, or
artifact substitution.

Before the hard object-store cutover, release automation creates one draft
GitHub Release for the versioned cohort, uploads every package object, verifies
the remote asset sizes and digests against the release index, and publishes the
immutable release. After the cutover, the corresponding publisher instead
writes and verifies the complete cohort under absent content-addressed keys in
the package-object R2 bucket.

The repository-metadata publisher uploads the complete signed snapshot beneath
its digest in the metadata R2 bucket, reads it back for verification, and writes
the family/architecture nightly object last. That final atomic object write is
the visibility point. The publisher has no package-object or Worker deployment
credential. A published package version is never replaced.

Retain prior cohorts needed for supported rollback. Prune nightly snapshots and
package objects only after they leave the bounded rollback retention set and no
retained nightly snapshot references them. Before object-store cutover, pruning
deletes the whole eligible nightly GitHub Release; it never edits an immutable
release or removes an individual asset. After cutover, a separate retention
identity removes unreferenced immutable snapshot prefixes and content-addressed
R2 objects. Retained rollback cohorts are not prunable.

Gate: an interruption before package-object publication exposes no cohort; an
interruption before the final nightly-object write leaves the previous snapshot
active; a completed nightly write cannot reference a missing or unverified
package object; and the Worker origin serves the exact qualified cohort named by
the trusted release index.

## Phase 8: Publish and Qualify the Nightly Update Lifecycle

Publish only nightly repository snapshots. Enroll clean Debian/Ubuntu,
Fedora/RHEL-family, and Arch-family systems through the nightly repository
package or documented trust bootstrap. Qualify on arm64 and x86_64:

1. clean repository enrollment and installation;
2. ordinary package-manager upgrade to a newer complete cohort;
3. interrupted download and interrupted transaction recovery;
4. explicit downgrade to a retained prior cohort;
5. signing-key transition through an earlier keyring update;
6. Android package installation, update, removal, and persistent-state
   preservation;
7. removal without deleting user-authored or persistent product state; and
8. reinstallation after removal.

No active workflow creates beta or stable metadata, enrollment, credentials, or
publication state. Nucleus OS images carry the nightly repository configuration
and keyring at image creation, so their first update uses the ordinary package
manager without a bootstrap step.

Gate: a nightly-enrolled system remains current through ordinary `apt upgrade`,
`dnf upgrade`, or `pacman -Syu`; no Nucleus updater or Collider command
participates, and the publication surface contains no beta or stable channel.

## Phase 9: Add Non-Installed Remote Development Generations

Add `collider dev-deploy linux-runtime` on macOS after the production artifact,
qualification, package, and update contracts are complete. It selects one target
architecture and one existing runtime build selection, including debug, release,
Tracy, or a sanitizer, then builds or reuses the matching validated development
generation. The generation identity includes the complete Git working-copy
identity, toolchain and native dependency identities, architecture,
optimization, and instrumentation selection. Deploying uncommitted work
therefore cannot be mistaken for a qualified product artifact or repository
release.

Development generation assembly belongs to the platform-neutral Linux artifact
graph, not `ColliderLinuxOperations`. It reuses the portable product-artifact
identity, file-tree digest, executable metadata, and local validation primitives
from the self-hosted CI plan while remaining a distinct unsigned artifact type
with no qualification or publication authority. macOS composes it from
cross-built Linux outputs without executing a target ELF binary. The task graph
rebuilds only invalidated inputs: a compositor edit does not rebuild Chromium,
AOSP, a target SDK, or an unchanged native dependency. `--no-build` republishes
an already validated matching generation when only transfer must be repeated.

The intended inner-loop command is:

```sh
collider dev-deploy linux-runtime \
  --host <ssh-config-alias> \
  --architecture <arm64|x86_64> \
  --optimize <debug|release>
```

This path invokes no CI job, release signer, native package assembly,
repository publication, or package-manager refresh. It consumes the established
artifact contract without entering the production pipeline.

Use the host's standard SSH configuration and `rsync` transport. Do not add a
Collider daemon, worker, remote scheduler, source checkout, source upload, or
custom artifact protocol on the Linux target. The macOS host performs every
network operation; build containers remain offline.

Transfer into a temporary directory below the remote user's development store:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/nucleus/development/
  <workspace-identity>/generations/<digest>/
```

Use the preceding generation as an `rsync --link-dest` basis so unchanged files
become hard links and changed files alone cross the network. Validate the
transferred manifest and file digests before atomically renaming the temporary
directory and replacing the workspace's `current` symlink. A failed or
interrupted transfer leaves both the previous current generation and the
package-managed Nucleus installation untouched.

The development store is mode `0700`, deployment refuses symlinks that escape
it, and the generation is not signed as a release. Its authenticity comes from
the authenticated SSH connection and its user-owned destination; its integrity
comes from the validated generation manifest. It is never admitted into a
package repository or a system-owned installation prefix.

The deployed generation carries a self-contained
`nucleus-development-session` launcher. A stable user-level symlink points to
the workspace's current launcher; no package-managed executable interprets a
private development manifest or private same-build protocol. The launcher sets
workspace-specific configuration, data, state, cache, runtime, socket, and log
roots so the development session cannot read or mutate the installed nightly
session's operational state by accident.

Deployment never launches the compositor remotely. The developer switches to a
free local virtual terminal, logs in normally, and invokes the development
launcher there. Logind or the selected seat provider transfers DRM and input
ownership as the active VT changes; the package-managed session and development
session do not attempt simultaneous KMS ownership. Switching back resumes the
package-managed session through its ordinary seat pause/resume lifecycle.

The target satisfies host dependencies through its enrolled package repository.
The `nucleus-development-host` package provides the runtime-only host capability
dependencies for a target that does not otherwise have Nucleus installed. It
does not contain a Nucleus runtime or grant a development generation additional
privilege. Optional capabilities such as Android are used only when a matching
development capability generation is deployed; a development session never
silently mixes its private runtime with the installed `nucleus-android` payload.

Retain the current generation, a bounded number of prior generations, and every
generation held by a live session lease. Pruning takes the generation's lease
lock non-blockingly and cannot remove files from a running session.

Gate: a Linux desktop can run signed nightly packages on its primary VT, receive
a local dirty debug or release generation directly from the M2 Ultra, run that
generation on another VT, switch between them through normal seat handling, and
remove every development generation without changing package-manager state or
installed Nucleus state.
