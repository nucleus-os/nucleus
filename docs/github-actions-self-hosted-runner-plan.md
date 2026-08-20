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
runner group, builder account, and registered runner are provisioned, and
protected-main verification runs green on the M2 Ultra for both a `main` push
and an exact-revision manual dispatch.

That builder account holds no materialized dependency graph. Verification
currently establishes provenance rather than building products, so the retained
cache, staged SDKs, images, and persistent workspaces still live in the
interactive account. Phase 4 moves them, and the Phase 3 gate items that
require an executed build wait on that move.

Collider already represents runner, execution, and artifact platforms
independently. It owns typed Apple-container lifecycle, offline OCI execution,
durable runs, content-derived task identity, persistent build workspaces,
cancellation, logs, and cleanup. Its execution lease serializes task-graph
execution across every account on this host, through one root-installed inode no
account can replace, while retaining internal task and architecture concurrency.

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

Collider's retained state is currently per-user, and its largest component is
the set of Apple-container persistent volumes beneath the current user's
Developer root. That placement is incidental rather than required: the container
service accepts an explicit application root, so one machine-owned store serves
every account. One trusted builder identity executes all build code, and Phase 4
separates that identity from the location of the state it produces.

Persistent workspace names are currently scoped by a digest of the absolute
checkout root, and each volume also records that digest in its label and an
absolute source path in its metadata. A builder-owned CI checkout and the
authoritative development checkout therefore select different volumes even when
the builder identity and source contents match. Phase 4 removes that
workspace-owner identity rather than replacing it.

The existing retained M2 Ultra state belongs to the interactive account and is
roughly nine-tenths live data, so it is migrated rather than rebuilt. The
machine-owned build store, allocation reporting, workspace reclamation, the
interactive account's password-free path to the root launcher, and the complete
`main` workflow do not yet exist.

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
  interactive development, and can authorize builds and delivery operations
  through one sudoers entry admitting only the root build launcher, which grants
  no shell and no other privileged path;
- `nucleus-builder` owns the clean `main` checkout, GitHub Actions runner,
  Apple-container service, and every write to the machine-owned build store
  holding the shared cache, persistent workspaces, staged build artifacts, and
  run records, and receives read-only access to the Nucleus development checkout
  for an explicitly initiated local build;
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

Status: complete

One protected verification workflow loads only from `main`. Its normal trigger
is a push to `refs/heads/main` and its manual trigger accepts only an exact
commit already reachable from protected `main`. No workflow subscribes to
`pull_request`, `pull_request_target`, non-`main` pushes, issue comments,
labels, or fork events. The admission job executes no checkout or
repository-controlled code and rejects foreign repositories, non-main workflow
refs, unsupported events, mutable revisions, branch-only commits, and
pull-request merge commits before its API request. It passes an immutable
revision and the product-provenance contract to a fixed runner group and label:

```text
NUCLEUS_PRODUCT_SOURCE_AUTHORITY=protected-main
NUCLEUS_PRODUCT_SOURCE_COMMIT=<verified full revision>
NUCLEUS_PRODUCT_SOURCE_REF=refs/heads/main
NUCLEUS_PRODUCT_PRODUCER_TRUST_DOMAIN=nucleus-builder
```

Collider requires a full lowercase commit, `refs/heads/main`, the
`protected-main` authority, and the `nucleus-builder` producer trust domain. It
rechecks `HEAD`, records the protected branch even when the revision is checked
out detached, rejects tracked or untracked dirtiness anywhere in the checkout
even when a product declares a narrower source closure, and refuses release
qualification without both protected-main provenance and nucleus-builder
production. A local invocation supplies none of these assertions and is recorded
with `local-development` authority and the `local-developer` producer trust
domain. The source-tree digest is independent of both provenance forms, so equal
source bytes reuse build work without making a local product releasable.

