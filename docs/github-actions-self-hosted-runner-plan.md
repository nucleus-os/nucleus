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

The checked-in workflow admits only pushes to `refs/heads/main` and manual
requests naming an exact commit already reachable from protected `main`. A
GitHub-hosted preflight validates the repository, event, workflow ref, full
revision, and main reachability before checkout. The admitted revision alone
may address the fixed `nucleus` runner group and `nucleus-m2-ultra` label, where
Collider independently validates the protected-main provenance contract. The
runner group, builder account, and registered runner exist, and the first
protected-main verification reached the builder. Its Collider step never
executed: the Actions runner substitutes each `run:` step-script path into the
shell command line unquoted, so a machine-wide root containing whitespace
splits into separate arguments and `bash` fails before the step body. The host
contract now pins whitespace-free machine-wide roots, and Phase 3 stays open
until the builder is re-provisioned under them.

Collider already represents runner, execution, and artifact platforms
independently. It owns typed Apple-container lifecycle, offline OCI execution,
durable runs, content-derived task identity, persistent build workspaces,
cancellation, logs, and cleanup. Its execution lease serializes task-graph
execution within one configured storage root while retaining internal task and
architecture concurrency.

Collider now also owns the portable product-artifact contract, a tested local
content-addressed product-store primitive, distinct provenance identities, and
digest-bound qualification records. Effective Git-owned source and task
identities are independent of checkout placement and of whether identical
contents have been committed. Production package producers and qualification
consumers are not yet wired through that store; the active package phase and
Phase 6 complete that integration before CI cutover.

Collider also owns the patched Linux SwiftPM/SwiftBuild host-tool closure. The
root pins the Nucleus forks as submodules; host resolution materializes their
exact dependency closure, an offline arm64 container compiles the unified
`swift-package-manager` executable in a persistent workspace, and Collider
assembles and validates the
bounded overlay as a host artifact mounted read-only by production SwiftPM
actions. The single stable builder image does not contain or depend on that
artifact, so overlay revisions reuse it and avoid repeated OCI unpacking.
Production actions invoke only the mounted executable; the official adjacent
SwiftPM remains available solely for bootstrap work. This work is part of the same cacheable graph used locally and
later by self-hosted `main`. There is no GitHub-hosted overlay workflow or
separately published overlay release.

The same graph no longer creates entrypoint-only variants of the native image
for AOSP, gfxstream, Chromium, or Swift target-runtime work. Those actions mount
their hashed operational entrypoint read-only and reuse the dependency image.
Entrypoint changes therefore preserve the shared image layers and avoid repeated
Apple Container import and unpack costs. Collider also verifies that every
recorded clean image producer still has its exact local runtime digest before a
job may reuse it.

Collider's complete incremental state is deliberately per-user. The largest
state includes Apple-container persistent volumes beneath the current user's
Developer root, not only loose files beneath a cache directory. Pointing two
macOS accounts at a shared directory would therefore not give them the same
warm build. One trusted builder identity must own both automated and locally
initiated execution.

Persistent workspace names are currently scoped by a digest of the absolute
checkout root. A builder-owned CI checkout and the authoritative development
checkout therefore select different Apple-container volumes even when the
builder identity and source contents match. Phase 4 replaces that remaining
workspace-owner identity before local pre-commit builds can warm the exact
persistent state later used by CI.

The existing retained M2 Ultra state belongs to the interactive account. The
`nucleus-builder` account, its clean checkout, its persistent Apple-container
per-user service, the one-time retained-state cutover, and the complete `main`
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

Status: complete

Collider defines one content-addressed product-artifact envelope before a CI
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

Placement-only checkout, cache, home, workspace, and output roots are
canonicalized before encoding identity. Semantic relative paths and file
contents remain intact. Artifact construction rejects an identity containing an
unrecognized absolute host path
instead of producing a bundle that another runner or qualifier cannot validate.

