# GitHub Actions macOS Builder and Self-Hosted Runner Plan

## Invariant

The M2 Ultra is the primary Nucleus build host. Linux products compile in
digest-selected `linux/amd64` OCI images through Apple `container` and Rosetta.
macOS products compile natively as `macOS/arm64`. Build artifacts are qualified
on the operating system, architecture, kernel, graphics stack, and hardware
they claim to support.

Runner platform, artifact target, and execution backend are independent values.
No recipe infers one from another through compile-time host conditionals. GitHub
Actions routes trusted work into Collider lanes; it does not become a second
build system.

Development builds use the same lanes without GitHub. Collider snapshots the
local source graph, transfers only missing content to the M2 Ultra, schedules
the work through the same host-wide resource coordinator, and returns artifacts
and durable logs by content identity. A developer does not commit or push work
to use the builder.

The public repository never executes pull-request code on a persistent or
privileged self-hosted runner. Build workers contain no signing identities,
publication credentials, personal credentials, or access to unrelated host
data.

Status: proposed

## Required Runner Topology

The final topology contains these distinct roles:

| Role | Environment | Purpose |
| --- | --- | --- |
| Hosted verification | Disposable GitHub-hosted worker | Untrusted pull-request formatting, policy, source-lock, and focused unit validation |
| macOS builder | Native `macOS/arm64` environment on the M2 Ultra | macOS Swift toolchain, Apple-platform products, and native macOS validation |
| Linux builder | Apple `container` on the M2 Ultra | All Linux compilation in pinned `linux/amd64` OCI images through Rosetta |
| Linux qualifier | Real `Linux/x86_64` worker | Loader, libc, sandbox, io_uring, process, integration, and performance qualification |
| GPU/DRM qualifier | Real `Linux/x86_64` Nucleus target hardware | Vulkan, DRM, GBM, DMA-BUF, synchronization, scanout, input, display, and session qualification |
| Publisher | Protected isolated environment | Signing, provenance attestation, release publication, and channel advancement |

The M2 Ultra also runs one local Collider worker service. Local development
clients and the GitHub runner submit work to that service; neither starts heavy
build processes independently.

The Linux qualifier may be an on-demand worker. The GPU/DRM qualifier is a
dedicated hardware role. Neither role is replaced by Rosetta, QEMU, software
Vulkan, or a Linux VM on the Mac.

## Platform Contract

Every build task declares all three coordinates explicitly:

```text
runner:
  operatingSystem: macOS
  architecture: arm64

executor:
  kind: oci
  backend: apple-container
  platform: linux/amd64

artifact:
  operatingSystem: linux
  architecture: x86_64
  abi: glibc
```

The initial production policy uses `linux/amd64` builders for every Linux
product. AOSP, Chromium/CEF, the Linux Swift host toolchain, SwiftAndroid,
Skia, React Native native dependencies, and Linux native support libraries all
retain one amd64 build graph. Nucleus does not add parallel ARM builder paths.

Native ARM execution is reserved for macOS products. A Linux build may move to
native ARM execution only after its complete host-tool closure and target
cross-compilation contract have separate qualification. That is a future
architecture migration, not part of this plan.

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
- `ExecutionBackend` selects native execution, Apple `container`, or Podman.

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

## Phase 3: Make OCI Execution Backend-Neutral

Replace Podman-specific build operations with one `OCIExecution` contract. It
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

Implement `AppleContainerExecutor` for macOS and `PodmanExecutor` for Linux.
Both executors enforce the same contract and produce the same structured
execution evidence. Recipes never construct backend CLI arguments.

The Apple backend uses the supported `container` command on macOS 26 or newer.
It requests `linux/amd64` explicitly and requires Rosetta availability before
building. Collider does not implement a custom Virtualization.framework or
Containerization.framework VM manager.

The Linux backend continues to use rootless Podman. Both backends disable
networking during compilation, drop capabilities, prohibit privilege
acquisition, hide the runner home, expose no desktop or device sockets, and
mount source inputs read-only.

### Exit Gate

- One behavioral contract suite runs against both executors.
- Mount, network, privilege, environment, and platform violations fail before
  the child command starts.
