# Wayland Protocol Coverage — Plan

## Goal

Make Nucleus a drop-in replacement for `sway` / `Hyprland` / `KWin` / `Mutter` from a protocol-coverage standpoint. The user shouldn't ever have to discover that "X doesn't work because Nucleus is missing protocol Y." Every commonly-used Wayland protocol gets a real implementation; the few protocols we genuinely don't need (test/debug-only, deprecated, compositor-internal) are documented explicitly.

This plan covers the **non-capture** protocol surface. Capture protocols (`ext-image-copy-capture`, `wlr-screencopy`, `wlr-export-dmabuf`, foreign-toplevel-list, foreign-toplevel-management, xdg-desktop-portal ScreenCast) are handled by `docs/screen_recording_plan.md` — they share a `SCStreamEngine` that's a prerequisite, so they belong with the capture subsystem.

## Implementation status

### Already in tree

Core wire + foundational:
- `wayland.xml` core (wl_display, wl_compositor, wl_subcompositor, wl_seat, wl_pointer, wl_keyboard, wl_output, wl_shm, wl_region, wl_data_device family)
- `linux-dmabuf-unstable-v1` — DMA-BUF buffer import
- `linux-drm-syncobj-v1` — explicit GPU sync via syncobj timelines
- `viewporter` — surface viewport (used by xwayland scaling)
- `presentation-time` — frame timing feedback
- `fractional-scale-v1` — fractional output scale signaling
- `cursor-shape-v1` — named cursor shapes from clients
- `tearing-control-v1` — opt-in tearing for games
- `commit-timing-v1` — commit deadline hints
- `fifo-v1` — FIFO commit policy
- `xdg-output-unstable-v1` — output geometry / logical position
- `xdg-decoration-unstable-v1` — client/server-side decoration negotiation

Shell surfaces:
- `xdg-shell` — toplevel and popup
- `wlr-layer-shell-unstable-v1` — layer surfaces (shell widgets, lockscreens via clients)
- `xdg-activation-v1` — focus / activation requests

Visual effects:
- `kde-blur` (`org_kde_kwin_blur`) — surface background blur
- `ext-background-effect-v1` — surface backdrop effects

Output / hardware:
- `wlr-gamma-control-unstable-v1` — per-output gamma LUT
- `wlr-output-management-unstable-v1` — output configuration RPC

Recently added (this protocol-coverage push):
- `keyboard-shortcuts-inhibit-unstable-v1` — clients (remote desktop / VMs / nested compositors) request the compositor stop intercepting shortcuts on their focused surface
- `pointer-constraints-unstable-v1` — lock / confine the pointer to a surface (FPS games, VMs, looking-glass)
- `relative-pointer-unstable-v1` — raw / unaccelerated pointer deltas (mouselook, VMs)
- `idle-inhibit-unstable-v1` — clients (video players, presentations) suppress idle dimming
- `ext-idle-notify-v1` — daemons (swayidle, lockscreen triggers) subscribe to idle timeouts

### Landed since this plan was drafted

These were listed below as "to implement" but are now real, registered globals in the Swift compositor runtime (`compositor-core/Sources/NucleusCompositorWaylandRuntime/`). Each calls `NucleusWaylandRouter.addGlobal` and is wired from `WaylandRouterRuntime.swift`. The detailed entries and batch listings further down are kept for historical rationale but are marked **Implemented**.

- `ext-session-lock-v1` — `SessionLock.swift` (`ext_session_lock_manager_v1`). Session locking works (swaylock / hyprlock).
- `ext-workspace-v1` — `ExtWorkspace.swift` (`ext_workspace_manager_v1`), served as a projection of the Spaces / desktop model.
- `xdg-foreign-v2` — `XdgForeign.swift` (`zxdg_exporter_v2` / `zxdg_importer_v2`), cross-process surface parenting.
- `xwayland-shell-v1` — `XwaylandShell.swift` (`xwayland_shell_v1`); Xwayland binds it to associate each X11 window to a router `wl_surface` by serial.
- `ext-data-control-v1` — `ExtDataControl.swift` (`ext_data_control_manager_v1`), the privileged clipboard-manager channel. Note: only the `ext-` form landed; the older `wlr-data-control-unstable-v1` form is still unimplemented.
- `wlr-screencopy-unstable-v1` — `Screencopy.swift` (`zwlr_screencopy_manager_v1`); also cross-referenced under "Handled by other plans."

### Scanned but not implemented