Task source identity comes from the effective Git-owned file tree: tracked
contents after applying modifications and deletions, non-ignored untracked
files, executable bits, symlink targets, and nested-checkout trees. The same
effective tree has the same cache identity before and after commit and from the
builder CI checkout or authoritative development checkout. Base commit, branch,
dirty paths, and protected-`main` authority are recorded separately as
provenance; those facts decide releasability but do not force identical source
bytes to compile twice. Any task whose result genuinely consumes Git metadata
declares that metadata as a semantic input.

The same canonical identity and digest primitives serve domain-specific
contracts without making those contracts interchangeable. A CI product bundle,
digest-bound qualification record, package release index, allowlisted GHCR
contributor input, and unsigned dirty development generation remain distinct
types with distinct authorities and storage boundaries. There is no generic
remote artifact cache, generic publication operation, or implicit conversion
between those domains.

Qualification consumes only an immutable product bundle and its manifest. A
native Linux or physical GPU/DRM qualifier emits a separate record bound to the
artifact and provenance digests, evidence, trust domain, and declared
capability. Cross-build inspection and
Apple-translated execution cannot satisfy native kernel, performance, GPU, DRM,
or release gates.

Collider defines and behaviorally validates a local filesystem artifact store.
Production package publication adopts it in Phase 3 of the package plan, and
the complete verification graph adopts it for product and qualification
exchange in Phase 6 below. Reconstructible Chromium, AOSP, Swift, native-SDK,
compiler-cache, incremental-workspace, and pre-package artifact state do not
enter GitHub Actions caches or release assets. The package plan alone defines
the final release index and immutable package-object publication boundary.

Gate evidence: Collider tests prove identical product identity across relocated
checkout, cache, home, workspace, and output roots; identical source and task
identity immediately before and after commit; distinct local and protected-main
provenance; invalidation by source, toolchain, configuration, target, and
semantic argument; rejection of undeclared absolute host paths; source-free and
cache-free validation in a clean artifact store; archive substitution and
payload corruption failure; multiple provenance authorities for one bundle;
and rejection of cross, translated, and nonphysical qualification capabilities.

## Phase 2: Establish the Main-Only Workflow Boundary

Status: active.

The checked-in workflow now has only `main` push and exact-revision manual
triggers. Its admission job executes no checkout or repository-controlled code,
rejects foreign repositories, non-main workflow refs, unsupported events,
mutable revisions, branch-only commits, and pull-request merge commits, and
passes its immutable revision to a fixed self-hosted runner group and label.
The self-hosted job checks out that revision with credentials removed and passes
the complete protected-main provenance environment to `collider check
protected-main-source`.

Collider requires a full lowercase commit, `refs/heads/main`, the
`protected-main` authority, and the `nucleus-builder` producer trust domain. It
rechecks `HEAD`, rejects tracked or untracked dirtiness anywhere in the checkout
even when a product declares a narrower source closure, and refuses release
qualification unless both protected-main provenance and nucleus-builder
production are present.

Local gate evidence: the admission script accepted push and manual forms for an
exact commit reachable from `main` and rejected foreign-repository,
mutable-revision, and non-main-ref probes before its API request or checkout.
Collider run `2026-08-17T17-07-08.878Z-34486` passed the complete CLI and engine
suites, including exact-commit, whole-checkout cleanliness, complete environment,
generated grammar, and release trust-domain coverage. The phase remains active
until the workflow and runner-group restriction are exercised on GitHub; Phase 3
provides the account and runner required for the self-hosted half of that live
gate.

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

After the protected preflight selects and verifies the immutable revision, it
passes this product-provenance contract to Collider:

```text
NUCLEUS_PRODUCT_SOURCE_AUTHORITY=protected-main
NUCLEUS_PRODUCT_SOURCE_COMMIT=<verified full revision>
NUCLEUS_PRODUCT_SOURCE_REF=refs/heads/main
NUCLEUS_PRODUCT_PRODUCER_TRUST_DOMAIN=nucleus-builder
```

