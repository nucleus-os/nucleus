# Nucleus Session Contract

## Invariant

Every process launched by Nucleus must resolve session-scoped Linux
coordinates to the Nucleus session, not to the parent desktop session. The
compositor consumes this environment; the launcher or user unit constructs it.

This keeps singleton applications from redirecting a Nucleus launch request to
an already-running parent-session instance before the process ever connects to
Nucleus's Wayland socket.

## Required Environment

| Key | Owner | Contract |
| --- | --- | --- |
| `XDG_RUNTIME_DIR` | Launcher/unit | Points at a Nucleus-private runtime directory under the user's runtime root. The compositor places its Wayland socket in this directory. |
| `WAYLAND_DISPLAY` | Compositor | Set after `runtimeListenAuto` chooses the socket name. Nucleus-launched children inherit it. |
| `WAYLAND_SOCKET` | Compositor child handoff only | Unset for normal launched clients unless a privileged protocol child is handed a preconnected fd. |
| `DISPLAY` | XWayland manager | Set only after the XWayland display slot is reserved. |
| `XAUTHORITY` | Launcher/unit | Cleared unless a future XWayland authority file is intentionally generated for the Nucleus session. |
| `DBUS_SESSION_BUS_ADDRESS` | Launcher/unit | Points at the Nucleus-private session bus. Sharing the parent user bus breaks the session-isolation invariant. |
| `DBUS_STARTER_ADDRESS` | Launcher/unit | Cleared for launched children unless a D-Bus activation child specifically needs it. |
| `DBUS_STARTER_BUS_TYPE` | Launcher/unit | Cleared for launched children unless a D-Bus activation child specifically needs it. |
| `XDG_CONFIG_HOME` | Launcher/unit | Points at the Nucleus app config root. |
| `XDG_DATA_HOME` | Launcher/unit | Points at the Nucleus app data root. |
| `XDG_STATE_HOME` | Launcher/unit | Points at the Nucleus app state root. |
| `XDG_CACHE_HOME` | Launcher/unit | Points at the Nucleus app cache root. |
| `GIT_CONFIG_GLOBAL` | Launcher/unit | Preserved when already set. Otherwise points at the live parent global git config when that file exists, preferring `$HOME/.config/git/config` and falling back to `$HOME/.gitconfig`. |
| `PIPEWIRE_RUNTIME_DIR` | Launcher/unit | Cleared first, then set to the parent runtime directory only when the parent PipeWire socket exists. |
| `PIPEWIRE_REMOTE` | Launcher/unit | Cleared first, then set when PipeWire is shared. Existing parent value is preserved; otherwise defaults to `pipewire-0`. |
| `PULSE_SERVER` | Launcher/unit | Cleared first, then set when the parent PulseAudio-compatible socket exists. Existing parent value is preserved; otherwise defaults to the parent runtime socket. |
| `XDG_SESSION_TYPE` | Launcher/unit/compositor | `wayland` for Nucleus compositor sessions. |
| `XDG_CURRENT_DESKTOP` | Launcher/unit | `Nucleus:Wayland`. |
| `XDG_SESSION_DESKTOP` | Launcher/unit | `Nucleus`. |
| `DESKTOP_SESSION` | Launcher/unit | `Nucleus`. |

`NUCLEUS_SESSION_ID` identifies the launcher/session-manager instance.
`NUCLEUS_SESSION_RUNTIME_DIR` mirrors the canonical Nucleus runtime directory
after validation. Launched app commands may not override either value.

`XDG_RUNTIME_DIR` must be an absolute, non-root, existing, non-symlink parent
runtime directory. The Nucleus runtime directory must live directly under that
parent, must use a basename beginning with `nucleus-` and a non-empty id
suffix, must not be a symlink, and must not be an existing non-directory path.
`NUCLEUS_SESSION_ID` must be non-empty and must not contain `/`.

Explicitly set session-control paths are validated as supplied. An empty
`NUCLEUS_SESSION_ID`, `NUCLEUS_SESSION_RUNTIME_DIR`, or
`NUCLEUS_SESSION_STATE_ROOT` is invalid rather than being treated as unset.