Automated checkout fetches complete history and tags, including submodules,
because dependency mirroring resolves version requirements against the
first-party submodules and each must carry the tag it resolves to. Shallowing
this checkout fails at resolution rather than at provenance.

Gate evidence: a `main` push and an exact-`main` manual invocation both reached
the M2 Ultra and passed provenance verification, with the recorded source
revision equal to the commit the event selected. The negative half holds by
construction and is verified live: the repository contains one workflow, whose
only triggers are `push` to `main` and exact-revision `workflow_dispatch`, so no
pull-request, fork, or branch-push context can start it; the runner group
reports `visibility: selected`, `restricted_to_workflows: true`, a single
selected workflow of `ci.yml@refs/heads/main`, and a single allowed repository;
and every run recorded against the repository is a `main` push or manual
dispatch. Local probes rejected foreign-repository, mutable-revision, and
non-main-ref forms before any API request. A live branch or pull-request probe
would exercise GitHub's trigger evaluation rather than a Nucleus contract, so
none is required.


## Phase 3: Provision One Trusted Builder Identity

Status: complete

A hidden standard macOS account named `nucleus-builder` owns automated and
locally initiated execution on the M2 Ultra. It is not an administrator and has
no Secure Token, FileVault unlock authority, sudo path, remote-login
membership, interactive GUI use, iCloud account, personal Keychain item,
personal TCC grant, developer signing identity, or publication credential. The
interactive account installs or runs no Actions service.

The source boundary is an allow list, and the interactive home's mode is what
makes it one. macOS makes every local account a member of `staff` through a
well-known group GUID, so a private home cannot be expressed through group
membership: at the macOS default of 0750 the builder reads the entire home
through `staff`. Both traverse gates are mode 0700, leaving exactly two
`search` entries as the way in. `search` is execute-only, so neither the home
nor its source directory can be listed, and the checkout is read through its
ordinary other-readable mode. The builder holds a dedicated primary group,
which is what objects it creates are grouped by, but membership of `staff` is
not refusable on macOS and provisioning does not pretend otherwise.

Mode removes enumeration, not reachability: a traverse grant reaches any child
by name, so each sibling of the checkout carries an explicit deny, bounded at
one entry per top-level entry and reasserted every run. A sibling created
between two provisionings is reachable by name until the next run, and closing
that residual structurally means giving the checkout a parent directory that
contains nothing else.

No recursive pass over the working tree exists. A blanket per-file grant would
have to override every mode the developer deliberately restricted, which is how
owner-only local signing keys inside the checkout became builder-readable under
an earlier model. Generated Android signing and tooling state has since moved
to declared account-local storage, so the builder needs nothing from the
interactive checkout that is not source. Ownership denies the builder every
write, so the only explicit write entries are one inheritable deny on the
checkout root and a bounded scan closing world-writable objects package
managers leave behind. The boundary is a fixed handful of entries rather than
one per file, and it neither weakens with time nor grows with the tree.

The machine-wide runner and host-contract roots are absolute, whitespace-free,
and named once by the host contract. The Actions runner formats a `run:` step
into one command string that the process launcher resplits, so whitespace in
these roots reaches `bash` as separate arguments and every `run:` step fails
before its body executes. The work root carries the same requirement, because
step scripts are written to its `_temp`. `/Library/Application Support` is
therefore unusable for this role. The roots are
`/Library/Nucleus/GitHubActionsRunner` and `/Library/Nucleus/Builder`, and both
share one machine-wide parent so retirement removes installed state as a single
directory. The job checkout lives in builder-owned per-user storage outside
that parent, so retiring or upgrading the runner preserves a multi-gigabyte
recursive submodule checkout instead of forcing a full re-clone.

The host contract pins the Actions runner version, its exact arm64 archive size
and SHA-256, the runner group, label, name, service identity, account, group,
home, organization, repository, authoritative checkout, and machine roots. It
selects the macOS and Xcode major releases rather than exact beta builds,
because those build identifiers move under the host without changing what
Nucleus compiles against; the selected developer directory, the Swift compiler
it provides, and its testing macro plugin remain exact.

