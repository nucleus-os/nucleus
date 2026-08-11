# GitHub Actions Self-Hosted CI Plan

Status: deferred

## Invariant

Every Nucleus CI job runs on explicitly authorized self-hosted infrastructure.
Pull-request and `main` verification invoke the same complete Collider build,
test, artifact, and qualification graph. Pull requests never publish, sign, or
promote releases.

A pull request authored by the configured repository owner may enter CI
automatically. A pull request authored by anyone else reaches no runner until
the owner approves that exact workflow run. Approval authorizes execution of
one exact pull-request merge revision; it does not make the code trusted, grant
credentials, or permit its writable state to become an input to trusted builds.

GitHub Actions remains orchestration around Collider, not a second build
system. Workflow YAML selects an immutable source revision, runner capability,
and existing Collider commands. Collider owns dependency planning, offline
Apple-container execution, persistent workspaces, artifacts, logs,
cancellation, and host-wide execution admission.

Remote development is defined by the
[macOS Remote Development Plan](macos-remote-development-plan.md). CI never
uses the development checkout, accepts editor sessions, snapshots uncommitted
work, or introduces a Collider worker protocol.

## Current State

The current `pull_request` job runs only whitespace and submodule-declaration
checks on a GitHub-hosted Ubuntu worker. The current self-hosted Linux jobs run
only for `main` pushes and manual dispatches. Pull requests therefore do not
receive meaningful build or test coverage, and the workflow violates the
self-hosted-only invariant.

Collider already represents runner, execution, and artifact platforms
independently. It owns typed Apple-container lifecycle, offline OCI execution,
durable runs, content-derived task identity, persistent build workspaces,
cancellation, logs, and cleanup. Its host-wide execution lease serializes
task-graph execution within a configured cache root while retaining internal
task and architecture concurrency. Cross-account admission and CI trust-domain
storage isolation remain to be completed.

The macOS builder contract already declares the selected macOS, Xcode,
Apple-container service, storage, and resource prerequisites. The current
trusted workflow still targets Linux x86_64 self-hosted workers; the M2 Ultra
runner identities and full shared verification workflow do not yet exist.

## CI Event and Trust Contract

The repository has three CI event classes:

1. `pull_request` verifies GitHub's exact merge revision for the proposed head
   and base. It runs the complete non-publication graph.
2. A push to protected `main` verifies that exact commit with the same graph.
3. An explicitly authorized release operation consumes the already verified
   `main` artifacts and performs signing, repository publication, and channel
   promotion without compiling source.

Workflow cancellation supersedes an older run for the same pull request or
branch. A new pull-request commit creates a new revision and requires a new run;
an approval never carries forward to a different revision.

All jobs have read-only repository permissions, disable persisted checkout
credentials, and receive no repository, organization, environment, signing,
package-publication, or personal secrets. Publication is a separate protected
workflow and runner authority.

Publication uses mutually exclusive protected identities. The release signer
receives only the constrained signing subkey and no network publication
credential. The GitHub release-object publisher receives `contents:write`; the
repository-metadata publisher receives Object Read & Write access only to the
metadata R2 bucket; the contributor-input publisher receives `packages:write`;
and the post-cutover package-object publisher receives Object Read & Write
access only to the package-object R2 bucket. Worker deployment uses a separate
infrastructure identity. No build, qualification, approval, signing,
publication, or deployment job receives more than one of these authorities.

## Phase 1: Establish the Trusted Workflow Boundary

Create one reusable verification workflow whose definition is loaded only from
the protected `main` branch. Restrict the Nucleus CI runner groups to jobs
defined directly by that exact workflow path at `refs/heads/main`. A workflow
added or modified by pull-request code cannot address any Nucleus runner.

The pull-request and `main` entry workflows call that reusable workflow. The
reusable workflow derives the source revision from the GitHub event context and
rejects unsupported event types, mutable branch-name inputs, caller-supplied
repository identities, and source revisions that do not equal the event's
exact merge or push SHA.

Pin every external action to a reviewed full commit identity. Do not use
`pull_request_target`, `workflow_run`, issue comments, labels, or downloaded
artifacts to cross from an untrusted event into execution. Disable GitHub-hosted
jobs for this repository; a missing self-hosted capability leaves the job
queued rather than falling back to hosted compute.

Gate: only the protected reusable workflow can address a Nucleus runner, a
pull request cannot alter its runner-side steps, and the executed checkout is
the exact event revision reported by the resulting check.

## Phase 2: Enforce Owner-Controlled Pull-Request Admission

