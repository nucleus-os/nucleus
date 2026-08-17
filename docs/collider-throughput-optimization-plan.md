# Collider throughput optimization plan

Status: complete.

## Invariant

Collider makes expensive work concurrent only when its inputs and writable
state are independent. Performance work never weakens source validation,
content-addressed product identity, offline container execution, bounded output
ownership, package qualification, or product-store reachability. Unchanged
invocations reuse all valid build and package state.

## Current Evidence

Run `2026-08-16T17-27-41.466Z-39675` is the corrected full native package
baseline. The arm64 and x86_64 package-cohort actions took 357.380 and 400.960
seconds respectively. Both actions claimed the same writable product-store root
and publication lock, so the scheduler correctly serialized them even though
their expensive archive assembly is architecture-local. Each action also
claimed 24 CPUs, which prevents safe overlap on the M2 Ultra without first
right-sizing the lanes.

Run `2026-08-16T17-45-01.664Z-43818` is the unchanged package baseline. All
expensive package cohorts and qualifications remained clean. Executed work was
9.298 seconds in `core.sources`, 1.936 seconds in `browser.depot-tools`, 1.839
seconds in package retention, and negligible Swift SDK discovery. The run spent
9.323 seconds executing and 12.396 seconds planning. `core.sources` currently
performs a forced detached checkout and redundant Git queries for every Skia
external even when its commit, remote, and tracked state already match.

Run `2026-08-16T17-25-16.574Z-36193` is the Collider test baseline. The CLI
package test action took 105.591 seconds. Several tests independently construct
the complete production component catalog; the longest single test spent
78.845 seconds doing so while the test process was also running other catalog
construction tests.

Run `2026-08-16T19-38-50.660Z-92080` is the stage-instrumented native package
baseline. The arm64 action took 348.957 seconds, of which the declared stages
accounted for 343.957 seconds. The x86_64 action took 370.571 seconds, of which
the declared stages accounted for 365.527 seconds. RPM assembly dominated at
243.489 and 261.946 seconds, payload materialization took 54.130 and 54.779
seconds, and product-store publication took 10.507 and 10.836 seconds. The
family views materialized 2.461 GB for arm64 and 2.677 GB for x86_64 from
roughly 820 MB and 893 MB of logical package payload per family. Validation,
envelope construction, and generation publication are not critical paths.

Run `2026-08-16T20-39-31.103Z-19529` is the concurrent-assembly package gate.
Arm64 and x86_64 package assembly started 95 milliseconds apart and overlapped
for 354.581 seconds. Arm64 completed in 354.659 seconds while x86_64 completed
in 389.978 seconds; serial execution of those same actions would have consumed
744.637 seconds. Arm64 store publication took 4.166 seconds and ran while
x86_64 assembly remained active. X86_64 store publication took 4.325 seconds.
Each publication emitted a receipt for 18 validated products, and both
architecture lifecycle qualifications passed. RPM assembly still dominates at
252.139 and 273.570 seconds.

Run `2026-08-16T21-24-00.573Z-52797` is the narrowed-closure Collider test
gate. All CLI and engine tests passed in 85.8 seconds. The workspace test
process completed its 96 tests in 23.7 seconds. SwiftPM dependency inspection
shows that `NucleusLinuxAssembler` and `NucleusLinuxPackageQualifier` each
depend only on `LinuxPackageContracts` plus engine products, while
`LinuxPackageContracts` has no recipe-target dependencies.

Run `2026-08-16T21-58-39.169Z-81635` is the per-package RPM evidence gate.
Hard-linked RPM source-view construction took only 0.36 seconds for the 633 MB
arm64 browser payload and 0.33 seconds for the 705 MB x86_64 payload. The
browser `rpmbuild` subprocess instead took 182.98 and 210.45 seconds; runtime
`rpmbuild` took 48.08 and 49.43 seconds. Archive publication and cleanup were
negligible. Explicit RPM zstd level 7 in run
`2026-08-16T22-11-07.785Z-85102` reduced aggregate RPM assembly from 232.07 and
260.80 seconds to 19.02 and 20.83 seconds. Complete cohort time fell from
335.75 and 376.57 seconds to 124.67 and 137.60 seconds while both lifecycle
qualifications passed. RPM browser and runtime archives grew by approximately
21–23 percent; the measured throughput trade is intentional.

