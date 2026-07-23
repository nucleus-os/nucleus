# nucleus-compositor

The Nucleus **Wayland/DRM compositor** — the Linux OS substrate, DRM renderer backend, window/seat policy, shell overlay, and the `NucleusCompositor` executable.

It consumes the monorepo's [`core/`](../core) and
[`platform-linux/`](../platform-linux) packages plus the provisioned render
native SDK (Skia Graphite). It links **zero React**: the shell is an
out-of-process layer-shell client, so the compositor has no build-time
dependency on React Native.

## Component layout

This component contains two SwiftPM packages:

### `compositor-core/` — The library package

The Linux OS substrate and compositor policy modules. Tested via `swift test` (no `swift-system` dependency, so it tolerates the global C++-interop flag SwiftPM's test runner needs).

| Target | Description |
|---|---|
| `NucleusCompositorServerTypes` | Shared value types for the compositor server. |
| `NucleusCompositorOverlayTypes` | Shared value types for the shell overlay. |
| `NucleusCompositorServer` | Wayland server logic — connection handling, resource lifecycle. |
| `NucleusCompositorWindowManager` | Window/seat policy — surface ordering, focus, stacking. |
| `NucleusCompositorWindowScene` | Per-window render scene — ties Wayland surfaces to the Nucleus render tree. |
| `NucleusCompositorOverlay` | Shell overlay UI — built with the NucleusUI design system. |
| `NucleusCompositorOverlayScene` | Overlay render scene — composites overlay + managed windows. |
| `NucleusCompositorShell` | Shell integration — desktop application index, systemd, overlay routing. |
| `NucleusCompositorWaylandRuntime` | Wayland substrate runtime — server dispatch, xcb property handling, input (libinput/udev/seat). |
| `NucleusCompositorRendererLinux` | DRM/KMS renderer backend — GBM buffers, page-flip, CRTC/connector/encoder setup. |
| `NucleusCompositorRenderRuntime` | Render runtime facade — ties the DRM backend to the Nucleus renderer. |
| `NucleusCompositorDrmC` | libdrm/GBM C façade (systemLibrary). |
| `NucleusCompositorXcbC` | xcb C façade (systemLibrary). |
| `NucleusCompositorInputC` | libinput/udev C façade (systemLibrary). |

Linux D-Bus transport and AT-SPI export are shared with the out-of-process
shell through `NucleusLinuxDBus` and `NucleusLinuxAccessibility`; compositor
targets do not import libsystemd directly.

### `compositor/` — The executable package

The `NucleusCompositor` binary and composition root. Lives in a separate package because `swift-system` is C-interop-only and cannot tolerate the global C++-interop flag that `swift test` applies.

| Target | Description |
|---|---|
| `NucleusCompositorRuntime` | Main-actor composition root — awaitable shared Linux reactor, readiness dispatch, `CompositorBringup`, and ordered teardown. |
| `NucleusCompositorRenderSession` | DRM primary-node device session — owns the DRM primary fd, seat open/close injection, session generation for page-flip poll tokens. |
| `NucleusCompositor` | The executable — links the full Swift graph + text backend + Skia + libdrm/gbm + wayland-server + xcb/input/seat/udev/xkb + vulkan + fontconfig/freetype. |

## Build

The primary development path uses the host toolchain and system libraries:

```sh
tools/collider doctor runtime
tools/collider bootstrap
tools/collider build
```

Collider does not mutate the host package database. When a required system
dependency is absent, it reports the missing dependency so the user can install
it explicitly.

First-party dependencies use monorepo-relative paths. Independently released bindings such
as `swift-wayland` remain pinned package dependencies.

`bootstrap` delegates render-SDK provisioning to `../core`; the compositor does not
encode Skia build steps.

The lower-level commands remain available:

```sh
# From the monorepo root
tools/collider bootstrap compositor

# Rebuild
swift build --package-path compositor-core
swift build --package-path compositor

# Install the complete compositor + native shell session into one prefix
tools/collider install session
```

The root workspace CLI provisions the render SDK through `core/`, then builds
both compositor packages directly through SwiftPM. Their underlying build
systems own incremental rebuild state.

## Tests

```sh
bash -c 'swift test --package-path compositor-core \
  -Xswiftc -cxx-interoperability-mode=default \
  $(pkg-config --cflags-only-I xcb-ewmh | sed "s/-I/-Xcc -I/g")'
```

`compositor-core` holds the tests. The trailing `pkg-config`/`-Xcc` expansion is required because SwiftPM's synthesized test runner inherits neither the test target's `-Xcc` include flags nor the `XcbC` systemLibrary's `pkgConfig` cflags.

Notable test targets:
- `NucleusCompositorRendererLinuxTests` — Links the full renderer closure end to end.
- `NucleusCompositorWaylandRuntimeTests` — Wire-level protocol conformance over the in-process WaylandTestClient harness.
- `NucleusCompositorOverlayTests` — Shell overlay runtime behavior (covers `NucleusCompositorOverlay`, links NucleusUI + text backend + Skia).
- `NucleusCompositorWindowSceneTests` — Compositor-root self-hosting topology.

## Run

```sh
# From a free virtual terminal or display-manager session
tools/collider run
tools/collider run --seconds 20
tools/collider run --scale 1.25
```

The command incrementally builds and stages the compositor, native shell, PAM
helper, and session launcher before starting the complete private-bus session.
`--seconds N` cleanly stops any ordinary, profiled, sanitized, validation, or
Valgrind run after the requested duration.
`--scale N` sets the positive fractional output scale for every connected
display and applies to every run mode.
The compositor serves the standard Wayland compositor protocols plus extension
protocols (`wlr-layer-shell`, `wlr-foreign-toplevel-management`,
`ext-session-lock`, `wlr-screencopy`). Any layer-shell client can connect.

On multi-GPU hosts, startup selects the unique GPU driving a connected display,
then uses the PCI boot-VGA hint as a tie-breaker. Use
`tools/collider run --drm-device /dev/dri/renderD…` only when multiple display
GPUs remain genuinely ambiguous or an explicit device is required.

## Profile

```sh
tools/collider run --tracy --seconds 20
```

Run from a free virtual terminal or a display-manager session.
Nucleus uses DRM directly and cannot launch inside an existing Wayland/X11
desktop session that already owns the seat.

The first Tracy run builds the capture and CSV tools from the exact revision
recorded by the resolved `swift-tracy` package. Captures and summaries are
written under `profiles/` by default.
Captures wait for the native compositor-and-shell readiness protocol and fail
when bring-up stalls, either required process exits, or a Tracy-enabled
run contains no events or plots. The retained profile directory contains the
receiver log and a `nucleus_drm.log` symlink to the unified run log for
diagnosis. Every invocation writes the build and complete compositor/shell
session stream to a timestamped file under the workspace `logs/` directory;
`logs/latest` points to the newest run.

The same runtime entry point owns the other launch-time diagnostics:

```sh
tools/collider run --sanitize address
tools/collider run --sanitize undefined
tools/collider run --sanitize thread
tools/collider run --vk-validation
tools/collider run --valgrind
```
