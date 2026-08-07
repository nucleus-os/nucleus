# Remote Development, macOS Builder, and Self-Hosted Runner Plan

## Invariant

The M2 Ultra is the primary Nucleus development and build host. The
authoritative development workspace lives on M2-owned storage in a persistent,
digest-selected `linux/arm64` development machine. Developer computers are
replaceable editor and terminal clients; their packages, paths, caches, and
operating systems never enter a Nucleus build identity.

Linux host tools execute in separate digest-selected `linux/arm64` OCI images
through Apple `container`; those tools cross-compile Linux/amd64 artifacts.
Tasks that must execute a declared x86_64 configure probe or pinned x86_64-only
Android NDK host utility explicitly require macOS 27 Intel
binary translation inside that ARM64 guest. Translation is an execution policy
on the task, never a different builder image or artifact target.
macOS products compile natively as `macOS/arm64`. The persistent development machine never produces a candidate or
release artifact directly. Build artifacts are qualified on the operating
system, architecture, kernel, graphics stack, and hardware they claim to
support.

Runner platform, artifact target, and execution backend are independent values.
No recipe infers one from another through compile-time host conditionals. GitHub
Actions routes trusted work into Collider lanes; it does not become a second
build system.

Development builds use the same lanes without GitHub. Collider snapshots the
M2-owned development workspace, schedules work through the same host-wide
resource coordinator, and returns artifacts and durable logs by content
identity. A developer does not commit or push work to use the builder. Importing
a snapshot from another computer remains supported, but it is not the primary
development path.

The development environment is persistent and interactive. Product build
executors are disposable and hermetic. Native qualification workers are
replaceable implementations of declared capability contracts. The current
Ubuntu computer is neither a source authority nor a build dependency.

The public repository never executes pull-request code on a persistent or
privileged self-hosted runner. Build workers contain no signing identities,
publication credentials, personal credentials, or access to unrelated host
data.

Status: deferred

## Current Progress

The repository has closed the executable pull-request path into self-hosted
runners. Public pull requests now use a disposable GitHub-hosted verification
job with read-only permissions, immutable action identities, and no persisted
checkout credential. Trusted branch and manual events remain the only routes to
the self-hosted build and hardware jobs. Organization runner-group policy and
the isolated publisher remain provisioning work.

`ColliderCore` now represents runner, execution, artifact, and backend
coordinates independently. OCI and AOSP task identities, dry-run plans,
manifests, and explanations carry those coordinates. Linux amd64 artifact tasks
reject unsupported runner, execution, artifact, and translation combinations
before launching a child process.

Collider now owns one OCI operation model. Product recipes never construct
backend commands. `AppleContainerExecutor` translates the declared mount,
network, user, capability, privilege, process-filesystem, resource,
environment, platform, and output contract. AOSP compilation, signing, image
assembly, and sandbox validation use that contract. Behavioral tests cover the
translation and planning evidence.

Container lifecycle is an in-process Swift boundary. Collider builds against
the root-owned `apple/container`, `apple/containerization`, and `apple/swift-log`
upstream-main gitlinks, constructs the same typed configuration as Apple's CLI, and calls
`ContainerClient` for create, bootstrap, process start/wait, forced deletion,
and exact-name deletion verification. It uses the upstream build library plus
image, network, health, and disk-usage clients directly for image build and
identity, network inspection, cache reporting, pruning, and backend health. Cancellation shares
the same idempotent cleanup transaction. The installed CLI remains only in the
privileged login-session bootstrap script, which runs before the API service is
available. Clone-local SwiftPM mirrors make every
transitive dependency edge resolve to the root-owned gitlink without modifying
Apple's manifests. Doctor exercises the typed XPC health request, so an
installed CLI alone cannot satisfy the backend contract.

The Apple backend's concurrent build lifecycle is hardware-qualified. The M2 Ultra now
runs macOS 27.0 build `26A5388g`, Xcode 27 beta 4 build `27A5228h`, Apple
`container` 1.2.0. Native `linux/arm64` execution passes on the
host-only `nucleus-build-internal` network, and the declared case-sensitive
APFS volumes are provisioned. A forced concurrent ARM64 and x86_64 runtime
build passes through the typed lifecycle and leaves no managed container after
completion. `collider build runtime --rebuild` dirties only the selected build
tasks while reusing clean prerequisites. Collider's macOS graph compiles
through the public Apple Swift surface and the focused builder-doctor suite
passes under the selected Xcode. Native macOS builds now use that Xcode toolchain directly.
Swift compilers and LLVM are no longer built from source. Collider uses an
official Linux/arm64 Swift bootstrap compiler in a native Apple container to
build the Linux/arm64 target runtime natively and cross-build the Linux/amd64
target runtime against architecture-matched, libc++-only Ubuntu package
sysroots. SDK assembly then runs natively on macOS with Xcode and installs the
official Android Swift SDK artifact. Xcode supplies the macOS compiler, SDK,
and developer tools. Native Linux dependencies and
Linux-only integration work continue to use pinned Linux/arm64 OCI images and
declare their Linux/amd64 artifact target independently. Full Xcode is required
because Command Line Tools does not provide the complete macOS SDK and test
tooling contract.

