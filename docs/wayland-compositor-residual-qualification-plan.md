# Wayland compositor residual qualification plan

Status: active.

## Invariant

The compositor publishes truthful protocol state, owns every Wayland and DRM
resource through one explicit lifecycle, reconciles output changes atomically,
and never acknowledges presentation before the corresponding DRM completion.
Headless, paused, resumed, device-loss, output-removal, and hostile-client paths
remain valid states rather than exceptional alternate implementations.

Topology planning and reconciliation, pause/resume, redraw demand, presentation
generations, surface transactions, synchronized subsurfaces, XDG configure
tracking, dynamic seat capabilities, DMA-BUF validation, and DRM clock handling
are implemented with behavioral tests. The earlier source-audit phases are
complete and are not repeated.

## Phase 1 — Reproduce only residual failures

Run the existing protocol, topology, surface, XDG, seat, DMA-BUF, presentation,
and pause/resume suites. Exercise malformed requests, disconnect during callback,
output removal during presentation, final-output removal, device loss, and
resume with replaced DRM identities. Add diagnostics before changing behavior.

Gate: every remaining issue is represented by a reproducible behavioral test or
a captured physical-hardware trace.

## Phase 2 — Correct reproduced lifecycle defects

Fix only failures established in Phase 1. Preserve one owner per resource,
generation-check late callbacks, cancel pending work during teardown, and keep
protocol errors scoped to the offending client.

Gate: the new regression tests and the complete compositor test graph pass.

## Phase 3 — Qualify physical DRM behavior

On the Linux GPU/DRM qualifier, exercise startup, output hotplug, final-output
removal, VT pause/resume, suspend/resume, direct-scanout transitions, mixed
modifiers, cursor planes, client disconnect storms, and clean session shutdown.

Gate: the compositor remains responsive, reports exact presentation state, and
releases all DRM, DMA-BUF, fence, Wayland, input, and renderer resources.

## Phase 4 — Close the hardening record

Move residual invariants into the compositor architecture and protocol
documents and remove this qualification plan.
