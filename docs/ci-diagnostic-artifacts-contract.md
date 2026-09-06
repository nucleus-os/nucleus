# CI diagnostic artifacts

## Invariant

Every admitted verification attempt exports bounded diagnostic evidence to its
GitHub Actions run. Export does not invoke Collider, acquire its execution
lease, rebuild a tool, or require an interactive host login. A crash in Collider
must not prevent collection. The builder-owned original records remain the
authoritative evidence; the uploaded bundle is a scrubbed diagnostic copy, not
a product artifact or qualification record.

## Selection and contents

An attempt captures its start time before host validation. The collector selects
run manifests by exact admitted source revision, protected-main authority,
builder trust domain, and start time within that attempt. A run still marked
running after a crash is included. Older attempts and local-development records
are excluded.

The bundle contains selected manifests, event streams, run logs, and stage logs.
Its index records the GitHub run and attempt, source revision, outcome, available
planning and input-hashing durations, file sizes, omissions, and truncations.
The index does not label deferred tasks as executed work.

For macOS crash reports created during the attempt, collection selects only
Collider and the declared Swift/compiler/linker process allowlist in the
builder account's diagnostic directory. Both report creation and crash capture
time must match. Export retains fault details, stacks, and image information
needed for symbolication, while omitting unrelated device identifiers and
report metadata. No process-memory dumps are exported. Failure collection has
a bounded ten-second grace period for asynchronous macOS report generation.

Catalog verification also enables Swift's noninteractive runtime backtracer,
with a twenty-second timeout, a 128-frame limit, sanitized paths, and register
dumps disabled. Its attempt-local output is exported through the same bounded
and scrubbed file path. This does not depend on macOS emitting an IPS report.

## Privacy and resource boundaries

The collector never exports environment dumps, credential files, the builder
home tree, source trees, caches, binaries, container storage, or unrelated
system logs. Discovered file paths cannot traverse symlinks, including parent
directory symlinks, and only regular files are read. Credential patterns and
known secret environment values are scrubbed before output. Scrubbing is
defense in depth, not permission for producers to log secrets.

Each file is bounded to 8 MiB. Large text logs retain their tail and are marked
as truncated; oversized structured records are omitted rather than emitted as
invalid JSON. Payload is bounded to 128 MiB and 512 files, with crash evidence
collected first. The index records omissions. Artifact names contain both run
ID and attempt number, and GitHub retains them for fourteen days under the
repository's normal Actions artifact access controls.

## Failure behavior

Collection and upload run after success or failure, with best-effort collection
on cancellation. Collection is independently time-bounded and cannot overwrite
the verification result. Missing upload data is an explicit diagnostic failure.
A dead host, terminated runner, forced cancellation, or report generated after
the grace period can still prevent export; an absent report is never evidence
that no crash occurred. Records remain on the host under its normal retention
policy. Checkout failure precedes repository-owned diagnostic initialization
and is investigated from GitHub's own checkout logs.

Collector contract tests run in CI before invoking Collider. They exercise
attempt isolation, interrupted-run selection, crash-field projection,
credential scrubbing, symlink rejection, and bounded output.

The collector tests, failure-path collection, and artifact upload passed in
[run 34017830255](https://github.com/nucleus-os/nucleus/actions/runs/34017830255).
That run exported both provenance and interrupted verification records after
SIGBUS, but macOS supplied no matching IPS. Runtime-backtrace capture is the
additional diagnostic path for that case; its crash evidence remains to be
verified on CI.
