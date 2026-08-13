# Wayland protocol coverage plan

Status: active.

## Invariant

Nucleus advertises only Wayland globals whose behavior it implements and
validates. Protocol breadth follows current product consumers. Generated
bindings do not count as an implementation; a protocol is implemented only
when the compositor registers a global, enforces its state machine, isolates
client failure, and passes behavioral wire tests.

Capture protocols and portal publication belong to
[`screen_recording_plan.md`](screen_recording_plan.md). Generated dispatch
isolation, handler binding, and resource ownership follow
[Swift Wayland Architecture](../../swift-wayland/ARCHITECTURE.md).

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
  management, screencopy, text-input-v3, input-method-v2, and security context.
- supervisor-authorized virtual-keyboard-v1 and virtual-pointer-v2, visible only
  on the current shell generation's private Wayland connection.

This list supersedes the older inventory that described alpha modifier,
security context, text-input-v3, ext-data-control, screencopy, and several shell
protocols as missing. FIFO and commit-timing are intentionally not registered;
generated bindings alone do not make them supported.

`productionRegistryMatchesSupportedProtocolContract` already asserts the exact
public global names and versions and confirms that commit-timing, FIFO, tearing
control, and the privileged Xwayland shell are not exposed to ordinary clients.
Keep that fixture synchronized with every registry change.

## Phase 1 — Complete the text-input pair

Status: complete.

Implement input-method-v2 mediation over the existing text-input-v3 runtime as
specified by [`appkit-api-plan.md`](appkit-api-plan.md). Add content-type only
with a current consumer and a complete compositor-to-client mapping.

Gate: real IME behavior and hostile-client wire tests cover serials, focus,
preedit, commit, surrounding text, cancellation, and teardown.

Achieved state: the compositor registers input-method-v2 and mediates its
activation, text state, serial-checked edits, popup role, keyboard grab, focus,
and teardown against the per-seat text-input-v3 authority.

Gate evidence: the typed client/server wire suite passes focus, surrounding
text, preedit, commit, deletion, stale serial, secure-field, duplicate-method,
popup, keyboard-grab, and destruction behavior in `collider test compositor`.
Real-IME interaction remains the user-owned qualification handoff in the AppKit
API plan and does not keep this implementation phase open.

## Phase 2 — Add physical gesture and tablet protocols

Status: complete.

Execute the gesture normalization, pointer-gestures-v1, and compositor policy
sequence in [`compositor-trackpad-gestures.md`](compositor-trackpad-gestures.md).
Then normalize libinput tablet tool and tablet pad events and implement
tablet-v2 over that stream. Preserve per-seat focus and cancellation semantics.

Gesture normalization, the complete pointer-gestures-v1 client projection,
compositor gesture policy, typed libinput tablet tool and pad normalization, and
the complete tablet-v2 client projection are implemented. Tablet focus follows
surface hit testing independently of pointer focus; tool, pad, device, client,
session, and compositor teardown retire their protocol state exactly once.

Gate: event normalization and wire tests cover begin/update/end/cancel,
multi-device seats, focus changes, device removal, and client teardown.

Gate evidence: the gesture and tablet normalization suites, tablet-v2 inventory
and wire lifecycle coverage, production global contract, multi-device
cancellation, device removal, focus transition, and client teardown coverage all
pass under `collider test compositor`.

## Phase 3 — Add trusted synthetic input

Status: complete.

Implement virtual-keyboard and virtual-pointer through the existing input
dispatch path. Bind authorization to a private supervisor-issued Wayland
connection for the current shell generation rather than to client-controlled
security-context metadata.

Gate: unauthorized clients are rejected, authorized clients share normal focus
and serial rules, and disconnect cannot leave pressed keys, buttons, or grabs.

Achieved state: the supervisor creates one private Wayland socketpair alongside
each shell policy endpoint. The compositor adopts the server endpoint as a
revocable managed client, and the shell uses the client endpoint for its normal
Wayland connection. Only that exact live client can discover or bind the virtual
keyboard and virtual pointer globals. Requests enter the central annotated
session input path, virtual keymaps replace and republish the seat keymap, and
resource or shell-generation teardown synthesizes releases for every held key
and button before destroying the client.

Gate evidence: the production registry fixture proves ordinary clients cannot
discover either global while the supervisor-issued client discovers both at the
implemented versions. Session protocol and supervisor acceptance tests prove the
two-endpoint generation handoff, replacement, and teardown. The complete
`collider test compositor` gate passes, including malformed-readiness precedence
and shell-restart coverage.

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
