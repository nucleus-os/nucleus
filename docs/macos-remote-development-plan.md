# macOS Remote Development Plan

Status: active

Execution position: Phases 2 through 6 follow the production package, CI,
publication, distribution-qualification, and development-generation phases in
the root documentation inventory. The production artifact contract defines the
generation that this plan deploys; remote development does not define a second
artifact model.

## Invariant

The M2 Ultra is the Nucleus development and build host. The authoritative Git
checkout lives at `~/Developer/nucleus`. Durable source state, including
submodule selections, is pushed to a remote. Uncommitted work and dirty
submodule worktrees are transient and explicitly outside the host-loss recovery
guarantee. Remote computers are replaceable SSH, editor, and terminal clients;
they do not own a second checkout that must be uploaded before it can build. A
declared Linux presentation target may receive an immutable user-owned
development generation for local VT testing, but it never receives source or
becomes a build host.

The interactive development account runs no GitHub Actions service. Automated
CI/CD supports only protected `main` and uses the separate non-admin
`nucleus-builder` account. Remote branch and pull-request activity never
schedules M2 Ultra compute. A locally initiated Collider build may execute the
authoritative checkout's committed, branch, or dirty source as
`nucleus-builder` through read-only checkout access. Automated and local builds
therefore reuse the builder account's one Apple-container service, cache, SDKs,
compiler caches, and persistent workspaces without exposing personal
credentials, unrelated interactive state, signing identities, or publication
identities.

This plan governs the M2 Ultra remote-development topology, not every supported
contributor platform. The independent
[Linux x86_64 development host plan](linux-x86-64-development-host-plan.md)
adds self-contained contributor clones without becoming part of this remote
topology or weakening the M2 Ultra's authoritative-checkout role.

Collider runs directly on macOS, where it owns Xcode, host-side downloads,
durable runs, task scheduling, Apple-container execution, and persistent Linux
build workspaces. Linux containers remain offline build executors. There is no
persistent Linux build machine in this topology, nested container runtime,
Collider worker daemon, source-snapshot service, or remote-execution protocol.
Development artifact deployment uses one-shot SSH and rsync from macOS to a
user-owned store on a declared Linux presentation target.

Remote access uses the host's standard SSH service over an authenticated private
network. Long-running work remains attached to a standard terminal multiplexer.
Collider inspection commands remain available after reconnect, and an
interrupted run resumes through its existing run identity.

The release root key remains offline. A constrained release-signing subkey
lives in the host's protected credential store, outside the checkout, and can
be revoked and replaced from the offline root material after host loss; the same
private subkey is not reproducible from the root key. Qualified but unpublished
cohorts remain reconstructible staging outputs. A cohort that must survive host
loss crosses the signed repository publication boundary into the immutable
GitHub Release package-object store instead of becoming protected local build
state.

Host-loss recovery is a fresh authoritative clone and clean builder checkout
followed by AOSP synchronization and rebuilding all SDKs, container images,
compiler caches, and persistent workspaces. The accepted current recovery cost
is roughly 900 GB of reconstructible state. No source snapshot or build-cache
backup service exists.

## Current State

Collider already identifies Git-owned source from the committed tree plus the
scoped working-copy overlay. Modified, deleted, and non-ignored untracked files,
including dirty nested submodules, participate in task identity. No additional
source representation is required when planning and execution occur on the same
host.

Collider records durable run manifests, events, stage logs, task outcomes,
timings, container evidence, and interruption state. It supports resuming a
failed or interrupted run when its resolved task identities still match.
Persistent Linux build and compiler-cache state is separate from source and
survives individual build-container lifetimes.

Task-executing and state-mutating commands currently acquire a per-user kernel
lease below the conventional Collider Developer state root. It coordinates
local terminals, remote SSH sessions, and alternate checkouts for one user but
cannot yet serialize the interactive and future `nucleus-builder` accounts. The
main-only CI plan replaces it with machine-wide admission while leaving
inspection and dry-run commands lock-free. Contended runs publish wait events,
and cancellation releases admission after normal runtime shutdown and run
finalization.

The authoritative checkout already lives at `~/Developer/nucleus`. The
[macOS host storage consolidation plan](macos-host-storage-consolidation-plan.md)
removes the remaining custom APFS storage contract and places Collider-managed
state in conventional per-user directories. No custom volume owns source.

## Phase 1: Correct Host Storage Ownership

Status: complete. The authoritative checkout is `~/Developer/nucleus`, Collider
discovers it directly, and Git plus its remotes own durable source history.
Custom APFS source and snapshot volumes are not part of the endpoint. The
remaining builder-storage migration belongs exclusively to the
[macOS host storage consolidation plan](macos-host-storage-consolidation-plan.md).

Gate evidence: the active checkout is `~/Developer/nucleus`; local editing and
Collider workspace discovery use that checkout directly; and no source move,
backup service, snapshot service, or worker-owned source role remains.

## Phase 2: Establish Private Host Access

Enable the standard macOS SSH service for the builder-development identity.
Admit key-based authentication only through the selected private network or VPN.
Do not expose SSH, an editor server, Apple-container XPC services, or a Collider
listener to the public network.

Remote editors use ordinary SSH integration and open the authoritative host
checkout directly. Shells, Git, Swift and C++ language services, JavaScript
tooling, and Collider execute on macOS. Git authentication and verified-commit
signing use the host's existing protected credential facilities; private-key
directories are not copied from clients or mounted into Linux containers.

Do not add editor-specific commands to Collider. VS Code, Zed, JetBrains,
terminal clients, and future clients remain interchangeable implementations of
the SSH client boundary.