The Linux architecture lanes now build concurrently in separate resource and
lock domains. Both boot the same `linux/arm64` builder image. The arm64 lane
executes only arm64 Linux processes. The x86_64 lane cross-compiles its products
and explicitly enables macOS 27 Intel binary translation only when a task must
execute an x86_64 configure probe or pinned x86_64-only Android NDK host
utility. Both production architecture graphs compile and link, but the Swift,
loader, and headless Vulkan test graph exists and executes only on native
Linux/arm64. Intel translation is never treated as native Linux x86_64, kernel,
performance, GPU, DRM, or release qualification evidence.

Apple `container` does not restore its dynamically bootstrapped launchd
registration after reboot. Its API server and helpers are launch agents that
are intentionally scoped to a logged-in user and cannot serve clients from the
system bootstrap namespace. Nucleus now declares the complete host contract and
persistent login-session bootstrap under `tools/macos-builder/`; installing
that bootstrap now restores Apple `container` successfully in the active
builder login session. Passing `collider doctor ci-macos-builder` and repeating
the reboot-and-login gate are the remaining Phase 4 host work. Phase 5 then
provisions the persistent development machine.

## Required Runner Topology

The final topology contains these distinct roles:

| Role | Environment | Purpose |
| --- | --- | --- |
| Hosted verification | Disposable GitHub-hosted worker | Untrusted pull-request formatting, policy, source-lock, and focused unit validation |
| Development gateway | Native service on the M2 Ultra | Authenticated remote access, editor tunneling, and development-machine lifecycle |
| Development machine | Persistent `linux/arm64` Apple container machine | Source checkout, uncommitted work, shell, editor server, language services, and Collider client |
| macOS builder | Native `macOS/arm64` environment on the M2 Ultra | macOS Swift toolchain, Apple-platform products, and native macOS validation |
| Linux builder | Apple `container` on the M2 Ultra | Linux-native C/C++ dependency builds and Linux-only build tools in pinned `linux/arm64` OCI images; declared x86_64 probes and pinned host utilities use macOS 27 Intel translation |
| Linux qualifier | Real `Linux/x86_64` worker | Loader, libc, sandbox, io_uring, process, integration, and performance qualification |
| GPU/DRM qualifier | Real `Linux/x86_64` Nucleus target hardware | Vulkan, DRM, GBM, DMA-BUF, synchronization, scanout, input, display, and session qualification |
| Publisher | Protected isolated environment | Signing, provenance attestation, release publication, and channel advancement |

The M2 Ultra also runs one native Collider worker service. The development
machine, imported development clients, and the GitHub runner submit work to
that service; none starts heavy build processes independently. The persistent
development machine does not host nested build containers.

The Linux qualifier may be an on-demand worker. The GPU/DRM qualifier is a
dedicated hardware role. The translated x86_64 confidence lane on the M2 Ultra
replaces neither role. QEMU, software Vulkan, and an amd64 Linux VM are absent.
No particular Ubuntu installation is required: any worker satisfying the
declared x86_64 or GPU/DRM capability contract can perform the corresponding
qualification.

## Platform Contract

Every build task declares all three coordinates explicitly:

```text
runner:
  operatingSystem: macOS
  architecture: arm64

executor:
  kind: oci
  backend: apple-container
  platform: linux/arm64

artifact:
  operatingSystem: linux
  architecture: x86_64
  abi: glibc
```

The production policy uses `linux/arm64` OCI builders for Linux-native host
tools. AOSP, Chromium/CEF, Skia, React Native native dependencies, and Linux
native support libraries retain one Linux/amd64 artifact graph through their
supported target/cross-compilation controls.
Swift product compilation uses the signed macOS host compiler with the pinned
Linux amd64 target SDK; it does not require an amd64 host Swift toolchain or an
OCI executor. Nucleus does not add a second source-built Swift pipeline.

Every Apple-container machine boots Linux/arm64. Compilation and ordinary Linux
host tools execute natively as arm64. A task sets Intel binary translation to
`required` only when its declared command must execute an x86_64 configure
probe or pinned x86_64-only Android NDK host utility. The Apple
backend then enables macOS 27's integrated translation facility for that task;
there is no separately installed Rosetta runtime, QEMU executor, or amd64 VM.

Translated x86_64 execution is limited to build inputs that have no native
arm64 equivalent, such as admitted configure helpers and pinned Android host
utilities. It proves only that the required tool can execute far enough to
produce its declared output. It does not qualify a Nucleus x86_64 product or
prove native CPU behavior, kernel behavior, sandbox performance, io_uring,
physical GPU behavior, DRM, GBM, DMA-BUF, explicit sync, scanout, or release
fitness. Real x86_64 and physical GPU/DRM workers remain the only authorities
for those qualification records.

## Phase 1: Close the Public-Repository Trust Boundary

Remove self-hosted jobs from the `pull_request` trigger before registering any
runner. Pull-request code runs only on disposable GitHub-hosted workers and
receives no repository, organization, signing, deployment, or runner-management
secret.