Provisioning that needs no privilege belongs to Collider. `collider provision
macos-builder prepare` acquires and verifies the pinned runner archive.
`commission` reconciles the workflow-restricted runner group, obtains a
short-lived registration token, invokes one root provisioning boundary, and
verifies the resulting registration, after verifying the canonical checkout,
executing user, complete archive, provisioning executables, and local account
and service state. It is named for the state it establishes rather than for the
privilege transfer inside it, and it converges rather than transferring once.
`retire` returns a provisioned host to the pre-artifact state commission resumes
from, deriving the installed machine root from the installed service rather
than from the contract so a host provisioned under an earlier root is retired
completely; recursive removal requires both a system Library location and a
root holding nothing but the two subtrees this provisioning creates.

The language boundary sits on the privilege boundary. Collider decides and
reconciles; every privileged mutation stays in a root-owned script it invokes
through `sudo`, because Collider rebuilds itself from the working tree when its
source fingerprint changes and must never do that as root. No control-plane
response reaches the logging runtime: the registration token is read straight
into memory and travels to the privileged boundary on standard input only,
never through argv, the environment, or the durable run log.

Commission is resumable across GitHub API failures. Fresh, pre-artifact,
unregistered, and registered local states each combine with exactly one
runner-group state and select provisioning or finalization without requesting
another token or replacing host state. A completed host finalizes again rather
than only verifying, because finalization converges on the host contract and
ends in verification, so machine state the contract later declares is installed
by re-running the commission. Every other partial pair, unexpected runner,
multiple runners, or mismatch between local and GitHub state stops for explicit
recovery. The probe deciding whether provisioning may
resume tests the builder home's owner and mode but not its group, because
provisioning is what assigns the group.

Support two manual paths through the same identity. GitHub manual dispatch uses
the protected workflow and clean builder checkout. A local invocation is
`collider` itself, which re-runs as the builder through a root-owned,
synchronous account-switching launcher accepting the canonical
authoritative-checkout path, typed Collider command words, and options from a
closed list. It grants no arbitrary shell and is not a daemon, worker protocol,
source copy, or remote-execution service. Launcher,
SwiftPM, package-resolution, generated-configuration, and host-acquisition
writes live in builder-owned declared storage rather than the source checkout,
and the effective source identity is revalidated before local outputs are
accepted.

Gate evidence: account and filesystem probes prove the builder lacks admin,
Secure Token, sudo, remote-login, GUI, TCC, Keychain, signing, publication, and
personal-home access; that it can read but not mutate the development checkout,
cannot list either traverse gate, and cannot reach unrelated interactive state;
and that the runner installation is root-owned with a builder-owned work root
outside it. Commission provisioned, finalized, registered, and verified the
runner, and protected-main verification then ran green on it end to end.

The gate items requiring an executed build move to Phase 4: effective-user and
Apple-container parity between automated and local invocations, a dirty-tree
build observing every declared working-copy change, and source mutation
superseding a run. The builder account's Collider storage is empty until Phase 4
performs its cutover, so exercising those against it would measure a
from-scratch materialization of the entire native dependency graph rather than
the contracts they state.


## Phase 4: Establish One Machine-Owned Build Store

Status: active

Execution identity and state location are independent concerns.
`nucleus-builder` is the only identity that executes build code, because build
code is native code and must not run where it can read personal data. Where the
state that execution produces lives is a separate question, and answering it
with an account home is what bakes a home-derived identity into every persistent
workspace name, splits the Apple-container service across two accounts, and
leaves the developer unable to read the records of builds initiated from the
authoritative checkout. Collider's retained build state is therefore
machine-owned, and no part of it lives in any account home.

