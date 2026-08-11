# Linux Package Distribution and Update Plan

Status: active

## Invariant

Collider builds, tests, stages private development generations, and produces
Linux package and repository artifacts. Collider never installs, upgrades,
rolls back, or removes the Nucleus product on a user system.

APT, DNF, and pacman are the only authorities that mutate system-owned Nucleus
files. An installed Nucleus component owns activation and rollback of optional
product capabilities whose lifecycle extends beyond package extraction. Nucleus
does not ship a parallel updater, background package client, or distribution-
independent replacement for the host package manager.

Every distribution package consumes the same immutable Nucleus runtime payload
for its architecture. Distribution adapters add dependency metadata and native
host integration; they do not rebuild, patch, or select a different runtime.
Repository metadata is published atomically, package versions are immutable,
and ordinary system upgrades keep Nucleus current after one explicit repository
enrollment.

## Product and Tool Boundaries

The macOS development host owns source orchestration and Linux artifact
production through Collider and Apple containers. It does not model a Linux
installation prefix as a product deployment.

The boundaries are:

- `collider build` produces immutable architecture artifacts;
- `collider run` builds or reuses a checkout-private development generation on
  a Linux development host;
- `collider dev-deploy linux-runtime` transfers that generation from the macOS build
  host to a declared Linux development target without installing it;
- `collider package` produces native packages and repository snapshots;
- release automation signs and uploads an already validated repository snapshot;
- APT, DNF, or pacman installs and updates Nucleus on Linux; and
- the installed `nucleus` administration boundary manages optional capability
  activation that must be transactional beyond the package-manager transaction.

`collider-setup.sh` remains the one-time developer-tool bootstrap. Its Collider
launcher installation is not Nucleus product installation and is outside this
plan's package-manager boundary.

## Current State

Collider currently retains three transitional product installation surfaces:

- `collider install session` assembles a generation below the checkout-local
  `.install` prefix;
- `collider install browser` publishes the Linux x86_64 browser into that prefix
  and is exposed even by the macOS Collider command tree; and
- `collider install android-addon` validates and mutates an add-on store directly
  on Linux.

`collider run` now publishes or reuses the requested checkout-private development
generation directly. Its active generation lives below
`.nucleus/runtime/development-runtime`; no run workflow calls the transitional
session install command. The shell recipe and runtime assembler describe runtime
publication rather than installation.

The Linux distribution portability work already provides the common relocatable
runtime payload, explicit host dependency contract, content-addressed
generations, host-integration templates, and deterministic Debian, RPM, and Arch
package manifests. It does not yet emit native package archives or repositories
that ordinary package managers can consume.

## Package Cohort

One release publishes a version-matched package cohort:

- `nucleus-runtime` contains the architecture-specific immutable runtime;
- `nucleus-session` contains systemd, PAM, Wayland-session, and host-integration
  policy;
- `nucleus-browser` contains the architecture-specific Chromium/CEF product;
- `nucleus-android-addon` contains the optional signed Android capability;
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
Stable, beta, and nightly are separate, explicit channels. Their enrollment
packages conflict so one machine cannot unintentionally follow more than one.
Nightly is the normal package-managed channel for development machines; it is
not a substitute for deploying an uncommitted development generation.

Repository paths are family-, channel-, and architecture-aware:

```text
packages.nucleus-os.org/apt/<channel>/
packages.nucleus-os.org/rpm/<channel>/
packages.nucleus-os.org/arch/<channel>/$arch/
```

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

## Phase 2: Add Non-Installed Remote Development Generations

Add `collider dev-deploy linux-runtime` on macOS. It selects one target architecture
and one existing runtime build selection, including debug, release, Tracy, or a
sanitizer, then builds or reuses the matching validated development generation.
The generation identity includes the complete Git working-copy identity,
toolchain and native dependency identities, architecture, optimization, and
instrumentation selection. Deploying uncommitted work therefore cannot be
mistaken for a repository release.

Development generation assembly belongs to the platform-neutral Linux artifact
graph, not `ColliderLinuxOperations`. macOS composes it from cross-built Linux
outputs without executing a target ELF binary. The task graph rebuilds only
invalidated inputs: a compositor edit does not rebuild Chromium, AOSP, a target
SDK, or an unchanged native dependency. `--no-build` republishes an already
validated matching generation when only transfer must be repeated.

The intended inner-loop command is:

```sh
collider dev-deploy linux-runtime \
  --host <ssh-config-alias> \
  --architecture <arm64|x86_64> \
  --optimize <debug|release>
```

This path requires neither CI, release signing, native package assembly,
repository publication, nor a package-manager refresh.

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
silently mixes its private runtime with a package-installed add-on generation.

Retain the current generation, a bounded number of prior generations, and every
generation held by a live session lease. Pruning takes the generation's lease
lock non-blockingly and cannot remove files from a running session.