Restrict self-hosted execution to trusted `main`, protected staging or merge
queue revisions, and explicitly authorized manual invocations. Do not use
`pull_request_target` to check out or execute pull-request code.

Set workflow permissions to `contents: read` by default. Disable checkout
credential persistence. Pin every external action to a verified full commit
identity. Permit only approved actions and repository-owned workflows.

Create organization runner groups that grant access only to the Nucleus
repository and the exact trusted workflows that own each role. Labels describe
capabilities; runner groups enforce access policy.

### Exit Gate

- No public pull-request event can route to a self-hosted runner.
- No build worker receives a write-capable GitHub token.
- Every external action is immutable by full commit identity.
- Publication credentials exist only in the protected publisher environment.

## Phase 2: Separate Runner, Executor, and Artifact Models

Add first-class platform types to `ColliderCore`:

- `RunnerPlatform` identifies the operating system and architecture executing
  Collider.
- `ExecutionPlatform` identifies native execution or an OCI operating system
  and architecture.
- `ArtifactTarget` identifies the product operating system, architecture, ABI,
  and Android API level where applicable.
- `ExecutionBackend` distinguishes native execution from Apple `container`.

Replace recipe-level `#if os(macOS)` and `#if os(Linux)` decisions that choose a
product, architecture, tool path, or build strategy. Compile-time conditionals
remain only around APIs that cannot be referenced on another host.

Make platform coordinates part of task identity, artifact fingerprints,
diagnostics, manifests, and durable run records. Reject undeclared host or
container architecture fallback.

Replace hard-coded `darwin-x86_64`, `linux-x86_64`, multiarch library paths, and
NDK host tags with values resolved from the explicit execution contract.

### Exit Gate

- The same Collider binary can resolve a Linux amd64 build graph on macOS ARM64
  without changing the artifact target.
- Task explanations show runner, executor, and artifact coordinates.
- An accidentally resolved `linux/arm64` image fails before execution.
- No recipe uses the compiler host as an implicit product target.

## Phase 3: Centralize OCI Execution

Represent every container build operation with one `OCIExecution` contract. It
contains:

- immutable image identity and required OCI platform;
- command and working directory;
- read-only and read-write mounts;
- network policy;
- environment allowlist;
- user and group policy;
- capability, device, socket, and privilege policy;
- temporary filesystem policy;
- resource limits;
- declared outputs.

Implement `AppleContainerExecutor` as the only OCI build executor. It runs only
on the macOS ARM64 builder and produces structured execution evidence. Recipes
never construct backend CLI arguments or call Apple lifecycle APIs.

The Apple backend uses `ContainerAPIClient` and `ContainerCommands` from the
upstream-main `apple/container` source plus upstream-main
`apple/containerization` and `apple/swift-log`. It requests `linux/arm64` explicitly and owns create,
bootstrap, process start/wait, cancellation, force-delete, and deletion
verification as one typed transaction. Collider does not implement a custom
Virtualization.framework VM manager.

Pin the installed Apple `container` service release used by provisioning and
CI. Pin the client, containerization, and logging sources independently with
root gitlinks that track their canonical upstream main branches. `collider-setup.sh`
generates clone-local SwiftPM mirrors so all shared identities resolve to the
root-owned source closure. Keep image-build CLI arguments and output parsing
behind `AppleContainerExecutor`; keep lifecycle calls behind the typed runtime
adapter. A source or service update is an explicit infrastructure update with
contract qualification.

The executor disables external networking during compilation, drops
capabilities, prohibits privilege acquisition, hides the runner home, exposes
no desktop or device sockets, and mounts source inputs read-only. Linux hosts
never execute OCI build tasks; native Linux workers only qualify already-built
artifacts against declared capabilities.

### Exit Gate

- The behavioral contract suite covers typed Apple container configuration,
  exact-name cleanup, cleanup retry, and concurrent cleanup idempotence.
- Mount, network, privilege, environment, and platform violations fail before
  the child command starts.
- Every OCI task resolves to Apple `container` on the macOS ARM64 builder.
- Backend command lines do not appear in product recipes.
- The resolved dependency graph uses the root-owned upstream-main `container`
  and `containerization` gitlinks without conflicting SwiftPM identities.
- Updating the source gitlinks or installed service cannot change execution
  without passing typed health, behavioral, cancellation, and real-build gates.

## Phase 4: Qualify the macOS ARM64 Host Contract

Define a read-only macOS builder doctor lane. It requires:

- the selected macOS release and Xcode 27 beta 4 build `27A5228h`; full Xcode
  supplies the Swift Testing macro plugin required by the repository test
  targets, so Command Line Tools alone does not satisfy the lane;
- Apple `container` and its persistent builder-login launch agent;
- native Linux/arm64 container execution;
- macOS 27 Intel binary translation inside the Linux/arm64 container for
  explicitly declared x86_64 execution tasks;
- sufficient CPU, memory, and disk allocation;
- a case-sensitive build volume;
- the selected Xcode Swift compiler for native macOS work and the pinned Linux
  arm64 bootstrap compiler inside the Swift builder image;
