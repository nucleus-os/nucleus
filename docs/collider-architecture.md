# Collider Architecture

## Invariant

Collider orchestrates repository-scale work that no individual build system
owns: cross-system dependency ordering, typed artifact handoff, Apple-container
execution, storage coordination, scheduling, run attribution, and boundary
validation. SwiftPM, llbuild, CMake, Ninja, Soong, ccache, and package managers
retain their own source-level dependency graphs, incremental state, and output
layouts.

The engine is product-neutral. The `collider` executable is the Nucleus
application that owns command grammar, workspace discovery, component
composition, Nucleus path policy, and selection of the Apple-container backend.

## Engine and Application Boundary

Reusable graph, identity, planning, persistence, download, execution, and
storage types live under `collider/engine`. Engine modules contain no Nucleus
workspace paths, environment variables, component names, or command routes.

Nucleus recipes and application composition live under `collider/Sources`.
`ComponentRegistry` assembles only the catalog required by the selected command.
One invocation explicitly owns its workspace context, OCI runtime, cancellation
domain, run registry, logging configuration, and component catalog. The engine
does not import ArgumentParser, Nucleus recipes, or workspace policy.

Build definitions remain ordinary Swift in recipe modules. Collider has no
build-definition language, rule ecosystem, compiler wrapper, or per-file action
graph. Semantic recipe actions retain their domain intent instead of lowering
into a generic shell-command vocabulary.

## Artifact Identity and Incrementality

A Collider task represents a coarse-grained artifact or validation boundary.
Host SwiftPM work always reaches SwiftPM, allowing SwiftPM and llbuild to decide
whether compilation is necessary. OCI work retains an outer input gate because
avoiding container startup and mount preparation is a meaningful boundary-level
optimization.

Downloaded bytes have one digest-addressed cache. Deterministic generators run
from declared inputs and outputs; Collider does not snapshot their outputs into
a second artifact cache. A successful process exit is sufficient for a terminal
host product. Additional validation exists only for an artifact consumed by a
downstream task or crossing a container-to-host publication boundary.

SwiftPM product locations come from its public interfaces. Collider does not
reconstruct private SwiftPM intermediate directories or duplicate SwiftPM's
build-before-test semantics.

The Linux builder pairs the official arm64 Swift 6.4 toolchain with a
Collider-built Nucleus SwiftPM/SwiftBuild host-tool artifact. The pinned SwiftPM
and SwiftBuild checkouts are root submodules. Collider resolves their exact
package closure on the networked host, compiles `swift-package-manager`
natively for arm64 in an offline container and persistent workspace, and
publishes a bounded directory containing that unified executable, its
`swift-package` and `swift-build` links, matching
resources, and source/compiler provenance. Production SwiftPM actions mount
that directory read-only at `/swiftpm-overlay`. Their typed artifact references
retain its producer edge, and its revision participates in every Linux SwiftPM
action identity.

The single stable builder image retains the official adjacent SwiftPM
executables and resources for bootstrap work. Production actions invoke the
mounted unified executable directly, select its command mode explicitly, and
use the official arm64 compiler through `SWIFTPM_CUSTOM_BIN_DIR`; they never
resolve the adjacent SwiftPM. The image never contains or depends on the
overlay artifact, so changing SwiftPM,
SwiftBuild, their resources, or the overlay assembly does not import or unpack
the heavyweight image again. No GitHub workflow or external release artifact is
part of this graph. The overlay replaces no compiler, driver, LLVM, Clang,
standard library, or target SDK component. Its only behavioral patch keeps host
build tools and transitive helpers on the arm64 Linux host SDK while SwiftBuild
plans an x86_64 target.

The generated target-SDK store publishes one active generation through the
stable `swift-target-sdks/current` link. SwiftPM discovery links target paths
below that stable root rather than a generation-specific directory. A dedicated
publication barrier produces the active SDK and Swift references only after both
discovery links have been validated or repaired, so no consumer can bypass
discovery repair by following an otherwise reusable generation marker.