XML is present under `swift-wayland/Protocols` and included by
`tools/collider generate wayland`, so generated bindings exist, but no
`NucleusCompositorWaylandRuntime/*.swift` router file registers a global.
Treated as "to implement," not "done." Listed here so an auditor doesn't
confuse scanner coverage with runtime coverage.

- `tablet-v2` — scanned as `tablet_unstable_v2` (pulled in as a cursor-shape interface dependency); no router file, no integration. Moved into Batch 2.

(`content-type-v1` is not vendored yet — neither generated nor implemented.
Adding it requires the XML under `swift-wayland/Protocols`, regeneration
through Collider, and a router file. Still tracked in Batch 1.)

### Pre-existing protocol bugs in "in tree" modules

These are spec-compliance gaps inside modules listed as done. Scheduled as cleanup alongside the warp work in Batch 7.

- `pointer-constraints-unstable-v1` locked-pointer `cursor_position_hint`: `PointerConstraints.swift` parses and stores the hint but the deactivation path never warps the cursor to it. Fix requires the same seat warp-pointer primitive `pointer-warp-v1` needs.

### Handled by other plans

These appear in `docs/screen_recording_plan.md`, not here. Mentioned so this file's coverage map is complete. (Two of these have already landed in the runtime: `wlr-screencopy-unstable-v1` in `Screencopy.swift` and `wlr-foreign-toplevel-management-unstable-v1` in `ForeignToplevel.swift`.)

- `ext-image-capture-source-v1` family
- `ext-image-copy-capture-v1`
- `wlr-screencopy-unstable-v1`
- `wlr-export-dmabuf-unstable-v1`
- `ext-foreign-toplevel-list-v1`
- `wlr-foreign-toplevel-management-unstable-v1`
- `xdg-desktop-portal` ScreenCast backend + PipeWire producer

### To implement (this plan)

Grouped by domain. Each entry includes scope estimate, app impact, dependencies, and notes.

## Input

### `pointer-gestures-v1`
- **Scope:** ~150 lines plus libinput binding additions.
- **Apps unblocked:** Firefox pinch-to-zoom, GTK/Adwaita swipe-to-go-back, Chromium gestures, any touchpad-aware app.
- **Notes:** libinput already delivers `gesture` events; we drop them today. Three sub-protocols: pinch, swipe, hold. Each is a small stateful machine (begin / update / end / cancel) per-client per-pointer. Pairs naturally with the input work already done — same shape as `RelativePointer.swift`.
- **Dependencies:** libinput binding for `libinput_event_gesture_*`. None on engine work.

### `text-input-v3` + `input-method-v2`
- **Scope:** ~700 lines combined; complex state machine for preedit / surrounding text / commit / serial reconciliation.
- **Apps unblocked:** Every IME-using user (CJK input, accented Latin via fcitx/ibus, autocorrect on GTK/Qt apps). Electron / Chromium / Firefox honor text-input-v3 properly; without it those apps are limited to dead-key composition via xkbcommon, which is incomplete for non-English users.
- **Notes:** Co-design. text-input-v3 is the client (app) side; input-method-v2 is the IME-process side. Compositor mediates between them with serial tracking to prevent stale-state commits. Skipping older versions: text-input-v0/v1/v2 are essentially dead; fcitx5/ibus speak v3 directly. **Dedicated session worth.**
- **Dependencies:** xkbcommon (already linked). No engine work.

### `virtual-keyboard-unstable-v1`
- **Scope:** ~250 lines.
- **Apps unblocked:** On-screen keyboards (`squeekboard`, `wvkbd`), accessibility tools, touch-screen text input.
- **Notes:** Client (the on-screen keyboard) sends synthetic key events through this protocol; compositor injects them into the focused client as if real keypresses. Trust boundary is "only allow this from clients granted the capability" — for V1, allow from any client (matches sway behavior); refine if security-context wiring lands first.
- **Dependencies:** Pairs nicely with `wp-security-context-v1` later for proper trust gating.

### `wlr-virtual-pointer-unstable-v1`
- **Scope:** ~200 lines.
- **Apps unblocked:** `wtype`, `ydotool`, accessibility tools that synthesize pointer events, remote-desktop receivers (waynergy), automation pipelines.
- **Notes:** Mouse-side counterpart to `virtual-keyboard-unstable-v1`. Client emits synthetic motion / button / axis / frame events; compositor feeds them through the same input dispatch path used for libinput pointer events. Same trust model as virtual-keyboard — open by default for V1, gated by security-context later. Naturally shares `Seat.warpPointer` with the warp work in Batch 7 if absolute-motion events are supported.
- **Dependencies:** None. Pairs with `virtual-keyboard-unstable-v1` in Batch 6.

