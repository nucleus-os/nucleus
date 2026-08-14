# GitHub Actions Main-Only Self-Hosted CI/CD Plan

Status: active

## Invariant

Nucleus CI/CD executes only for an exact revision on protected `main`. A push to
`main` and an owner-authorized manual rerun of a `main` revision invoke the same
complete Collider build, test, artifact, and qualification graph. A protected
delivery operation consumes the resulting qualified artifacts without rebuilding
them.

Remote branch pushes, pull requests, forks, and pull-request-associated
dispatches are unsupported. They do not schedule Nucleus compute. Any remote
event or revision that reaches a shared entrypoint outside the declared `main`
contract fails before checkout, Collider setup, or repository-controlled
execution. Expanding automated CI to untrusted revisions requires a separate
future threat model and plan.

The personal M2 Ultra is the only macOS builder. Automated `main` runs and
locally initiated builds execute through one dedicated non-admin macOS
account, `nucleus-builder`. They therefore use the same per-user Collider host
storage, Apple-container service, OCI images, persistent workspaces, compiler
caches, downloaded inputs, staged SDKs, and incremental build state. A pipeline
does not start from a clean build unless declared cache invalidation or incident
recovery requires it.

The interactive `maddy` account owns the authoritative development checkout,
personal credentials, and remote-development sessions but runs no GitHub
Actions service. CI uses a separate clean checkout owned by `nucleus-builder`.
A locally initiated build may instead give `nucleus-builder` read-only access to
the authoritative checkout so committed, modified, deleted, untracked, and
dirty-submodule source can build before it reaches `main`. The accounts share
host execution admission and that narrow read-only source view, not home
directories, credentials, checkout write access, or general writable files.

GitHub Actions remains orchestration around Collider, not a second build
system. Workflow YAML selects an immutable `main` revision, runner capability,
and existing Collider commands. Collider owns dependency planning, offline
Apple-container execution, persistent workspaces, artifacts, logs,
cancellation, cache validity, and host-wide execution admission.

Remote development is defined by the
[macOS Remote Development Plan](macos-remote-development-plan.md). Automated CI
never uses the authoritative development checkout. Local execution reads it in
place without uploading or copying it into a second source authority and does
not introduce a Collider worker daemon, source-snapshot service, or
remote-execution protocol.

## Current State

The only current workflow runs whitespace and submodule-declaration checks for
pull requests on a GitHub-hosted Ubuntu worker. It does not invoke Collider.
There is no automated `main` build until this plan establishes the main-only,
self-hosted M2 Ultra execution contract.

Collider already represents runner, execution, and artifact platforms
independently. It owns typed Apple-container lifecycle, offline OCI execution,
durable runs, content-derived task identity, persistent build workspaces,
cancellation, logs, and cleanup. Its execution lease serializes task-graph
execution within one configured storage root while retaining internal task and
architecture concurrency.

Collider's complete incremental state is deliberately per-user. The largest
state includes Apple-container persistent volumes beneath the current user's
Developer root, not only loose files beneath a cache directory. Pointing two
macOS accounts at a shared directory would therefore not give them the same
warm build. One trusted builder identity must own both automated and locally
initiated execution.

Persistent workspace names are currently scoped by a digest of the absolute
checkout root. A builder-owned CI checkout and the authoritative development
checkout therefore select different Apple-container volumes even when the
builder identity and source contents match. The source-closure digest also
distinguishes a base Git tree plus working-copy overlay from the identical tree
after commit. Both identities must be corrected before local pre-commit builds
can warm the exact state later used by CI.

The existing retained M2 Ultra state belongs to the interactive account. The
`nucleus-builder` account, its clean checkout, its persistent Apple-container
login service, the one-time retained-state cutover, and the complete `main`
workflow do not yet exist.

## Threat Model and Host Roles

Only protected `main` is authorized for remote execution and delivery. The sole
developer may explicitly initiate local execution of the authoritative
checkout before commit. In both cases build code is native code. A compromised
dependency, toolchain, checkout, local modification, or main revision can read
and modify every byte visible to `nucleus-builder`, including its persistent
caches. The builder account is therefore a containment boundary around
reconstructible project state, not proof that executed code is harmless.

The M2 Ultra roles are:

- `maddy` owns personal data, credentials, the authoritative checkout, and
  interactive development, and can authorize builds and delivery operations;