- content-addressed cache and artifact roots;
- noninteractive execution with no pending license or authorization prompt.

Move all machine mutation into the runner image or host provisioning process.
Collider setup and CI jobs never install packages, select Xcode with `sudo`,
or modify system services.

Do not use the ordinary macOS home directory for large Linux build trees.
Apple-container VM filesystems and Collider-owned cache volumes hold Chromium,
AOSP, Swift, Skia, React Native, compiler cache, and OCI storage. Host-shared
source mounts are admitted only after performance and case-sensitivity
qualification.

Provision the first M2 Ultra executor in this order:

1. install Apple `container` 1.2.0 from the selected signed package on macOS
   27.0 build `26A5388g`;
2. register its builder-login launch agent and prove it restores the complete
   service set after restart and builder login without an authorization prompt;
3. prove an explicit `linux/arm64` container executes an arm64 binary, an amd64
   target build emits x86_64 ELF, and a separately declared translated
   confidence task executes that ELF without changing the guest platform;
4. create the internal host-only network named
   `nucleus-build-internal`, with no external routing or DNS;
5. allocate the case-sensitive Collider storage roots and apply their quotas;
6. install and select Xcode 27 beta 4 build `27A5228h`, verify its Swift 6.4
   compiler and Swift Testing macro plugin, and build Collider;
7. run `collider doctor` and the Apple OCI behavioral contract suite;
8. build one Linux amd64 fixture through Apple `container`, transfer its
   declared output to a Linux x86_64 qualifier, and validate the artifact
   target independently of the runner.

Host provisioning owns steps 1 through 6. Collider only inspects their state
and emits a precise failure when the contract is absent.

Create separate storage roots for development machines, source snapshots,
materialized build workspaces, incremental caches, OCI storage, immutable
artifacts, and logs. Each root has an owner, quota, retention policy, and
recoverability classification. The development workspace and uncommitted source
snapshots are protected data. Build trees and caches are reconstructible data.

The source-controlled host contract is also the environment authority. It maps
`XDG_CACHE_HOME`, the native SDK root, and the Android SDK root into
`NucleusCache`; shell startup files are not the build-system source of truth.
The persistent development workspace remains on `NucleusDev`, protected source
snapshots remain on `NucleusSnapshots`, and host-worker materializations remain
on `NucleusBuild`.

Collider validates typed owner, storage-class, cleanup-policy, quota, reserve,
and mount evidence. `collider cache status` combines that APFS evidence with
logical cache generations and Apple Container disk usage. `collider cache
prune --dry-run` enumerates proven candidates; the mutating form removes stale
run records, locked abandoned Swift SDK candidates, and dangling OCI images.
It never prunes the development workspace, source snapshots, active SDK
generation, immutable artifacts, or reusable incremental build trees.

### Exit Gate

- `collider doctor ci-macos-builder` is entirely read-only and passes without
  interaction.
- A fresh runner environment reaches the first declared task without `sudo`,
  package installation, license acceptance, or credential discovery.
- All build and cache roots reside on declared case-sensitive storage.
- No build path refers to a developer-specific absolute path.
- All storage status reports ownership, quota usage, retention, and explicit
  safe reclamation candidates.
- ARM64-native and translated x86_64 confidence lanes pass, and their evidence
  cannot satisfy a native x86_64 or physical GPU/DRM qualification gate.

## Phase 5: Provision the Persistent Remote Development Environment

Add a source-controlled development-machine image under `development/`. It is
a digest-selected `linux/arm64` OCI image. It contains the interactive shell,
Git and SSH clients, Collider
client, Swift and C/C++ language services, TypeScript and React Native editor
tooling, Android inspection tools, debuggers, and editor-server prerequisites.
It does not replace any product builder image or supply undeclared product
libraries, SDKs, sysroots, or compilers.

Provision one named Apple container machine from that image with explicit CPU,
memory, platform, and storage limits. Set `home-mount=none`. Create the
development user and stable `/workspace/nucleus` path inside the machine. The
source checkout, submodule worktrees, editor indexes, and uncommitted changes
live on its persistent filesystem rather than in the Mac user's home or a
developer computer's filesystem.

Add an `AppleContainerMachine` adapter to Collider for create, inspect, start,
stop, update, and recovery operations. The adapter requires the selected
`linux/arm64` image and rejects host-architecture fallback. Updating the image
recreates the environment from its declaration while restoring workspace
content from a content-addressed source snapshot.

Do not run product build containers inside the development machine. The M2
Ultra does not provide the nested-virtualization contract required for that
architecture. The native macOS Collider worker remains the sole owner of Apple
container build execution.

### Exit Gate

- A newly provisioned development machine opens the repository at the same
  stable Linux path without mounting the macOS home directory.
- Its image identity, platform, resources, and lifecycle state are visible in
  Collider diagnostics.
- Recreating the machine restores source and uncommitted work without restoring
  build products or mutable tool installations.
- No product recipe resolves a dependency from the development-machine image.
- No nested container runtime or privileged host socket is exposed inside the
  development machine.

## Phase 6: Add Secure Remote Access and Editor Integration