Gate: a clean remote client opens `~/Developer/nucleus`, edits a tracked
file, creates a non-ignored untracked file, performs Git operations, and runs a
Collider dry-run without installing a Nucleus build toolchain locally.

## Phase 3: Make Session Continuity Operational

Use a standard terminal multiplexer for long-running interactive commands so an
SSH or editor disconnect does not deliver `SIGHUP` to Collider. Document one
canonical builder session and the reconnect procedure.

After reconnecting, use `collider status`, `collider runs`, and `collider logs`
to observe work. If the host process was actually interrupted, resume the same
command with its existing `--run-id`; do not create a second run merely because
the client disconnected.

Do not add a Collider daemon, detached-process supervisor, remote event
protocol, or duplicate log service. A future need for noninteractive service
execution belongs to the self-hosted-runner contract, not remote development.

Gate: disconnecting and reconnecting a remote client leaves a multiplexer-owned
Collider run active, its logs remain readable, and an intentionally interrupted
run resumes without repeating clean tasks.

## Phase 4: Add Host-Wide Collider Admission

The single-account implementation is complete. Phase 4 of the
[GitHub Actions self-hosted CI plan](github-actions-self-hosted-runner-plan.md)
replaces its per-user location with machine-wide admission before this plan
resumes. This phase completes the remote-development integration and
operational gate.

Add one cross-process execution lock in a host-owned path outside every
checkout and user home. Both `maddy` and `nucleus-builder` can acquire it without
reading one another's private state. Every task-executing Collider command,
local account-switching build, CI run, and mutating cache operation acquires it
before execution and holds it through shutdown and cancellation. Inspection
commands do not acquire the lock.

The lock admits one Collider run at a time across local terminals, remote SSH
sessions, the authoritative checkout, the clean builder checkout, automated
`main`, and locally initiated branch, dirty, debug, and release builds. Task
parallelism remains internal to the admitted run, so arm64 and x86_64 lanes,
independent OCI tasks, and lightweight prerequisites retain their declared
concurrency. Do not replace the lock with a worker daemon, queue service,
weighted resource scheduler, or remote coordinator.

Record lock ownership and wait state using the existing run and lock evidence.
Cancellation releases the lock only after child processes and managed
containers have completed their normal cleanup transaction.

Move the lease from
`~/Library/Developer/Nucleus/Collider/build/state/locks/host-execution.lock` to
one root-provisioned Nucleus admission directory under `/Library/Application
Support`. Record the owning account, checkout, source identity, configuration,
and run beside it using the existing cancellable file-lock acquisition path.
Mutating commands and non-dry task commands acquire it. Doctor, status, run,
log, task, graph, cache-status, and dry-run commands remain available without
it.

Gate: the interactive and builder accounts cannot execute task graphs
concurrently; a developer-initiated dirty build reads the authoritative checkout
without modifying it and reuses the same builder cache as CI; inspection
remains available while a build owns admission; internal architecture
concurrency is unchanged; and interruption leaves the lock reusable.

## Phase 5: Add the Linux Presentation Target

Implement the non-installed development-generation deployment defined by the
[Linux package distribution and update
plan](linux-package-distribution-and-update-plan.md) Phase 9.
Collider builds and validates the selected Linux runtime on macOS, transfers it
through standard SSH and rsync, and atomically publishes it below the remote
user's development state root. The Linux target has no checkout, build
toolchain, Collider worker, or listening Nucleus service.

Keep the package-managed nightly runtime and every development workspace in
separate configuration, data, state, cache, runtime, and log roots. Deployment
does not launch a session. A person launches the generation from a free local VT
and relies on ordinary logind or seat-provider pause/resume when switching
between the package-managed and development sessions.

Gate: editing and building remain entirely on the M2 Ultra while a declared
Linux target can run the exact dirty development generation on a secondary VT
without changing its package database or primary Nucleus installation.

## Phase 6: Complete the Remote-Development Cutover

Update builder setup, agent guidance, and architecture documentation to state
that macOS is both the development control plane and build orchestrator. Remove
all remaining references to a persistent Linux development machine, source
snapshot service, Collider worker endpoint, `collider dev`, and `collider
remote` commands.

Keep self-hosted CI, native qualification, repository publication, and shipping
Apple virtualization in their own plans. None is a prerequisite for remote
editing, development builds, or one-shot deployment to a declared presentation
target.

Gate: remote development from a clean client succeeds through standard SSH;
client replacement leaves the authoritative host checkout untouched;
locally initiated committed, branch, and dirty builds execute as
`nucleus-builder` against the read-only authoritative checkout; one heavy build
can use the M2 Ultra's internal parallelism without competing with another
Collider process; a Linux presentation target receives no source; and deleting
every reconstructible build workspace and deployed development generation
leaves pushed source history, installed packages, and user state intact.

## Explicit Non-Goals

- Do not put the authoritative checkout inside an Apple container or VM.
- Do not create a second Linux checkout for editor convenience.
- Do not implement source snapshotting, source upload, a custom artifact
  protocol, or a remote artifact daemon. One-shot development-generation
  transfer through standard SSH and rsync is the only deployment path.
- Do not back up transient working-copy state or reconstructible build state.
  Push durable source work and publish cohorts that must survive host loss.
- Do not add a Collider worker daemon or remote-execution API.
- Do not make remote development depend on GitHub Actions.
- Do not expose Apple-container services or build containers to remote clients.
- Do not move Linux build intermediates back onto host-shared source storage.
- Do not add a Linux indexing environment until a measured macOS language-server
  limitation justifies that independent tool.