- `nucleus-builder` owns the clean `main` checkout, GitHub Actions runner,
  Apple-container service, shared Collider cache, persistent workspaces, staged
  build artifacts, and run records, and receives read-only access to the Nucleus
  development checkout for an explicitly initiated local build;
- native Linux and physical GPU/DRM qualifiers receive only immutable artifact
  bundles and emit digest-bound qualification records; and
- signing, GitHub Release publication, R2 publication, contributor-input
  publication, and Worker deployment remain separate protected identities that
  the builder and qualifiers cannot assume.

The account boundary protects ordinary personal files and credentials from
ordinary builder processes. It does not isolate the personal account from a
macOS kernel, firmware, hypervisor, privileged host-service, or hardware escape
on the same physical machine. That residual risk is accepted by the one-M2-Ultra
requirement and is recorded explicitly rather than hidden behind a second user
account or an Apple container.

Persistent cache reuse is intentional persistence inside the trusted builder
domain. A suspected compromise quarantines the builder account and all of its
cache and workspace state. Normal pipeline completion never performs that
recovery operation.

## CI Event and Trust Contract

The repository has three supported remote event classes:

1. A push to `refs/heads/main` verifies that exact commit and produces qualified
   but unpublished artifacts.
2. An owner-authorized manual invocation reruns an exact commit already present
   on protected `main`, using the same workflow, builder identity, commands, and
   cache.
3. An explicitly authorized delivery operation consumes successful artifacts
   and qualification records from an exact verified `main` commit and performs
   signing, repository publication, and channel promotion without compiling
   source.

Every other event class is unsupported. The repository subscribes to no branch
push or pull-request event. A reusable or manually dispatched entrypoint
validates the repository, event, full revision, and `refs/heads/main` membership
before it requests a source checkout or invokes a repository-controlled file.

A local invocation is not a CI event. It originates from the authenticated
interactive M2 Ultra session, names the authoritative checkout and a typed
Collider operation, and may build its current committed or dirty source. It
uses the shared builder account and cache but records local-dirty provenance,
cannot request a native release qualification, and cannot satisfy a signing or
publication gate.

Build and qualification jobs have read-only repository permissions, disable
persisted checkout credentials, and receive no repository, organization,
environment, signing, package-publication, or personal secret. The job-scoped
GitHub token is the only workflow credential visible to a build, and its
authority is limited to reading the exact repository revision and reporting the
current run.

Publication uses mutually exclusive protected identities. The release signer
receives only the constrained signing subkey and no network publication
credential. The GitHub release-object publisher receives `contents:write`; the
repository-metadata publisher receives Object Read & Write access only to the
metadata R2 bucket; the contributor-input publisher receives `packages:write`;
and the post-cutover package-object publisher receives Object Read & Write
access only to the package-object R2 bucket. Worker deployment uses a separate
infrastructure identity. No build, qualification, signing, publication, or
deployment job receives more than one of these authorities.

## Phase 1: Define Portable Product Artifacts and Qualification Evidence

Define one content-addressed product-artifact envelope in Collider before a CI
workflow, package publisher, or development transport consumes it. Every
transferable product bundle carries a manifest containing:

- source and submodule closure identities;
- producing task identity;
- runner, executor, and artifact platforms;
- toolchain, Swift SDK, native SDK, and builder-image identities;
- build configuration and semantic build arguments;
- archive, file-tree, and individual file digests;
- executable metadata and dynamic-library closure;
- producer trust domain; and
- required qualification roles.

Canonicalize placement-only checkout, cache, home, workspace, and output roots
before encoding identity. Retain semantic relative paths and file contents.
Reject an artifact identity containing an unrecognized absolute host path
instead of producing a bundle that another runner or qualifier cannot validate.

Define task source identity from the effective Git-owned file tree: tracked
contents after applying modifications and deletions, non-ignored untracked
files, executable bits, symlink targets, and nested-checkout trees. The same
effective tree has the same cache identity before and after commit and from the
builder CI checkout or authoritative development checkout. Record the base
commit, branch, dirty paths, and protected-`main` authority separately as
provenance; those facts decide releasability but do not force identical source
bytes to compile twice. Any task whose result genuinely consumes Git metadata
declares that metadata as a semantic input.

