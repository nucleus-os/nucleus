# nucleus-shell

The first-party Nucleus **desktop shell** — an out-of-process Wayland layer-shell client built as a React Native app.

`nucleus-shell` is a normal Wayland client: it draws its own surfaces (bar, dock, launcher, notifications, …) with the Nucleus render core (Skia/Vulkan) onto client-owned `wl_surface`s, and drives windows over **standard protocols** — `wlr-layer-shell`, `wlr-foreign-toplevel-management`, `ext-session-lock`, `wlr-screencopy`. It has **no build-time relationship** with the compositor: the two meet only at runtime over those protocols. The compositor is swappable under the shell, and the shell is swappable under the compositor.

Where the compositor is a Wayland **server** over DRM/KMS, the shell is a Wayland **client** over the WSI swapchain — it binds the same protocols on the client side and presents the render core's output onto client surfaces via `VK_KHR_wayland_surface`.

## Package layout

| Target | Description |
|---|---|
| `NucleusShellWayland` | Swift Wayland client — connection, registry, layer-shell / foreign-toplevel / session-lock / screencopy client drivers. |
| `NucleusShellRender` | Client render backend — `VK_KHR_wayland_surface` Vulkan swapchain presenting the render core's output onto each client `wl_surface`. Models the Android WSI presenter on `wl_display`/`wl_surface`. |
| `NucleusShellRuntime` | App host — boots the RN runtime, installs the shell native modules (layer-shell, foreign-toplevel, session-lock, screencopy), wires the RN-produced layer tree to the render backend, drives the frame loop off the `wl_display` fd. |
| `NucleusShell` | The executable — links the full Swift graph + text backend + RN runtime (static) + Skia + wayland-client + Vulkan + ICU. |
| `BuildShellBundle` | Plugin — Metro → Hermes bytecode for the shell's RN components. |

The shell consumes the monorepo's `../core` and `../react-native` packages directly.

## Build

```sh
# From the monorepo root
tools/nucleus bootstrap shell

# Rebuild from the monorepo root
source core/tools/host-env.sh
swift build --package-path shell

# Wayland bindings are pre-generated and supplied by swift-wayland.

# Bundle the RN app from the monorepo root
swift package --package-path shell build-shell-bundle --allow-writing-to-package-directory
```

The workspace bootstrap provisions both native SDKs, builds the shell, and creates the JS bundle.

The manifest resolves `swift-wayland` from its pinned Git dependency.

## Run

`nucleus-shell` connects to the compositor named by `WAYLAND_DISPLAY`. Under a running `nucleus-compositor` (or any compositor serving the shell-facing protocols), launch it as an ordinary client:

```sh
WAYLAND_DISPLAY=wayland-1 ./.build/out/Products/Debug-linux-x86_64/NucleusShell
```

The event loop is `wl_display` fd + a frame timer (poll-based, in Glibc) — no `swift-system` dependency.

## JS app

The shell's React Native components (bar, dock, etc.) and Metro/bundle config live under `js/`. The bundled Hermes bytecode is produced by the `BuildShellBundle` plugin into `.rn-build/bundles/`.

## Directory layout

```
Sources/NucleusShellWayland/    Swift Wayland client module
Sources/NucleusShellRender/     Client render backend (VK_WSI)
Sources/NucleusShellRuntime/    App host + frame loop
Sources/NucleusShell/           Executable entry point
js/                             RN app (components, Metro config)
Plugins/BuildShellBundle/       Metro → hermesc bundle plugin
tools/                          Bootstrap script
docs/                           Shell-specific documentation
```