Operational specialization does not create entrypoint-only child images.
AOSP build and artifact tools, gfxstream, Chromium build and artifact tools, and
the Swift target-runtime builder select hashed, read-only mounted entrypoints
over their reusable dependency image. `OCIExecution` identity covers the mount
and explicit entrypoint override. The task input covers the script bytes. This
keeps an entrypoint edit out of the image store and prevents Apple Container
from re-streaming and unpacking the dependency image for a few bytes of layer
delta. The shared native dispatcher is part of the native dependency-image
contract; there is no entrypoint-only or bootstrap-to-production derivative.

Planning validates clean OCI image outputs against the runtime image catalog.
If the recorded active repository/digest is absent or differs from `:latest`,
the image producer becomes dirty and rebuilds through its declared preparation.
Deleting reconstructible local images therefore cannot leave a false cache hit
that falls through to an external registry lookup.

Collider cache identities use one `IdentityEncoder`. Values are appended in
semantic source order with explicit primitive discriminators and unambiguous
length framing; records, optionals, and ordered sequences preserve their
boundaries. Callers sort only collections whose domain semantics are unordered.
`FilePath` values alone pass through the relocation map. Identity bytes are an
internal same-build implementation detail: an encoding change deliberately
invalidates recorded task state instead of introducing field numbers, schema
versions, compatibility readers, or parallel encoders.

Git source inputs identify the effective Git-owned tree, not the current commit
object plus a working-copy overlay. Tracked contents after modification and
deletion, non-ignored untracked files, executable bits, symlink targets, and
materialized nested-checkout trees participate. Checkout placement, branch,
commit, and dirty state do not. A task that consumes Git metadata declares that
metadata separately as a semantic input.

A product crossing a build, qualification, packaging, or development-transport
boundary uses `ProductArtifactEnvelope`. Its content identity covers source and
submodule closures, producing task, runner/execution/artifact platforms,
toolchain and SDK inputs, builder image, configuration, semantic arguments,
archive and tree digests, individual files, executable metadata, dynamic
libraries, producer trust domain, and required qualification roles. Declared
checkout, cache, home, workspace, and output roots become named placeholders;
an undeclared absolute host path makes construction fail.

Git provenance remains a separate digest-bound record. Identical bytes built
before and after commit therefore retain one product and task identity while
local-development and protected-`main` authority remain distinct. The local
filesystem product store keeps one immutable content-addressed bundle with any
number of provenance records. It rehashes the archive, payload tree, and every
file before consumption. Qualification reads only that stored bundle and emits
a separate record bound to product identity, provenance identity, declared
capability, evidence digest, and qualifier trust domain. OCI, translated, or
virtual execution cannot claim native Linux or physical GPU/DRM roles.

Native package retention treats the active and one rollback cohort generation
for each architecture as the product-store live roots. After both package lanes
and their lifecycle qualifications complete, one always-assessed host action
prunes superseded package generations and removes only known product/archive
objects absent from the retained manifests. It runs even when package cohorts
are clean because a separate cache-prune operation can change reachability.
Unknown store paths survive. Generation stores declare their own naming pattern,
so cache pruning does not confuse legacy 24-hex names, digest-prefixed names, or
AOSP product names.

The browser build graph publishes one validated payload for each Linux
architecture under the payload's complete tree digest. A separate
`BrowserPackageInputManifest` binds the target, exact immutable payload
generation, payload digest, build-manifest digest, and distro-neutral host
capability contract. The identity covers the complete manifest, so dependency
contract changes invalidate package assembly without rebuilding or copying the
browser payload.

`collider package linux-runtime` consumes the exact runtime and browser
publications for arm64 and x86_64. Its offline Linux arm64 builder emits native
Debian, RPM, and Arch cohorts containing separate runtime, session, browser,
development-host, and complete-installation packages. The Android add-on joins
that split with its installed activation boundary in the next package phase.
Every emitted package and complete family cohort carries a
`ProductArtifactEnvelope` bound to source provenance and the exact consumed
publications. Repository enrollment is produced later with the explicit signing
identity; the unsigned package cohort cannot invent a keyring.