`/Library/Nucleus/Collider` holds that state: the Apple-container application
root and its persistent volumes, downloads, SDKs, package and repository inputs,
compiler caches, build intermediates, task state, staged artifacts, the product
store, and run records. It is owned `nucleus-builder:nucleus-build-state`, mode
2750 with the setgid bit, so the builder writes it and the group reads it.
Local-development signing material is a builder-only subtree at mode 0700 inside
that store: the identity that executes is the identity that signs, and no other
account can read its private keys.

Commissioning provisions the store: the reading group, the four roots with the
setgid bit that keeps every object the builder creates in the group the
developer reads, the log root the developer also writes, the signing subtree
only the builder reads, and the developer's password-free path to the launcher.

Two groups keep those facts separate. `nucleus-builder` remains the builder's
primary group and gates the runner registration credentials.
`nucleus-build-state` grants the interactive developer read access to run
records, logs, and finished artifacts without privilege, and nothing else. The
developer never writes the store, because the developer never executes build
code.

One Apple-container application root serves the host. `container system start`
takes an explicit application root, so the builder's service owns the store's
container root and the interactive account runs no container service at all.

The storage substrate does not change. Case-sensitive Linux workloads stay
inside sparse ext4 images on the default Data volume, reached as block devices.
Measured against a host directory shared into the guest, a block volume creates
ten thousand small files twelve times faster, sweeps their metadata ten to
twenty-five times faster, and deletes them twenty-four times faster, while bulk
sequential throughput is identical. Build work is metadata work, so a shared
host filesystem is not viable at the scale this repository builds, and no host
path is substituted for a persistent workspace.

Persistent workspaces remain one volume per component, target, and role. Two
containers cannot mount one ext4 block device read-write without corrupting it,
so a coarser volume would force independent component lanes to serialize on a
shared lock and would trade the machine's parallelism for nothing.

Volume capacity is not the control surface. An unclaimed ceiling on a sparse
image costs nothing, so the sum of declared capacities is not a budget and is
not managed as one. The control surface is the store's actual allocation against
the physical disk, which Collider does not currently report: most declared roots
answer that their allocation is not measured. Every storage root reports its
real allocation, a volume through one stat of its image and a host root through
its own accounting, so growth is observable long before it is a surprise.

Freed guest blocks return to the host. The runtime mounts an ext4 volume with no
discard option, so a workspace retains every block it has ever written even
after the files are gone. The block device supports discard and trimming a
volume returns its free space exactly, so reclamation is a declared operation
over persistent workspaces. It runs in a minimal maintenance container that
mounts one volume, trims it, and exits, carrying the single capability the
operation requires and no build input, build code, or network. No build
container carries that capability.

The interactive account's retained state was migrated into the store rather than
rebuilt, because the volume set was roughly nine-tenths live data whose
reconstruction cost is the complete native dependency graph. That migration was
a one-way pass over state that no longer exists in its previous shape, so it is
deleted rather than maintained. It moved each root by rename on one filesystem,
renamed every volume, rewrote each volume's recorded name, label, and source
path, and repointed every absolute symlink addressing a migrated root, the
container's default kernel and the staged native SDK include trees among them.

Persistent workspaces are owned by the build store rather than by a checkout.
The owner a volume name and label carry is derived from the store, so the clean
CI checkout and the authoritative development checkout resolve to one value and
select the same volume; without a store a checkout owns its own workspaces,
because nothing is shared. The owner stays a digest rather than being dropped:
volume names carry it, and two Collider domains sharing one container
application root — production and an integration test among them — would
otherwise collide on name alone while their labels disagreed. Dropping it would
also have been the larger change, because every existing volume must be renamed
either way.

Architecture residency is declared rather than incidental. Nearly every source
tree, output tree, and compiler cache exists once per supported architecture,
which is the largest single multiplier on the store's size. Each target's
retention states whether its state stays continuously resident or is
materialized on demand, so residency is a recorded decision rather than a
consequence of whatever was built last.

