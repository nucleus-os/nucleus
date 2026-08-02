# Noctalia-to-Nucleus shell migration plan

**Status: active.**

**Invariant: the final shell is native Swift/NucleusUI, out of process, and shell-policy only. The compositor remains shell-agnostic, the configuration service is the sole configuration owner, and Noctalia leaves no runtime dependency or preserved parallel UI path.**

## Landed foundation

The root package contains the native shell process, NucleusUI product views, Wayland window/input/render clients, PAM helper, configuration subscription, service projections, bar framework, battery UI, notifications, and lock-screen foundation.

## Phase 1 — Finish the minimal bar

Complete clock, workspaces, volume, battery, network, and tray widgets using typed shell state. Add per-output and per-bar settings to `ShellConfiguration` before consuming them. Preserve demand-driven rendering and avoid polling widgets per frame.

Gate: behavioral tests cover widget state, output add/remove, configuration replacement, service loss, and idle wakeups.

## Phase 2 — Add panels and transient surfaces

Build the panel host, scrolling, focus dismissal, placement, clipping, and keyboard navigation. Land only controls required by the first battery, network, volume, notification, and launcher panels.

Gate: panels behave correctly across fractional scale, multiple outputs, focus loss, service restart, and constrained geometry.

## Phase 3 — Complete native services

Finish StatusNotifierItem/dbusmenu, network state and actions, audio control, notifications, application search/launch, power actions, clipboard-mediated actions, and shell preferences. Service implementations publish typed snapshots; views do not own D-Bus or process clients.

Gate: fixture services cover reconnect, malformed peers, cancellation, and teardown without a live desktop.

## Phase 4 — Add browser-backed product surfaces

After the CEF product passes its own optimized and runtime gates, host it in a separate shell service process. Expose only the commands, pixels, input, and lifecycle required by the Apple Music surface through narrow opaque-handle seams. A browser crash must not terminate the shell.

Gate: process crash/restart, GPU-buffer lifetime, input focus, audio ownership, and resource cleanup are proven.

## Phase 5 — Complete accessibility and security

Publish the native accessibility tree, keyboard navigation, reduced-motion/contrast policy, secure lock-screen behavior, and privileged-action mediation. The shell never obtains compositor-global authority merely because it is first party.

Gate: accessibility behavior tests, hostile service fixtures, PAM isolation tests, and session teardown all pass.

## Phase 6 — Retire Noctalia

Move the final daily-driver surfaces and settings, remove every Noctalia launcher, asset, compatibility adapter, and packaging input, and make missing native functionality a hard failure rather than a fallback.

Gate: repository searches and installed-runtime inventory contain no Noctalia runtime path, and the complete native shell passes the session acceptance suite.