Use the same canonical identity and digest primitives for domain-specific
contracts without making those contracts interchangeable. A CI product bundle,
digest-bound qualification record, package release index, allowlisted GHCR
contributor input, and unsigned dirty development generation remain distinct
types with distinct authorities and storage boundaries. There is no generic
remote artifact cache, generic publication operation, or implicit conversion
between those domains.

Qualification consumes only an immutable product bundle and its manifest. A
native Linux or physical GPU/DRM qualifier emits a separate record bound to the
artifact digest and its declared capability. Cross-build inspection and
Apple-translated execution cannot satisfy native kernel, performance, GPU, DRM,
or release gates.

Use a local filesystem artifact store for build and qualification. Do not
upload reconstructible Chromium, AOSP, Swift, native-SDK, compiler-cache,
incremental-workspace, or pre-package artifact state to GitHub Actions caches or
release assets. The package plan alone defines the final release index and
immutable package-object publication boundary.

Gate: planning the same representative products under different checkout,
cache, home, workspace, and output roots produces the same portable artifact
identity; an effective local tree and the identical committed tree produce the
same source and task cache identities but distinct provenance authority;
changing source, toolchain, configuration, target, or a semantic input changes
the relevant identity; a clean qualifier validates a bundle without builder
cache or source; corruption and substitution fail; and no domain-specific
artifact can be consumed through another domain's authority.

## Phase 2: Establish the Main-Only Workflow Boundary

Create one protected verification workflow loaded only from `main`. Its normal
trigger is a push to `refs/heads/main`. Its manual trigger accepts only an exact
commit already reachable from protected `main`. It rejects a mutable branch
name, a different repository, a branch-only commit, a pull-request merge commit,
and caller-supplied workflow or runner selection.

Do not subscribe any workflow to `pull_request`, `pull_request_target`,
non-`main` pushes, issue comments, labels, or fork events. A shared entrypoint
that receives an unsupported context runs only a protected preflight and fails
before checkout, action setup, Collider setup, cache access, or execution of a
repository-controlled path. No unsupported event can address a native
qualifier or delivery identity.

Restrict the Nucleus runner group to the protected workflow path at
`refs/heads/main`. Pin every external action to a reviewed full commit identity.
Disable GitHub-hosted fallback; a missing M2 Ultra or native qualifier leaves a
supported `main` job queued rather than moving it to different compute.

Gate: a `main` push and exact-`main` manual invocation reach the M2 Ultra; branch
push, pull-request, fork, foreign-repository, mutable-ref, and pull-request-merge
probes execute no checkout or repository code; and the recorded source revision
equals the protected `main` commit selected by the event.

## Phase 3: Provision One Trusted Builder Identity

Provision a hidden standard macOS account named `nucleus-builder` on the M2
Ultra. It is not an administrator and has no Secure Token, FileVault unlock
authority, sudo path, remote-login membership, interactive GUI use, iCloud
account, personal Keychain item, personal TCC grant, developer signing identity,
or publication credential.

The interactive home outside `~/Developer/nucleus`, SSH agents, browser
profiles, personal developer state, and unrelated source remain unreadable and
unsearchable by `nucleus-builder`. Give the builder traverse and read access to
only the authoritative Nucleus checkout. It cannot create, modify, delete, or
rename source, Git metadata, ignored state, or files in that checkout. The
account also owns a separate clean checkout whose automated executable revision
is the exact protected `main` commit admitted by Phase 2. The interactive
account installs or runs no Actions service.

Install the pinned GitHub Actions runner and persistent Apple-container login
service for `nucleus-builder`. Keep runner configuration and service bootstrap
outside the checkout-controlled work directory. Disable automatic runner
replacement by job code; host provisioning owns runner upgrades after their
exact versions are reviewed.

Support two manual paths through the same identity. GitHub manual dispatch uses
the protected workflow and clean builder checkout. A local invocation uses a
root-owned, synchronous account-switching launcher that accepts only the
canonical authoritative-checkout path, a typed existing Collider operation, and
declared debug or release configuration. It executes checkout-controlled code
as `nucleus-builder` in that account's existing login and Apple-container
context. The launcher grants no arbitrary shell and is not a daemon, worker
protocol, source copy, or remote-execution service.

