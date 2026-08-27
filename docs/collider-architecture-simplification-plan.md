# Collider architecture simplification

Status: active

## Invariant

Collider keeps its exact task identity, declared-effect, offline-execution,
artifact-provenance, qualification, persistent-workspace, and authority
boundaries while making their implementation direct to navigate and audit. One
explicit composition root assembles the complete build graph. Storage policy is
pure before any filesystem mutation. Package-family implementations own their
format-specific behavior. Every command states its execution authority in one
place.

This work removes oversized implementation concentrations and implicit policy;
it does not reduce the rigor of the build model. It introduces no plugin system,
dependency-injection container, dynamic recipe registration, alternate graph,
compatibility wrapper, feature flag, or deprecated API.

## Current concentration

Four areas carry unrelated responsibilities that now change for different
reasons:

- `ComponentRegistry.swift` resolves source graphs, constructs package-root
  views, prepares toolchains and every recipe, wires cross-recipe artifacts,
  creates product lanes, and declares user-facing routes in one body;
- `RepositoryCache.swift` combines inventory, live observation, allocation
  measurement, reachability, retention decisions, filesystem mutation, and
  console reporting;
- `LinuxNativePackageAssemblyAction.swift` combines canonical payload assembly,
  three native package formats, Android input validation, archive inspection,
  lifecycle generation, subprocess execution, and publication validation; and
- command marker protocols infer admission, builder identity, run recording,
  presentation, and resumability through overlapping defaults.

The action protocol, typed identity encoder, action-effect declarations,
heterogeneous `AnyColliderAction` boundary, product artifact store, source-free
qualification, and persistent-workspace model remain architectural foundations.
They are not simplification targets.

## Phase 1: Decompose catalog construction

Keep `ComponentRegistry` as the sole explicit composition root. Extract concrete
package-scoped builders for these sequential products:

1. resolved checkout and SwiftPM source inputs;
2. native builder, target SDK, and typed build contexts;
3. prepared recipe products;
4. cross-recipe artifact and product-lane wiring; and
5. the final component catalog, aliases, and entrypoint routes.

Each builder accepts a typed result from the preceding stage and returns a typed
value consumed by the next. It performs work immediately and has no registration
callback, service locator, global mutable state, existential configuration map,
or protocol introduced only to enable mocking. Move route declarations next to
one route-table constructor while keeping cross-component aliases visible in a
single list.

Delete the old monolithic construction helpers after all callers use the staged
assembly. Preserve action identities, task names, entrypoint spellings,
dependency edges, declared effects, and artifact coordinates byte for byte.

Gate: catalog tests cover every component, alias, and entrypoint; dry-run task
graphs and identity explanations for every public build, test, bootstrap,
package, benchmark, and sanitizer selection are unchanged before and after the
move; and no recipe can register itself dynamically or depend back on the
workspace command layer.

## Phase 2: Separate storage inventory, policy, and mutation

Replace the combined repository-cache implementation with four concrete layers:

- `StorageInventory` resolves declared roots, active links, persistent
  workspaces, run records, images, and measured allocation into immutable
  observations;
- `StorageRetentionPlanner` consumes declarations, inventory, current graph
  reachability, and retention limits and returns an ordered plan containing
  retained objects, reclaimable objects, refusals, and reasons;
- `StorageCollector` validates every planned target against its owning
  declaration immediately before performing the requested removal; and
- storage commands render status and prune results without participating in
  either policy or mutation.

Make retention planning deterministic and free of filesystem, container,
process, clock, and console access. Represent live or unavailable observations
as input data rather than control-flow callbacks. Preserve the rule that current
reachability outranks retention count, automatic bounding failures do not fail a
build, explicit prune reports refusals, and no declared root can authorize a
target outside itself.

Move filesystem traversal, symlink handling, allocated-size measurement, and
container image/workspace observation behind the inventory boundary. Keep
deletion narrow and never weaken explicit target validation.

Gate: table-driven planner tests require no temporary filesystem and cover every
storage class and retention policy; mutation tests prove traversal, symlink,
undeclared-root, changed-after-planning, live-workspace, and active-generation
targets are rejected; existing status and prune command behavior remains
equivalent; and a collecting prune retains every graph-reachable object.

## Phase 3: Split native package assembly by durable contract

