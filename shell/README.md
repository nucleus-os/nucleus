# NucleusShell

The first-party Nucleus desktop shell: an out-of-process Wayland layer-shell
client written in Swift against `NucleusUI`.

`NucleusShell` owns native bar and lock-screen windows, presents them through
the shared Skia Graphite/Vulkan renderer, and drives compositor state over
standard protocols including `wlr-layer-shell`,
`wlr-foreign-toplevel-management`, `ext-session-lock`, and
`wlr-screencopy`. It has no build-time relationship with the compositor and no
React Native, Hermes, Fabric, Yoga, or JavaScript runtime dependency.

## Package layout

| Target | Responsibility |
|---|---|
| `NucleusShellProduct` | Native Swift views, typed product state, and product composition using public `NucleusUI`. |
| `NucleusWindowClientWayland` | Public desktop Wayland connection and surface protocol implementation. |
| `NucleusWindowClientRender` | DMA-BUF backing-store presenters backed by the shared render core. |
| `NucleusWindowClientInput` | Wayland input and text-input translation into NucleusUI events. |
| `NucleusShellServices` | Typed Linux service projections such as UPower. |
| `NucleusShellRuntime` | Native surface registry, application lifecycle, services, and demand-driven reactor. |
| `NucleusShell` | Thin executable composition entry point. |
| `NucleusShellPamHelper` | Isolated PAM authentication helper used by the native lock screen. |

## Build

From the monorepo root:

```sh
collider bootstrap shell

source tools/host-env.sh
swift build --package-path shell
```

The shell consumes the render SDK provisioned by `core/`. A shell-only
bootstrap does not provision the React Native SDK or build JavaScript bundles.

## Install

Install the complete compositor session into one shared prefix:

```sh
collider install session
```

This publishes one relocatable runtime generation under `.install/`: public
executables in `bin/`, first-party frameworks and the Swift runtime closure in
`lib/`, and session services plus `NucleusShellPamHelper` in `libexec/`. Use
`--prefix DIR` to choose another location.

## Run

In a Nucleus session, `NucleusShell` connects through the ordinary
`WAYLAND_DISPLAY` selected by `nucleus-session`. The compositor does not track
or authenticate a shell client identity. The supervisor gives each shell
generation a private typed policy channel for accepted shortcuts and Nucleus
semantics without a standard Wayland vocabulary.

For development against another conformant compositor:

```sh
WAYLAND_DISPLAY=wayland-1 \
  shell/.build/out/Products/Debug-linux-x86_64/NucleusShell
```

The runtime creates one native bar per output, maps each Wayland surface to a
NucleusUI `Window`, and publishes the shared `WindowScene` only when state,
input, animation, service data, or a presentation deadline requires a frame.

## Directory layout

```text
Package.swift                  Launch-only executable and PAM helper
auth-wire/                     PAM helper wire contract
shell-kit/
  Sources/NucleusShellProduct/ Native product views and typed state
  Sources/NucleusShellServices/Discovery, launcher, notifications, policy
  Sources/NucleusShellRuntime/ Process composition and shell-owned surfaces
```