- The same digest-selected image produces equivalent declared outputs through
  Apple `container` and Podman.
- Backend command lines do not appear in product recipes.

## Phase 4: Qualify the macOS ARM64 Host Contract

Define a read-only macOS builder doctor lane. It requires:

- the selected macOS and Xcode releases;
- Apple `container` and its system service;
- Rosetta availability for Linux VMs;
- sufficient CPU, memory, and disk allocation;
- a case-sensitive build volume;
- the selected Swift bootstrap compiler;
- the selected Android SDK and NDK;
- content-addressed cache and artifact roots;
- noninteractive execution with no pending license or authorization prompt.

Move all machine mutation into the runner image or host provisioning process.
Collider setup and CI jobs never install packages, select Xcode with `sudo`,
install Rosetta interactively, or modify system services.

Do not use the ordinary macOS home directory for large Linux build trees.
Apple-container VM filesystems and Collider-owned cache volumes hold Chromium,
AOSP, Swift, Skia, React Native, compiler cache, and OCI storage. Host-shared
source mounts are admitted only after performance and case-sensitivity
qualification.

### Exit Gate

- `collider doctor ci-macos-builder` is entirely read-only and passes without
  interaction.
- A fresh runner environment reaches the first declared task without `sudo`,
  package installation, license acceptance, or credential discovery.
- All build and cache roots reside on declared case-sensitive storage.
- No build path refers to a developer-specific absolute path.

## Phase 5: Introduce Collider-Owned CI Lanes

Add `collider ci run <lane>` and `collider ci doctor <lane>`. Each lane owns a
strict task graph and capability contract:

1. `pr-verify` runs formatting, workflow policy, source-lock validation,
   manifest validation, generated-source consistency, and focused Collider
   tests on disposable hosted workers.
2. `macos-arm64-build` builds and validates native macOS products.
3. `linux-amd64-build` builds Linux products in Apple `container` or Podman.
4. `android-build` builds AOSP, SwiftAndroid, and Android native products in
   their declared amd64 OCI builders.
5. `linux-x86_64-qualify` validates produced Linux artifacts on native x86_64.
6. `gpu-drm-qualify` runs the physical Vulkan/DRM/GBM and session gates.
7. `publish` verifies qualification evidence, signs products, records
   provenance, and advances distribution channels.

The workflow files select a lane and route it to a matching runner group. They
contain no component dependency logic, package-manager commands, build flags,
or artifact-layout knowledge.

### Exit Gate

- Each lane can be explained and dry-run locally.
- Each lane has a distinct doctor scope and directed capability failures.
- Workflow YAML contains only checkout, Collider bootstrap, lane invocation,
  log preservation, and artifact-reference handoff.
- Local and CI invocation resolve the same task graph for the same coordinates.

## Phase 6: Add Local Development Dispatch

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
declared generated roots. The transfer protocol sends only blobs absent from the
worker's private content-addressed store. The worker materializes each snapshot
as a new read-only source generation; it never mutates or overlays a persistent
checkout.

Add a dedicated Collider worker service on the M2 Ultra and an authenticated
local client transport. The initial transport runs over SSH and exposes Collider
operations rather than an unrestricted remote shell. It binds no public network
listener and requires an explicitly admitted developer identity.

Provide these commands:

```text
collider worker serve
collider remote explain <lane> --worker <name>
collider remote run <lane> --worker <name>
collider remote cancel <run-id> --worker <name>
collider remote logs <run-id> --worker <name>
collider remote artifacts <run-id> --worker <name>
```

The remote command resolves the same lane locally, creates the source snapshot,
uploads missing content, submits the run, streams structured events, and records
the remote run identity locally. Cancellation uses Collider's normal transaction
and lock cleanup. Reconnection resumes the durable event stream rather than
starting another run.

Local artifacts remain on the M2 Ultra's artifact store by default. The client
downloads only requested products or manifests. Development source snapshots,
logs, and artifacts never transit GitHub and never require a GitHub token.

### Exit Gate

- An uncommitted source edit and a newly created source file build remotely
  without a commit or push.
- The snapshot excludes every declared generated, cache, signing, and credential
  root.