Keep the existing canonical-payload, family-adapter, and cohort-publication task
boundaries. Split their implementation into:

- canonical payload materialization and validation;
- Android package-input validation;
- Debian metadata, lifecycle, assembly, and archive inspection;
- RPM metadata, lifecycle, assembly, and archive inspection;
- Arch metadata, lifecycle, assembly, and archive inspection;
- cohort publication and product-artifact validation; and
- narrowly shared deterministic filesystem and subprocess utilities.

Define one small package-family adapter protocol only if all three implementations
perform the same operation over the same domain inputs. Keep family-specific
metadata and command construction concrete when their package managers differ.
Do not introduce a generalized packaging DSL, template engine, arbitrary hook
system, or intermediate package schema beyond the existing native package
contract.

Remove the aggregate implementation file after its declarations have durable
owners. Preserve canonical payload reuse, independent family cache identities,
archive bytes, metadata, permissions, lifecycle behavior, tool requirements,
effect scopes, product identifiers, and qualification reports.

Gate: focused package-contract tests compare exact metadata and archive
inventories for all package families; action-identity tests prove the split does
not merge or invalidate unrelated family tasks; malformed Android provenance and
unsafe lifecycle content still fail; and the graph-owned package qualification
lane passes install, upgrade, downgrade, removal, reinstallation, and retention
for every cohort member.

## Phase 4: Give large recipes one declaration owner per action

Apply the same physical decomposition to the remaining recipe files whose
preparation logic, models, action execution, and validation are colocated.
Process recipes in dependency order: native builder, target SDK, core, Wayland,
React Native, Chromium, Android runtime, Linux runtime, then release gates.

For each recipe:

1. keep its descriptor, public entrypoints, and `prepare` composition in one
   recipe file;
2. move each substantial action and its private helpers into a file named for
   that action;
3. move domain values shared by multiple actions into one narrowly named model
   file;
4. keep validation beside the contract it validates; and
5. delete helpers and models that become unused or duplicate an engine
   primitive.

Do not create one-file wrappers, directories containing a single declaration,
or protocols that have one production implementation. A split is complete only
when the recipe file reads as the graph definition and each action file owns a
cohesive executable unit.

Gate: each recipe's focused tests pass after its step; public component and task
identities remain unchanged; dependency direction continues from workspace
composition to recipes to engine modules; and no action implementation imports
the CLI or workspace-command target.

## Phase 5: Replace command capability inference with explicit policy

Introduce one immutable `CommandExecutionPolicy` containing presentation kind,
execution-admission requirement, builder-identity requirement, run-recording
behavior, and resumption behavior. Every concrete workspace command declares
one policy at its definition. Task options may derive a policy from `dry-run`
and `--as-builder`, but the derivation remains one total function with explicit
cases.

Retain Argument Parser option groups for shared syntax. Remove marker protocols
and defaults whose only purpose is to infer execution authority. Keep a protocol
only when the command runner calls behavior through it, not merely as a tag.
Central preflight validates impossible combinations before workspace discovery,
elevation, admission, or run creation.

Gate: a table enumerates every command and its effective policy for ordinary,
dry-run, builder-planning, and resumed invocation where supported; command
composition tests prove inspection never crosses identity or records a run,
execution takes admission exactly once, planning crosses only when requested,
and unsupported resumption fails before mutation.

## Phase 6: Consolidate and close the simplification

Audit the completed structure for abstractions with one caller, duplicate typed
models, pass-through wrappers, stale compatibility names, and target dependencies
made unnecessary by the moves. Delete them directly and fix every caller.
Update Collider architecture documentation with the durable staged composition,
storage planning, package adapter, recipe ownership, and command-policy
boundaries, then regenerate the managed Collider skill from the final command
grammar.

Run the focused Collider host test suites throughout the phases. At completion,
run the complete Collider package tests, compare representative full dry-run
graphs and identity traces against the Phase 1 baseline, and use the protected
`main` CI sweep for graph-executing Linux, Android, browser, GPU, packaging, and
release gates.

Gate: the composition root and major subsystems have cohesive file ownership;
the architecture contains no new dynamic extension mechanism; command grammar
and documented skill agree; representative task graphs and identities match the
baseline; complete Collider host tests pass; and protected-main CI accepts the
unchanged product and qualification graph.
