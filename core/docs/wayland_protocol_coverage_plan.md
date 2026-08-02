# Wayland protocol coverage plan

Status: active.

## Invariant

Nucleus advertises only Wayland globals whose behavior it implements and
validates. Protocol breadth follows current product consumers. Generated
bindings do not count as an implementation; a protocol is implemented only
when the compositor registers a global, enforces its state machine, isolates
client failure, and passes behavioral wire tests.

Capture protocols and portal publication belong to
[`screen_recording_plan.md`](screen_recording_plan.md). Dispatch isolation and
handler binding belong to
[`../../docs/wayland-dispatch-isolation-and-handler-binding-plan.md`](../../docs/wayland-dispatch-isolation-and-handler-binding-plan.md).

## Current registered surface

`WaylandRouterRuntime` currently registers these protocol families:

- core compositor, subcompositor, output, seat, SHM, region, and data device;
- xdg-shell, layer-shell, xdg-output, xdg-decoration, activation, xdg-foreign,
  Xwayland shell, and ext-session-lock;
- viewporter, fractional scale, alpha modifier, cursor shape, keyboard shortcut
  inhibition, pointer constraints, relative pointer, idle inhibition, and idle
  notification;
- presentation time, Linux DMA-BUF, Linux DRM syncobj, gamma control, and output
  management;
- blur, background effect, ext-workspace, ext-data-control, foreign-toplevel
  management, screencopy, text-input-v3, and security context.

This list supersedes the older inventory that described alpha modifier,
security context, text-input-v3, ext-data-control, screencopy, and several shell
protocols as missing. FIFO and commit-timing are intentionally not registered;
generated bindings alone do not make them supported.

`productionRegistryMatchesSupportedProtocolContract` already asserts the exact
public global names and versions and confirms that commit-timing, FIFO, tearing
control, and the privileged Xwayland shell are not exposed to ordinary clients.
Keep that fixture synchronized with every registry change.

## Phase 1 — Complete the text-input pair

Implement input-method-v2 mediation over the existing text-input-v3 runtime as
specified by [`appkit-api-plan.md`](appkit-api-plan.md). Add content-type only
with a current consumer and a complete compositor-to-client mapping.

Gate: real IME behavior and hostile-client wire tests cover serials, focus,
preedit, commit, surrounding text, cancellation, and teardown.

## Phase 2 — Add physical gesture and tablet protocols

Execute the gesture normalization, pointer-gestures-v1, and compositor policy
sequence in [`compositor-trackpad-gestures.md`](compositor-trackpad-gestures.md).
Then normalize libinput tablet tool and tablet pad events and implement
tablet-v2 over that stream. Preserve per-seat focus and cancellation semantics.

Gate: event normalization and wire tests cover begin/update/end/cancel,
multi-device seats, focus changes, device removal, and client teardown.

## Phase 3 — Add trusted synthetic input

Implement virtual-keyboard and virtual-pointer through the existing input
dispatch path. Bind authorization to the existing security-context and session
policy rather than allowing an untrusted client to inject global input.

Gate: unauthorized clients are rejected, authorized clients share normal focus
and serial rules, and disconnect cannot leave pressed keys, buttons, or grabs.

## Phase 4 — Close current desktop consumer gaps

Implement remaining protocols only when a current product or supported
application requires them. The initial candidate set is primary selection,
output power management, pointer warp, DRM lease, ext-foreign-toplevel-list,
and the modern color-management family. Prefer the current stable or staging
protocol and do not add obsolete aliases without a demonstrated consumer.

Gate: each protocol lands with a named consumer, a complete behavioral
contract, registry coverage, hostile-client tests, and destruction tests.

## Explicit exclusions

Do not implement deprecated shell versions, test-only protocols, or a protocol
whose accepted requests would be inert. Capture and recording protocols remain
owned by the capture plan. Remote-desktop authorization and portal mediation
remain portal/security work rather than unauthenticated input globals.