Configure one repository variable with the owner's exact GitHub login. The
trusted reusable workflow routes owner-authored pull requests directly to the
PR runner group. Every other pull request references a dedicated protected
`pull-request-ci` environment before requesting a runner.

Configure that environment with the owner as its sole required reviewer,
prevent self-review, store no secrets in it, and permit no bypass. Configure
fork workflow policy to require approval for all external contributors as a
second independent gate. Keep organization membership and repository write
access narrow enough that no other identity bypasses the external-contributor
policy.

Approval occurs only after reviewing the complete diff, including workflow,
submodule, package-manifest, build-script, generated-input, and dependency-lock
changes. Synchronizing, reopening, or retargeting a pull request produces a new
run and returns non-owner execution to the approval gate.

Gate: the owner's pull request can queue automatically, every non-owner pull
request remains undispatched until the owner approves its current run, and an
approval of one SHA cannot start or authorize another SHA.

## Phase 3: Provision Separate PR and Trusted Runner Identities

Provision dedicated macOS runner identities on the M2 Ultra for pull-request
and trusted-branch work. Neither identity has access to the interactive
development account, personal SSH agents, browser profiles, iCloud data,
developer signing identities, publication keys, or unrelated source.

The PR identity can read immutable host acquisition inputs and pinned OCI
images but can write only PR-owned checkouts, logs, artifacts, caches, and
persistent workspaces. The trusted identity has distinct writable roots that
the PR identity cannot read or mutate. Native Linux and GPU/DRM qualifiers use
equivalently separated self-hosted runner identities and capability-scoped
runner groups.

Use ephemeral or just-in-time runner registrations. Registration state is
disposable; only declared Collider storage survives jobs. Host provisioning
installs the selected Xcode and Apple-container release before registration.
Jobs run `collider doctor ci-macos-builder` and never select Xcode, install host
packages, mutate launch services, or discover credentials interactively.

Gate: PR code cannot read or modify trusted build state, development data, or
credentials; a fresh registration reaches Collider without interaction; and
runner replacement leaves no undeclared executable state.

## Phase 4: Define One Complete Verification Graph

Define the required verification graph once as a sequence of existing Collider
commands. Both pull-request and `main` events invoke that exact sequence. Do
not add `collider ci`, duplicate component dependency logic in YAML, or create a
reduced pull-request profile.

The graph includes:

- host and toolchain doctor contracts;
- complete repository build and test lanes for every supported target
  architecture;
- Swift SDK, native SDK, Android, Chromium, CEF, compositor, shell, and browser
  artifact construction selected by the repository's ordinary build graph;
- artifact linkage, dependency-closure, ABI, packaging, and consumer
  validation;
- translated x86_64 execution checks where they provide build confidence;
- native Linux and physical GPU/DRM qualification on their declared
  self-hosted capability runners; and
- preservation of Collider run records, task logs, immutable artifact
  manifests, and qualification records on failure and success.

Pull-request and `main` verification differ only in source identity, trust-domain
storage, retention policy, and the authority of their results. Neither path
publishes. The release path consumes successful trusted-`main` artifacts and
qualification records without rebuilding them.

Gate: the same source revision produces the same task graph and artifact
coordinates in PR and `main` verification, while no pull-request event can
reach a publication or signing operation.

## Phase 5: Complete Cross-Identity Admission and Storage Isolation

Place the Collider host-execution lease in one explicitly provisioned
cross-account location whose ownership and POSIX permissions allow both CI
identities and the development account to lock it without reading one
another's state. Every mutating Collider command acquires that lease before
using Apple containers, build volumes, or host-intensive native tools.
Inspection remains available while another run holds admission.

Keep trusted and pull-request writable storage in separate roots and separate
Apple-container volume namespaces. Main verification never consumes a PR
compiler cache, incremental workspace, generated output, artifact, run record,
or mutable checkout. Share only immutable content-addressed downloads, exact
source objects, signed toolchains, and pinned OCI images, mounted read-only.

Allocate PR storage per pull request and retain it only while that pull request
is active. A new revision may reuse its own PR namespace, but no other PR or
trusted build may consume it. Closing a pull request makes its complete mutable
namespace reclaimable through declared Collider storage ownership.

Gate: interactive, PR, and trusted runs cannot overlap host execution; a PR
cannot poison a later `main` build through writable state; and deleting all PR
state leaves trusted incrementality and authoritative inputs intact.

## Phase 6: Bind Build and Qualification Evidence

Make every transferable product an immutable artifact bundle with a manifest
containing source and submodule identities, runner, executor, and artifact
platforms, toolchain and SDK identities, build arguments, file digests,
executable metadata, dynamic-library closure, trust domain, and required
qualification roles.