Move every launcher, SwiftPM, package-resolution, generated-configuration, and
host-acquisition write out of the source checkout and into builder-owned
declared storage. The builder consumes either checkout read-only. Revalidate the
effective source identity before accepting local outputs; if the developer
changes the working tree during execution, mark the run superseded instead of
assigning artifacts to the earlier identity.

Gate: account and filesystem probes prove that the builder lacks admin, Secure
Token, sudo, remote-login, GUI, TCC, Keychain, signing, publication, and
personal-home access; it can read but not mutate the Nucleus development
checkout and cannot traverse unrelated interactive state; automated and local
invocations report `nucleus-builder` as their effective user and the same
Apple-container application root; a dirty-tree build observes every declared
working-copy change; source mutation supersedes the run; and unsupported remote
revisions fail before account switching or checkout.

## Phase 4: Unify Persistent Cache and Host Admission

Make the conventional per-user Collider storage owned by `nucleus-builder` the
single trusted build store for automated and locally initiated execution:

- `~/Library/Application Support/Nucleus/Collider` owns service metadata;
- `~/Library/Developer/Nucleus/Collider` owns Apple-container state, persistent
  volumes, incremental build workspaces, staged artifacts, and host build state;
- `~/Library/Caches/Nucleus/Collider` owns downloads, SDKs, package inputs,
  repository inputs, and reproducible host caches; and
- `~/Library/Logs/Nucleus/Collider` owns service logs and build run records.

Move the retained cache, SDK, image, and persistent-workspace state needed by
the selected graph from the interactive account into the builder account in one
offline, same-filesystem cutover. Verify sparse allocation, volume metadata,
task identity, ownership, and warm reuse before retiring the old copy. Do not
duplicate the complete retained working set or leave two writable cache
authorities.

Every supported run reuses this state. Exact source, submodule, toolchain,
configuration, platform, and semantic input identities decide whether an
action is current. The checkout path, invocation source, GitHub run identifier,
and choice between automated and manual initiation do not create different
cache identities. A changed semantic input invalidates only its affected action
closure.

Replace the absolute-checkout digest used as the Apple-container persistent
workspace owner with one provisioned machine-local Nucleus builder-domain
identity. Only the clean CI checkout and canonical authoritative development
checkout may select it, and both execute as `nucleus-builder`. The machine-wide
lease prevents their source views from using the same mutable workspace
concurrently.

Store debug and release state in the same builder storage domain with explicit
configuration identity. Configuration-independent acquisitions, toolchains,
SDKs, source volumes, OCI images, and safe compiler-cache entries are shared.
Debug and release objects, SwiftPM products, CMake or GN output directories,
staged products, task records, and artifacts remain configuration-distinct.
Where an underlying build tool cannot safely keep both configurations in one
workspace, add the configuration to its persistent-workspace role or internal
directory instead of cleaning the other configuration.

Preserve downloads, staged SDKs, OCI images, persistent source volumes,
architecture-specific build workspaces, SwiftPM intermediates, and compiler
caches across runner jobs and manual invocations. Clean only the checkout work
directory, job temporary state, expired run history, and storage selected by
Collider's declared retention policies. Do not pass `--rebuild`, erase
persistent workspaces, recreate the Apple-container application root, or wipe
the account home as routine pipeline setup or teardown.

Place one machine-wide Collider execution lease in an explicitly provisioned
location that both the interactive account and `nucleus-builder` can lock
without reading one another's data. Automated builds, manual shared-cache
builds, ordinary developer builds, cache maintenance, and Apple-container
mutation all acquire it. One task graph uses the M2 Ultra at a time while the
admitted graph retains its internal component and architecture concurrency.

Gate: an automated build followed by a local build of identical effective
source and configuration, and the reverse ordering, reuse the same action
outputs, SDKs, images, compiler caches, and persistent workspaces; a dirty build
followed by committing the identical tree does not compile identical source
again; debug and release coexist without collisions or mutual cleaning; neither
ordering performs a clean rebuild; a semantic source or configuration change
invalidates only the expected closure; concurrent invocations serialize; and
deleting runner work directories leaves the retained build state intact.

## Phase 5: Enforce Account, Credential, Network, and Recovery Boundaries

Keep all build and qualification credentials read-only and job-scoped. The
builder cannot read personal homes, attach to personal agents, use signing
identities, reach publisher credentials, or deploy infrastructure. Host-side
acquisition reaches only the public origins required by the pinned source and
dependency graph. Apple containers retain the host-only network with DNS
disabled and receive only already acquired inputs.

