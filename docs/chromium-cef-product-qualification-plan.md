# Chromium and CEF product qualification plan

Status: active.

## Invariant

Nucleus Browser and embedded CEF build from one clean, content-addressed source
generation selected by `chromium/source.lock.json`. Every downstream change is
an ordinary commit in a genuine `nucleus-os` fork. Collider never applies a
Nucleus patch, runs CEF's patcher, adopts a dirty checkout, or repairs an
existing source generation.

CEF and Nucleus Browser retain separate GN outputs because their allocator and
process-boundary contracts differ. Compilation runs offline in the selected
rootless `chromium-builder`; packaging, artifact validation, focused executable
tests, and hardware qualification run on the host.

The fork migration, source materialization, containerized compilation,
packaging, immutable publication, and focused source-level tests are
implemented. This plan owns product qualification only.

## Phase 1 — Qualify cold product builds

From an empty external build generation, prepare the selected builder image,
materialize the exact source generation, generate both production GN graphs
offline, build and publish CEF, and then build and publish Nucleus Browser.

Gate: both products validate from read-only source and depot_tools mounts, and
no compiler output or generated state appears beneath the source generation.

## Phase 2 — Qualify artifacts and focused tests

Compile and run the external CEF consumer, browser artifact validator, focused
Ozone presenter suite, and focused Viz presenter suite. Verify dynamic-library
resolution, sandbox ownership, product metadata, source provenance, launcher
syntax, and absence of SwiftShader and unsupported renderer fallbacks.

Gate: every published artifact is executable on the qualifier and bound to the
selected source, GN, compiler, PGO, and builder identities.

## Phase 3 — Prove bounded incremental reuse

Repeat the complete product build without changing inputs. Prove GN, Ninja, and
Siso reuse the same bounded external outputs, publication remains deterministic,
and all six selected source repositories remain clean.

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