The interactive developer initiates a local build by running `collider`. One
store admits one writer, so a command that executes a task graph must run as the
builder; which commands those are is Collider's own knowledge, and it re-runs
itself as that identity rather than refusing and naming a second command for a
person to retype. The switch is announced on standard error every time, because
an identity change the operator cannot observe is worse than one they perform.
Inspection and dry runs do not cross, and stay in the developer's account.

The crossing goes through one root launcher reached without a password: one
sudoers entry admits exactly `/usr/local/bin/nucleus-builder-run` for that
account. What crosses is typed rather than passed through. The launcher accepts
the canonical authoritative checkout, command words matching a pattern that
cannot express a path, an option, or a shell metacharacter, and options from a
closed list each carrying its own value pattern; it grants no shell. That is
what keeps a password-free grant from becoming a way to run something else as
another identity, and it covers the command tree without the launcher becoming a
second command surface that has to grow whenever Collider does. An option
outside the list refuses rather than being dropped, because a build that
silently ignored `--rebuild` would answer a question nobody asked. The identity
it runs code as has no sudo, no keys, and no access to the interactive home, so
the entry lowers privilege rather than raising it.

Every supported run reuses this state. Exact source, submodule, toolchain,
configuration, platform, and semantic input identities decide whether an action
is current. The checkout path, invocation source, GitHub run identifier, and
choice between automated and manual initiation do not create different cache
identities. A changed semantic input invalidates only its affected action
closure.

Store debug and release state in the same machine store with explicit
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
the store as routine pipeline setup or teardown.

The machine-wide execution lease is in place ahead of the store. Provisioning
installs one root-owned lock file inside a root-owned directory, so the
interactive account and `nucleus-builder` lock the same inode, neither can
replace it, and neither reads the other's storage to find it. Automated builds,
manual shared-cache builds, ordinary developer builds, cache maintenance, and
Apple-container mutation acquire it; dry-runs and inspection do not. One task
graph uses the M2 Ultra at a time while the admitted graph retains its internal
component and architecture concurrency. A blocked invocation renders the account
and run holding the lease, so a build waiting behind the other account is
distinguishable from a stalled command.

No build writes the checkout it reads. Generated sources were the last
construct that did: generation wrote its result beside the sources, so the
build that produced them could not run as an identity holding the checkout
read-only. Generation now writes the build store, a verification task in each
owning component's test lane proves the committed copy still matches, and
`collider adopt <component>` is the one supported way the store's output enters
the checkout. Generation and adoption run as different identities by
construction, because the builder may not write the checkout and the developer
may not write the store. Gradle's Android outputs and project cache moved out of
the checkout the same way, leaving the tree writable only by the account that
owns it.

Placement roots are declared so that where the host keeps things cannot reach
an identity, and the checkout is such a root: the CI checkout and the
authoritative checkout hold identical source at different paths, and an
identity that records which one it was compiled from shares nothing with the
other. SwiftPM task identities, host scratch directories, and container build
workspaces resolve through the declared roots, and a symbolic link's target
resolves as the path it is rather than as an opaque string.

Compiled output must not record where its sources were either, or two builds of
one source are not interchangeable however equal their identities claim to be.
Every Swift and Clang compilation maps the declared roots out of the paths it
records, using the same roots identity resolves through so that the two cannot
disagree about what counts as placement. A representative object went from 139
recorded checkout paths to 17.

What survives is one record of each translation unit's own path, and it
survives because the build system passes source files absolutely: compiling the
same file by a relative path records nothing, and by an absolute path records it
once, which is exactly what a compiled object here contains. No mapping flag
reaches it. A file carrying test declarations repeats it once more per
declaration, because that macro expands the path into an ordinary string
literal before the compiler could recognize it as a path.