Treat every builder cache, workspace, image, checkout, staged artifact, and run
record as reconstructible project state. Never place a personal secret,
publication credential, release signing key, browser profile, private unrelated
source, or authoritative document in the builder account or its backups.

On ordinary failure or cancellation, Collider finalizes the run, terminates its
containers, and preserves valid incremental state. On suspected compromise,
unexpected persistence, account-boundary failure, or cache-integrity failure,
quarantine `nucleus-builder`; prevent CI, manual trusted builds, signing, and
publication; preserve diagnostics; then recreate its checkout, account-owned
state, runner, service, and caches from declared inputs. If a kernel, firmware,
hypervisor, or privileged host-service escape is suspected, recover the entire
M2 Ultra before restoring personal or release authority.

Gate: hostile probes executing as the builder cannot read the interactive home,
credentials, signer, publisher, private network services, or unrelated source;
containers cannot reach an external network; ordinary failure preserves valid
warm state; and a forced quarantine prevents subsequent trusted execution until
the declared recovery gate completes.

## Phase 6: Define One Complete Verification Graph

Define the required verification graph once as a sequence of existing Collider
commands. Automated `main`, GitHub manual, and a local request for the complete
CI-equivalent graph execute that exact sequence. Ordinary local build and test
requests select components and debug or release configuration from the same
catalog; they do not define a second dependency graph. Do not add `collider ci`,
duplicate component dependency logic in YAML, or create a reduced CI profile.

Add one typed `debug` or `release` build-configuration selection to the existing
build and test entrypoints wherever both configurations are meaningful. Keep
the graph's current opinionated defaults. The production verification graph
declares its exact required configuration for each product and test lane rather
than inheriting a local default or accepting arbitrary compiler flags from
workflow input.

The graph includes:

- host and toolchain doctor contracts;
- complete repository build and test lanes for every supported target
  architecture;
- Swift SDK, native SDK, Android, Chromium, CEF, compositor, shell, and browser
  artifact construction selected by the ordinary build graph;
- artifact linkage, dependency-closure, ABI, packaging, and consumer
  validation;
- translated x86_64 execution checks where they provide build confidence;
- native Linux and physical GPU/DRM qualification on their declared
  self-hosted capability runners; and
- preservation of Collider run records, task logs, immutable artifact
  manifests, and qualification records on failure and success.

All invocation sources produce the same task identities and artifact coordinates
for the same effective source, configuration, and semantic inputs. A local debug
build can reuse configuration-independent state from release and warms the
debug-specific state later consumed by a matching CI lane. A local release build
of the same source warms the release-specific state directly. Delivery consumes
successful qualified `main` artifacts without rebuilding them.

Gate: automated and local planning of identical effective source and
configuration produces the same task identities, cache hits, and artifact
identities; debug and release select distinct configuration-specific products
while sharing configuration-independent prerequisites; only the complete
protected-`main` graph can request release qualification; no build path
publishes or signs; and delivery performs no compilation or package assembly.

## Phase 7: Cut Over Main CI/CD

Remove the GitHub-hosted pull-request job. Install the protected main-only
workflow, M2 Ultra runner, native qualification routing, successful-run
artifact retention, and protected delivery consumers.

Workflow YAML owns only supported event selection, preflight validation,
checkout, runner capability, Collider setup, command invocation, timeout,
concurrency, and preservation of run and artifact references. It contains no
package-manager commands, component dependency graph, build flags, retry
policy, cache wiping, or artifact layout knowledge.

Use one GitHub concurrency group for protected `main`. A newer `main` revision
cancels a superseded queued or running revision; Collider performs cooperative
cancellation, cleanup, run finalization, and admission release without deleting
valid persistent state. GitHub manual reruns and locally initiated branch,
dirty, debug, and release builds join the same machine admission and cache
domain without becoming CI events.

Delivery accepts only the exact artifacts and qualification records from a
successful supported `main` run. A branch artifact, pull-request artifact,
locally dirty artifact, or failed/superseded run cannot enter signing or
publication.

Gate: a `main` push and authorized `main` rerun execute the complete graph on
the M2 Ultra with warm-state reuse; branch and pull-request activity schedules
no build; a deliberately misrouted invocation fails before checkout; and only a
successful exact-`main` artifact cohort can reach delivery.

