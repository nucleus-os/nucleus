# Collider Engine Boundary Plan

Status: complete.

## Invariant

The Collider engine is a product-neutral orchestration library for graphs of
coarse-grained build artifacts. It owns task identity, planning, scheduling,
execution, storage coordination, output validation, and run records. It does
not own the Nucleus workspace layout, Nucleus environment policy, Nucleus
component composition, command-line grammar, or Apple-container implementation.

The `collider` executable is the Nucleus application. It owns command routing,
workspace discovery, Nucleus component registration, Nucleus path policy, and
selection of the Apple-container runtime integration.

Collider orchestrates existing build systems. SwiftPM, llbuild, Ninja, CMake,
Soong, and the other invoked systems retain source-level dependency tracking and
incrementality. A Collider task produces or validates a coarse-grained artifact;
Collider does not model compiler actions or replace a build system.

Portability means that engine modules contain no Nucleus product assumptions and
do not directly depend on a particular container implementation. It does not
mean that Collider must support every host, container runtime, or external
project before one requires that support.

## Deliberate omissions

The engine does not acquire a build-definition language, result-builder DSL,
interpreter, rule ecosystem, compiler wrapper, or per-file dependency graph.
Build definitions remain ordinary Swift in project-owned recipe modules.

The engine does not replace semantic recipe actions with generic CMake, Ninja,
Make, or process actions. Recipe actions retain domain intent and exact identity.
Common implementation may be factored into helpers without erasing those action
types.

The engine does not acquire Podman, Docker, or another container backend until a
supported host requires one. Apple-container remains the sole implementation.
The runtime boundary must permit another implementation without maintaining an
unused second pipeline.

The engine does not acquire remote execution, a shared artifact cache,
filesystem-effect sandboxing, externally versioned persistence formats, or
remote package dependencies as part of this plan. Those are independent product
features with separate correctness requirements. They require concrete demand
and their own plans.

## Current state

The engine modules under `collider/engine/Sources/` already own the reusable
graph, identity, planning, persistence, download, and execution machinery. The
Nucleus recipe modules live under `collider/Sources/`.

All three phases are complete. Cache namespaces, OCI resource policy, logger
labels, and SwiftPM container environment projection are explicit configuration
supplied by the Nucleus application. Nucleus run-directory variables no longer
enter task environments or engine identity policy. AOSP cache ownership receives
its resolved cache root from recipe composition.

`ColliderRuntime` owns the semantic `OCIRuntimeBackend` interface, contract
validation, temporary storage, observations, logging, and cancellation
coordination. `ColliderAppleContainer` is the sole module that imports Apple's
container and containerization packages. The Nucleus CLI injects that
implementation, while runtime tests use a deterministic backend without starting
a container.

`ColliderCommand` constructs one explicit application composition for each
invocation. Every command leaf receives its `WorkspaceContext` directly; no
mutable command globals or fallback runtime construction remain. Nucleus-owned
commands use `ComponentRegistry` to assemble only the catalog required by the
selected operation immediately before passing it to the reusable engine. This
preserves the rule that unselected components are not configured or inspected.

A direct engine test constructs a synthetic external catalog, executes ordered
host and OCI work through an injected deterministic backend, validates the host
artifact, and verifies the durable run record without importing a Nucleus recipe
or workspace module.

The Android API level and Android execution-platform cases remain engine data.
They describe an artifact target rather than Nucleus product identity.

## Phase 1 — Make product and workspace policy explicit

Status: complete.

Remove every Nucleus product literal from engine modules.

Introduce small configuration values at the subsystem boundaries instead of a
single product-identity object:

- cache configuration supplies the download namespace;
- OCI runtime configuration supplies the managed network name, managed-resource
  labels, guest home, and temporary-filesystem paths;
- logging configuration supplies logger labels;
- workspace composition supplies environment-derived roots and storage
  declarations.

Defaults may express engine-neutral behavior but never a Nucleus name or path.
The Nucleus executable supplies all Nucleus values from its workspace composition
layer.

Split the current workspace model so the engine-facing value contains only the
resolved roots and storage declarations required for planning and execution.
Keep `NUCLEUS_WORKSPACE_ROOT`, `NUCLEUS_NATIVE_SDK_ROOT`, host ccache policy,
`MacOSBuilderContract`, and native-SDK layout in
`ColliderWorkspaceCommands`.

