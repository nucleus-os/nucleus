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
architectures. Collider imports the resulting immutable generation into one
EXT4 source workspace per architecture. Only that import reads the host
generation; both products' build and qualification actions mount the imported
source read-only.

CEF and Nucleus Browser retain separate GN outputs because their allocator and
process-boundary contracts differ. Each architecture has one source workspace
shared by both products; each product has independent persistent Linux arm64
and x86_64 output and compiler-cache workspaces. Compilation, packaging,
artifact validation, and focused executable tests run offline in the selected
rootless `chromium-builder` without a host source mount. Hardware qualification
runs on the target system.

The builder is two content-addressed images. A stable dependency image owns the
Linux package closure and tool environment. A thin operational image adds only
the current entrypoint onto the exact local dependency-image digest. Container
orchestration changes cannot invalidate dependency installation.

The fork migration, source materialization, containerized compilation,
packaging, immutable publication, and focused source-level tests are
implemented. This plan owns product qualification only.

## Phase 1 — Qualify cold product builds

From empty persistent workspaces, prepare the selected builder image,
materialize the exact source generation, generate all four production GN graphs
offline, build and publish arm64 and x86_64 CEF, and then build and publish
arm64 and x86_64 Nucleus Browser. The two architecture branches of each product
remain concurrent.

Gate: both architectures of both products validate from their read-only EXT4
source workspaces, the source-pinned Linux host tools execute through macOS 27
translation, and no compiler output or generated state appears beneath the host
source generation or a host-backed intermediate tree.

## Phase 2 — Qualify artifacts and focused tests

Cross-compile, link, and run the external CEF consumer for each architecture.
Run each browser artifact validator and each target's focused Ozone and Viz
presenter suite. Use the matching Chromium sysroot and target loader so arm64
executes natively and x86_64 executes through macOS 27 Intel binary translation.
Verify dynamic-library resolution, sandbox ownership, product metadata, source
provenance, launcher syntax, and absence of SwiftShader and unsupported renderer
fallbacks.

Gate: every published architecture is executable on the qualifier and bound to
the selected source, target, GN, compiler, sysroot, PGO, and builder identities.

## Phase 3 — Prove bounded incremental reuse

Repeat the complete product build without changing inputs. Prove GN, Ninja,
Siso, and ccache reuse the same persistent target workspaces, publication
remains deterministic, and all six selected source repositories remain clean.

Gate: the unchanged run performs no source repair and produces equivalent
validated products without rebuilding unaffected work.

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