## Phase 8: Complete Acceptance

Exercise `main` pushes, same-revision reruns, owner manual dispatches, local
clean-main builds, local branch builds, modified and deleted tracked files,
non-ignored untracked files, dirty submodules, debug and release selection,
cancellations, runner restarts, host restarts, and superseded revisions.
Exercise remote branch pushes, pull requests, forks, mutable refs, pull-request
merge revisions, foreign repositories, and modified workflow callers. Prove
that local source executes only after interactive initiation and that only exact
protected `main` revisions reach automated checkout, release qualification, or
delivery.

Run one declared cold reconstruction to prove reproducibility. Then run the
complete graph warm through automated and manual paths in both orderings. Prove
that the same configuration reuses downloads, images, SDKs, native build trees,
SwiftPM intermediates, AOSP and Chromium source/output volumes, and compiler
caches, while semantic changes invalidate only the expected task closure.
Build a dirty tree, commit that identical tree, and prove the later `main` build
reuses its compilation state while emitting new protected provenance. Alternate
debug and release builds and prove their configuration-specific products remain
simultaneously valid.

Request automated, local manual, remote-development, and cache-maintenance work
concurrently. Prove the machine-wide admission lease allows one task graph to
execute while preserving the admitted graph's internal concurrency. Restart
the runner and Apple-container login service and prove the same persistent
workspaces remain available.

Attempt personal-home traversal, Keychain access, SSH-agent use, TCC-protected
data access, sudo and admin operations, signing, publication, deployment,
private-service access, runner reconfiguration, and delivery substitution from
builder code. Each attempt fails at the declared boundary. Then simulate cache
integrity failure and prove quarantine blocks all trusted consumers until
recovery completes.

Finally, publish an immutable GitHub Release and signed repository snapshot from
existing qualified `main` package objects and prove that publication performs
no compilation, package assembly, cache lookup, or artifact substitution.

Gate: Nucleus has one self-hosted `main` CI/CD lane on the required M2 Ultra;
automated main and locally initiated clean, branch, dirty, debug, and release
builds use one persistent Collider cache; unsupported remote revisions fail
closed; local non-main artifacts cannot acquire release authority; the builder
account remains separate from the personal account and delivery identities;
warm reuse is the routine path; and recovery, not every pipeline, owns clean
reconstruction.

## Explicit Non-Goals

- Do not run CI for branch pushes, pull requests, forks, issue comments, labels,
  or pull-request-associated events in this phase.
- Do not use GitHub-hosted runners as a fallback or preliminary tier.
- Do not let remote branch, pull-request, fork, or mutable-ref activity invoke
  the builder merely because locally initiated branch and dirty builds are
  supported.
- Do not qualify, sign, publish, or deploy a locally dirty or non-`main`
  artifact, even when its content digest later matches protected `main`.
- Do not run the GitHub Actions service or CI checkout as `maddy`.
- Do not give the builder account personal credentials, signing keys,
  publication credentials, deployment credentials, or unrelated private data.
- Do not split automated and manual CI-equivalent builds across different
  macOS users, Apple-container application roots, caches, or persistent
  workspace sets.
- Do not let debug and release share a configuration-specific output path or
  force either configuration to clean the other's valid state.
- Do not wipe downloads, SDKs, images, build workspaces, compiler caches, or the
  Apple-container application root during ordinary job setup or teardown.
- Do not combine the release signing subkey, GitHub release publication, GHCR
  publication, R2 metadata publication, R2 package-object publication, or
  Worker deployment credentials in one identity or job.
- Do not claim that a second macOS account or Apple container protects personal
  state from a same-host kernel, firmware, hypervisor, or privileged-service
  escape.
- Do not use a persistent Linux development machine as a runner or gateway.
- Do not add `collider ci`, `collider dev`, `collider remote`, a worker daemon,
  source-snapshot service, or remote-execution protocol.
- Do not add a generic remote artifact or cache backend. Immutable GitHub
  Releases store only final qualified native package objects and their release
  index at the publication boundary. The allowlisted GHCR inputs owned by the
  [Linux x86_64 development host
  plan](linux-x86-64-development-host-plan.md) are a separate contributor-input
  contract, not CI cache state.
- Do not treat Intel translation, QEMU, or software rendering as native
  qualification.