Two builds of one source are therefore functionally interchangeable but not
byte-identical, and the difference is a provenance record naming a checkout that
exists on the same host. Both mechanisms are interim: rewriting a path out of an
identity and mapping one out of debug information correct a leak that execution
creates upstream, which is why they cannot reach that last record. The
[placement-independent build plan](placement-independent-build-plan.md) removes
the leak instead, by giving every build tool one canonical path and no host
path, and deletes both corrections rather than maintaining them. Container mount
targets keep repeating the host path until it does, because canonicalizing that
identity is what asserts an interchangeability the artifacts do not yet have.

This phase carries the Phase 3 gate items that require an executed build,
because no build has yet executed against the machine store.

The first automated build lane is deliberately bounded to the ordinary
`collider build all` catalog entrypoint. Its first watched run is also the
second-checkout experiment in the placement-independent build plan: the CI
checkout must consume the state warmed from the authoritative checkout rather
than compiling it again. The executed-versus-cached task count is the gate.
Tests, packaging, qualification, and delivery join the workflow only after that
measurement passes.

The clean checkout resolves every URL-based forked SwiftPM dependency from its
public immutable revision, which equals its gitlink commit. Checkout-local
submodule repositories are not package remotes: Actions guarantees the gitlink
tree, not the complete repository state Git serving requires. No dependency
resolution requires a mutable branch ref or state retained by an earlier runner
job. The only SwiftPM mirror rule is checkout-independent and checked in at each
package root, so the launcher does not generate or repair configuration on a CI
run.

Verify the store's ownership, mode, and group access from both accounts before
any state enters it, and verify the builder reads every migrated volume and
artifact root before the interactive copies are released. The store is
unreadable to the interactive account, so a permission fault found afterwards is
diagnosed without access to the state it concerns.

Gate: an automated build followed by a local build of identical effective source
and configuration, and the reverse ordering, reuse the same action outputs,
SDKs, images, compiler caches, and persistent workspaces; automated and local
invocations report `nucleus-builder` as their effective user and the same
Apple-container application root; the interactive account runs no container
service, reads run records and artifacts, and writes nothing in the store; every
storage root reports its actual allocation and the store's total is observable
against the physical disk; trimming a workspace returns its free space to the
host while no build container carries the trim capability; every migrated volume
matches its declaration and the previous location holds no retained state; a
dirty-tree build observes every declared working-copy change and source mutation
during execution supersedes the run; every component that commits generated
sources verifies them without writing the checkout, and adoption is the only
path that updates the committed copy; a dirty build followed by committing the
identical tree does not compile identical source again; debug and release
coexist without collisions or mutual cleaning; neither ordering performs a clean
rebuild; a semantic source or configuration change invalidates only the expected
closure; concurrent invocations serialize; a local build starts without a
password prompt while a direct interactive-account build refuses; and deleting
runner work directories leaves the retained build state intact.

## Phase 5: Enforce Account, Credential, Network, and Recovery Boundaries

Keep all build and qualification credentials read-only and job-scoped. The
builder cannot read personal homes, attach to personal agents, hold a release
signing or code-signing identity, reach publisher credentials, or deploy
infrastructure. The local-development signing material it owns signs
development images only and confers no publication authority. Host-side
acquisition reaches only the public origins required by the pinned source and
dependency graph. Apple containers retain the host-only network with DNS
disabled and receive only already acquired inputs.

Treat every builder cache, workspace, image, checkout, staged artifact, and run
record as reconstructible project state. Never place a personal secret,
publication credential, release signing key, browser profile, private unrelated
source, or authoritative document in the build store, the builder account, or
their backups.

On ordinary failure or cancellation, Collider finalizes the run, terminates its
containers, and preserves valid incremental state. On suspected compromise,
unexpected persistence, account-boundary failure, or cache-integrity failure,
quarantine `nucleus-builder`; prevent CI, manual trusted builds, signing, and
publication; preserve diagnostics; then recreate its checkout, the machine-owned
build store, runner, service, and caches from declared inputs. If a kernel,
firmware, hypervisor, or privileged host-service escape is suspected, recover
the entire M2 Ultra before restoring personal or release authority.

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