When `NUCLEUS_SESSION_RUNTIME_DIR` is set, the launcher treats that directory as
externally owned. It must already exist, and the launcher leaves it in place.
This is the systemd `RuntimeDirectory=` path. If `NUCLEUS_SESSION_ID` is also
set, it must match the runtime basename after the `nucleus-` prefix. If only
`NUCLEUS_SESSION_RUNTIME_DIR` is set, the launcher derives `NUCLEUS_SESSION_ID`
from that basename. When it is not set, the launcher
owns the default `$XDG_RUNTIME_DIR/nucleus-$NUCLEUS_SESSION_ID` path, removes
any stale directory there before startup, and removes the recreated directory on
exit.

`HOME` must be an absolute non-root path. Nucleus intentionally shares user
home files rather than substituting a synthetic home directory.

`NUCLEUS_SESSION_STATE_ROOT`, when set, must be absolute, must not be `$HOME`
or `/`, must not be a symlink, and must not be an existing non-directory path.
The selected XDG root, including the default `$HOME/.config-nucleus`, must not
be a symlink or an existing non-directory path. The child XDG roots below it
must be real directories, not symlinks.

## Ownership Boundary

The launcher or user unit owns:

- creating the private runtime directory
- starting or selecting the private session bus
- creating persistent or ephemeral XDG roots
- passing parent audio service coordinates through explicit service env vars
- passing live parent git configuration through `GIT_CONFIG_GLOBAL`
- clearing inherited parent display and bus starter variables
- clearing stale inherited PipeWire/Pulse coordinates when the matching parent
  socket is absent
- stripping launched app command wrappers, such as `/usr/bin/env -i`,
  `/usr/bin/env -S`, or inline assignments, that would clear or override
  session coordinates
- protecting Nucleus session control variables such as `NUCLEUS_SESSION_ID`
  and `NUCLEUS_SESSION_RUNTIME_DIR` from launched app command overrides

The compositor owns:

- binding its Wayland socket inside `XDG_RUNTIME_DIR`
- setting `WAYLAND_DISPLAY` after the socket name is known
- setting `DISPLAY` through the XWayland manager
- running compositor-owned protocol infrastructure such as XWayland
- validating that a launcher-provided `XDG_RUNTIME_DIR` is an existing
  `nucleus-<id>` directory and matches `NUCLEUS_SESSION_RUNTIME_DIR` /
  `NUCLEUS_SESSION_ID` when those variables are present

The compositor does not own launcher/session-manager policy. The installed
launcher and native supervisor are the production session entrypoint.

Runtime policy is a versioned `SessionConfiguration` created by
`tools/collider run`, forwarded through `nucleus-session`, and inherited by both
native children from a supervisor-owned descriptor. Scale, present policy, DRM
selection, Vulkan validation, diagnostics, and wallpaper selection are members
of that one record. The environment remains responsible only for standard
process/session coordinates such as XDG paths, D-Bus, Wayland, PipeWire, and
sanitizer runtime variables.

The native supervisor publishes typed readiness. Compositor readiness follows
the first physical KMS presentation; shell readiness follows a GPU-resident
wallpaper and accepted wallpaper/bar presentation on every live output. Startup
is bounded, and either required sibling exiting terminates the other process
group.

## Modes

The default production mode is isolated:

- private runtime directory
- private session bus
- Nucleus XDG roots
- shared parent PipeWire/Pulse services through explicit env vars
- shared `$HOME`

An integration mode may intentionally share the parent session bus for
debugging parent desktop services, but it is not the default Nucleus app-launch
model and must be opt-in.

## Verification

A valid session proves these checks inside a Nucleus-launched terminal:

```sh
nucleus-session-validate
```

End-to-end verification requires a parent-session singleton app to already be
running, then launching the same app from Nucleus and confirming that the new
window appears in Nucleus instead of being forwarded to the parent session.