Distribution adapters preserve the staged payload byte-for-byte. In particular,
RPM disables `__os_install_post`; host-architecture strip helpers never inspect
or rewrite a cross-architecture package payload.

The browser package-input manifest is a local typed input to native package
assembly, not a transferable product bundle or generic cache entry.
Development diagnostics read the browser publication directly. Collider has no
browser installation task, prefix, component entrypoint, or command.

Task outputs have one description: producer, slot, path, and `PathValidation`.
An `ExecutableReference` is the only additional capability and the only output
reference that can become a command executable. Ordinary dependency ordering
uses `TaskOrderingReference`; Collider has no value-less typed result channel,
erased artifact-kind mirror, or reflected Swift type identity. Graph validation
checks real construction failures—unknown producers and slots—rather than
rechecking facts that `TaskBuilder` minted together.

## Execution and Scheduling

The scheduler protects declared filesystem effects and uses explicit execution
lanes: host-exclusive work, bounded OCI work, and bounded lightweight host work.
It does not perform fractional CPU, memory, or I/O bin packing. Concrete OCI
resource limits and guest job counts remain action inputs, while independent
architecture lanes may overlap when their claims do not conflict.

Every command that can execute work or mutate repository-owned state first
acquires one host-wide kernel lease below the shared Nucleus cache root. The
lease spans checkouts, local terminals, SSH sessions, and future trusted runner
invocations, and remains held through runtime shutdown and run finalization.
Dry-runs and inspection commands never acquire it. Contention is represented by
the existing run wait events and lock-owner record; `collider status`, run, and
log inspection remain available while another invocation owns admission.

`ColliderRuntime` owns action execution, process groups, output streaming,
credential scrubbing, cancellation, teardown, observations, and run records.
The first interruption requests orderly cancellation through that ownership
path; subsequent interruption may escalate child termination without creating a
second cleanup mechanism.

The storage classes and container mount rules are defined by
[Collider Build Storage Architecture](collider-build-storage-architecture.md).

## Container Boundary

`ColliderRuntime` defines the semantic OCI backend required by actions:
preparing images, executing declared workloads, inspecting owned resources,
cleaning them, and reporting service and storage state. `ColliderAppleContainer`
is the sole engine module that imports Apple's `container` and
`containerization` packages. The Nucleus application injects that implementation;
engine tests inject a deterministic backend.

Apple-container is the only supported backend. Another implementation lands
only with a supported host that requires it; the interface does not justify an
unused Podman or Docker pipeline. Login-session service bootstrap remains host
provisioning rather than normal OCI workload management.

Containers compile, test, assemble, and package only mounted inputs. Network
acquisition occurs on the host before container execution.

## CLI and Observation Contract

Collider has one executable, one command grammar, one typed event model, and one
output policy. Machine output goes to stdout. Human progress and diagnostics go
to stderr. Complete child output remains in durable per-run logs. Interactive
children retain direct terminal ownership.

Planning, task inventory, runs, logs, cache state, and active status are
read-only views of the task graph and run records. They do not implement a
second scheduler, cache, resumability system, daemon, or observer protocol.
Internal records shared by one Collider installation do not carry a protocol
version.

Run terminalization applies bounded retention after logs and records close.
Active runs are never pruned, and retention preserves the newest failed run for
diagnosis. Artifact reuse is represented by a clean task, not a restored-task
outcome. Every running record holds a kernel-backed lease for the lifetime of
its Collider process. The next invocation terminalizes an abandoned running
record as interrupted only when that lease is no longer held; timestamps and
process identifiers do not determine liveness.

Product installation remains a transitional CLI responsibility until the
[Linux package distribution and update plan](linux-package-distribution-and-update-plan.md)
replaces it with development staging, native packages, repositories, and
installed Nucleus capability management.

## Deliberate Omissions

Collider does not provide remote execution, a worker daemon, a shared artifact
cache, filesystem-effect sandboxing, an externally versioned persistence format,
or a generic package/build abstraction. Each requires a concrete product need
and its own technical boundary.
