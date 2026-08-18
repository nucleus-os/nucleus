# Source Identity From Git Objects Plan

Status: complete

## Invariant

Source closure identity derives from the object identities Git already
maintains for content it tracks, and reads file content only where Git cannot
answer: paths modified relative to the index, untracked paths, and paths whose
type is not a regular file. Identity remains exact. A tree that differs in any
tracked path, untracked path, executable bit, symbolic-link destination, or
nested checkout produces a different closure, and identical trees produce
identical closures.

The digest is a total function of the effective working tree, never of how the
tree was produced. A clean checkout at a revision and a dirty checkout restored
to the same content produce the same identity.

## Current State

`GitSourceCheckoutHasher.digest` lists the effective tree with `git ls-files
--cached --others --exclude-standard`, then reads and hashes the content of
every listed regular file, recursing into every nested checkout
unconditionally. On the authoritative checkout that is 1,069,801 files and more
than six gigabytes read on every capture.

The information required to identify tracked content is already loaded and
discarded. `trackedModes` runs `git ls-files --stage`, parses
`<mode> <object> <stage>\t<path>`, and keeps only the mode. The object field is
a content identity for exactly the bytes the hasher then reads from disk.

Measured on the authoritative checkout:

| Operation | Cost |
| --- | --- |
| `git ls-files --stage` (superproject) | 0.015 s |
| `git ls-files --others --exclude-standard` | 0.05 s |
| `git diff-files --name-only` | 2.1 s |
| the three above, recursively across 38 submodules | 4.1 s |
| current capture, warm cache | ~75 s |
| capture after Phase 1, warm cache | 16.5 s |

Capture runs on every `collider check protected-main-source`, on every local
invocation that revalidates source, and on every task identity that binds a
source closure. It reports no progress, because it is a single synchronous
operation rather than a task, so a slow capture is indistinguishable from a
hang.

## Phase 1: Partition The Listed Tree

Status: complete

Split the listed paths into the set Git identifies and the set that requires
reading.

A path is Git-identified when it is tracked, `git diff-files` does not report
it as differing from the index, and its recorded mode is a regular file or a
symbolic link. Its type and executable bit come from that mode and its identity
from the index, so neither its content nor its metadata is read. A deletion is
a difference from the index, so a Git-identified path is present without
checking.

Every other listed path is inspected: paths `git diff-files` reports, untracked
paths, nested checkouts, and any other type.

File content occupies one identity domain: the Git object identity. It is read
from the index when Git already holds it and computed with `git hash-object`
otherwise, so identical content produces one identity whether or not it happens
to be committed. Two domains, distinguished by a discriminator, were the first
attempt and were wrong: they made a closure change when content was committed
without changing, which invalidates every derived identity on commit and is the
opposite of what the invariant requires. The existing before-and-after-commit
tests rejected that encoding.

Symbolic links encode their destination in both branches rather than an object
identity, for the same reason and at no cost, since reading a link is not
reading content.

Racily clean entries need no special handling and no index refresh. Git
re-reads content for entries whose modification time defeats stat comparison,
so `git diff-files` is exact against a read-only checkout, which is the only
form the local build path may assume.

Reject a checkout carrying `assume-unchanged` or `skip-worktree` entries.
Both instruct Git to report a path as unmodified without checking, which a
source identity contract cannot accept. `git ls-files -v` reports them.

Gate: identical trees produce identical closures across a clean checkout and a
restored dirty checkout; a single changed byte, changed executable bit, changed
symbolic-link destination, added untracked file, and removed tracked file each
change the closure; a checkout carrying `assume-unchanged` or `skip-worktree`
fails rather than hashing incorrectly.

## Phase 2: Nested Checkouts Are Always Walked

Status: superseded by the Phase 1 finding

Identifying a clean nested checkout by its recorded commit, and walking only a
modified one, was measured at a further halving of capture cost. It is not
adopted, because it reintroduces the fault Phase 1 removed one level up: a
nested checkout advanced to a different commit without a content change would
carry a commit-derived identity where an identical tree carries a walked one,
and the two would disagree over identical content.

Walking every nested checkout is correct and is no longer expensive. The cost
that made recursion worth avoiding was content reading, and Phase 1 removed it
from the recursion as much as from the top level.

## Phase 3: Report Capture Progress

Status: complete

Capture is not a task, so no progress renders while it runs. Each checkout
reports the paths Git identified and the paths whose content must be read,
before reading any of them, so a capture that is slow because a working tree is
genuinely dirty is distinguishable from one that is stalled. Commands render
that through one shared reporter rather than each deciding for itself.

Gate: a capture over a clean fixture reports its paths as identified and none
as read; a capture over the same fixture with one modified and one untracked
path reports both as requiring reads before reading them. Against the
authoritative checkout the report names each nested checkout as it is reached,
so a sixteen-second capture is visibly progressing rather than silent.

## Identity Migration

This changes the encoding, so every derived identity changes once: task
identities that bind a source closure, and recorded provenance closures. That
invalidation is deliberate and happens on the change that lands Phase 1.
Recorded provenance from before the change identifies the encoding that
produced it and is not comparable to closures produced after it.

## Object Identity Strength

Git object identities are SHA-1, and all file content identity now rests on
them, including untracked and modified content. Protected-main provenance
already asserts that `HEAD` equals an exact asserted commit, and that commit
commits to every tracked blob through the same construction, so tracked content
already rested on SHA-1 for that authority. Untracked content did not, and now
does. `git hash-object` computes these identities with the collision detection
Git applies to its own objects.

A single identity domain is what the closure invariant requires. Keeping the
artifact hasher for content Git does not track would mean identical bytes
carrying two identities depending on whether they are committed, which is the
encoding the tests rejected.

If resting untracked content on SHA-1 is later judged unacceptable, the
replacement is an artifact-hasher digest cached by object identity, applied
uniformly to every file: identity stays in one domain, content is hashed once
per distinct object rather than once per capture, and the improvement survives
after the first capture populates the cache. That alternative is not adopted
now because a cold capture, which is the CI case, would gain nothing from it.

## Explicit Non-Goals

Do not weaken what participates in identity. Ignored paths remain excluded
because `--exclude-standard` excludes them today, and no path that participates
now stops participating.

Do not cache capture results across invocations. The improvement comes from
reading less, not from trusting a previous answer.

Do not special-case the protected-main authority. Its dirty-path rejection
already empties the set requiring reads, so the partition produces the commit
identity for it without a separate path through the code.