Run a development gateway under a dedicated native macOS identity. Admit
developers through SSH over a private network or VPN. The gateway is the only
remote entry point; the development machine and Collider worker bind no public
listener. Tunnel the development machine's SSH endpoint and editor protocol
through the gateway.

Run the editor server, language servers, terminals, Git operations, and source
tools inside the development machine. Editor clients on Linux or macOS display
the interface only. Support standard SSH-based clients without making the plan
dependent on VS Code, Zed, JetBrains, or one terminal implementation.

Personal SSH and Git credentials remain outside the persistent machine. Use
session-scoped agent forwarding or a narrowly scoped credential broker. Never
mount private-key directories, cloud credentials, signing identities, GitHub
runner credentials, or publication credentials. A development identity can
submit development lanes and read its artifacts; it cannot administer runners,
read CI secrets, qualify releases, or publish products.

Provide these lifecycle commands:

```text
collider dev provision
collider dev start
collider dev shell
collider dev status
collider dev update
collider dev stop
```

### Exit Gate

- A clean client computer can open the remote workspace with only its admitted
  SSH identity and editor or terminal client.
- Disconnecting the client leaves the workspace and active tasks intact.
- No development service is reachable directly from the public network.
- Removing a developer identity terminates future access without rotating CI,
  qualification, signing, or publication credentials.
- The persistent machine contains no private key or reusable GitHub credential.

## Phase 7: Add Source Snapshots and Development Dispatch

Add a content-addressed `SourceSnapshot` model to Collider. A snapshot records:

- the root repository and nested repository base commit identities;
- tracked file content at the developer's current worktree state;
- modified and deleted tracked files;
- non-ignored untracked source files;
- exact submodule selections and nested worktree overlays;
- source-lock and builder configuration content;
- exclusions derived from Collider-owned build, cache, candidate, artifact,
  signing, and run-record roots;
- the digest of the complete materialized source tree.

Snapshot creation never requires a commit. It previews included untracked files,
rejects known credential and signing-key paths, and never traverses ignored or
declared generated roots. The primary snapshot source is the persistent M2
development workspace. An imported client workspace uses the same model and
sends only blobs absent from the worker's private content-addressed store. The
worker materializes every snapshot as a new read-only source generation; it
never mutates or overlays the persistent development checkout.

Add a dedicated Collider worker service on the M2 Ultra and an authenticated
client transport. The development machine submits through a private worker
endpoint exposed by the native macOS gateway. Imported clients use SSH and
expose Collider operations rather than an unrestricted worker shell. The worker
binds no public network listener and requires an explicitly admitted identity.

Provide these commands:

```text
collider worker serve
collider dev snapshot
collider dev explain <lane>
collider dev run <lane>
collider dev cancel <run-id>
collider dev logs <run-id>
collider dev artifacts <run-id>
collider remote explain <lane> --worker <name>
collider remote run <lane> --worker <name>
collider remote cancel <run-id> --worker <name>
collider remote logs <run-id> --worker <name>
collider remote artifacts <run-id> --worker <name>
```

The development command snapshots the M2-owned workspace and submits its content
identity to the native worker. The imported-client command resolves the same
lane, creates the same snapshot model, uploads missing content, and submits the
run. Both stream structured events and record the run identity. Cancellation
uses Collider's normal transaction and lock cleanup. Reconnection resumes the
durable event stream rather than starting another run.

Every product task executes against the worker's immutable snapshot in its
declared native or OCI executor. It clears the ambient environment and rejects
undeclared host binaries, SDKs, `PATH` entries, `pkg-config` paths, CMake package
roots, Swift toolchains, writable source mounts, mutable image tags, compilation
network access, and developer-specific paths. Interactive formatting, indexing,
and editor diagnostics may run in the declared development machine, but they do
not emit distributable artifacts.

Local artifacts remain on the M2 Ultra's artifact store by default. The client
downloads only requested products or manifests. Development source snapshots,
logs, and artifacts never transit GitHub and never require a GitHub token.

### Exit Gate

- An uncommitted edit and a newly created source file in the M2 development
  workspace build without a commit, push, or transfer from another computer.
- An imported uncommitted workspace produces the same snapshot identity as the
  equivalent M2-owned workspace.
- The snapshot excludes every declared generated, cache, signing, and credential
  root.
- Repeating an unchanged local build transfers no source blobs and reuses the
  same task identities.
- Local and Actions requests enter the same worker queue and lock domain.
- Disconnecting the client does not terminate or duplicate the build.
- A host-contamination test fails a task that discovers an undeclared tool,
  package, path, network fallback, or writable source input.

## Phase 8: Introduce Collider-Owned Development and CI Lanes

Add `collider ci run <lane>` and `collider ci doctor <lane>`. Each lane owns a
strict task graph and capability contract:

1. `pr-verify` runs formatting, workflow policy, source-lock validation,
   manifest validation, generated-source consistency, and focused Collider
   tests on disposable hosted workers.
2. `macos-arm64-build` builds and validates native macOS products.
3. `linux-amd64-build` builds Linux products through Apple `container`.
4. `android-build` builds AOSP, SwiftAndroid, and Android native products in
   declared ARM64 OCI environments, cross-compiling target architectures and
   translating only required x86_64 host utilities.
