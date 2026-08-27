# Shell Architecture — a shell-agnostic compositor

## Invariant

The Nucleus compositor is a **shell-agnostic Wayland host**. It serves the standard
protocols a desktop shell needs and draws **no desktop shell chrome of its own**. Any
conformant shell drives it over the wire — third-party (Noctalia, DankMaterialShell) or the
first-party **Nucleus shell** (`nucleus-shell`) — and no shell is privileged in the
compositor. `nucleus-shell` is the installed default. The compositor's job is to serve the
protocols and to expose window / workspace / output / capture state through them; the
**shell** owns the bar, dock, launcher, notifications, control center, OSDs, lock screen,
wallpaper, and tray.

Two consequences follow:

- **One desktop model.** `NucleusCompositorServer` is the single authoritative, observable
  model of desktop state — the live windows (`WindowList`), their metadata and state
  (`Window`), the workspaces (`Spaces`), focus, and outputs. Every external-shell protocol
  router is a *thin projection* over it: on bind it snapshots the model and replays it as
  synthetic "added" events, then streams the model's per-frame change log; inbound requests
  route back through the model's one action API. No projection keeps a parallel copy of
  window/workspace state, and no action bypasses that single funnel. The compositor's own
  keybinds drive the same model, so there is never a second source of truth.

- **The compositor draws only its own UI.** It may draw UI for actions/state that no
  external shell can know about — the window right-click menu (`xdg show_window_menu`, part
  of server-side decorations), compositor-action feedback (e.g. "screenshot saved"), and the
  hotkey / effect bezel. It draws **no** bar, dock, launcher, global application menu bar,
  app notifications, or volume/brightness OSD — those belong to the shell, over the relevant
  protocols.

## What every shell speaks

The compositor serves one protocol set that third-party shells and `nucleus-shell` consume
identically — there is no Nucleus-private shell protocol. Already served: `wl_compositor` /
`wl_shm` / `wl_output`, `xdg-output`, `xdg-shell`, `wlr-layer-shell`, `ext-idle-notify` +
`idle-inhibit`, `wlr-gamma-control`, `ext-background-effect`, `viewporter` +
`fractional-scale`, `xdg-activation`, `cursor-shape`. Plus the management surface the desktop
model projects: `zwlr_foreign_toplevel_management_v1` (taskbar / window list), `ext_workspace_v1`
(workspaces), `wlr-screencopy` (screenshots / recording / blur), `ext_session_lock_v1` (lock
screen), and `data-control` (clipboard history). Lock-screen password entry
(`zwp_virtual_keyboard_v1` / `zwp_text_input_v3`) is still pending — see
`docs/wayland_protocol_coverage_plan.md` for the authoritative protocol status.

## The shell process

`nucleus-session` constructs the isolated login environment and delegates both
native children to `nucleus-session-supervisor`. The launcher creates one
validated, immutable session configuration and the supervisor sends the same
binary record to each child over a private inherited descriptor. Runtime policy
does not come from ambient `NUCLEUS_*` strings.

The supervisor launches the shell only after the compositor completes a real
KMS presentation. Shell readiness means every live output has configured
wallpaper and bar surfaces and accepted a frame after the wallpaper image became
GPU-resident. A bounded startup deadline turns a stalled child into a typed
failure. Either sibling exiting retires both process groups, so a partially
alive desktop is never considered a session. The compositor remains
shell-agnostic: it serves standard Wayland protocols and never invokes a shell
command line. Window-management and system keybinds (tile, VT switch, exit)
stay compositor-owned.

The shell retains one shared scene and render device, but every Wayland
presentation surface selects the exact window root returned by scene
publication. Wallpaper, bar, lock, and future panel swapchains therefore cannot
sample one another merely because their rectangles overlap. Asynchronous image
residency is also presentation state: when a decoded image becomes GPU-resident,
each consuming output repaints its accumulator before acknowledging that
resource generation.

## The global application menu bar — not in the compositor

A macOS-style global menu bar is shell chrome, so it does not live in the compositor. The
in-process menu bar (`ShellOverlayMenuBarView` and its `org_kde_kwin_appmenu` → dbusmenu →
menubar model chain) has been **removed**. The compositor keeps only the
`org_kde_kwin_appmenu` Wayland global as a **served-but-dormant relay**, so apps still export
their menu address; nothing in the compositor consumes it. If a shell wants to draw the
global menu, exposing the per-window appmenu D-Bus address to shell clients (a new
`ext`/`foreign` surface carrying it) is a future *additive* feature — not compositor chrome.

## What the compositor keeps drawing

`NucleusCompositorOverlay` renders three compositor-owned surfaces, none of which are shell
chrome:

- **the window right-click menu** (`show_window_menu`) — server-side-decoration UI the
  compositor owns;
- **compositor-action notifications** — screenshot saved/failed and thumbnails; the
  compositor connects to the notification bus but **never claims
  `org.freedesktop.Notifications`** (the shell owns the notification daemon), so this path
  only ever shows the compositor's own action feedback;
- **the hotkey overlay** — a reference sheet for the compositor's own keybinds, toggled by a
  hotkey; compositor state no external shell can see.

The compositor draws **no wallpaper**. Like niri, the desktop background is a `wlr-layer-shell`
BACKGROUND surface a shell client provides (Noctalia / swaybg / `nucleus-shell`), rendered
beneath windows. With no such surface present the compositor shows a solid backdrop (an opaque
per-frame clear), never a compositor-owned wallpaper.

## Status

The model-and-projection architecture is shipped: `NucleusCompositorServer` is the one model;
foreign-toplevel and ext-workspace project it; screencopy, session-lock, and data-control are
served; the installed session launches the native `nucleus-shell`, whose bar and lock surfaces
use the same public protocol set as third-party shells. The global menu bar removal (above) is
done. Remaining shell-facing work is protocol coverage and broader product parity.