Gate: a Linux desktop can run signed nightly packages on its primary VT, receive
a local dirty debug or release generation directly from the M2 Ultra, run that
generation on another VT, switch between them through normal seat handling, and
remove every development generation without changing package-manager state or
installed Nucleus state.

## Phase 3: Make the Browser a Package Input

Make both browser architectures ordinary immutable outputs of `collider build
browser`. Remove the special x86_64 installation task and its checkout prefix.
The common Linux package graph consumes the selected browser artifact by digest
and places it in `nucleus-browser` without rebuilding it.

Browser qualification consumes the package-installed generation. Development
diagnostics consume the build publication directly and do not simulate a system
installation on macOS.

Gate: the browser has no install entrypoint in the Collider component graph, and
arm64 and x86_64 package inputs come from their corresponding qualified build
publications.

## Phase 4: Emit Native Distribution Packages

Add the root `collider package linux-runtime` operation. It consumes the common
runtime, session integration, browser, and optional Android artifacts and emits
real `.deb`, `.rpm`, and `.pkg.tar.zst` packages for both architectures.

The existing distribution manifests become typed inputs to native package
assembly rather than user-facing results. Every adapter declares only runtime
dependencies, exact cohort relationships, owned paths, configuration-file
semantics, lifecycle hooks, and removal behavior. No adapter contains source
build logic.

Generate family-specific repository enrollment and keyring packages alongside
the product packages. Validate archive metadata, ownership, permissions,
dependency closure, maintainer scripts, installed paths, and clean removal
without modifying the build host.

Gate: a local package-manager root can install, upgrade, downgrade, and remove
the complete cohort using only the emitted native packages.

## Phase 5: Move Android Add-on Activation into Nucleus

Install the signed Android artifact through `nucleus-android-addon`. Add an
installed Nucleus add-on manager that validates compatibility and signatures,
activates one immutable generation atomically, preserves persistent Android
state across package changes, rolls back failed activation, and deactivates a
removed capability.

Package lifecycle hooks communicate with that installed boundary; they do not
reimplement its state machine. The installed `nucleus` administration CLI owns
manual installation of an offline signed artifact when that workflow is needed.
Collider only assembles and tests the artifact.

Gate: package-manager installation and removal exercise the same product-owned
activation contract as an offline artifact, and Collider does not mutate the
installed add-on store.

## Phase 6: Assemble Signed Repository Snapshots

Add deterministic repository assembly after native package production. Produce:

- APT `Packages`, `Release`, and `InRelease` metadata;
- RPM `repodata` plus package and metadata signatures;
- pacman database, files database, package signatures, and database signature;
- enrollment packages, public key material, checksums, and provenance; and
- a machine-readable release index tying every file to the source, toolchain,
  architecture artifact, package cohort, and channel.

Repository assembly accepts explicit signing identities and an immutable package
set. It performs no upload and no source or package download. Unsigned local test
snapshots are a distinct test fixture and cannot satisfy a release gate.

Upload versioned package objects before metadata. Publish repository metadata
last as the atomic visibility point. Never replace a published package version;
retain prior cohorts needed for supported rollback.

Gate: each package manager resolves a complete signed cohort from a local copy of
the generated snapshot, and interrupted publication cannot expose metadata that
references a missing package.

## Phase 7: Remove Collider Product Installation

Move every remaining caller to development staging, native packaging, or the
installed Nucleus add-on boundary. Then delete, in one cutover:

- `collider install session`;
- `collider install browser`;
- `collider install android-addon` and its lifecycle children;
- the root `collider install` command group;
- component install entrypoints and checkout installation-prefix policy; and
- obsolete parser, capability, action, and installation tests.

Regenerate the repository-scoped Collider skill from the reduced grammar.
Collider help and documentation describe only build, test, development run,
package, and inspection responsibilities.

Gate: no public Collider grammar, component entrypoint, workspace path, or test
models product installation, and the macOS and Linux Collider command trees
share that invariant.

## Phase 8: Publish and Qualify Native Update Lifecycles

Publish nightly repository snapshots first, then beta. Enroll clean Debian/Ubuntu,
Fedora/RHEL-family, and Arch-family systems through their native repository
package or documented trust bootstrap. Qualify on arm64 and x86_64:

1. clean repository enrollment and installation;
2. ordinary package-manager upgrade to a newer complete cohort;
3. interrupted download and interrupted transaction recovery;
4. explicit downgrade to a retained prior cohort;
5. signing-key transition through an earlier keyring update;
6. Android add-on installation, update, deactivation, and persistent-state
   preservation;
7. removal without deleting user-authored or persistent product state; and
8. reinstallation after removal.

Promote exact qualified repository snapshots from nightly to beta and from beta
to stable without rebuilding packages. Nucleus OS images carry their selected
repository configuration and keyring at image creation, so their first update
uses the ordinary package manager without a bootstrap step.

Gate: an enrolled system remains current through ordinary `apt upgrade`, `dnf
upgrade`, or `pacman -Syu`; no Nucleus updater or Collider command participates.