Product assembly rechecks that the asserted revision equals `HEAD`, records the
protected branch even when GitHub checked out that revision detached, and
rejects a dirty checkout. A local invocation supplies none of these assertions;
Collider records the observed branch, revision, and dirty paths with
`local-development` authority and the `local-developer` producer trust domain.
The source-tree digest remains independent of both provenance forms, so equal
source bytes can reuse build work without making a local product releasable.

Gate: a `main` push and exact-`main` manual invocation reach the M2 Ultra; branch
push, pull-request, fork, foreign-repository, mutable-ref, and pull-request-merge
probes execute no checkout or repository code; and the recorded source revision
equals the protected `main` commit selected by the event.

## Phase 3: Provision One Trusted Builder Identity

Status: active

Provision a hidden standard macOS account named `nucleus-builder` on the M2
Ultra. It is not an administrator and has no Secure Token, FileVault unlock
authority, sudo path, remote-login membership, interactive GUI use, iCloud
account, personal Keychain item, personal TCC grant, developer signing identity,
or publication credential.

The interactive home outside `~/Developer/nucleus`, SSH agents, browser
profiles, personal developer state, and unrelated source remain unreadable and
unsearchable by `nucleus-builder`. Give the builder traverse and read access to
only the authoritative Nucleus checkout. It cannot create, modify, delete, or
rename source, Git metadata, ignored state, or files in that checkout.

The source boundary is an allow list, and the interactive home's mode is what
makes it one. macOS makes every local account a member of `staff` through a
well-known group GUID, so a private home cannot be expressed through group
membership: at the macOS default of 0750 the builder reads the entire home
through `staff`, and every exclusion has to be enumerated at provisioning time
and kept current against state created later. Mode 0700 removes that access at
its source, leaving exactly two traverse entries as the way in. `search` is
execute-only, so neither the home nor its source directory can be listed. The
checkout is then read through its ordinary other-readable mode.

Mode removes enumeration, not reachability: a traverse grant reaches any child
by name, so each sibling of the checkout carries an explicit deny. Those denies
are bounded at one entry per top-level entry and are reasserted on every
provisioning, which is what keeps them current. A sibling created between two
provisionings is reachable by name until the next run, and closing that
residual structurally means giving the checkout a parent directory that
contains nothing else.

The builder still holds a dedicated primary group, which is what objects it
creates are grouped by, but that group is not what excludes it: membership of
`staff` is not refusable on macOS, and provisioning does not pretend otherwise.

No recursive pass over the working tree exists. A blanket per-file grant would
have to override every mode the developer deliberately restricted, which is how
owner-only local signing keys inside the checkout became builder-readable under
the previous model. Those keys are no longer in the checkout at all: generated
Android signing and tooling state moved to declared account-local storage, so
the builder needs nothing from the interactive checkout that is not source.
Ownership already denies the builder every write, so the
only explicit write entries are one inheritable deny on the checkout root for
objects created later and a bounded scan closing the world-writable objects
package managers leave behind. The boundary is therefore a fixed handful of
entries rather than one per file, and it neither weakens with time nor grows
with the tree. The
account also owns a separate clean checkout whose automated executable revision
is the exact protected `main` commit admitted by Phase 2. The interactive
account installs or runs no Actions service.

Install the pinned GitHub Actions runner and persistent Apple-container per-user
service for `nucleus-builder`. Keep runner configuration and service bootstrap
outside the checkout-controlled work directory. Disable automatic runner
replacement by job code; host provisioning owns runner upgrades after their
exact versions are reviewed.

The job checkout lives in builder-owned per-user storage, not under the machine
root. Retiring or upgrading the runner therefore preserves a multi-gigabyte
recursive submodule checkout instead of forcing a full re-clone, and
finalization no longer walks every submodule working tree twice to reassign
ownership. Verification proves the work root is builder-owned and outside the
runner installation.