### `tablet-v2`
- **Scope:** ~600 lines.
- **Apps unblocked:** Wacom / Huion / XP-Pen styli, drawing pads, Krita / GIMP / Inkscape pressure + tilt input, OBS pen-tool controls.
- **Notes:** XML is scanned (`tablet_unstable_v2` in `plugin.swift`, pulled in as a cursor-shape dependency) but no router file exists. Real implementation covers `zwp_tablet_manager_v2`, per-seat tablet seats, tools (stylus / eraser / mouse / lens), pads with buttons / rings / strips, and `set_cursor` for tool-specific cursors. libinput already delivers tablet events; the work is wire-up plus per-tool focus tracking.
- **Dependencies:** libinput tablet event bindings.

### `wlr-data-control-unstable-v1` + `ext-data-control-v1`
**Partially implemented** — `ext-data-control-v1` is done (`ExtDataControl.swift`, `ext_data_control_manager_v1`); the `wlr-data-control-unstable-v1` form is still pending. Original rationale retained below.
- **Scope:** ~400 lines (cover both — they're alternate forms of the same idea; tools vary on which they speak).
- **Apps unblocked:** Clipboard managers (`clipman`, `wl-clipboard`, `cliphist`), automation tools.
- **Notes:** `wl_data_device` only delivers clipboard to the focused client; clipboard managers need a side channel to observe all selections. data-control is that channel. ext-data-control-v1 is the standardized successor; wlr-data-control-unstable-v1 is what existing tools use today. Both adapt over the same clipboard state in `DataDevice.swift`.
- **Dependencies:** None.

### `primary-selection-unstable-v1` / `wp-primary-selection-v1`
- **Scope:** ~200 lines.
- **Apps unblocked:** Middle-click-paste behavior across all GTK / Qt apps and most terminals. Currently broken on Nucleus because clients can't read the X-style "primary" selection.
- **Notes:** Parallel to wl_data_device but for the primary (middle-click) selection. Some clients explicitly require it.
- **Dependencies:** Touches `DataDevice.swift`. Clipboard-manager interaction (data-control above) ideally lands first or together.

## Surface composition

### `alpha-modifier-v1`
- **Scope:** ~80 lines. Trivial.
- **Apps unblocked:** Terminals and clients that want per-surface opacity (some Wayland-native terminals, some media players in PiP mode).
- **Notes:** Client sets a surface's alpha multiplier as commit-buffered state; compositor multiplies that into the per-quad alpha when composing.

### `single-pixel-buffer-v1`
- **Scope:** ~100 lines.
- **Apps unblocked:** Clients that need a quick solid-color buffer (placeholder backgrounds, fade overlays, splash screens). Useful for shells that draw solid backgrounds without allocating real buffers.
- **Notes:** Tiny — just a new `wl_buffer` source that's a fixed-color quad. No real backing memory.

### `pointer-warp-v1` (staging)
- **Scope:** ~80 lines protocol + ~120 lines for the shared `Seat.warpPointer` primitive (synthetic motion generation, output/transform mapping, constraint clamping).
- **Apps unblocked:** Clients that want to programmatically move the cursor (some games, accessibility tools, autotype tools). Also fixes the locked-pointer `cursor_position_hint` deactivation warp listed under "Pre-existing protocol bugs."
- **Notes:** Client requests "warp cursor to (x, y) in surface coords." Compositor honors only when the requesting surface has pointer focus (per spec) and the global warp lands inside any active confine region. The seat warp-pointer entry point is shared with `PointerConstraints.swift` and `wlr-virtual-pointer-unstable-v1` (absolute-motion path).

### `content-type-v1`
- **Scope:** ~120 lines.
- **Apps unblocked:** mpv / firefox video / games signaling `video` / `game` content-type so the compositor can bias toward direct scanout, disable effects, or relax frame pacing on those surfaces.
- **Notes:** Not yet in the generator list (`plugin.swift`) and no router file exists. Wire-up is a per-surface enum stored as commit-buffered (double-buffered) surface state and consumed by the render scheduling / blur / tearing-policy code.
- **Dependencies:** Pairs naturally with `tearing-control-v1` (already in tree) since both feed surface-presentation policy.

## Window lifecycle

### `xdg-dialog-v1`
- **Scope:** ~100 lines.
- **Apps unblocked:** GTK / Qt apps that mark modal dialogs (file pickers, confirmation popups). Lets the WM render modal styling and apply modal focus policy.
- **Notes:** Adds a `set_modal` / `unset_modal` request on xdg-toplevel. Window-management policy decides what to do with the hint (currently we have no WM policy that uses it; setting up the protocol now means policy can pick it up later).

### `xdg-toplevel-drag-v1`
- **Scope:** ~250 lines.
- **Apps unblocked:** Tab tear-out in Chromium / Firefox / VSCode / Electron editors.
- **Notes:** Extends xdg-toplevel with "this toplevel is being dragged from another toplevel; here's the source-of-drag pointer state to inherit." Touches xdg_shell + data_device interaction. Slightly more involved because the interaction with the existing drag-and-drop state machine needs to be careful.

### `xdg-toplevel-icon-v1`
- **Scope:** ~150 lines.
- **Apps unblocked:** Clients that ship their icon in-protocol rather than relying on `.desktop`-file lookup. Better app-switcher iconography, especially for apps without `.desktop` entries (web app frames, Electron apps in flatpak that don't ship a separate `.desktop`).
- **Notes:** Client sends a list of `wl_buffer`s at multiple sizes; compositor caches and uses for taskbar / app-switcher / window decoration glyphs.

### `xdg-system-bell-v1`
- **Scope:** ~100 lines.
- **Apps unblocked:** Terminal bell that does something visible / audible (currently a `\a` goes nowhere on Wayland-native terminals).
- **Notes:** Tiny protocol — client says "ring the bell" optionally on a surface. Compositor does whatever (flash an output, play a sound through PipeWire, show a notification). MVP: flash the focused window's titlebar briefly.

### `xdg-toplevel-tag-v1` (staging)
- **Scope:** ~80 lines.
- **Apps unblocked:** Clients that want stable identifiers per-toplevel for window-manager policy hooks (per-app rules engines like KWin's window-rules).
- **Notes:** Adds a `set_tag` request. Compositor stores the tag for lookup by policy code. Pairs with future window-rules engine in WindowServer.

### `xdg-session-management-v1` (staging)
- **Scope:** ~300 lines.
- **Apps unblocked:** Session restore — apps remember where they were last placed and request to be put back there on next launch. GNOME and some KDE apps use this.
- **Notes:** Compositor stores per-session window state, restores on app reconnect. Lower priority — useful but not "broken without it."

### `ext-workspace-v1`
**Implemented** — `ExtWorkspace.swift` (`ext_workspace_manager_v1` on the router), a projection of the Spaces / desktop model. Original rationale retained below.
- **Scope:** ~400 lines.
- **Apps unblocked:** Third-party panels and indicators (`waybar`, `eww`, `ironbar`, `i3status-rust`, kdeconnect workspace indicator, polybar Wayland builds) rendering workspace pips and responding to clicks. Even though the bundled RN dock reads workspace state through internal Swift `NucleusCompositorWindowManager` IPC, users on a drop-in compositor target install third-party shells that speak this protocol.
- **Notes:** Exposes workspace groups (per-output sets of workspaces), per-workspace state (active / urgent / hidden), and `activate` / `assign` requests. The compositor mirrors the policy state already maintained by `NucleusCompositorWindowManager` onto the protocol; clients read and request transitions through it. WM policy stays the authority — this is the introspection / RPC surface.
- **Dependencies:** Stable workspace IDs in `NucleusCompositorWindowManager`. Mostly wire-up.

### `xdg-pip-v1` (staging)
- **Scope:** ~150 lines.
- **Apps unblocked:** Firefox PiP, Chromium PiP, mpv PiP, video-call apps (Discord, Zoom Electron) using the platform PiP role instead of always-on-top hacks. KDE 6.2+ honors it today; Chromium and mpv are queueing support.
- **Notes:** Adds a `pip` toplevel role with sized-bounds hinting; WM policy treats the surface as always-on-top, snap-to-corner, and draggable without focus stealing. Pairs with the always-on-top hint policy that `NucleusCompositorWindowManager` already needs for tear-out / floating windows.
- **Dependencies:** Always-on-top floating window class in WM policy. Light protocol layer over that.

### `ext-session-lock-v1`
**Implemented** — `SessionLock.swift` (`ext_session_lock_manager_v1` on the router). Original rationale retained below.
- **Scope:** ~350 lines.
- **Apps unblocked:** `swaylock`, `hyprlock`, `gtklock`, `waylock`, `loginctl lock-session` integration.
- **Notes:** Compositor exposes `ext_session_lock_manager_v1.lock`, hides regular surfaces, accepts lock-surface roles on every output, and routes input only to the lock client until `unlock_and_destroy`. Pairs with `wlr-layer-shell` exclusivity rules and the existing focus / activation funnel.
- **Dependencies:** Needs an "input route everything to one client" mode at the seat / focus layer. Touches `InputDispatch.swift`.

## Cross-client

### `xdg-foreign-v2` (`zxdg-foreign-v2`)
**Implemented** — `XdgForeign.swift` (`zxdg_exporter_v2` / `zxdg_importer_v2` on the router). Original rationale retained below.
- **Scope:** ~300 lines.
- **Apps unblocked:** Flatpak / Snap file pickers (via xdg-desktop-portal-gtk / -gnome) correctly parenting their dialog window to the caller's surface; portal screencast picker windows correctly parenting; cross-app drag-and-drop with origin tracking.
- **Notes:** Exports a stable handle for a surface; another client can import that handle and set its toplevel's parent to the exported surface. Foundational for the portal ecosystem.
- **Dependencies:** Stable surface handles already exist for window-management. Mostly wire-up.

### `xwayland-shell-v1`
**Implemented** — `XwaylandShell.swift` (`xwayland_shell_v1` on the router). Original rationale retained below.
- **Scope:** ~200 lines.
- **Apps unblocked:** Properly-associated X11 surfaces under XWayland — fixes the "which wl_surface is this X window?" race that bites stacking order, focus, and decoration policy on busy X11 apps (Steam, JetBrains IDEs, some Java AWT apps).
- **Notes:** Adds an `xwayland_surface_v1.set_serial` request that XWayland uses to bind a wl_surface to an X11 window via a stable serial, replacing the earlier implicit association path in XWM.
- **Dependencies:** Touches XWM in the `Xwayland*.swift` router files (`NucleusCompositorWaylandRuntime/`, e.g. `XwaylandXWM.swift`, `XwaylandSurface.swift`).

### `xwayland-keyboard-grab-unstable-v1`
- **Scope:** ~200 lines.
- **Apps unblocked:** X11 games that capture the keyboard (older Steam titles, RetroArch X11 build, dosbox-x, qemu's X11 UI), X11 remote-desktop clients (TigerVNC viewer, x11vnc, NoMachine) needing to forward modifier combos verbatim, X11 emulators that intercept Alt+Tab / F-keys.
- **Notes:** Despite the name, XWayland *requests* this protocol but the compositor must *advertise* it for X11 grabs to work at all. Without the global, X11 keyboard grabs silently fail and the compositor steals every keystroke. The interaction with native keyboard-shortcuts-inhibit (already in tree) is symmetric — both ask the compositor to stop intercepting shortcuts on the focused surface; this one is the XWayland-side entry point.
- **Dependencies:** Touches XWM in the `Xwayland*.swift` router files (`NucleusCompositorWaylandRuntime/`) and the keyboard-shortcut interception logic that already exists for `keyboard-shortcuts-inhibit-unstable-v1` (in `WlSeat.swift`).

## Sandboxing / identity

### `wp-security-context-v1`
- **Scope:** ~200 lines (the protocol itself; the policy hooks across the compositor are the real work).
- **Apps unblocked:** Flatpak / Snap / Bubblewrap clients identifying themselves as sandboxed. Enables compositor policy like "don't let sandboxed apps create virtual-keyboards" / "limit keyboard-shortcuts-inhibit to native clients" / "screencast portal asks for explicit consent on sandboxed apps even when default is auto-approve."
- **Notes:** The wire is trivial — a single `commit` request that locks in identifying metadata for the client's socket. The leverage is in *what the compositor does with that identity*. V1 = just expose the protocol and store the metadata on the runtime client; policy hooks come as needed.
- **Dependencies:** None on protocol side. Policy side touches multiple subsystems (virtual-keyboard, keyboard-shortcuts-inhibit, portal).

## Specialty hardware

### `drm-lease-v1`
- **Scope:** ~400 lines.
- **Apps unblocked:** VR headsets (Valve Index via Monado, Quest via ALVR), dedicated-display passthrough (some kiosk / signage cases).
- **Notes:** Client requests a "lease" of a specific DRM connector; compositor stops driving that connector and hands the FD to the client which drives it directly. Touches DRM connector lifecycle. Niche but specific — VR users absolutely need it.
- **Dependencies:** Per-connector active/inactive state in `NucleusCompositorRendererLinux/drm/DrmDevice.swift`. Existing hotplug machinery is most of the prerequisite.

### `wlr-output-power-management-unstable-v1`
- **Scope:** ~150 lines.
- **Apps unblocked:** `swayidle`, `hypridle`, `wlopm`, GNOME-style "blank the screen after N minutes of idle" — the canonical laptop power-management path. Without it there is no automatic screen-off-on-idle on a daily-driver laptop.
- **Notes:** Adds a per-output `set_mode(on/off)` request. The "off" path drops the output to DPMS-off via the existing DRM connector control (`NucleusCompositorRendererLinux/drm/DrmDevice.swift`, `DrmOutputPolicy.swift`); the "on" path restores it. Pairs naturally with the already-in-tree `ext-idle-notify-v1` (the daemon listens for idle events and then asks the compositor to power the output off).
- **Dependencies:** Per-connector DPMS control in `NucleusCompositorRendererLinux/drm/DrmDevice.swift` / `DrmOutputPolicy.swift`.

## Color management (future)

### `wp-color-management-v1` (staging)
- **Scope:** Significant — several hundred lines plus rendering pipeline updates.
- **Apps unblocked:** HDR content, wide-gamut content, ICC profile-aware apps.
- **Notes:** Adds image-description / surface-feedback / image-description-creator objects. Compositor needs to track per-surface color spaces and tone-map or color-convert appropriately for the output. **Defer until we want HDR.** Stable spec landed in 2024; ecosystem support is still thin (KDE 6.2+, Mutter 47+). Not blocking apps today.

## Intentionally not in scope

Hard "no" — these are dead, superseded, or test-only. Not part of a daily-driver target.

- `fullscreen-shell-unstable-v1` — superseded by xdg-shell; only used by `weston-simple-*` tests.
- `linux-explicit-synchronization-unstable-v1` — superseded by `linux-drm-syncobj-v1` (in tree). Mesa 24+ uses syncobj exclusively; the old protocol is on its way out.
- `wlr-input-inhibit-manager-unstable-v1` — older "grab all input to one client" protocol superseded by `ext-session-lock-v1` (Batch 4). Modern lockers speak session-lock; legacy ones can fall back to layer-shell exclusivity.
- `weston-*` protocols — test/debug only.
- `xdg-shell-unstable-v5` / `v6` — superseded by stable `xdg-shell`. Every live client has migrated.

## Deferred — implement on demand

These are real protocols with real clients, but the client base is narrow enough that implementing on demand is fine. Each entry names the trigger that should pull it into a batch.

- `input-timestamps-unstable-v1` — niche today, but `gamescope`, SDL3 high-rate-mouse, OBS input pipelines, and OpenXR runtimes use precision input timestamps for prediction. Pull in if VR / game-streaming surfaces become a target. ~100 lines.
- `ext-transient-seat-v1` — used by `waypipe` (Wayland-over-SSH) and some multi-seat / kiosk setups. Pull in if remote-development on Nucleus is a goal.
- `org_kde_kwin_idle` — legacy KDE idle protocol; superseded by `ext-idle-notify-v1` (in tree). A few older KDE apps and older `kdeconnect` builds still ask for it. ~80 lines compatibility shim over the existing idle-notify state. Pull in if a real user hits it.
- `org_kde_kwin_server_decoration` — pre-`xdg-decoration` server-side-decoration protocol. A few KDE apps (older Dolphin, Krita on some channels) still request it. Tiny compatibility shim over the existing decoration state. Pull in if a real user hits it.
- `chrome-color-management-v1` / `frog-color-management-v1` — Chrome-specific and Steam/gamescope-specific predecessors to `wp-color-management-v1`. Skip in favor of the stable protocol unless a specific client refuses to migrate.

## Pairs with another batch

- `color-representation-v1` — describes YUV chroma siting / range / matrix for video buffers. Orthogonal to `wp-color-management-v1`'s gamut/transfer-function work, but the same surface-color pipeline consumes both. Lands with **Batch 9** (color management) so the pipeline can act on the metadata; implementing in isolation has no consumer.

## Implementation order

Recommended batching. Each batch is a coherent chunk that lands together; batches are roughly ordered by impact and inverse complexity.

### Batch 1 — Small wins + laptop power
Total scope: ~700 lines. Self-contained, fast to land, immediately improves day-to-day app experience.

- `alpha-modifier-v1`
- `single-pixel-buffer-v1`
- `xdg-system-bell-v1`
- `xdg-toplevel-icon-v1`
- `content-type-v1`
- `wlr-output-power-management-unstable-v1` — completes the idle / DPMS story alongside the already-in-tree `ext-idle-notify-v1`; unblocks `swayidle` / `hypridle` for laptop screen-off-on-idle

### Batch 2 — Trackpad / tablet / input completion
Total scope: ~750 lines.

- `pointer-gestures-v1` — finishes the trackpad gesture story alongside the pointer-constraints / relative-pointer work already done
- `tablet-v2` — stylus / pad input; XML is already scanned but the module is missing

### Batch 3 — Clipboard ecosystem
Total scope: ~600 lines.

- `primary-selection-unstable-v1` / `wp-primary-selection-v1`
- `wlr-data-control-unstable-v1` + `ext-data-control-v1` — the `ext-` form is **implemented** (`ExtDataControl.swift`); the `wlr-` form and primary-selection remain.

Both touch the existing `DataDevice.swift` module. Co-designed batch.

### Batch 4 — Window-lifecycle polish + session lock + workspaces
Total scope: ~1500 lines.

- `xdg-dialog-v1`
- `xdg-toplevel-drag-v1`
- `xdg-toplevel-tag-v1`
- `xdg-pip-v1`
- `ext-workspace-v1` — **implemented** (`ExtWorkspace.swift`)
- `ext-session-lock-v1` — **implemented** (`SessionLock.swift`)

These all touch the focus / input-routing / WM-policy surfaces. Session-lock and workspaces both mirror WM-authoritative state onto a protocol; PiP and dialog both define floating window roles.

### Batch 5 — Cross-client + sandboxing + XWayland completion
Total scope: ~900 lines.

- `xdg-foreign-v2` — **implemented** (`XdgForeign.swift`)
- `xwayland-shell-v1` — **implemented** (`XwaylandShell.swift`)
- `xwayland-keyboard-grab-unstable-v1`
- `wp-security-context-v1`

All four touch the cross-client identity / XWayland boundary. The two XWayland protocols co-design with the existing XWM; security-context and xdg-foreign are foundational for the portal ecosystem.

### Batch 6 — IME + input synthesis (dedicated session)
Total scope: ~1150 lines.

- `text-input-v3`
- `input-method-v2`
- `virtual-keyboard-unstable-v1`
- `wlr-virtual-pointer-unstable-v1`

Co-design. The biggest single batch — worth doing as its own focused session. The four protocols share the synthetic-input dispatch path; the IME work unblocks every non-English user, the virtual-{keyboard,pointer} work unblocks on-screen keyboards and automation tooling.

### Batch 7 — Specialty + warp
Total scope: ~600 lines.

- `Seat.warpPointer` primitive (synthetic motion, output/transform mapping, constraint clamping)
- `pointer-constraints-unstable-v1` `cursor_position_hint` deactivation fix (consume the shared primitive)
- `pointer-warp-v1`
- `drm-lease-v1`

VR / niche. The warp primitive is the unifying piece — it backs pointer-warp, the pointer-constraints bug fix, and the absolute-motion path of `wlr-virtual-pointer-unstable-v1` from Batch 6 (which calls into the primitive once it exists).

### Batch 8 — Session management (optional)
Total scope: ~300 lines.

- `xdg-session-management-v1`

Defer until window-state persistence is a feature.

### Batch 9 — Color management (future)
Total scope: significant — several hundred lines plus rendering pipeline updates.

- `wp-color-management-v1` (whenever HDR is on the roadmap)
- `color-representation-v1` (lands together — the same surface-color pipeline consumes both; isolated implementation has no consumer)

## Per-protocol notes — implementation patterns to reuse

Every protocol added so far follows the same shape (see `Fifo.swift` or `Idle.swift` in `compositor-core/Sources/NucleusCompositorWaylandRuntime/` as the canonical small-protocol template):

1. A router file under `NucleusCompositorWaylandRuntime/<Protocol>.swift`, with a manager class that owns the request vtables. Coupled protocols share one file (as in `Idle.swift`).
2. Request handlers are `@convention(c)` closures installed into the generated `swift_wayland_<interface>_requests` vtable struct at bring-up.
3. Per-surface state is claimed through the `WlSurface` aux seam — `surface.claimAux(.<name>)` / `surface.releaseAux(.<name>)` — rather than a raw opaque back-pointer.
4. Resource ownership and typed dispatch go through `WaylandResource.create(...)` / `WaylandResource.owner(of:as:)`; protocol errors via `swift_wayland_resource_post_error`.
5. `register(in: router)` calls `router.addGlobal(interface:version:impl:bind:)` to advertise the global(s).
6. All globals are wired from `WaylandRouterRuntime.swift`; per-resource cleanup runs in the owner's `deinit` (releasing any claimed aux state).
7. Focus / activation events hook into the input funnels in `InputDispatch.swift` / the seat driver where relevant.

New protocols slot into these patterns. The work per protocol is mostly mechanical request dispatch + small policy decisions in the per-protocol router file; the framework is already in place.

(Historical note: this plan was originally drafted against the retired Zig compositor — Zig `.zig` modules under `src/compositor/wayland/`, a `build.zig` scanner list, and a `WaylandServer` object. That compositor has been replaced by the Swift runtime described above; the protocol-coverage intent is unchanged.)

## Verification

Per-batch acceptance criteria:

- **Batch 1:** Clients that exercise each protocol (a custom test client for alpha-modifier; mpv with `--alpha-modifier` if it ships support; a terminal that rings the bell; a test client that allocates single-pixel buffers) all work as expected. mpv setting content-type `video` and a game setting `game` are observable in render-server diagnostics and feed into tearing / scanout policy as designed. `swayidle -w timeout 60 'wlopm --off \*' resume 'wlopm --on \*'` blanks every output after 60 seconds idle and restores them on input.
- **Batch 2:** Firefox pinch-to-zoom works on a trackpad inside Nucleus; GTK swipe-to-go-back works in Files / Adwaita demo. Krita pressure curve responds to Wacom stylus pressure and tilt; a pad button bound to a Krita action triggers it.
- **Batch 3:** `wl-clipboard` `wl-paste --watch` sees every selection change; `cliphist` builds a clipboard history; middle-click paste works in terminals and GTK text fields.
- **Batch 4:** GTK file picker shows as modal-styled in Nucleus; Chrome tab tear-out creates a new window correctly inheriting drag state; a client that sets a toplevel tag has the tag visible in window-management diagnostics. `swaylock` and `hyprlock` lock and unlock the session; input is correctly routed only to the lock client while locked, and resumes to the previously-focused surface on unlock. `waybar`'s `wlr/workspaces` and `ironbar`'s `workspaces` module render workspace pips and switch workspaces on click. Firefox PiP popup renders as a floating always-on-top window with snap-to-corner behavior.
- **Batch 5:** Flatpak file picker correctly parents to its caller; a sandboxed client identifies itself via security-context; portal infrastructure can read the identity (even if no policy uses it yet). Steam (XWayland) launches without surface-association races on first map; JetBrains IDEs no longer mis-stack popups. An X11 game that calls `XGrabKeyboard` (RetroArch X11 build, dosbox-x) captures Alt+Tab / F-keys instead of leaking them to the compositor; TigerVNC viewer forwards every modifier combo to the remote session.
- **Batch 6:** fcitx5 + a CJK IME work in Firefox / Chrome / GTK apps / Qt apps; `wvkbd` injects keystrokes via virtual-keyboard; `wtype "hello"` types text into the focused surface; `ydotool mousemove` moves the cursor.
- **Batch 7:** Monado-based SteamVR session can lease a Vive / Index headset; `xdotool`-equivalent Wayland tool warps the cursor successfully. Locked-pointer unlock correctly warps the cursor to the previously-set `cursor_position_hint` (regression test for the latent bug); a `wlr-virtual-pointer` client emitting absolute motion lands the cursor at the right global coordinates.
- **Batch 8:** A test app remembers its position across restarts.
- **Batch 9:** Acceptance criteria defined when HDR / wide-gamut work is scheduled. Minimum bar: an HDR-aware client (gamescope, mpv with `--vo=gpu-next --target-trc=pq`) reports the correct surface color description and the compositor honors it through to scanout on an HDR-capable display. A YUV video buffer with non-default chroma siting / range (via `color-representation-v1`) is sampled correctly in the render pass.

System-level once batches 1–6 land: pick a random sample of 20 Wayland-native apps from `flathub`, install them in a Flatpak runtime, verify each launches and core functionality works inside Nucleus. The expected failure mode shrinks to "this specific app has a Nucleus-specific quirk to investigate," not "Wayland protocol X isn't implemented."