Run `2026-08-16T23-58-06.658Z-43964` is the per-package graph gate. Five
content-addressed payload tasks and fifteen independently cached family adapter
tasks completed for each architecture, followed by lightweight cohort actions
of 18.44 seconds for arm64 and 19.45 seconds for x86_64. Canonical payload
materialization totaled 17.34 and 18.95 seconds instead of rebuilding the same
logical payload for each family. APFS copy-on-write family views represented
6.18 GB of logical input across all 30 adapters but took 0.741 seconds total;
the slowest view took 0.123 seconds. The arm64 Debian browser adapter remained
active while all five arm64 RPM adapters executed, proving that disjoint family
adapters overlap within the two-container OCI lane. Browser `rpmbuild` took
13.35 and 16.00 seconds, and runtime `rpmbuild` took 5.79 and 4.40 seconds. Both
architecture lifecycle qualifications passed. Debian browser assembly is now
the dominant archive stage at 98.31 and 120.13 seconds; Debian runtime assembly
took 26.30 and 27.35 seconds. The 18 control-only session,
development-host, and complete adapter tasks used 44.14 seconds of summed task
time even though each archive assembly took less than 0.2 seconds; container
bootstrap and teardown dominate those tasks.

Run `2026-08-17T01-48-28.948Z-19896` is the Linux packaging-tool gate. The
packaging-tool SwiftPM action completed in 271.91 seconds from a clean tool
context, including 269.76 seconds in the build command and 2.12 seconds in
product publication. The preceding warm LLD run completed in 234.72 seconds,
versus the 262.43-second pre-Phase-8 action. The final assembler is linked by
LLD 21, has no DWARF classification, and fell from 25 MiB to 9.2 MiB. An
instrumentation experiment that issued separate target and product commands
took 1,144.99 seconds because SwiftBuild repeated dependency planning for all
six commands; the retained implementation keeps one planning pass.

## Phase 1: Establish the Measured Critical Paths

Status: complete.

The full-build, unchanged-build, task-graph, package-stage, store-retention, and
test-suite paths have been audited. The dominant structural costs are the
package actions' shared writable store, repeated payload copies and compression,
unconditional Skia external mutation, repeated complete catalog construction in
tests, and the broad SwiftPM target closure of the Linux assembler.

Gate satisfied: the three successful baseline runs above identify task-level
costs without a cache wipe, synthetic workload, or relaxed validation.

## Phase 2: Record Native Package Stage Costs

Status: complete.

Record package payload materialization, Debian assembly and validation, RPM
assembly and validation, Arch assembly and validation, product-envelope
construction, product-store publication, and final generation publication as
separate run observations. Include input and output byte counts. Timing data
belongs only to run records and never enters task identity, package bytes,
product envelopes, or generation digests.

Gate: a rebuilt arm64 and x86_64 package cohort exposes every declared stage in
the run record, and repeated assembly still produces the same deterministic
package and product identities.

Gate satisfied: run `2026-08-16T19-38-50.660Z-92080` rebuilt and qualified both
architecture cohorts. Each cohort persisted all ten declared observations with
duration, input bytes, and output bytes. A same-input assembly audit isolated
the only differing bytes to RPM's wall-clock header build time while confirming
identical RPM payload bytes; RPM assembly now uses fixed nonzero source epoch
`1`, because RPM treats epoch `0` as absent. Observation values remain confined
to run manifests and do not participate in task, archive, envelope, product, or
generation identity.

## Phase 3: Unlock Concurrent Architecture Assembly

Status: complete.

Make each architecture package action write only its immutable package
generation, product envelopes, and the small payloads required by those
envelopes. Remove the product-store mount, product-store effect, shared
product-store lock, and source-snapshot publication lock from expensive OCI
assembly.

Add a lightweight host publication action per architecture. It consumes the
completed immutable generation, revalidates every archive, payload, envelope,
and provenance binding, publishes them into the single architecture-neutral
`LocalProductArtifactStore`, and emits a receipt. Only these small publication
actions serialize on the product store. Lifecycle qualification consumes the
receipt and reads the immutable store without a publication lock. Retention
continues after both architecture qualifications.

Run the two architecture assembly actions together with 12-CPU OCI limits so
their combined declared budget fits the M2 Ultra. Preserve distinct package
roots and all existing artifact targets.

Gate satisfied: run `2026-08-16T20-39-31.103Z-19529` executed the two 12-CPU
architecture package actions concurrently, with disjoint package publication
locks and no product-store mount. Separate host actions revalidated and
published each 18-product cohort, recorded only the
`product-store-publication` stage, and emitted generation-bound receipts before
lifecycle qualification. The Collider graph and envelope validation tests cover
store independence, receipt ordering, substituted payload rejection, and
shared-store serialization.

## Phase 4: Narrow Collider Rebuild and Test Closures

Status: complete.

