# Linux x86_64 Development Host Plan

Status: active

Execution position: Phases 1 and 2 are complete. Phases 3 through 13 follow the
production package, CI, publication, distribution-qualification, development-
deployment, and Collider-simplification sequence in the root documentation
inventory. The contributor workflow reuses portable build identities and
content-addressed results without becoming a production artifact, release path,
or remote CI runner.

## Invariant

Nucleus supports two complementary development workflows. The M2 Ultra remains
the primary development host, full arm64 and x86_64 builder, main-only CI
executor, artifact publisher, and authoritative cache producer. Automated
`main` and locally initiated clean, branch, dirty, debug, and release builds run
through its dedicated `nucleus-builder` account and reuse one persistent
Collider store. Remote branch and pull-request CI remain unsupported. An x86_64
Linux development host independently clones, provisions, edits, builds, tests,
and runs the supported x86_64 first-party graph.

The two hosts share immutable content, never mutable build directories. Each
host owns its SwiftPM/SwiftBuild database, GN/Ninja/Siso output tree, CMake/Ninja
output tree, compiler working directories, and Collider task state. Fine-grained
compiler and tool actions reuse a shared content-addressed store through exact
action identities. Large natural build boundaries reuse signed published build
inputs. A cache miss executes locally; a matching result avoids the action; an
invalid result fails closed.

The Linux workflow is containerized and distribution-independent. The
contributor distribution supplies Collider's host prerequisites and a rootless
container runtime; it never becomes the runtime or link baseline for Nucleus
products. Containers have no general or external network access and hold no
registry or cache credentials. Declared cache-capable build tools may connect
only to a Collider-owned host cache proxy through a mounted Unix-domain socket.
The proxy authenticates remote traffic, verifies digests, enforces namespaces,
and stores local content. Cache availability accelerates an action but is never
required to execute it.

Linux x86_64 contributors build and execute x86_64 products and tests. The M2
Ultra continues to own trusted arm64 products, arm64 tests, dual-architecture
release cohorts, signing, and publication. Only qualified protected-`main`
artifacts create release evidence. Linux arm64 development hosts and
foreign-architecture execution on Linux remain outside this plan.

## Cache and Artifact Model

The development system has three deliberately separate reuse planes.

### Local mutable state

SwiftPM and SwiftBuild databases, Swift incremental records, GN and Ninja
metadata, CMake trees, Siso state, compiler scratch, materialized source, and
Collider task-state records remain local to one host and one backend workspace.
They contain absolute paths, locks, in-progress mutations, backend-specific
filesystem state, or scheduler history. They may be deleted without losing an
authoritative input or finished artifact. They are never copied, synchronized,
network-mounted, or restored from another host.

### Fine-grained action results

An action cache maps one canonical action digest to declared output digests,
stdout, stderr, and execution metadata. A content-addressable store holds the
input and output blobs and Merkle trees. The action identity covers:

- the executable or qualified semantic toolchain identity;
- normalized arguments, working directory, and allowlisted environment;
- the complete declared input tree;
- target operating system, architecture, ABI, and execution requirements;
- container image, SDK, sysroot, and relevant host-tool identities;
- declared output paths and action behavior revision; and
- a cache namespace salt used to retire poisoned or semantically obsolete
  mappings.

The first integrations stay below Collider's coarse task boundary:

- Chromium uses its source-pinned Siso REAPI client;
- SwiftPM/SwiftBuild use Swift compiler compilation caching and a CAS plugin;
- CMake/Ninja components use ccache remote storage first and an REAPI compiler
  wrapper only where measured misses justify it.

Collider owns cache configuration, the host proxy, credentials, policy,
observability, and lifecycle. Native build systems continue to own their action
graphs and incremental scheduling. Collider does not reimplement Bazel, parse
Ninja graphs, or infer undeclared compiler inputs from process tracing.

### Published build inputs

Large, naturally bounded inputs remain signed OCI artifacts rather than millions
of action-cache lookups. The allowlisted inputs are:

- the x86_64 native-builder image;
- the x86_64 slice of the Nucleus Linux Swift target SDK;
- the x86_64 `render`, `rn`, `wayland`, and `android/gfxstream` native SDK
  partitions;
- the x86_64 Chromium/CEF product; and
- the signed x86_64 AOSP generation.