- Repeating an unchanged local build transfers no source blobs and reuses the
  same task identities.
- Local and Actions requests enter the same worker queue and lock domain.
- Disconnecting the client does not terminate or duplicate the build.

## Phase 7: Split Build, Qualification, and Publication

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

## Phase 8: Add Remote Artifact and Cache Boundaries

Add a backend-neutral content-addressed artifact store. Support a local
filesystem backend for development and an OCI registry or object-store backend
for CI. GitHub Actions carries only small manifests, logs, test reports, and
artifact references between jobs.

Do not upload Chromium, AOSP, Swift toolchain, or native SDK incremental trees
to the ordinary Actions cache. Keep expensive incremental state on dedicated
Collider-owned runner volumes. Treat it as reconstructible and untrusted.

Separate storage namespaces by trust class:

- untrusted pull-request cache;
- trusted branch incremental cache;
- immutable candidate artifacts;
- qualified artifacts;
- published artifacts;
- signing identities.

Content verification occurs on every cache admission and artifact retrieval.
No cache contains credentials. Collider lifecycle locks protect the same roots
in local and CI execution.

### Exit Gate

- Jobs exchange artifact digests rather than absolute paths.
- Cache poisoning cannot turn an unverified file into a qualified artifact.
- A cache miss rebuilds successfully without changing the artifact contract.
- Storage status identifies ownership, trust class, activity, and safe
  reclamation candidates.

## Phase 9: Enforce Host-Wide Resource Admission

Define resource classes for lightweight verification, native macOS compilation,
Chromium, AOSP, Swift toolchain, native SDKs, qualification, and publication.
The M2 Ultra exposes 20 CPU cores and 96 GiB of memory to the build scheduler,
reserving four CPU cores and 32 GiB for macOS, the worker service, storage, and
interactive development. The M2 Ultra admits only one heavy build at a time.
Chromium, AOSP, and the Swift toolchain never overlap on the 128 GB host.

One persistent coordinator owns a weighted CPU and memory semaphore plus the
existing workflow locks. Local development and GitHub Actions are clients of
that coordinator. They cannot maintain separate resource counters. Lightweight
tasks may accompany a heavy build only when their declared reservation fits
inside the remaining scheduler capacity.

Local interactive requests have admission priority over queued Actions work.
They do not preempt an active build or corrupt an incremental tree. Trusted
publication has priority once its transaction begins. All other work uses FIFO
order within its priority class.

Every OCI execution receives an enforced CPU and memory limit derived from its
reservation. Native macOS commands receive bounded job counts and process
priority derived from the same reservation. Build tools never independently use
the host processor count to choose concurrency.

Acquire locks outside the checkout so separate Actions workspaces cannot evade
them. Bound CPU, memory, temporary storage, and OCI storage per lane. Record
resource selections in run manifests.

Use a dedicated case-sensitive build volume with separate roots for OCI storage,
source snapshots, incremental products, compiler caches, artifacts, and logs.
Collider never deletes data merely to admit a task. Storage lifecycle status and
explicit pruning identify reclaimable state before capacity becomes constrained.

Use one active GitHub runner per heavy environment. Do not register multiple
runner processes merely to increase queue throughput on the same hardware.

### Exit Gate

- Independent checkouts cannot start conflicting heavy builds.
- Local development and Actions submissions cannot overcommit aggregate CPU or
  memory.
- macOS retains four CPU cores and 32 GiB outside all build reservations.
- Cancellation releases locks and leaves reusable build roots consistent.
- Resource exhaustion produces a directed preflight failure rather than a
  compiler, linker, or disk corruption symptom.
- Lightweight hosted verification remains independent of the builder queue.

## Phase 10: Provision Disposable Runner Environments

Run the GitHub runner under a dedicated identity with no personal login data,
SSH agent, browser profile, cloud credentials, iCloud data, development signing
identity, or access to unrelated volumes.

Use ephemeral or just-in-time GitHub runner registration. Restore the runner
environment from a controlled snapshot or image after every job. Preserve only
explicit content-addressed caches and immutable artifacts. Forward runner
service logs and Collider durable run records to external storage before the
environment is destroyed.