Automated checkout fetches complete history and tags, including submodules.
Provenance capture alone would not require it: the source snapshot uses only
`rev-parse HEAD`, `symbolic-ref`, `diff --name-only HEAD`, `ls-files --others`,
and the declared submodule paths. Resolution does. Dependency mirroring
redirects upstream dependency URLs to the first-party submodules, so SwiftPM
resolves ordinary version requirements against those local mirrors and each
must carry the tag it resolves to along with that tag's history. A mirror is
routinely checked out past the tag a dependent resolves, so the required
objects are not reachable from the gitlink alone. Shallowing this checkout
therefore fails at resolution rather than at provenance, and the depth a mirror
needs is a property of the mirroring, not something a pin update can remove.

The machine-wide runner and host-contract roots are absolute, whitespace-free,
and named once by the host contract. The Actions runner formats a `run:` step
into one command string and lets the process launcher resplit it, so any
whitespace in these roots reaches `bash` as separate arguments and every `run:`
step fails before its body executes. The work root carries the same
requirement, because step scripts are written to its `_temp`.
`/Library/Application Support` is therefore unusable for this role. The roots
are `/Library/Nucleus/GitHubActionsRunner` and `/Library/Nucleus/Builder`.
Provisioning refuses a contract that names a relative or whitespace-bearing
root, and verification gates the installed roots the same way. Per-user
Collider storage keeps its conventional `~/Library` locations, which no runner
argument formatting reaches.

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

The host contract now pins Actions runner `2.336.0`, its exact arm64 archive
size and SHA-256, the runner group, label, name, service identity, account,
home, organization, repository, and authoritative checkout. It selects the
macOS and Xcode major releases rather than exact beta builds, because those
build identifiers move under the host without changing what Nucleus compiles
against; the selected developer directory, the Swift 6.4 compiler it provides,
and its testing macro plugin remain exact. Doctor evidence still reports the
observed macOS and Xcode build identifiers.

Collider owns provisioning that needs no privilege. `collider provision
macos-builder prepare` acquires and verifies the pinned runner archive into the
interactive account's provisioning cache, as one more pinned host acquisition.
`collider provision macos-builder handoff` creates or reconciles the
workflow-restricted `nucleus` runner group, obtains a short-lived organization
registration token, invokes one root provisioning boundary, and verifies the
resulting GitHub registration. Before its first GitHub mutation it verifies the
canonical checkout, executing user, complete pinned runner archive,
provisioning executables, and local account/service state. Named stages
identify the exact failing control-plane operation without printing
credentials. The registration token bypasses the logging runtime entirely: it
is read straight into memory, reaches the privileged boundary only on standard
input, and never enters argv, the child environment, or the durable run log.
Credential scrubbing covers JSON-encoded secret fields as well as form and
header shapes, so a captured control-plane response cannot carry a secret into
a run log.

The language boundary sits on the privilege boundary. Collider decides and
reconciles; every privileged mutation stays in a root-owned script it invokes
through `sudo`, because Collider rebuilds itself from the working tree when its
source fingerprint changes and must never do that as root. The local and
runner-group state contract, its admitted transitions, and the machine-root
removal guard are typed and directly tested rather than compared as shell
output.
Root provisioning is one-time and non-replacing: it creates the locked hidden
account by assigning the non-authenticating directory password marker directly,
applies the narrow source ACLs, installs a root-owned runner
LaunchDaemon and constrained local launcher, bootstraps the headless per-user
Apple-container service, and executes the isolation probes. No organization or
host mutation occurs before that explicit handoff.

The handoff is resumable across GitHub API failures. Fresh local state combines
only with an empty runner group and selects provisioning. An exact pre-artifact
state created before the runner, host contract, launcher, or service exists also
combines only with an empty runner group and resumes provisioning. The source
boundary never follows symbolic links, and its inheritable entry means objects
created later retain the read-only contract without any traversal.
An extracted runner whose organization registration failed before `.runner`
and `.credentials` exist is also resumable: provisioning recreates only that
unregistered staging tree from the pinned archive, preserves the source
boundary, and registers against the organization URL and runner group.
Registration and local finalization are separate checkpoints. A runner with the
exact `.runner` and credential contract but no host contract, launcher, or
service resumes finalization without requesting another token or registering a
second runner. Finalization explicitly materializes `_work` before assigning its
ownership, normalizes only its exact derived per-user LaunchAgent target before
the builder renders the complete plist in temporary storage and installs it in
one operation. Exact matching derived service files remain in place; a partial
derived file is normalized and replaced only within the dedicated builder
service paths. Finalization then installs and verifies the local service
boundary.
Complete local state combines only with the exact configured runner and selects
full re-verification without requesting another registration token or replacing
any host state. Every other partial account/service pair, unexpected runner,
multiple runners, or mismatch between local and GitHub state stops for explicit
recovery.