5. `linux-x86_64-qualify` validates produced Linux artifacts on native x86_64.
6. `gpu-drm-qualify` runs the physical Vulkan/DRM/GBM and session gates.
7. `publish` verifies qualification evidence, signs products, records
   provenance, and advances distribution channels.

Classify every result as one of these states:

- an interactive result is an editor diagnostic, index, format result, or
  lightweight check produced inside the declared development machine;
- a development artifact is an isolated build from any content-addressed source
  snapshot, including uncommitted work;
- a candidate artifact is an isolated clean build from immutable repository and
  submodule identities;
- a release artifact is a candidate with every required native qualification
  and publication record.

Only development, candidate, and release builds emit distributable bundles.
Only candidate and release artifacts satisfy final-product gates. Publication
never promotes an interactive result or an artifact built from an uncommitted
snapshot.

The workflow files select a lane and route it to a matching runner group. They
contain no component dependency logic, package-manager commands, build flags,
or artifact-layout knowledge.

### Exit Gate

- Each lane can be explained and dry-run from the remote development machine.
- Each lane has a distinct doctor scope and directed capability failures.
- Workflow YAML contains only checkout, Collider bootstrap, lane invocation,
  log preservation, and artifact-reference handoff.
- Development and CI invocation resolve the same task graph for the same
  coordinates and source identity.
- Result classification prevents an uncommitted or ambient build from entering
  candidate qualification or publication.

## Phase 9: Split Build, Qualification, and Publication

Remove assumptions that the builder, validator, and publisher share a
filesystem. Every product build emits an immutable artifact bundle and a
content-addressed manifest containing:

- source and submodule identities;
- builder image identities;
- runner, executor, and artifact coordinates;
- toolchain and SDK identities;
- declared build arguments;
- file digests and executable metadata;
- dynamic-library closure;
- required qualification lanes;
- structured build evidence.

Qualification consumes only the artifact bundle and manifest. It emits a
separate signed qualification record bound to the artifact digest and runner
capabilities. Publication accepts only artifacts with every required record.

Build workers never hold signing keys. Qualifiers cannot mutate build
artifacts. Publishers do not compile source.

### Exit Gate

- A Linux artifact built on the Mac can be transferred to a clean x86_64
  qualifier and validated without access to the builder cache.
- Replacing any file invalidates qualification evidence.
- Publication rejects missing, stale, emulated, or wrong-platform evidence.
- Signing material is absent from build and qualification workers.

## Phase 10: Add Remote Artifact and Cache Boundaries

Add a backend-neutral content-addressed artifact store. Support a local
filesystem backend for development and an OCI registry or object-store backend
for CI. GitHub Actions carries only small manifests, logs, test reports, and
artifact references between jobs.

Do not upload Chromium, AOSP, Swift toolchain, or native SDK incremental trees
to the ordinary Actions cache. Keep expensive incremental state on dedicated
Collider-owned runner volumes. Treat it as reconstructible and untrusted.

Separate storage namespaces by trust class:

- protected development workspaces and recoverable uncommitted snapshots;
- untrusted pull-request cache;
- trusted branch incremental cache;
- development artifacts;
- immutable candidate artifacts;
- qualified artifacts;
- published artifacts;
- signing identities.

Content verification occurs on every cache admission and artifact retrieval.
No cache contains credentials. Collider lifecycle locks protect the same roots
in development and CI execution. Back up development workspaces and uncommitted
source snapshots to encrypted storage. Do not back up reconstructible build
trees or caches. A workspace restore never imports executables into a build
cache or candidate namespace.

### Exit Gate

- Jobs exchange artifact digests rather than absolute paths.
- Cache poisoning cannot turn an unverified file into a qualified artifact.
- A cache miss rebuilds successfully without changing the artifact contract.
- Storage status identifies ownership, trust class, activity, and safe
  reclamation candidates.
- Destroying and recreating the development machine preserves committed and
  uncommitted source while reconstructing editor indexes and build state.

## Phase 11: Enforce Host-Wide Resource Admission

Define resource classes for lightweight verification, native macOS compilation,
Chromium, AOSP, Swift toolchain, native SDKs, qualification, and publication.
The M2 Ultra reserves four CPU cores and 16 GiB exclusively for macOS, the
worker service, storage, and remote access. The coordinator owns the remaining
20 CPU cores and 112 GiB. While the development machine is running, it receives
a floor of four CPU cores and 24 GiB; a heavy build receives at most 16 CPU
cores and 88 GiB. Idle capacity above those floors may be borrowed by interactive
work but is reclaimed before admitting a heavy task. The M2 Ultra admits only
one heavy build at a time. Chromium, AOSP, and the Swift target runtime never overlap
on the 128 GB host.

One persistent coordinator owns development-machine allocation, a weighted CPU
and memory semaphore, storage admission, and the existing workflow locks.
Development and GitHub Actions are clients of that coordinator. They cannot
maintain separate resource counters. Lightweight tasks may accompany a heavy
build only when their declared reservation fits inside the remaining scheduler
capacity.

