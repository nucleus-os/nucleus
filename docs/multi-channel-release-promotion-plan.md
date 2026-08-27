# Multi-channel release promotion

Status: deferred

## Invariant

Nightly remains the only active Nucleus package repository channel until its
installation, update, recovery, rollback, signing-key transition, retention,
and publication contracts are qualified across both architectures and every
supported package family. The initial repository implementation contains no
beta or stable enrollment package, metadata path, mutable channel object,
publisher credential, promotion command, or support promise.

When this plan activates, beta and stable reuse exact immutable package objects
and signed repository snapshots already published and qualified through the
nightly pipeline. Promotion never rebuilds, resigns, copies, substitutes, or
otherwise changes a package cohort. A new channel becomes visible only through
an atomic metadata pointer written after every referenced object and signature
has been verified remotely.

## Activation gate

Activate this plan only after the nightly update lifecycle is complete and the
repository has retained enough qualified nightly and rollback cohorts to prove
its recovery, retention, and signing-key-transition behavior. Activation also
requires an explicit product support contract defining who consumes beta and
stable, how each channel retains rollback cohorts, and what evidence makes a
nightly cohort eligible for promotion.

## Phase 1: Define independent enrollment and authority

Add explicit beta and stable enrollment packages that conflict with nightly and
with each other. Give every package family and architecture its own immutable
snapshot pointer per channel. Extend repository-metadata publication authority
to those pointers without granting package-object, signing, Worker deployment,
or build authority.

Gate: a machine follows exactly one declared channel; no enrollment transaction
can leave multiple Nucleus repositories active; and each publisher credential
can mutate only its declared metadata pointers.

## Phase 2: Promote exact cohorts to beta

Select a qualified nightly release index and publish beta metadata that names
the same package-object digests and signed snapshot contents. Qualify clean
enrollment, update, interruption recovery, downgrade, key transition, removal,
and reinstallation on beta across both architectures and every supported
package family.

Gate: the beta cohort is byte-identical to its nightly source cohort, no build or
signing action runs during promotion, and beta clients observe either the
previous complete snapshot or the promoted complete snapshot.

## Phase 3: Promote exact cohorts to stable

Select a qualified beta release index and publish stable metadata that names the
same package-object digests and signed snapshot contents. Apply the stable
support and rollback-retention contract, then qualify the complete native update
lifecycle on both architectures and every supported package family.

Gate: nightly, beta, and stable provenance resolves to one immutable cohort;
stable publication performs no compilation, signing, package assembly, or
object copy; and retained stable and rollback cohorts are never prunable while
their support contract requires them.