The macOS runner image owns Xcode, Apple `container`, Rosetta, the bootstrap
Swift compiler, and host tools. The Linux qualifier image owns the selected
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

## Phase 11: Establish Native x86_64 and Hardware Qualification

Provision a real Linux x86_64 qualifier for every Linux product built through
Rosetta. It validates:

- ELF architecture, interpreter, and dynamic-library closure;
- glibc and C++ ABI requirements;
- process, pidfd, io_uring, filesystem, and sandbox behavior;
- browser sandbox and media processes;
- Android image host tooling and runtime startup;
- Swift toolchain execution and package consumption;
- performance-sensitive smoke thresholds.

Provision separate GPU/DRM workers for each supported hardware class. These
workers run the existing loader, headless, DRM, GBM, DMA-BUF, explicit-sync,
scanout, display, input, suspend, and session gates.

Rosetta results are build evidence only. They never satisfy a native x86_64,
kernel, GPU, DRM, sandbox-performance, or hardware qualification requirement.

### Exit Gate

- Every Linux product has native x86_64 qualification bound to its artifact
  digest.
- Every claimed GPU class has physical qualification bound to its kernel,
  firmware, and driver identities.
- Emulated or software-rendered execution is labeled explicitly and cannot
  satisfy a native gate.

## Phase 12: Land the GitHub Actions Workflows

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

- Workflow behavior is reproducible through the corresponding local Collider
  lane.
- Trusted and untrusted jobs cannot route to the same runner group or cache
  namespace.
- A failed build or qualification leaves no partially published product.
- Required checks represent hosted verification plus every product-specific
  native qualification gate.

## Phase 13: Final Qualification

Run acceptance in this order:

1. provision a clean macOS ARM64 runner image on the M2 Ultra;
2. start the Collider worker and submit an uncommitted development source
   snapshot without GitHub;
3. prove the worker reserves four CPU cores and 32 GiB for macOS while one
   heavy development build occupies the declared build capacity;
4. queue an Actions build concurrently and prove it cannot bypass the local
   coordinator or overcommit the host;
5. validate Apple `container`, Rosetta, case-sensitive storage, and the complete
   noninteractive host contract;
6. build every Linux builder image for the explicit `linux/amd64` platform;
7. build the Linux Swift host toolchain and both supported SwiftAndroid SDKs;
8. build host and Android Skia;
9. build React Native native dependencies and host archives;
10. build Chromium and CEF;
11. build the AOSP Nucleus image;
12. repeat every heavy build and prove bounded incremental reuse;
13. transfer immutable artifact bundles to a clean native Linux x86_64 worker;
14. pass every native Linux product qualification lane;
15. pass physical GPU/DRM qualification on each claimed hardware class;
16. verify all selected source repositories and submodules remain clean;
17. verify every build output exists only in a declared writable root;
18. verify no build task used an ARM Linux image, undeclared host compiler,
    host package, mutable tag, network fallback, or developer-specific path;
19. execute the protected publication lane against qualified candidate
    artifacts without rebuilding them.

## Final State

The M2 Ultra supplies the primary CPU and memory capacity for Nucleus builds.
Apple `container` presents the existing Linux build systems with ordinary
`linux/amd64` OCI environments through Rosetta, preserving one x86_64 product
architecture and one build graph. macOS artifacts remain native ARM64 products.

Collider owns platform selection, container policy, task ordering, artifact
identity, storage lifecycle, qualification requirements, and publication
admission. Apple `container` and Podman are interchangeable executors of the
same declared OCI contract. GitHub Actions owns event handling, trust routing,
and job presentation only.

The local Collider worker accepts content-addressed snapshots directly from
development workspaces, so the same M2 Ultra capacity is available before code
is committed or pushed. Local and Actions builds share one queue, one resource
budget, one lock domain, and one artifact model. The 128 GB host always retains
32 GiB and four CPU cores outside build reservations.

Public pull requests never execute on Nucleus infrastructure. Build workers
hold no release authority. Native x86_64 and physical hardware runners provide
the evidence that translated builds cannot provide. Every published product is
traceable from exact source and builder identities through native
qualification to its final signed artifact.
