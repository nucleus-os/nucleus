# nucleus-shell

The first-party Nucleus desktop shell: an out-of-process Wayland layer-shell
client written in Swift against `NucleusUI`.

`nucleus-shell` owns native bar and lock-screen windows, presents them through
the shared Skia Graphite/Vulkan renderer, and drives compositor state over
standard protocols including `wlr-layer-shell`,
`wlr-foreign-toplevel-management`, `ext-session-lock`, and
`wlr-screencopy`. It has no build-time relationship with the compositor and no
React Native, Hermes, Fabric, Yoga, or JavaScript runtime dependency.

## Package layout

| Target | Responsibility |
|---|---|
| `NucleusShellProduct` | Native Swift views, typed product state, and product composition using public `NucleusUI`. |
| `NucleusShellWayland` | Wayland connection and shell protocol clients. |
| `NucleusShellRender` | `VK_KHR_wayland_surface` presenters backed by the shared render core. |
| `NucleusShellInput` | Wayland input and text-input translation into NucleusUI events. |
| `NucleusShellServices` | Typed Linux service projections such as UPower. |
| `NucleusShellRuntime` | Native surface registry, application lifecycle, services, and demand-driven reactor. |
| `NucleusShell` | Thin executable composition entry point. |
| `NucleusShellPamHelper` | Isolated PAM authentication helper used by the native lock screen. |

## Build

From the monorepo root:

```sh
tools/nucleus bootstrap shell

source core/tools/host-env.sh
swift build --package-path shell
```

The shell consumes the render SDK provisioned by `core/`. A shell-only
bootstrap does not provision the React Native SDK or build JavaScript bundles.

## Install

Install the complete compositor session into one shared prefix:

```sh
tools/nucleus install session
```

This writes the compositor, session launchers, native shell, and
`nucleus-pam-helper` to `.install/`. Use `--prefix DIR` to choose another
location. `tools/nucleus install shell` installs only the two shell executables.

## Run

`nucleus-shell` connects to the compositor named by `WAYLAND_DISPLAY`. The
Nucleus compositor starts the installed shell automatically; a development
binary is launched and supervised as a required peer by `nucleus-session`.

Against any already-running conformant compositor:

```sh
WAYLAND_DISPLAY=wayland-1 \
  shell/.build/out/Products/Debug-linux-x86_64/NucleusShell
```

The runtime creates one native bar per output, maps each Wayland surface to a
NucleusUI `Window`, and publishes the shared `WindowScene` only when state,
input, animation, service data, or a presentation deadline requires a frame.

## Directory layout

```text
Sources/NucleusShellProduct/   Native product views and typed state
Sources/NucleusShellWayland/   Wayland client and shell protocols
Sources/NucleusShellRender/    Vulkan WSI presentation
Sources/NucleusShellInput/     NucleusUI input adapters
Sources/NucleusShellServices/  Linux service projections
Sources/NucleusShellRuntime/   Native application/surface host
Sources/NucleusShell/          Executable entry point
```