Interactive development requests have admission priority over queued Actions
work. They do not preempt an active build or corrupt an incremental tree.
Trusted publication has priority once its transaction begins. All other work
uses FIFO order within its priority class.

Every OCI execution receives an enforced CPU and memory limit derived from its
reservation. Native macOS commands receive bounded job counts and process
priority derived from the same reservation. Build tools never independently use
the host processor count to choose concurrency.

Acquire locks outside the checkout so separate Actions workspaces cannot evade
them. Bound CPU, memory, temporary storage, and OCI storage per lane. Record
resource selections in run manifests.

Use dedicated case-sensitive storage with separate roots for development-machine
disks, protected workspace backups, OCI storage, source snapshots, incremental
products, compiler caches, artifacts, and logs. Set hard quotas for every
reconstructible namespace and reserve emergency capacity for workspace backup
and service operation. Collider never deletes data merely to admit a task.
Storage lifecycle status and explicit pruning identify reclaimable state before
capacity becomes constrained.

Use one active GitHub runner per heavy environment. Do not register multiple
runner processes merely to increase queue throughput on the same hardware.

### Exit Gate

- Independent checkouts cannot start conflicting heavy builds.
- Development and Actions submissions cannot overcommit aggregate CPU, memory,
  temporary storage, or persistent storage.
- macOS retains four CPU cores and 16 GiB outside the coordinator, and the
  running development machine retains its four-core and 24 GiB floor.
- A heavy build cannot reduce the development machine below its interactive
  floor or make an editor session unresponsive.
- Cancellation releases locks and leaves reusable build roots consistent.
- Resource exhaustion produces a directed preflight failure rather than a
  compiler, linker, or disk corruption symptom.
- Lightweight hosted verification remains independent of the builder queue.

## Phase 12: Provision Disposable Runner Environments

Run the GitHub runner under a dedicated identity with no personal login data,
SSH agent, browser profile, cloud credentials, iCloud data, development signing
identity, or access to unrelated volumes.

Use ephemeral or just-in-time GitHub runner registration. Restore the runner
environment from a controlled snapshot or image after every job. Preserve only
explicit content-addressed caches and immutable artifacts. Forward runner
service logs and Collider durable run records to external storage before the
environment is destroyed.

The macOS runner image owns Xcode, Apple `container`, and host tools. The
pinned Linux/arm64 Swift runtime-builder image owns its official bootstrap compiler. The
Linux qualifier image owns the selected
distribution, kernel contract, loader, system libraries, and test tools. The
GPU worker additionally owns its pinned kernel, firmware, and driver stack.

Runner registration uses a narrowly permitted GitHub App or just-in-time
configuration service. Registration credentials never enter job environments.

### Exit Gate

- A completed job cannot leave executable state for the next job outside
  declared caches.
- Runner and Collider logs survive environment destruction.
- Revoking the runner-management identity does not affect build or publication
  credentials because they are separate identities.
- The physical Mac contains no personal or release secret reachable by build
  code.

## Phase 13: Establish Native x86_64 and Hardware Qualification

Provision a real Linux x86_64 qualifier for every cross-built Linux/amd64
product. Define it through a `QualifierCapabilityManifest` containing the
distribution image, architecture, kernel, loader, system libraries, CPU
features, sandbox capabilities, test tools, and permitted devices. Provision
the operating-system state from that declaration; never encode the current
Ubuntu machine identity or filesystem layout. It validates:

- ELF architecture, interpreter, and dynamic-library closure;
- glibc and C++ ABI requirements;
- process, pidfd, io_uring, filesystem, and sandbox behavior;
- browser sandbox and media processes;
- Android image host tooling and runtime startup;
- Swift toolchain execution and package consumption;
- performance-sensitive smoke thresholds.

Provision separate GPU/DRM workers for each supported hardware class. These
workers add pinned hardware, firmware, kernel, and driver identities to the same
capability model. They run the existing loader, headless, DRM, GBM, DMA-BUF,
explicit-sync, scanout, display, input, suspend, and session gates.

Cross-build inspection is build evidence only. It never satisfies a native
x86_64, kernel, GPU, DRM, sandbox-performance, or hardware qualification
requirement.

### Exit Gate

- Every Linux product has native x86_64 qualification bound to its artifact
  digest.
- Every claimed GPU class has physical qualification bound to its kernel,
  firmware, and driver identities.
- Translated, emulated, or software-rendered execution is labeled explicitly
  and cannot satisfy a native gate.
- Replacing the current Ubuntu qualifier with another conforming x86_64 worker
  does not change a build graph, artifact identity, or qualification procedure.

## Phase 14: Land the GitHub Actions Workflows

Create thin workflows in this order:

1. public pull-request verification on disposable hosted workers;
2. trusted macOS ARM64 build;
3. trusted Linux amd64 container build on the M2 Ultra;
4. trusted Android/AOSP build on the M2 Ultra;
5. native Linux x86_64 qualification;
6. physical GPU/DRM qualification;
7. protected publication.