`collider provision macos-builder retire` returns a provisioned host to the
pre-artifact state handoff resumes from. It refuses while the runner is
executing a job, removes the LaunchDaemon, machine-wide builder state, and both
installed launchers through the root boundary, then deletes the organization
runner registration. It derives the installed machine root from the installed
service rather than from the contract, so a host provisioned under an earlier
root is retired completely. Recursive removal requires both that the root lives
under the system Library and that it holds nothing but the two subtrees this
provisioning creates; anything else stops retirement. The builder account, its
source ACLs, per-user Collider storage, and Apple-container service are
preserved, so re-provisioning never rebuilds the persistent cache.

Collider launcher builds, fingerprints, SwiftPM configuration, resolution
caches, security state, and scratch outputs now live under the invoking user's
conventional Library roots. Local account-switched invocations enable effective
source revalidation; a changed or unreadable effective tree finishes the
durable run as `superseded` and returns failure. The launcher accepts only the
canonical checkout and the declared build, test, or package/configuration
pairs.

Runnable gate evidence: the root-owned checkout shim resolves and executes the
externally built Collider, all provisioning scripts pass shell syntax and diff
validation, and handoff execution reaches GitHub reconciliation only after the
complete local preflight. Collider run `2026-08-18T04-01-58.146Z-36794`
passed all four Collider test tasks, including the exhaustive local,
runner-group, and handoff-action transition tables, the machine-root removal
guard, credential-scrubbing, superseded-run, per-user service,
machine-wide-root, and host-release-selection contracts. Run
`2026-08-18T04-03-29.607Z-40483` passed every `ci-macos-builder` prerequisite
on the current host, and run
`2026-08-18T02-12-07.739Z-42176` verified the pinned runner archive against the
contract through `collider provision macos-builder prepare`. Handoff has since
provisioned, finalized, and registered the runner, and an admitted `main`
revision reached it and exercised checkout on the builder.

Gate: account and filesystem probes prove that the builder lacks admin, Secure
Token, sudo, remote-login, GUI, TCC, Keychain, signing, publication, and
personal-home access; it can read but not mutate the Nucleus development
checkout and cannot traverse unrelated interactive state; automated and local
invocations report `nucleus-builder` as their effective user and the same
Apple-container application root; a dirty-tree build observes every declared
working-copy change; source mutation supersedes the run; and unsupported remote
revisions fail before account switching or checkout.

Handoff: the interactive owner grants the existing `gh` login the `admin:org`
scope and runs `collider provision macos-builder handoff`. Phase 3 becomes
complete only after that command's local and GitHub verification gates pass.

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
- local native-builder construction, including the pinned, offline
  SwiftPM/SwiftBuild overlay build;
- complete repository build and test lanes for every supported target
  architecture;
- Swift SDK, native SDK, Android, Chromium, CEF, compositor, shell, and browser
  artifact construction selected by the ordinary build graph;
- artifact linkage, dependency-closure, ABI, packaging, and consumer
  validation;
- publication of every transferable product through
  `LocalProductArtifactStore`, followed by qualification from a source-free,
  cache-free store view rather than a producer workspace or loose envelope;
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
protected-`main` graph can request release qualification; every qualifier
resolves its exact immutable input from the local product store without source
or producer-cache access; no build path publishes externally or signs; and
delivery performs no compilation or package assembly.

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
