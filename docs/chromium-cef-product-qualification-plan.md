# Chromium and CEF product qualification plan

Status: active.

## Invariant

Nucleus Browser and embedded CEF build from one clean, content-addressed source
generation selected by `chromium/source.lock.json`. Every downstream change is
an ordinary commit in a genuine `nucleus-os` fork. Collider never applies a
Nucleus patch, runs CEF's patcher, adopts a dirty checkout, or repairs an
existing source generation.

The host prepares that generation in two passes: native macOS hooks and CEF
translation first, then a no-hooks Linux x86_64 build-host synchronization.
The host-side CIPD client materializes Chromium's official Linux x86_64 graph
through an explicit platform adapter. Offline arm64 builder VMs execute those
tools through macOS 27 Intel translation while producing both target
architectures. The builder's pinned amd64 runtime closure covers checked-in and
generated host executables. Collider imports the resulting immutable generation
into one EXT4 source workspace, shared by every product and architecture,
because the prepared tree is a pure function of the pinned revisions and
nothing in it is target-specific. Only that import reads the host generation;
both products' build and qualification actions mount the imported source
read-only. The per-architecture workspaces this plan first described were
retired by
[`chromium-source-materialization-plan.md`](chromium-source-materialization-plan.md).

CEF and Nucleus Browser retain separate GN outputs because their allocator and
process-boundary contracts differ. One source workspace serves every product
and architecture; each product has independent persistent Linux arm64 and
x86_64 output workspaces, and each architecture one compiler cache shared by
both products. Compilation, packaging,
artifact validation, and focused executable tests run offline without a host
source mount. The focused test task compiles and executes in a separate
target-runtime image derived from the stable builder image. Hardware
qualification runs on the target system.

The Chromium lane owns two independently content-addressed dependency images.
The stable builder image owns compilers, build tools, and checked-in x86_64 host
tool runtime dependencies. The test-runtime image derives from that builder and
adds only the target-execution closure. Runtime dependency changes therefore
invalidate runtime materialization and focused tests without changing product
build or artifact identities. Operational entrypoints remain mounted inputs;
container orchestration changes do not invalidate dependency installation.

The fork migration, source materialization, containerized compilation,
packaging, immutable publication, and focused source-level tests are
implemented. This plan owns product qualification only.

## Phase 1 — Qualify cold product builds

Status: active.

From empty persistent workspaces, prepare the selected builder image,
materialize the exact source generation, generate all four production GN graphs
offline, build and publish arm64 and x86_64 CEF, and then build and publish
arm64 and x86_64 Nucleus Browser. The two architecture branches of each product
remain concurrent.

Gate: both architectures of both products validate from their read-only EXT4
source workspaces, the source-pinned Linux host tools execute through macOS 27
translation with their complete declared runtime closure, and no compiler
output or generated state appears beneath the host source generation or a
host-backed intermediate tree.

Observed on 2026-09-03: all four product builds and all four artifact
assemblies succeeded in one sweep, from read-only source workspaces, with the
source-pinned x86_64 host tools running under translation. The gate is not
claimed. What ran was incremental across several runs rather than one pass from
empty workspaces, so cold preparation and offline GN generation for all four
graphs remain unwitnessed in a single run.

## Phase 2 — Qualify artifacts and focused tests

Cross-compile and link the external CEF consumer for each architecture. Execute
the arm64 consumer against the builder image's real arm64 distribution runtime.
Statically validate the x86_64 consumer's ELF architecture and direct dependency
closure because Apple Intel translation cannot load CEF's relocation table. Run
each browser artifact validator and each target's focused Ozone and Viz presenter
suite. Chromium's stripped sysroots remain compile/link inputs and are never
used as runtime roots. Each test executes through the target architecture's
kernel-selected loader with the test-runtime image's explicit multiarch library
path. This preserves Chromium's `/proc/self/exe` contract for locating runtime
data while keeping translated x86_64 processes out of arm64 directories. Verify
dynamic-library resolution, sandbox ownership, product metadata, source
provenance, launcher syntax, and absence of SwiftShader and unsupported renderer
fallbacks.

Gate: every published architecture is executable on the qualifier and bound to
the selected source, target, GN, compiler, sysroot, PGO, and builder identities.

Observed on 2026-09-03: the CEF consumer cross-compiles, links, and validates
for both architectures, and the browser artifact validators pass for both. That
step had never run before -- it called `/usr/bin/clang`, which no image here
installs, and declared no translation for the checked-in x86_64 compiler it
should have been using instead.

The focused Ozone and Viz presenter suites this phase requires had not run at
all. `collider verify all` asked for the browser lane by name for `.build` and
not for `.testDefault`, so `browser.test.arm64` and `browser.test.x86_64` were
absent from the plan rather than skipped as clean, and no run reported their
absence. Both entrypoints are now requested, and
`verifyingEverythingSelectsBothHalvesOfTheBrowserLane` fails if either is
dropped again.

The first execution attempt incorrectly selected Chromium's stripped sysroot as
a runtime and both suites died during process startup. The next attempt used the
container's implicit native runtime; arm64 passed, while x86_64 could not resolve
`libxkbcommon.so.0`. The test lane now separates compilation from execution and
owns a dedicated runtime image whose construction asserts both target loaders
and the target libraries required by the focused binaries, including x86_64
`libgbm.so.1` and both `libxkbcommon.so.0` objects. The runtime package closure
is not part of the repository-wide native-builder image or the Chromium
product-builder identity.

## Phase 3 — Prove bounded incremental reuse

Repeat the complete product build without changing inputs. Prove GN, Ninja,
Siso, and ccache reuse the same persistent target workspaces, publication
remains deterministic, and all six selected source repositories remain clean.

Gate: the unchanged run performs no source repair and produces equivalent
validated products without rebuilding unaffected work.

Partly observed, and one finding stands against it. Repeated sweeps complete
every product build in eleven to nineteen seconds reporting `ninja: no work to
do`, which is siso and Ninja reuse. ccache reuse is not demonstrated and cannot
yet be: the cache was reaching no compilation at all -- its settings were
declared in the execution field that never becomes the container process's
environment, and clang modules make a compilation uncacheable without depend
mode and modules sloppiness besides. Both are corrected and each build now
reports the cache's configuration and counters, but every build since has
compiled nothing, so the counters remain zero and the property is unproven.

Against the gate: on 2026-09-03 `browser.cef.x86_64.build` spent nine minutes
loading its graph to perform zero steps, where the same build was eleven
seconds in the run before and its three sibling builds were unaffected in the
same sweep. That is this gate's own definition of rebuilding unaffected work,
and it has no explanation yet.

## Phase 4 — Qualify the live products

Run browser startup, sandbox, GPU, Wayland explicit synchronization, 120 Hz,
resize, fractional scale, accelerated video, WebGL, WebGPU, Widevine, crash,
restart, and shutdown checks on the real runner. Exercise the embedded CEF
consumer independently against its offscreen contract.

Gate: both products sustain their declared GPU paths and process boundaries
without CPU rendering, implicit-sync fallback, source mutation, or leaked
processes and resources.

## Phase 5 — Close the fork migration

Move the qualified identities and durable source/build rules into the Chromium
component contract and remove this qualification plan.