Use runner groups plus exact capability labels. Set explicit job timeouts and
workflow concurrency. Cancel superseded verification, but do not interrupt an
artifact publication transaction after channel mutation begins.

Always upload the Collider run manifest, structured events, stage logs, test
reports, and failure diagnostics. Emit a concise Actions summary containing
the artifact digest, selected coordinates, task reuse, qualification records,
and reclaimable storage.

### Exit Gate

- Workflow behavior is reproducible through the corresponding Collider lane
  from the remote development machine without GitHub Actions.
- Trusted and untrusted jobs cannot route to the same runner group or cache
  namespace.
- A failed build or qualification leaves no partially published product.
- Required checks represent hosted verification plus every product-specific
  native qualification gate.

## Phase 15: Final Qualification

Run acceptance in this order:

1. provision a clean macOS ARM64 runner image on the M2 Ultra;
2. validate the pinned Apple `container`, native Linux/arm64 execution,
   case-sensitive storage, and
   complete noninteractive host contract;
3. provision the digest-selected `linux/arm64` development machine with no
   macOS home mount or privileged host socket;
4. connect from a clean remote client, open the editor workspace, and prove the
   shell, language servers, Git, and Collider client execute in Linux on the
   M2-owned workspace;
5. create modified and untracked source, disconnect the client, reconnect, and
   prove the complete workspace remains intact;
6. snapshot the uncommitted workspace and submit a development build to the
   native Collider worker without GitHub;
7. create the equivalent snapshot from an imported client workspace and prove
   both source identities are identical;
8. destroy and recreate the development machine from its pinned image and
   encrypted workspace backup, proving source is restored while indexes, build
   trees, and caches are reconstructed;
9. prove macOS retains four CPU cores and 16 GiB, the development machine
   retains four CPU cores and 24 GiB, and one heavy development build cannot
   exhaust either reserve;
10. queue an Actions build concurrently and prove it cannot bypass the shared
    coordinator or overcommit CPU, memory, temporary storage, or persistent
    storage;
11. build every Linux builder image for the explicit `linux/arm64` platform;
12. cross-build the Nucleus Linux/amd64 Swift runtime and SDK overlays with the
    official Linux/arm64 bootstrap compiler, assemble the SDK with the official
    macOS compiler, and provision both supported SwiftAndroid SDKs;
13. build host and Android Skia;
14. build React Native native dependencies and host archives;
15. build Chromium and CEF;
16. build the AOSP Nucleus image;
17. repeat every heavy build and prove bounded incremental reuse;
18. rebuild a selected source identity on a clean worker and prove no output or
    dependency closure was inherited from the development machine or the
    original builder host;
19. transfer immutable artifact bundles to a clean native Linux x86_64 worker;
20. pass every native Linux product qualification lane on a worker provisioned
    from its capability manifest;
21. replace that qualifier with another conforming x86_64 worker and reproduce
    the qualification procedure without changing the artifact;
22. pass physical GPU/DRM qualification on each claimed hardware class;
23. verify all selected source repositories and submodules remain clean;
24. verify every build output exists only in a declared writable root;
25. verify every x86_64 process executed on the Mac was declared with required
    Intel translation and was limited to an admitted configure probe or pinned
    host utility; also verify no task used an undeclared host
    compiler, host package, mutable tag, network fallback, writable source mount,
    or developer-specific path;
26. verify the current Ubuntu development computer can be unavailable for the
    complete development, build, candidate, and publication sequence;
27. execute the protected publication lane against qualified candidate
    artifacts without rebuilding them.

## Final State

The M2 Ultra owns the authoritative Nucleus development workspace and supplies
the primary CPU, memory, and storage capacity for builds. A persistent,
digest-selected `linux/arm64` development machine holds source, uncommitted
work, editor services, and interactive tools. Developer computers are thin
clients and may be replaced or disconnected without affecting source or work.

Apple `container` presents the Linux build systems with separate native
`linux/arm64` OCI environments. They use explicit cross-compilation contracts
to preserve one Linux/amd64 product architecture and one build graph. The
persistent development machine never supplies ambient dependencies to those
executors. macOS artifacts remain native ARM64 products.

Collider owns platform selection, container policy, task ordering, artifact
identity, storage lifecycle, qualification requirements, and publication
admission. Apple `container` on the macOS ARM64 builder is the only OCI build
executor. Linux workers perform native qualification only. GitHub Actions owns
event handling, trust routing, and job presentation only.

The native Collider worker accepts content-addressed snapshots directly from the
M2-owned workspace and from explicitly imported workspaces, so the same capacity
is available before code is committed or pushed. Development and Actions builds
share one queue, one resource budget, one lock domain, and one artifact model.
The 128 GB host always retains four CPU cores and 16 GiB for macOS while a
running development machine retains four CPU cores and 24 GiB for interactive
work.

Public pull requests never execute on Nucleus infrastructure. Build workers
hold no release authority. Native x86_64 and physical hardware runners provide
the evidence that cross-build inspection cannot provide. Those qualifiers are
replaceable implementations of declared capability manifests rather than
dependencies on one Ubuntu installation. Every published product is traceable
from exact source and builder identities through native qualification to its
final signed artifact.
