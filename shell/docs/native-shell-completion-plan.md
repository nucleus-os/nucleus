# Native shell completion plan

Status: active.

## Invariant

`nucleus-shell` is the sole desktop shell: native Swift/NucleusUI, out of
process, and shell-policy only. The compositor remains shell-agnostic. Typed
service projections own system integration; views never own D-Bus, process, or
privileged clients. There is no Noctalia runtime, fallback, launcher, asset, or
compatibility path.

The native bar framework, per-output surfaces, taskbar, clock, battery widget
and panel, notification surfaces, launcher service, application index, UPower,
lock screen, configuration subscription, accessibility bridge, and
demand-driven rendering are implemented.

## Phase 1 — Complete bar services and widgets

Add volume, network, StatusNotifierItem tray, and workspace projections with
typed snapshots and actions. Add per-output bar configuration before consuming
it. Preserve output-keyed retained widget identity, service-loss state, and idle
operation without per-frame polling.

Gate: behavioral fixtures cover reconnect, output replacement, configuration
replacement, malformed service data, widget actions, and idle wakeups.

## Phase 2 — Unify transient panel hosting

Extract the shared lifecycle already proven by the battery and notification
surfaces into one panel host for placement, constrained geometry, scrolling,
focus dismissal, keyboard navigation, clipping, and teardown. Move battery and
notifications onto it, then add network, volume, tray-menu, and launcher panels.

Gate: every panel behaves across fractional scale, multiple outputs, focus loss,
output removal, service restart, and constrained geometry without duplicate
surface ownership.

## Phase 3 — Complete native service ownership

Finish StatusNotifierItem/dbusmenu, NetworkManager, PipeWire audio control,
freedesktop notifications, provider-neutral application search/launch, power
actions, clipboard-mediated actions, and shell preferences. Each adapter
publishes immutable typed state and accepts typed commands.

Gate: private fixture services prove reconnection, malformed peer handling,
cancellation, authorization, and teardown without a live desktop.

## Phase 4 — Add browser-backed product surfaces

After CEF product qualification passes, host the Apple Music surface in a
separate shell service process. Exchange only commands, input, lifecycle, and
GPU-buffer metadata through narrow opaque-handle boundaries. A browser crash
cannot terminate or stall the shell.

Gate: process crash/restart, focus, audio ownership, explicit synchronization,
GPU-buffer retirement, and complete resource cleanup pass.

## Phase 5 — Complete shell accessibility and security

Finish keyboard navigation and semantic coverage for every shell surface,
reduced-motion/contrast/transparency behavior, secure lock-screen transitions,
and privileged-action mediation. Keep compositor-global authority unavailable
to the shell unless a narrow authenticated capability requires it.

Gate: AT-SPI behavior, hostile service fixtures, PAM isolation, privilege
denial, session failure, and complete teardown pass.

## Phase 6 — Qualify the daily-driver shell

Run the complete native session acceptance suite with output hotplug,
pause/resume, service restart, lock/unlock, application launch, notification and
panel activity, browser-service failure, and shutdown.

Gate: the installed runtime contains only the native shell path and every
required shell capability is either functional or a directed startup failure.