Do not add environment-prefix discovery to the engine. The Nucleus composition
layer reads its environment and passes resolved values explicitly.

Gate: two independently constructed configurations produce disjoint cache and
OCI resource names, and a synthetic workspace can plan a graph without any
Nucleus path or environment variable entering an engine module.

## Phase 2 — Isolate Apple-container integration

Status: complete.

Add a narrow runtime interface for the OCI semantics required by task execution:

- prepare an image;
- execute an OCI workload with the declared mounts, network policy, resource
  limits, translation policy, and cancellation;
- inspect and clean resources owned by the configured runtime namespace;
- report service health and storage usage required by Collider commands.

Place this interface in `ColliderRuntime`. Do not expose Apple-container client
types or decompose it into a mirror of every low-level Apple API operation.

Move `AppleContainerImageBuilder.swift`, `AppleContainerLifecycle.swift`, and
the Apple-specific parts of OCI execution into a `ColliderAppleContainer`
module. That module is the only engine-package module that imports `container`
or `containerization`. `ColliderRuntime` receives the interface implementation
at construction and remains responsible for action execution, observations,
logging, and cancellation coordination.

Keep the current-user login-session bootstrap outside this interface. It is host
provisioning and may invoke the installed `container` executable directly.
Normal Collider image and workload management continues to use the Swift APIs.

Do not implement a second backend in this phase. The interface is proven by the
Apple implementation and a deterministic test implementation.

Gate: runtime tests exercise OCI planning, execution observations, cancellation,
and cleanup through the deterministic implementation; the Apple implementation
passes the existing container integration coverage; and no module other than
`ColliderAppleContainer` depends on Apple-container packages.

The gate is satisfied. Runtime image preparation and execution flow through an
injected backend, and runtime-owned health, network, disk-usage, and pruning
operations delegate through the same instance. Existing Apple flag, image-build,
cleanup, suspension, and AOSP isolation tests now import
`ColliderAppleContainer`. The complete engine and Collider test suites pass, and
only `ColliderAppleContainer` imports Apple container modules.

## Phase 3 — Make application composition explicit

Status: complete.

Keep CLI grammar and process lifecycle in the Nucleus-owned `collider`
application.

Replace hidden construction dependencies with an explicit Nucleus application
composition value that supplies:

- the resolved engine workspace values from phase 1;
- the Apple-container implementation from phase 2;
- the Nucleus workspace context from which the selected command assembles its
  `ComponentCatalog`;
- the run registry and command logging configuration.

`ComponentRegistry` remains the Nucleus composition mechanism. It may continue
to import Nucleus recipe modules and derive cross-component artifact references.
It must finish composition before invoking reusable engine planning or execution.
The engine does not import `ComponentRegistry`, recipe modules, ArgumentParser,
or Nucleus command routes.

Remove global runtime construction where explicit ownership can flow from the
application composition through command execution. One application invocation
owns one runtime, cancellation domain, run registry handle, and workspace
context. The selected command assembles one catalog at the last responsible
point, after parsing its operation-specific controls. Eager catalog construction
is incorrect because it would configure unselected work.

Add direct engine tests that construct a small synthetic catalog with two
coarse-grained tasks, plan it, execute it through deterministic host and OCI
operations, validate its outputs, and record the run. Do not add a fixture
executable; the library test is the external-composition proof needed at this
boundary.

Gate: the synthetic catalog executes without importing any Nucleus recipe or
workspace module; the Nucleus CLI supplies all application-specific composition;
and the complete Nucleus build and test entrypoints retain their current
behavior.

The gate is satisfied. `ColliderWorkspaceCommand.run(in:)` is the sole leaf
execution path, `WorkspaceContext` requires its runtime explicitly, and
`ColliderCommand` owns composition, shutdown, signals, logging, and run
finalization. The synthetic external catalog and complete engine and Collider
test suites pass.

## Completion boundary

The plan is complete when all three phase gates pass and engine modules contain
no Nucleus product identity or direct Apple-container implementation.

After completion, stop generalizing Collider. A second backend, external
consumer, shared cache, enforced filesystem effects, or published package begins
only from a concrete requirement and receives a separate plan grounded in that
requirement.