These inputs provide cold-start bootstrap, survive action-cache eviction, and
cross a deliberate producer/consumer boundary. They are not end-user packages,
release-channel objects, or arbitrary snapshots of mutable workspaces.

## Service, Network, and Trust Boundaries

The M2 Ultra's machine build store hosts a pinned
[`bazel-remote`](https://github.com/buchgr/bazel-remote) cache-only service. It
implements the Action Cache, Content Addressable Storage, ByteStream, and
Capabilities portions of the
[Remote Execution API](https://github.com/bazelbuild/remote-apis) without adding
remote workers. Collider installs and supervises it through the existing macOS
builder service contract; recipes never invoke or configure it directly. Its
blob CAS deduplicates immutable content across trust namespaces. Action-result
mappings remain separated:

- `developer` accepts results from locally initiated M2 and Linux development
  builds;
- `protected-main` accepts results only from the `nucleus-builder` protected-
  main path; and
- qualification never comes from either cache namespace.

Protected-main CI does not consume untrusted `developer` action mappings.
Identical blob digests may share physical CAS storage because consumers verify
the bytes; mapping authority remains distinct. Linux may read protected-main
results and read or write its developer namespace. No cache hit grants source
authority, provenance, release qualification, signing authority, or publication
permission.

The host cache proxy is the only process with remote credentials. On the M2 it
reaches the machine-local service. On Linux it reaches that service over the
authenticated private network. Containers receive one Unix socket and an
uncredentialed per-run capability scoped to the requested namespace. They
receive no host network, Docker or Podman socket, SSH key, TLS private key,
registry token, or cache administration API.

A connection failure, timeout, missing action, or evicted blob is a cache miss
and executes locally. A digest mismatch, malformed action result, undeclared
output, namespace violation, or inconsistent toolchain claim is an integrity
failure: Collider quarantines the mapping, records evidence, and fails the
action instead of silently rebuilding past possible cache poisoning.

Remote execution is not required for this plan. The cache protocol retains the
standard action/CAS separation so a later measured need can add remote workers
without replacing identities or storage, but the Linux host must complete the
supported graph from source when the M2 and cache service are unavailable.

## Toolchain Equivalence Policy

The Mac x86_64 lane currently runs an arm64 Swift compiler and most arm64 host
tools while producing x86_64 target artifacts. Linux runs native x86_64 host
tools. A shared target architecture does not make those producer tools
equivalent.

Exact executable content is the default tool identity. Cross-host reuse is
admitted immediately when both hosts run the same executable and inputs, as
Chromium does with its official Linux x86_64 Clang, GN, Ninja, and Siso tools:
Rosetta executes them on the M2 and Linux executes them natively.

A semantic toolchain identity may replace executable content only after a
differential qualification demonstrates that the arm64-host and x86_64-host
tools produce identical declared outputs for a representative corpus. The
identity binds source revision, configuration, target SDK, resource closure,
compiler flags, and cache format. Qualification includes cold local builds,
cross-host cache hits in both directions, byte comparison after declared path
normalization, dependency invalidation, diagnostics replay, debug information,
module artifacts, and link results. Any unexplained difference keeps the two
toolchains in separate namespaces.

Swift, Clang, C/C++, archive, link, code-generation, and ThinLTO actions qualify
independently. Passing one class never implies equivalence for another. A cache
key never lies about differing compiler binaries merely to improve hit rate.

## Boundaries

This plan does not replace the
[macOS remote-development plan](macos-remote-development-plan.md). That plan
governs the primary M2 workflow and authoritative checkout. This plan adds an
independently usable Linux checkout and a narrowly scoped build-result cache;
it does not turn the Mac into a source worker for the Linux checkout.

The [Linux package distribution and update
plan](linux-package-distribution-and-update-plan.md) exclusively owns end-user
APT, DNF, and pacman packages. Published contributor inputs use OCI artifacts in
GHCR, keyed by exact build-input identity rather than release channel. The
action cache lives in the private development build infrastructure and is not a
package repository or release archive.

The third-party application SDK remains a separate external compatibility
boundary. Its versioning, API documentation, source-compatibility policy, and
SwiftPM distribution do not belong to this plan.

## Current State

Collider currently builds only on macOS arm64:

- setup and host-environment resolution reject Linux before submodule,
  toolchain, workspace, or repository-controlled execution;
- `ColliderCLI` installs `AppleContainerRuntimeBackend` only on macOS;
- the planner accepts OCI execution only on an arm64 macOS runner;
- Doctor includes macOS-only Swift SDK prerequisites; and
- build recipes and `SwiftPMOCIExecution` assume an arm64 Linux guest.

Collider already has several required foundations:

- runner, execution, and artifact platforms are distinct;
- task and product identities canonicalize declared placement roots;
- the product store validates immutable manifests, payloads, archives, and
  provenance independently;
- architecture-specific persistent workspaces and compiler caches are explicit;
- host-owned downloads are content-addressed and containers run offline; and
- Chromium already invokes source-pinned Siso and uses the same official Linux
  x86_64 host-tool closure for both target lanes.

Chromium currently passes `--offline` to Siso, so it uses local execution and
local ccache only. Other C/C++ components use local ccache with content-based
compiler checks and normalized base directories. Swift's pinned compiler and
driver contain compilation-cache and CAS support, but Collider does not enable
or connect it to a remote service. Collider has no cache proxy, REAPI service,
remote CAS lifecycle, trust namespaces, or cross-host cache qualification.

Most x86_64 C and C++ work on the M2 is a conventional cross-compile in an arm64
guest. Chromium build/test and AOSP product operations execute x86_64 Linux host
tools through translation. Those domains provide the strongest initial
cross-host compatibility because Linux can run the same tools natively. Swift,
Skia, Wayland, React Native, Hermes, and gfxstream require explicit producer-
tool equivalence analysis before their fine-grained caches can cross hosts.

Persistent-workspace declarations also expose Apple-oriented EXT4 capacity and
journal policy as portable executor requirements. The Linux backend and shared
cache cannot land cleanly until those details move behind backend policy.

## Phase 1: Make Current Platform Claims Truthful

Status: complete.

`tools/host-env.sh`, `tools/collider-launcher.sh`, and `collider-setup.sh` expose
only the supported macOS host path. Setup rejects Linux before it can initialize
source or execute repository setup. Unsupported Linux workflow jobs are absent.
Current setup and architecture documents distinguish macOS host execution from
Linux target artifacts and the future Linux development workflow.

Gate evidence: shell syntax validation passes; mocked Linux setup and host-
environment invocations return the unsupported-host diagnostic; workflow
inspection finds no Linux runner, Collider setup, build, or test step; and the
generated Collider skill makes no supported Linux-host claim.

## Phase 2: Model Executable Architecture Per Action

Status: complete.

Guest platform, produced artifact target, and executable architecture are
independent. Actions declare exact foreign executables, and Apple Container
enables Rosetta only when a declaration cannot run natively.

Pure cross-build and artifact operations use arm64 host tools. The translated
domains are Chromium commands naming checked-in x86_64 GN, Siso, and Clang
tools, and AOSP commands naming x86_64 JDK, Soong, or `out/host/linux-x86`
tools.

Gate evidence: the dual-architecture native/package graph succeeded in run
`2026-08-16T16-22-13.643Z-8454`; the complete Android native package succeeded
in run `2026-08-16T15-54-54.335Z-81451`; Collider tests assert empty executable
requirements for pure cross-build and artifact actions; and the source audit
finds executable requirements only in the named Chromium and AOSP domains.

## Phase 3: Define Portable Action and Build-Input Identity

Land two typed identities with one shared canonicalization vocabulary.

`CachedActionIdentity` encodes the command, normalized environment, declared
input Merkle root, declared outputs, toolchain, execution platform, container
image, SDKs, behavior revision, and namespace salt. It remains independent of
the host proxy endpoint, credentials, local CAS path, checkout placement,
workspace placement, concurrency, timestamps, and provenance authority.

`PublishedBuildInput` encodes an allowlisted artifact kind, producing task,
source and submodule closure, producer runner and guest, artifact target,
toolchain and SDK identities, configuration, semantic arguments, archive and
tree digests, provenance, and publisher signature. It remains distinct from an
action result, CI product bundle, package release index, qualification record,
and development generation.

Audit every admitted identity. Canonicalize placement-only checkout, cache,
toolchain, workspace, socket, and output roots. Retain semantic relative paths
and contents. Reject unrecognized absolute paths. Plan representative actions
under two checkout, home, cache, and workspace roots; identities must match.
Changing source, toolchain, environment, behavior, target, declared outputs, or
a semantic input must change the corresponding identity.

Gate: every cacheable action and published input has one machine-independent
identity; non-allowlisted tasks cannot request publication; and no endpoint,
credential, mutable state path, or producer provenance contaminates an action
digest.

## Phase 4: Make Execution and Workspace Contracts Backend-Neutral

Replace scattered `.linuxARM64OCI` and `.macOSARM64Native` constants with a
typed build-executor context carrying runner platform, guest platform,
available executable architectures, and backend capabilities. Recipes continue
to declare artifact targets independently.

Remove filesystem type and journal mode from portable persistent-workspace
identity. Retain logical owner, artifact target, role, retention, and storage
budget. Apple Container uses sparse EXT4 volumes under backend policy. Linux
uses Collider-owned directories below the XDG cache root. Both report allocated
size and apply the declared budget as a diagnostic and pruning threshold.

Add a cache capability declaration to OCI execution. It names protocol,
namespace class, read/write policy, and the guest socket path; it never accepts
an arbitrary host endpoint. Filesystem effects and task identity account for
the socket without treating service location as a semantic build input.

Gate: the M2 graph retains its artifact targets and warm state;
backend-independent workspace tests use a directory implementation; and an
action without a cache capability cannot observe the proxy socket.

## Phase 5: Establish the Cache Service and Host Proxy

Pin `bazel-remote` by source revision and binary digest, build or acquire its
macOS arm64 executable as a host input, and provision its cache-only service in
the M2 machine build store. Collider's macOS builder contract owns its launchd
service, loopback listener, health check, log root, storage root, capacity, and
retention settings. Keep service state outside Apple Container application
storage and Collider task state. Use recent-use protection, integrity
scrubbing, storage accounting, and recoverable service replacement. Deduplicate
CAS blobs across namespaces while storing action mappings under separate
developer and protected-main authorities. Do not enable an execution service or
install a worker.

Implement the Collider host proxy and client policy. The proxy supports the
REAPI CAS, Action Cache, ByteStream, and Capabilities operations required by
Siso. Add the Swift CAS adapter only if the pinned Swift plugin cannot consume
the same CAS protocol directly. Linux transport uses authenticated private-host
TLS; containers connect only through a per-run Unix socket. The proxy strips
credentials, bounds concurrency and transfers, verifies returned digests, and
records hit, miss, upload, download, corruption, latency, and byte metrics by
component and action class.

Cache failures are observable but do not make execution depend on service
availability. Collider disables cache use for the remainder of a run after a
bounded sequence of transport failures. Integrity failures quarantine the
mapping and fail the action. Add `doctor`, status, and prune observations
through existing Collider command families rather than a cache daemon CLI or a
second scheduler.

Gate: two isolated local clients share action results through the service;
namespace access controls reject cross-authority writes; CAS corruption fails
verification; transport loss falls back locally; and containers cannot reach
the private network or obtain service credentials.

## Phase 6: Prove Chromium Siso Remote Caching

Replace Chromium's unconditional `siso ninja --offline` with a Collider-
supplied Siso configuration targeting the guest cache socket. Preserve a fully
offline local mode when no cache capability is available. Keep each product and
architecture in its own GN/Siso output workspace and retain local ccache as a
near cache.

Use the existing official Linux x86_64 GN, Siso, Ninja, Clang, sysroot, PGO,
source, and argument closure on the M2. Populate the developer namespace from
one clean Chromium workspace, then build the same target from a second empty
workspace. Measure action hits, downloaded bytes, local executions, and total
cache overhead. Exercise header changes, generated-source changes, GN argument
changes, compiler changes, interrupted uploads, missing blobs, diagnostics,
links, ThinLTO, tests, and final artifact validation.

Do not upload actions that Siso marks non-cacheable, depend on ambient state, or
produce undeclared outputs. Do not claim success from wall-clock improvement
alone; compare restored outputs and final product manifests.

Gate: two empty M2 workspaces reuse cacheable Chromium actions without sharing
Ninja state, all invalidation cases select the correct misses, and final CEF and
Browser payload digests match uncached builds.

## Phase 7: Enable Swift Compilation CAS

Enable Swift compiler compilation caching in the pinned SwiftPM/SwiftBuild
path. Configure a local CAS beneath each host cache and connect it to the host
proxy through the pinned CAS plugin. Include explicit dependency scanning,
Clang module inputs, bridging headers, macros/plugins, toolchain resources,
target SDKs, package traits, configuration, sanitizers, and path-prefix mappings
in the qualified cache contract.

Keep SwiftPM/SwiftBuild workspace state local. Cache compiler frontend, module,
and other outputs supported by the pinned toolchain; do not synthesize cache
entries for jobs the driver does not model. Preserve local incremental builds
when the cache is disabled. Add cache remarks and structured Collider metrics
that distinguish local CAS hits, remote hits, misses, replay failures, and
uncacheable jobs.

First prove reuse between two empty M2 SwiftPM workspaces using the same arm64
host toolchain. Then compare arm64-host cross-compilation with a pinned native
x86_64 toolchain over a representative Nucleus corpus. Admit a shared semantic
toolchain identity only when the Toolchain Equivalence Policy passes; otherwise
retain separate cache namespaces without weakening either workflow.

Gate: same-toolchain Swift builds reuse remote compile results across empty
workspaces; dependency and configuration changes invalidate correctly; cache
replay reproduces modules, objects, diagnostics, and debug path mappings; and
cross-host equivalence is either qualified with evidence or explicitly kept
separate.

## Phase 8: Extend Fine-Grained C and C++ Reuse

Add remote storage to existing ccache integrations through the host proxy. Keep
local ccache directories as bounded near caches. Preserve content-based compiler
checks, normalized base directories, target/sysroot identity, and exact compiler
inputs. Separate action mappings wherever the Mac and Linux compiler executable
contents differ.

Measure Skia, Wayland, React Native, Hermes, gfxstream, Swift target-runtime,
and AOSP compile populations. For components where ccache misses substantial
cacheable work such as archive, code-generation, or link actions, introduce an
REAPI compiler/action wrapper under the native build system. Do not replace
CMake or Ninja and do not wrap actions whose complete input and output closure
cannot be declared.

Qualify exact cross-host tools first. Consider a semantic compiler identity
only through the same differential gate as Swift. Retain separate action
namespaces when compiler host architecture, resource closure, or output differs.

Gate: each enabled component demonstrates correct hits across empty local build
workspaces, precise invalidation, bounded transfer overhead, and byte-identical
declared outputs; components without a demonstrated benefit remain local.

## Phase 9: Produce the x86_64 Native-Builder Image

Add an x86_64 variant of the native-builder input manifest and image. Acquire
the official x86_64 Swift 6.4 toolchain, CMake, Node, Bun, and all other archives
on the host with exact digests. Assemble the same pinned Ubuntu package-snapshot
closure used by the arm64 image.

The image contains no arm64 multiarch layer. Chromium, AOSP, Android NDK, Swift,
and generator tools execute natively. Publish it to `ghcr.io/nucleus-os` by
immutable OCI digest. Tags remain discovery aliases and never enter identity.

Gate: an x86_64 Linux host pulls the image by digest and completes network-
disabled representative Swift, C, and C++ builds with the declared glibc and
libc++ contracts.

## Phase 10: Publish and Resolve Contributor Build Inputs

Publish each allowlisted non-image input as an OCI artifact in GHCR with the
Phase 3 manifest. Split payloads only at natural independently verified
component boundaries. A dedicated publisher signs the manifest after trusted
build evidence and receives only GitHub package authority. Public consumers pull
by immutable digest.

Add a host-side Collider resolver. It requests the exact manifest identity,
downloads blobs into the content-addressed download cache, verifies signature
and digests, and atomically publishes the local generation. Containers consume
the generation through read-only mounts.

Resolution belongs to the ordinary graph. A matching artifact satisfies its
declared producer boundary. An absent artifact leaves the local producer
runnable. Signature, digest, platform, or identity mismatch is a hard failure
and never falls through to a similar artifact. Action-cache eviction remains
independent of published-input retention.

Gate: a fresh host materializes every allowlisted input exactly once; offline
consumers reuse it; corruption and substitution fail; and modifying an owned
source input selects its local producer without a mode flag.

## Phase 11: Implement the Rootless Linux Backend and Host Role

Implement `OCIRuntimeBackend` over rootless Podman. Collider owns image
inspection and build, offline execution, cancellation, logs, isolated network
state, bind mounts, directory-backed persistent workspaces, cache-proxy socket
projection, disk reporting, and declared pruning. The backend does not add a
second task graph or shell-script orchestration layer.

Enforce no general container network, all capabilities dropped, privilege
acquisition prohibited, bounded processes and writable mounts, read-only source
and acquired inputs, no host Podman socket, and no credentials. The cache proxy
socket is the only live service boundary admitted to build containers.

Replace operating-system-driven host augmentation with explicit macOS builder,
Linux x86_64 builder, Linux presentation-target, and CI-owned trusted roles.
Add XDG storage, Podman health, official Swift 6.4, Java, Android, Bun, Git, and
downloader prerequisites. Reintroduce Linux support in `collider-setup.sh` and
the normal launcher without installing Nucleus products.

Gate: a fresh x86_64 Linux installation completes setup and `collider doctor`;
backend lifecycle and cancellation tests pass without sudo, privileged
containers, loop devices, general container networking, leaked processes, or
leaked workspaces; and presentation commands appear only under their role.

## Phase 12: Cut Over and Qualify Cross-Host Reuse

Run the x86_64 SwiftPM, native SDK, browser, and Android graphs through the
native x86_64 builder. Materialize published inputs lazily and enable each
qualified fine-grained cache integration. Preserve local source rebuilds for
every owning component, including Chromium/CEF and AOSP when their identities
change.

Execute the cross-host matrix in strict order:

1. populate on M2 and consume on Linux;
2. populate on Linux and consume in an isolated M2 developer workspace;
3. build on Linux with the M2 and cache service unavailable;
4. compare cached and uncached final products;
5. repeat source, toolchain, SDK, configuration, generated-source, and behavior
   invalidation cases; and
6. exercise cache corruption, eviction, timeout, namespace denial, and
   interrupted transfer.

The Linux host never schedules arm64 builds or installs QEMU, FEX, Rosetta, or
another foreign-execution layer. Unsupported arm64 requests fail during
planning and name the owning M2 lane.

Gate: a fresh Linux clone builds, tests, and runs the complete supported x86_64
graph without the M2 or a warm cache; a warm clone reuses all qualified action
classes and published inputs; mutations invalidate only their exact closure;
and native GPU, DRM, kernel, and performance evidence remains Linux-owned.

## Phase 13: Complete the Platform Contract

Regenerate the Collider skill, update the documentation inventory, and revise
architecture, package, remote-development, storage, security, retention, and CI
documents to describe the final roles and cache boundary. Delete superseded
Linux scaffolding, platform constants, translation names, unsupported-host
diagnostics, and temporary integration switches.

Document service recovery, namespace rotation, corruption quarantine, cache
retention, capacity alerts, host-loss behavior, credential rotation, and how to
disable every cache integration without changing build semantics. Keep Linux
development separate from trusted runners and qualification.

Gate: CLI grammar, Doctor, setup, task planning, cache observations, storage
ownership, generated skill, workflows, and all architecture invariants describe
the same supported host matrix; cold uncached execution remains complete; and
no dead local-only or experimental cache path remains.

## Explicit Non-Goals

- Do not replace the M2 Ultra as the primary development or publication host.
- Do not support Linux arm64 development hosts.
- Do not run arm64 products or tests through emulation on Linux.
- Do not make the Linux development host a trusted runner, qualification
  authority, or general remote worker.
- Do not synchronize, network-mount, archive, or restore mutable SwiftPM,
  SwiftBuild, GN, Ninja, CMake, Siso, compiler, or Collider task-state
  directories.
- Do not rebuild the repository in Bazel or reimplement native build-system
  action graphs inside Collider.
- Do not cache an action without a complete declared input/output contract.
- Do not equate arm64-host and x86_64-host toolchains without differential
  qualification.
- Do not let cache availability, hit rate, or service reachability change build
  correctness.
- Do not let development cache results confer protected-main provenance,
  qualification, signing, or publication authority.
- Do not place contributor inputs in native package repositories or use the
  action cache as artifact retention.
- Do not define the public third-party application SDK or compatibility policy.
- Do not require genuine amd64 Swift cross-compilation on the M2 as a Linux-host
  prerequisite.
