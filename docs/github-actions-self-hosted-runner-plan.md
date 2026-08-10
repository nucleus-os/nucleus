# GitHub Actions Self-Hosted Runner Plan

Status: deferred

## Invariant

GitHub Actions routes trusted repository events into existing Collider commands;
it is not a second build system. Public pull-request code runs only on disposable
GitHub-hosted workers. The M2 Ultra self-hosted runner accepts only trusted
branch and explicitly authorized manual work and shares Collider's host-wide
execution admission boundary.

Remote development is defined separately by the
[macOS Remote Development Plan](macos-remote-development-plan.md). The runner
does not own the authoritative development checkout, accept interactive editor
sessions, snapshot uncommitted work, or expose a Collider worker protocol.

Build, native qualification, and publication remain distinct authority
boundaries. Apple-container execution produces Linux artifacts on the M2 Ultra;
translated x86_64 execution is build confidence, not native qualification.
Publication never compiles source and receives signing authority only after all
required artifact-bound qualification evidence exists.

## Current State

Public pull requests use a disposable GitHub-hosted job with read-only
permissions, immutable action identities, and no persisted checkout credential.
Trusted branch and manual events are the only routes to current self-hosted
jobs.

Collider represents runner, execution, and artifact platforms independently. It
owns typed Apple-container lifecycle, offline OCI execution, durable runs,
content-derived task identity, persistent build workspaces, cancellation, logs,
and cleanup. The macOS builder contract declares the selected macOS, Xcode,
Apple-container service, storage, and resource prerequisites.

The current trusted workflow still targets Linux x86_64 self-hosted workers. A
macOS runner identity, host-wide admission shared with interactive Collider
runs, isolated artifact handoff, and protected publication remain future work.

## Phase 1: Preserve the Trust Boundary

Keep all public pull-request execution on disposable GitHub-hosted workers with
read-only repository permissions and no persisted checkout credential. Pin
external actions to full reviewed commit identities. Do not use
`pull_request_target` to execute pull-request source.

Route self-hosted jobs only from protected trusted revisions and explicitly
authorized manual invocations. Runner groups enforce repository and workflow
access; labels describe capabilities but never substitute for authorization.

Gate: no public pull-request event can reach Nucleus hardware, no build worker
receives a write-capable GitHub token, and publication credentials exist only in
the protected publication environment.

## Phase 2: Provision the macOS Runner Identity

Provision a dedicated macOS runner identity with no personal SSH agent, browser
profile, cloud credentials, iCloud data, development signing identity, or
access to protected development source. Give that identity its own
login-session Apple-container service and declared cache, build, artifact, and
log roots.

Install the selected Xcode and Apple-container release through host
provisioning. Jobs run `collider doctor ci-macos-builder`; they never install
packages, select Xcode with elevated privileges, mutate launch services, or
discover credentials interactively.

Use ephemeral or just-in-time runner registration. Preserve only declared
Collider caches, persistent workspaces, immutable artifacts, and durable logs
between jobs.

Gate: a fresh runner registration reaches the first Collider task without
interaction, cannot read the development checkout or personal credentials, and
leaves no undeclared executable state after the job.

## Phase 3: Share Host-Wide Execution Admission

Use the cross-process Collider execution lock defined by the macOS remote-
development plan. A trusted Actions job and an interactive development run
cannot execute task graphs concurrently. The admitted run retains all internal
task and architecture concurrency.

Do not add a worker daemon, remote queue, weighted resource coordinator, or a
second set of task locks. GitHub provides queueing before job admission;
Collider owns execution after admission.

Gate: independent checkouts and runner identities cannot overlap task graph
execution, inspection remains available, cancellation releases admission after
cleanup, and one admitted Chromium or AOSP run can use its full declared
internal concurrency.

## Phase 4: Separate Build and Qualification Artifacts

Make every transferable product an immutable artifact bundle with a manifest
containing source and submodule identities, runner/executor/artifact platforms,
toolchain and SDK identities, build arguments, file digests, executable
metadata, dynamic-library closure, and required qualification roles.

Qualification consumes only the bundle and manifest. Native Linux and physical
GPU/DRM workers emit separate records bound to the artifact digest and their
declared capabilities. Cross-build inspection or Apple-translated execution
cannot satisfy native kernel, performance, GPU, DRM, or release gates.

Use a local filesystem artifact store on the builder initially. Add an object
or OCI-registry backend only when a real remote qualifier or publisher requires
transfer. Do not upload reconstructible Chromium, AOSP, Swift, or native-SDK
incremental trees to GitHub Actions caches.

Gate: a clean qualifier validates an artifact without builder cache or source,
modifying any file invalidates its evidence, and publication rejects missing,
stale, translated, or wrong-platform qualification.

## Phase 5: Land Thin Trusted Workflows

Add trusted workflows only after their Collider commands and capability
contracts exist. Workflow YAML owns checkout, Collider setup, doctor execution,
command invocation, timeout, concurrency, and preservation of logs and artifact
references. It contains no package-manager commands, component dependency
logic, build flags, or artifact-layout knowledge.

Keep native Linux, GPU/DRM, and publication jobs on separately authorized runner
groups. Build workers hold no publication keys, qualifiers cannot mutate build
artifacts, and publishers do not compile source.

Gate: every trusted workflow is reproducible with the same Collider command,
jobs exchange immutable artifact references rather than shared absolute paths,
and a failed job cannot partially publish a product.

## Phase 6: Complete Runner Acceptance

Recreate the macOS runner from its provisioning declaration, pass its doctor
contract, and build each supported artifact lane. Repeat expensive builds and
prove bounded persistent-workspace reuse. Run an interactive Collider request
and a trusted Actions request concurrently and prove the shared admission lock
allows only one task graph to execute.

Transfer declared artifacts to clean native qualification workers and bind all
records to artifact and capability identities. Execute protected publication
from existing qualified artifacts without rebuilding them. Verify logs and run
records survive runner replacement while no personal, development, or signing
credential is reachable by build code.

Gate: trusted automation is a thin invocation of the same Collider architecture,
all cross-host boundaries are digest-verified, and runner replacement does not
change build or qualification semantics.

## Explicit Non-Goals

- Do not execute public pull-request code on self-hosted infrastructure.
- Do not use a persistent Linux development machine as a runner or gateway.
- Do not add `collider ci`, `collider dev`, `collider remote`, or worker-service
  command families merely to rename existing task entrypoints.
- Do not add a remote artifact backend before an actual remote consumer exists.
- Do not treat Intel translation, QEMU, or software rendering as native
  qualification.
- Do not place signing or publication credentials on build workers.
