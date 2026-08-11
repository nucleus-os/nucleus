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

## Execution and Scheduling

The scheduler protects declared filesystem effects and uses explicit execution
lanes: host-exclusive work, bounded OCI work, and bounded lightweight host work.
It does not perform fractional CPU, memory, or I/O bin packing. Concrete OCI
resource limits and guest job counts remain action inputs, while independent
architecture lanes may overlap when their claims do not conflict.

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
