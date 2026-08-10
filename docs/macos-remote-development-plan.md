# macOS Remote Development Plan

Status: active

## Invariant

The M2 Ultra is the Nucleus development and build host. The authoritative Git
checkout, including uncommitted work and submodule worktrees, lives on protected
macOS storage under `/Volumes/NucleusDev`. Remote computers are replaceable SSH,
editor, and terminal clients; they do not own a second checkout that must be
uploaded before it can build.

Collider runs directly on macOS, where it owns Xcode, host-side downloads,
durable runs, task scheduling, Apple-container execution, and persistent Linux
build workspaces. Linux containers remain offline build executors. There is no
persistent Linux development machine, nested container runtime, Collider worker
daemon, source-snapshot service, remote-execution protocol, or development
artifact transport.

Remote access uses the host's standard SSH service over an authenticated private
network. Long-running work remains attached to a standard terminal multiplexer.
Collider inspection commands remain available after reconnect, and an
interrupted run resumes through its existing run identity.

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

The macOS builder contract already declares `NucleusDev` as protected source
storage, but the active checkout has not yet moved there. It also declares a
`NucleusSnapshots` volume and worker-oriented ownership names inherited from the
discarded remote-worker architecture. Collider execution lanes coordinate one
process; independently launched Collider processes do not yet share one
host-wide execution admission lock.

## Phase 1: Correct Host Storage Ownership

Make `/Volumes/NucleusDev/nucleus` the stable authoritative checkout. Preserve
the complete working tree, Git metadata, submodule selections, ignored local
configuration, and verified-commit setup during the move. Confirm the new path
passes Collider workspace discovery and produces unchanged source identities.

Back up `NucleusDev` with an encrypted off-host backup system. The APFS volume
is protected storage, not a backup by itself. Recovery restores source and user
state only; Linux build workspaces, compiler caches, downloaded packages, OCI
images, run logs, and generated artifacts remain reconstructible.

Remove `NucleusSnapshots` from the macOS builder contract. Do not delete the
physical volume until a read-only inspection proves it contains no data that
must be retained. Rename `NucleusBuild` ownership from the nonexistent Collider
worker to Collider build workspaces. Remove other storage descriptions that
refer to the discarded development-machine or snapshot-service architecture.

Gate: the authoritative checkout runs from `NucleusDev`, its backup can be
inspected independently of the Mac, and `collider doctor ci-macos-builder`
passes without requiring `NucleusSnapshots` or a worker service.

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

Gate: a clean remote client opens `/Volumes/NucleusDev/nucleus`, edits a tracked
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

Add one cross-process execution lock in a host-owned path outside every
checkout. Every task-executing Collider command acquires it before execution and
holds it through shutdown and cancellation. Inspection commands do not acquire
the lock.

The lock admits one Collider run at a time across local terminals, remote SSH
sessions, alternate checkouts, and the future trusted self-hosted runner. Task
parallelism remains internal to the admitted run, so arm64 and x86_64 lanes,
independent OCI tasks, and lightweight prerequisites retain their declared
concurrency. Do not replace the lock with a worker daemon, queue service,
weighted resource scheduler, or remote coordinator.

Record lock ownership and wait state using the existing run and lock evidence.
Cancellation releases the lock only after child processes and managed
containers have completed their normal cleanup transaction.

Gate: two checkouts cannot execute task graphs concurrently, inspection remains
available while a build owns admission, internal architecture concurrency is
unchanged, and interruption leaves the lock reusable.

## Phase 5: Complete the Remote-Development Cutover

Update builder setup, agent guidance, and architecture documentation to state
that macOS is both the development control plane and build orchestrator. Remove
all remaining references to a persistent Linux development machine, source
snapshot service, Collider worker endpoint, `collider dev`, and `collider
remote` commands.

Keep self-hosted CI, native qualification, publication, and shipping Apple
virtualization in their own plans. None is a prerequisite for remote editing or
development builds.

Gate: remote development from a clean client succeeds through standard SSH;
the authoritative checkout and uncommitted work survive client replacement;
one heavy build can use the M2 Ultra's internal parallelism without competing
with another Collider process; and deleting every reconstructible build
workspace leaves protected source and user state intact.

## Explicit Non-Goals

- Do not put the authoritative checkout inside an Apple container or VM.
- Do not create a second Linux checkout for editor convenience.
- Do not implement source snapshotting, blob upload, or custom artifact transfer.
- Do not add a Collider worker daemon or remote-execution API.
- Do not make remote development depend on GitHub Actions.
- Do not expose Apple-container services or build containers to remote clients.
- Do not move Linux build intermediates back onto host-shared source storage.
- Do not add a Linux indexing environment until a measured macOS language-server
  limitation justifies that independent tool.