The Linux package schema, browser package-input validation, distribution
manifest schema, archive assembly and validation, lifecycle report, and
stage-observation contract live in `LinuxPackageContracts`. Package assembly
and qualification helpers consume only that target plus engine products. A
separate runtime-publication executable owns the Shell runtime action, so the
package assembler no longer imports Chromium or Shell recipes. Graph task
naming is supplied explicitly as provenance rather than derived inside the
contract target.

Collider workspace tests now share one mutex-protected immutable catalog for
the repository-root, empty-environment, no-host-augmentation fixture. Tests for
relocation, environment overrides, and host augmentation retain explicit
catalogs. Run `2026-08-16T21-05-06.992Z-39152` passed the complete Collider
suite in 84.5 seconds; the workspace test process fell from 74.7 seconds in the
Phase 3 handoff run to 24.7 seconds, and its formerly 74.7-second catalog-heavy
test fell to 11.3 seconds.

The package source-provenance closure includes only the root package and
recursive filesystem dependencies. Source-control checkouts remain build
inputs but cannot enter the monorepo source snapshot merely because SwiftPM
places them beneath `.build`.

Gate satisfied: dependency inspection proves the narrowed helper closure. The
focused package targets have no unrelated recipe dependency, the source graph
keeps source-control dependencies out of provenance while retaining them as
build inputs, and run `2026-08-16T21-24-00.573Z-52797` passed the complete
Collider suite. The shared immutable workspace catalog fixture performs one
load for the repository-root empty-environment context; relocation,
environment, and augmentation tests retain explicit inputs.

## Phase 5: Add a Non-Mutating Skia Source Fast Path

Status: complete.

Keep `core.sources` always assessed so tracked modifications cannot hide behind
a stamp. For each Skia external, read the configured origin, current commit,
and tracked status first. Return immediately when all three match. Run those
independent read-only validations with bounded concurrency. Execute remote
repair, fetch, and detached checkout only for a checkout that is absent or does
not match, then perform the complete post-mutation validation.

Gate: the unchanged package graph does not run a checkout command for an exact
Skia external, tracked modifications still fail before mutation, missing
objects are acquired only by the host action, and the repaired checkout is
exactly the pinned commit and remote.

Gate satisfied: exact checkouts return after concurrent origin, commit,
dereferenced-pin, and tracked-status reads; behavior tests prove that the fast
path leaves the Git config and HEAD reflog byte-identical and that tracked
changes fail before remote repair. A non-exact external continues through the
repair path and complete post-mutation validation.

## Phase 6: Materialize Each Package Payload Once

Status: complete.

First retain the ten top-level package observations and add per-logical-package
child observations. Split RPM assembly into source-view construction, the
`rpmbuild` subprocess, archive publication, and cleanup. The child evidence
determines RPM task resource limits and any later compression change; validation
and compression are not weakened speculatively.

The evidence above proves that RPM source-view construction, archive
publication, and cleanup are not critical paths. RPM uses an explicit zstd
level 7 payload because `rpmbuild` dominated the measured interval and the
complete lifecycle gate passed with the resulting archives. Keep that setting
in every per-package RPM adapter.

Each architecture now owns one canonical payload task per logical package and
one adapter task per package and family. Payload tasks publish immutable
content-addressed trees. Each adapter creates an APFS copy-on-write view inside
its own bounded export, applies format metadata there, and publishes one
content-addressed archive. Cross-publication hard links are forbidden: Apple
Container bounded exports do not reliably open an inode whose origin lies
outside the export. RPM instead uses a symlinked source view inside the adapter
and keeps `__os_install_post` disabled so it cannot strip payload bytes. Every
RPM scratch root is removed before construction, so interrupted work cannot be
mistaken for a current source view.

Independent adapters use two CPUs and 8 GB each and overlap within the
two-container OCI lane. The architecture cohort action only validates adapter
publications, copies immutable archives into the generation, constructs
envelopes, and publishes the generation. Exact-cohort versioning deliberately
means that a browser or runtime digest change invalidates every family adapter:
all archives embed that cohort version. Content-addressed runtime and session
payload generations remain byte-identical when their own bytes do not change;
the graph never claims that a version-bearing archive is unrelated to another
cohort member.

Gate satisfied: run `2026-08-16T23-58-06.658Z-43964` materialized runtime and
browser payload bytes once per architecture, isolated format metadata in
adapter-owned views, overlapped independent Debian and RPM adapters, published
both architecture cohorts, and passed every native package lifecycle test.
Run `2026-08-16T23-47-28.022Z-36170` reused 21 already valid adapter
publications while completing the remaining work after a wrapper-only report
validation correction. Run `2026-08-17T00-10-52.408Z-47408` passed the complete
Collider suite with graph assertions for every payload and adapter task.