Qualification consumes only the immutable bundle and manifest. Native Linux
and physical GPU/DRM workers emit separate records bound to the artifact digest
and their declared capabilities. Cross-build inspection and Apple-translated
execution cannot satisfy native kernel, performance, GPU, DRM, or release
gates.

Use a local filesystem artifact store for build and qualification. After all
required qualification records bind to a package cohort, the protected
release-object publisher may upload only its final native package objects and
release index to the immutable GitHub Release governed by the
[Linux package distribution and update plan](linux-package-distribution-and-update-plan.md).
It returns the immutable release identity and remote digests without retaining
publication authority in a later job. The separately authorized metadata
publisher consumes that evidence and publishes the signed R2 snapshot and final
channel object. The package plan owns the equivalent separated R2 object path
after its hard backend cutover.

Do not upload reconstructible Chromium, AOSP, Swift, native-SDK, compiler-cache,
incremental-workspace, or pre-package artifact state to GitHub Actions caches or
release assets.

Gate: a clean qualifier validates an artifact without builder cache or source,
modifying any file invalidates its evidence, and publication rejects PR-owned,
missing, stale, translated, or wrong-platform qualification.

## Phase 7: Cut Over Pull-Request and Main CI

Replace the GitHub-hosted PR job and the current Linux-only trusted jobs with
the protected reusable verification workflow. Configure branch protection to
require its stable final result and to reject stale approvals after the source
revision changes.

Workflow YAML owns only event selection, authorization environment, checkout,
runner capability, Collider setup, command invocation, timeout, concurrency,
and preservation of run and artifact references. It contains no package-manager
commands, component dependency graph, build flags, retry policy, or artifact
layout knowledge.

Use one GitHub concurrency group per pull request and one for protected `main`.
GitHub cancels superseded queued or running revisions; Collider performs
cooperative cancellation, cleanup, run finalization, and admission release.

Gate: owner and approved external pull requests execute the complete
self-hosted non-publication graph, `main` executes the same graph, unapproved
pull requests reach no runner, and branch protection accepts only the final
result for the current revision.

## Phase 8: Complete Acceptance

Exercise owner-authored, external unapproved, external approved, synchronized,
cancelled, closed, and malicious workflow-modification pull requests. Prove
that only the intended exact revisions execute and that runner-group workflow
restriction cannot be bypassed from pull-request YAML.

Run PR, trusted `main`, and interactive Collider requests concurrently and
prove the shared admission lease allows only one task graph to execute while
preserving each admitted graph's internal architecture concurrency. Recreate
both macOS runner identities and every native qualifier from their provisioning
declarations, then repeat cold and warm complete verification.

Attempt credential reads, trusted-cache mutation, cross-PR state access,
publication, direct runner addressing, and artifact substitution from approved
PR code. Each attempt must fail without relying on the tested source to
cooperate. Finally, publish an immutable GitHub Release and signed repository
snapshot from existing qualified `main` package objects and prove that
publication performs no compilation, package assembly, or artifact
substitution.

Gate: all PR CI is self-hosted and owner-authorized, PR and `main` verification
are structurally identical except for trust and publication authority, mutable
state cannot cross trust domains, and runner replacement does not change build
or qualification semantics.

## Explicit Non-Goals

- Do not use GitHub-hosted runners as a fallback or preliminary PR tier.
- Do not treat workflow labels, comments, contributor history, or prior merged
  changes as authorization.
- Do not execute pull-request source through `pull_request_target`,
  `workflow_run`, issue-comment dispatch, or another elevated-token event.
- Do not give any build or qualification runner signing or publication
  credentials.
- Do not combine the release signing subkey, GitHub release publication, GHCR
  publication, R2 metadata publication, R2 package-object publication, or
  Worker deployment credentials in one identity or job.
- Do not let PR and trusted builds share writable caches, workspaces, artifacts,
  or Apple-container volumes.
- Do not use a persistent Linux development machine as a runner or gateway.
- Do not add `collider ci`, `collider dev`, `collider remote`, or worker-service
  command families merely to rename existing task entrypoints.
- Do not add a generic remote artifact or cache backend. Immutable GitHub
  Releases store only final qualified native package objects and their release
  index at the publication boundary. The allowlisted GHCR inputs owned by the
  [Linux x86_64 development host
  plan](linux-x86-64-development-host-plan.md) are a separate contributor-input
  contract, not CI cache state.
- Do not treat Intel translation, QEMU, or software rendering as native
  qualification.