## Phase 7: Accelerate Debian Archive Compression

Status: complete.

Split Debian assembly into control-tree construction, the `dpkg-deb` subprocess,
archive publication, and cleanup observations. Record the exact compressor,
level, and thread count selected by the pinned builder's `dpkg-deb`. Replace the
implicit compressor with explicit zstd settings after the lifecycle gate proves
the builder and target package manager support them. Choose the fastest level
whose archive-size increase remains justified by the measured end-to-end
package and installation paths; do not optimize the already negligible APFS
family view.

Gate: the run record attributes Debian time to its substages and records their
logical input/output bytes. Both architecture lifecycle qualifications pass
with the explicit compressor, package metadata and installed payload bytes
match the current contract, and the plan records the measured time/size trade.

Gate satisfied: run `2026-08-17T00-21-19.477Z-57263` used explicit zstd level
7 with two threads and passed both architecture lifecycle qualifications.
Browser `dpkg-deb` fell from 98.31 and 120.13 seconds to 3.84 and 4.29 seconds;
runtime fell from 26.30 and 27.35 seconds to 1.23 and 1.20 seconds. Control-tree
construction, archive publication, and cleanup each remained below 5
milliseconds. Browser archives grew from 142.04/148.36 MB to 172.57/178.33 MB,
and runtime archives grew from 43.57/44.19 MB to 53.27/53.52 MB. The measured
20–22 percent size increase matches the accepted RPM throughput trade.

## Phase 8: Accelerate Linux Packaging Tool Builds

Status: complete.

The SwiftPM action records each requested target build, product build, broad
multi-product build, and product publication as a named action stage. The
instrumented target/product split proved that separate SwiftPM commands repeat
planning rather than expose cheap compile and link phases, so the retained
multi-product path performs one broad build command. Product selection remains
exact when only one product owner is dirty.

The pinned builder supplies LLD 21. Linux packaging tools pass
`-use-ld=lld` and SwiftPM's typed `-debug-info-format none` setting. Debug-info
format participates in build-context identity, so a no-DWARF product cannot
reuse a DWARF context. `LinuxPackageContracts` now contains only package and
observation contracts; the 2,400-line assembly implementation lives in
`LinuxPackageAssembly`. Graph tests prove the assembler closure contains that
implementation target while the runtime publisher closure does not.

Persistent SwiftPM intermediates remain task-identity scoped. The native
SwiftPM overlay and SwiftBuild regression workspaces retain only their newest
identity context before executing a command. The retention path validates the
workspace root and 64-character context name, removes only older generated
siblings, and leaves failure diagnostics in the external run log. This closes
the 49.4/50 GiB accumulation discovered during the gate without periodic broad
cache wipes.

Gate satisfied: run `2026-08-17T01-48-28.948Z-19896` passed both architecture
package lifecycle qualifications with the LLD/no-DWARF tools. The executable
contains the LLD 21 linker marker, is no longer classified as carrying debug
information, and is 63 percent smaller. The complete Collider suite passed,
the graph asserts the assembly/publisher closure boundary, and a behavior gate
proved that bounded workspace retention preserves the current context while
removing a stale sibling.

## Phase 9: Batch Control-Only Package Work

Status: complete.

Replace the separate session, development-host, and complete payload containers
with one architecture-local control-payload task that publishes three distinct
content-addressed payload outputs. Replace their nine family adapter containers
per architecture with one control-adapter task that publishes nine distinct
archive outputs. Keep runtime and browser tasks independent. This batching does
not broaden semantic invalidation: exact-cohort versioning already invalidates
all three control-only packages and all family metadata together.

Gate: the bundled task exposes separate observations and publications for every
logical package and family, substituting any one output fails validation, both
architecture lifecycle qualifications pass, and a rebuilt graph eliminates at
least sixteen control-only container executions. The run record compares saved
container bootstrap/cleanup time against any lost scheduling overlap.

The graph now owns session, development-host, and complete payloads through one
three-output control-payload task per architecture. One nine-output
control-adapter task per architecture owns their Debian, RPM, and Arch archives.
Runtime and browser retain independent payload and family-adapter tasks. Payload
publication metadata binds the logical package and active content generation;
adapter metadata binds the family and logical package. Every batched output
therefore retains an independent content-addressed publication and fails closed
when substituted.

Gate satisfied: run `2026-08-17T02-47-26.416Z-36896` passed both architecture
lifecycle qualifications and reduced control-only containers from 24 to four.
Summed bootstrap plus cleanup fell from 18.57 to 2.91 seconds, saving 15.66
seconds, while summed container process time fell from 44.33 to 35.71 seconds.
The control-only wall window fell from 51.24 to 18.93 seconds on arm64 and from
63.58 to 20.14 seconds on x86_64, so batching lost no observed scheduling
overlap. Graph tests assert the three and nine distinct output slots and the
20-container reduction; behavioral tests reject cross-package payload and
cross-family or cross-package adapter substitution. The complete Collider suite
passed in run `2026-08-17T02-45-09.982Z-32864`.

## Phase 10: Build Architecture-Neutral Packages Once

Status: complete.

Classify a logical package as architecture-neutral only when its canonical
payload, lifecycle metadata, dependency relationships, and every family archive
are byte-identical across arm64 and x86_64. A distribution architecture value of
`all`, `noarch`, or `any` does not establish that invariant.

The audit of qualified run `2026-08-17T02-47-26.416Z-36896` found no eligible
package. Runtime and browser contain architecture-bearing binaries. Session
contains `/opt/nucleus/current` with the architecture-specific runtime
generation target and has an exact-cohort runtime dependency. Development-host
and complete contain their architecture cohort version in the installed marker;
complete also carries exact-cohort runtime, session, and browser dependencies.
The arm64 and x86_64 payload generation digests therefore differ for all three
control-only packages. Their package manifests differ, and every Debian, RPM,
and Arch archive has a different SHA-256 digest.

Gate satisfied by retaining architecture-local ownership for every package. A
shared neutral task is deliberately absent because no payload and archive set
passes the required byte-equality proof. This preserves exact-cohort validation
and avoids introducing a cross-architecture prerequisite that would delay
otherwise independent packaging work.

## Phase 11: Optimize Host Product Publication

Status: complete.

The product store now looks up the exact product and provenance identities
before materializing any producer bytes. A hit revalidates the stored manifest,
payload, archive, provenance, and reconstructed envelope, returns the artifact
without writes, and records zero publication output bytes. A new provenance for
an existing product remains an explicit provenance-only publication.

Missing products clone every regular payload and archive file into private
macOS candidates, validate the complete candidate, and atomically promote its
directory. Archive blobs remain content-deduplicated, while each product archive
has an independent clone-on-write inode; product-store content is never
hard-linked to a mutable package generation or another product.

Gate satisfied: full Collider run `2026-08-17T03-31-23.704Z-43760` passed. The
reuse test mutates both producer payload and archive after the initial publish,
then proves the exact stored envelope remains valid and the complete store
filesystem snapshot is unchanged after republishing. Archive isolation tests
prove equal archives have distinct inodes. An injected interruption after full
candidate validation leaves the prior product valid and reachable, does not
publish the interrupted product, and removes its private product candidate.

## Phase 12: Close the Throughput Qualification

Status: complete.

Full Collider run `2026-08-17T03-31-23.704Z-43760` passed the CLI and engine
suites, including exact-envelope zero-write reuse, clone isolation, and
interrupted product publication. Changed-input package run
`2026-08-17T03-37-40.101Z-49847` executed 35 tasks with no failure, rebuilt and
qualified both architecture cohorts, and overlapped the architecture package
lanes for 43.7 seconds within their declared resource limits. The one-time
Linux assembler tool rebuild accounted for 254.7 seconds of that run; its
package cohort actions took 19.80 seconds for arm64 and 19.51 seconds for
x86_64.

Against the Phase 2 stage baseline, cohort time fell 94.3 percent for arm64 and
94.7 percent for x86_64. Summed RPM assembly fell 91.5 and 92.3 percent,
canonical payload materialization fell 64.6 and 63.6 percent, and host product
publication fell 86.5 and 86.6 percent. The changed run retained the
architecture-local package classification established by Phase 10 and passed
install, upgrade, removal, and exact-cohort lifecycle qualifications for both
architectures.

Immediately unchanged run `2026-08-17T03-45-24.149Z-52712` kept every package,
adapter, cohort, product publication, and lifecycle task clean. It invoked no
SwiftPM build and no container, executed only the five declared always-assessed
or retention tasks in 4.62 seconds, and left the complete source status and diff
digest unchanged. This cuts unchanged execution by 50.5 percent from the Phase
1 baseline.

Retention leaves exactly two package generations per architecture: the active
cohort and one rollback cohort. Their manifests reference exactly the 72 stored
products and 62 unique archive blobs present in the product store; no product or
archive candidate remains. The cache-prune dry run performed no mutation and
reported 191 historical storage targets plus four inactive workspaces as
reclaimable. All throughput and correctness gates are satisfied.
