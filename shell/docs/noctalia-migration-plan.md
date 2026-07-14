# Noctalia-to-Nucleus Shell Migration Plan

## Invariant

`nucleus-shell` replaces Noctalia as an out-of-process Wayland shell built on the Nucleus
render and React Native platforms. Swift owns platform integration, authoritative desktop
state, security-sensitive behavior, native resources, and process lifecycle. React Native
owns product UI, layout, visual styling, panel composition, settings, and widgets. The shell
continues to communicate with any conformant compositor exclusively through standard Wayland
protocols and shell IPC.

This is a replacement implementation, not a source translation. Noctalia remains the
behavioral specification and production shell until the Nucleus shell reaches functional and
runtime parity. Its C++ scene graph and UI controls do not move into Swift. NucleusUI,
NucleusLayers, Fabric, Skia Graphite, and the Vulkan presentation stack replace them.

## Target architecture

```text
React Native / Fabric
  bar, panels, settings, launcher, media cards, notifications
                    │
          generated typed native modules
                    │
Swift shell services and state
  D-Bus, MPRIS, PipeWire, config, IPC, process management
                    │
          Nucleus shell platform
  Wayland clients, Vulkan/Skia, input, surfaces, frame scheduling
```

The boundary is established at the start and remains stable:

- Swift owns Wayland objects, D-Bus names, PipeWire connections, authentication, configuration
  persistence, subprocesses, native buffers, CEF, and long-lived service state.
- React Native consumes immutable state snapshots and sends typed commands. Restarting Hermes
  does not lose notification ownership, media discovery, session state, or native resources.
- NucleusUI remains the native view and layer substrate used by Fabric.
- Specialized native Fabric components present resources that do not fit ordinary React Native
  primitives, including CEF external textures, screenshot previews, and audio visualizations.
- Credential handling and emergency UI remain entirely native.

## Existing foundation

Nucleus already provides the destination platform's core pieces:

- `NucleusShellWayland` connects as a Wayland client and implements the initial layer-shell,
  foreign-toplevel, session-lock, and screencopy clients.
- `NucleusShellRender` presents multiple client-owned surfaces through Vulkan WSI and the shared
  Nucleus Skia Graphite renderer.
- `NucleusShellRuntime` installs the render host, boots Hermes and Fabric, attaches a React surface,
  forwards window state, and drives the Wayland/frame loop.
- `NucleusReactRuntime` supplies Hermes, Fabric, Yoga, JSI, native module registration, events, and
  the Swift-to-C++ runtime seam.
- `NucleusUI`, `NucleusLayers`, `NucleusRenderHost`, and `NucleusRenderer` supply retained UI state,
  transactions, resource hosting, text, images, effects, animation primitives, and rendering.
- The bar vertical slice proves the complete Wayland → Swift → Fabric → retained layers → Skia →
  Vulkan → Wayland presentation path.

The current shell is still a vertical slice. Its host is bar-specific, its screencopy path is
scaffolded, and most desktop services and product surfaces do not exist yet. Noctalia contains
substantial behavior across rendering, shell surfaces, UI controls, services, configuration,
compositor adapters, and system integration. The migration therefore grows the existing Nucleus
shell rather than introducing another shell package.

## Subsystem mapping

| Noctalia subsystem | Nucleus destination | Required work |
|---|---|---|
| GLES scene renderer | NucleusRenderer + Skia Graphite + Vulkan WSI | Use the existing renderer; complete shell scheduling and surface lifecycle |
| Custom UI controls | React Native/Fabric | Rebuild product UI as React components and native Fabric components |
| Layer-shell panels | NucleusShellWayland + generalized surface host | Generalize the bar-only host into multi-output, multi-role surfaces |
| Window/taskbar state | ForeignToplevelManager | Complete state projection, actions, icons, and lifecycle behavior |
| Workspaces | ext-workspace client | Add the shell-side client and observable workspace model |
| Session lock | SessionLockClient | Complete per-output surfaces, input, authentication, and lifecycle |
| Screenshots | ScreencopyClient | Complete buffer negotiation, import, selection UI, saving, and feedback |
| Animations | Fabric animation backend + NucleusLayers | Complete presentation-driven frame scheduling |
| Text and images | Nucleus text and resource hosts | Integrate loading, caching, SVG/raster decoding, and shell icon lookup |
| D-Bus integrations | Swift service modules with narrow C shims where necessary | Rebuild service discovery, exported interfaces, and object-manager observation |
| Configuration | Swift typed schema and store | Add persistence, validation, migrations, live reload, and RN settings bindings |
| CEF | CEF C/C++ SwiftPM target + native Fabric component | Add C ABI, Vulkan external-memory import, synchronization, input, and lifecycle |

## Native service inventory

The following behavior is rebuilt as Swift services with typed observable models:

- D-Bus connection management, exported objects, name ownership, properties, signals, and object
  manager observation.
- Notification daemon ownership, persistence, grouping, actions, filtering, and history.
- StatusNotifierItem, system tray, dbusmenu, and icon resolution.
- MPRIS discovery, metadata, playback state, controls, album art, and player selection.
- PipeWire and WirePlumber audio devices, streams, volume, mute, default-node selection, and audio
  visualization input.
- NetworkManager, BlueZ, UPower, power profiles, logind, brightness, and gamma/night-light.
- Polkit authentication agent and secure credential prompts.
- Desktop-file indexing, application launching, fuzzy search, recent use, and icon lookup.
- Clipboard history through data-control and secure selection handling.
- Configuration schema, persistence, migration, live reload, theme data, and widget/panel layout.
- Shell IPC, panel commands, compositor keybind integration, and process supervision.
- Wallpaper, output configuration, weather, calendar, HTTP, hardware telemetry, and hooks.

Services do not import React Native C++ modules. The runtime installs closures or protocol
conformers across the established non-C++ boundary, carrying only Swift values, opaque handles,
and scalars. Generated native module specifications define the JavaScript-facing API.

## Native presentation exceptions

Most visual components begin in React Native. Building them first as native Swift views and later
rewriting them in React Native creates a second migration and is not part of this plan.

Native presentation remains appropriate for:

- lock-screen authentication and credential entry;
- startup and failure UI required before Hermes is available;
- CEF external-image presentation and input routing;
- capture/selection overlays coupled directly to compositor frame state;
- performance-critical canvases such as audio visualizers;
- primitives that require resource types Fabric cannot otherwise express.

Each reusable native visual is exposed as a Fabric component rather than composed through an
untyped command channel.

## Phase 1 — General shell host

Replace the bar-specific composition root with a reusable multi-surface application host.

- Introduce a surface registry owning bars, backgrounds, docks, floating panels, overlays,
  notifications, lock surfaces, and per-output instances.
- Give every shell surface an independent Wayland role, Fabric surface ID, root view, dimensions,
  scale, focus state, visibility state, and render presenter.
- Support output discovery, hotplug, logical geometry, transforms, integer and fractional scaling,
  and deterministic surface recreation.
- Route pointer, keyboard, text input, focus, cursor shape, touch, scroll, and dismissal behavior
  into the correct Fabric surface.
- Replace fixed 16 ms polling with Wayland frame callbacks, presentation deadlines, explicit frame
  demand, and damage-driven rendering.
- Define popup positioning, exclusive zones, keyboard interactivity, click shields, layer selection,
  and panel placement as native surface descriptors.
- Preserve native service and Wayland state when a Fabric surface unmounts or Hermes restarts.

Acceptance requires a bar, background, centered panel, and notification overlay to render and
receive input concurrently on multiple outputs under both niri and Nucleus Compositor.

## Phase 2 — Service and state framework

Build the native infrastructure every product feature uses.

- Add an event-loop abstraction that integrates Wayland, D-Bus, PipeWire, timers, subprocess pipes,
  signals, inotify, and CEF scheduling without busy polling.
- Establish Swift concurrency ownership and actor boundaries for main-thread Wayland/render state,
  service I/O, resource loading, and background indexing.
- Implement typed D-Bus client and server facilities, including reconnect and name-owner changes.
- Add observable stores that publish versioned snapshots and accept typed commands.
- Implement configuration validation, atomic persistence, migrations, live reload, and defaults.
- Implement shell IPC and compositor-facing panel commands.
- Generate React Native native-module bindings for service snapshots, subscriptions, and commands.
- Add structured logging, diagnostics, lifecycle ordering, and service failure isolation.

Acceptance requires restarting Hermes without dropping D-Bus ownership or native service state,
and reattaching React surfaces to a current full snapshot without replay ambiguity.

## Phase 3 — Bar parity vertical slice

Build the first complete product slice on the generalized host and service framework.

- Implement configurable start, center, and end widget regions.
- Implement clock, workspaces, active window, taskbar, tray, media, audio, network, Bluetooth,
  battery, power profile, notifications, and session widgets.
- Add persistent widget ordering, per-widget settings, visibility policies, responsive sizing, and
  overflow behavior.
- Complete foreign-toplevel actions and add application identity and icon resolution.
- Implement MPRIS, tray, audio, network, Bluetooth, power, and notification native services needed
  by the widgets.
- Build the initial React Native design system, typography, semantic colors, spacing, effects,
  focus treatment, motion, and accessibility semantics.

Acceptance requires the Nucleus bar to replace Noctalia's bar for normal daily operation while
Noctalia continues providing panels not yet migrated.

## Phase 4 — Panel framework and primary panels

Build the reusable panel behavior before adding feature-specific panels.

- Implement open, close, toggle, exclusivity, placement, focus restoration, keyboard modes,
  dismissal, click shields, animations, output selection, and IPC addressing.
- Implement launcher indexing and application launching.
- Implement the control center and its audio, network, Bluetooth, media, power, and system pages.
- Implement notification center, session panel, calendar, clipboard, and settings.
- Implement settings editors for themes, bars, widgets, panels, services, keybind commands, and
  configuration import/export.
- Add virtualization for large application, notification, clipboard, and settings collections.

Acceptance requires all primary panels to preserve state across close/reopen, output changes,
configuration reload, and Hermes recovery.

## Phase 5 — Desktop and transient surfaces

Complete the remaining non-security shell surfaces.

- Implement per-output wallpaper and backdrop surfaces.
- Implement dock, desktop widgets, overview, window switcher, and workspace interaction.
- Implement volume, brightness, media, lock-key, keyboard-layout, privacy, and profile OSDs.
- Complete screenshot capture, region selection, annotation, saving, clipboard export, and feedback.
- Implement notification toasts, tooltips, context menus, transient dialogs, and file pickers.
- Implement hot corners, screen corners, idle inhibition, gamma/night-light, and output controls.

Acceptance requires correct stacking, focus, damage, scaling, and lifecycle behavior across every
surface role and output configuration.

## Phase 6 — Security and session lifecycle

Move all session-critical behavior onto native Swift services and surfaces.

- Complete ext-session-lock per-output surfaces and input routing.
- Implement secure password entry and authentication without exposing credentials to JavaScript.
- Implement the Polkit agent and native authentication dialogs.
- Integrate logind lock, unlock, suspend, reboot, shutdown, lid, idle, and session-state changes.
- Implement greeter/session selection behavior required by the deployment environment.
- Define fail-closed behavior for Hermes failure, renderer failure, disconnected outputs, and service
  restarts during a locked session.

Acceptance requires lock and authentication behavior to remain functional when the JavaScript
runtime is absent or crashes.

## Phase 7 — CEF and Apple Music

Integrate the codec-enabled CEF build through a narrow native boundary.

- Package CEF and its helper process as standalone build components consumed by the shell.
- Expose CEF through a C-compatible API so the non-C++ Swift service graph does not import CEF's
  C++ module graph.
- Keep browser, profile, Widevine, audio, and texture state in a process-lifetime Swift service.
- Accept accelerated off-screen frames only; import dmabuf planes into Vulkan external memory and
  synchronize producer and consumer access explicitly.
- Present the imported image through a specialized Fabric component while Swift owns browser input,
  focus, resize, cursor, visibility, and process lifecycle.
- Consume Chromium's native process-specific MPRIS player through the shared Swift MPRIS service.
- Preserve browser and playback state when the Apple Music panel unmounts or Hermes restarts.

Acceptance requires interactive Apple Music playback, Widevine, AAC, native MPRIS metadata and
controls, zero-copy presentation, panel persistence, and clean browser-process shutdown.

## Phase 8 — Full parity and Noctalia retirement

Close the remaining behavioral gaps against Noctalia.

- Port lower-priority widgets, weather, calendar providers, hardware telemetry, scripting, hooks,
  plugin behavior, custom buttons, theming breadth, and compositor-specific integrations.
- Provide a one-way configuration importer that maps supported Noctalia settings into the Nucleus
  typed configuration model and reports settings that require manual replacement.
- Audit keyboard navigation, accessibility, localization, high-DPI behavior, multi-output behavior,
  service reconnects, suspend/resume, memory pressure, and GPU recovery.
- Validate startup, idle CPU, animation pacing, frame latency, memory, and power behavior against
  explicit product budgets.
- Remove reliance on Noctalia only after the Nucleus shell owns every required desktop role and
  passes daily-use validation as the sole shell process.

## Principal risks

### Runtime maturity

The Nucleus shell architecture is correct, but the existing client WSI and Fabric path has limited
real-hardware coverage. Multi-output, resize, hotplug, input, frame pacing, and GPU recovery must be
proven before feature breadth grows.

### Native integration breadth

Noctalia's visible UI hides a large amount of D-Bus, PipeWire, system, configuration, process, and
compositor behavior. The migration tracks service parity independently from visual parity so a
matching screenshot cannot conceal missing lifecycle behavior.

### React Native boundary quality

An expanding generic JSON command bridge would erase type safety, create redundant state, and make
recovery ambiguous. Generated specifications, versioned snapshots, explicit commands, and native
state ownership are mandatory before broad feature work.

### Input and accessibility

A desktop shell requires keyboard navigation, focus restoration, text input, IME, pointer capture,
screen-reader semantics, reduced motion, and secure input. These are platform prerequisites, not
late visual polish.

### CEF external images

The Noctalia integration imports accelerated CEF frames through EGL/GLES. Nucleus uses Vulkan.
Linux dmabuf format/modifier negotiation, multi-plane imports, explicit synchronization, image
layout transitions, device-loss recovery, and buffer lifetime require a dedicated Vulkan path.

### Configuration compatibility

Preserving Noctalia's configuration format as the new shell's internal model would constrain the
new architecture. Compatibility is a one-way importer into a typed Nucleus configuration, not a
permanent dual configuration pipeline.

## Completion criteria

The migration is complete when `nucleus-shell` independently provides the bar, panels, desktop
surfaces, notifications, tray, launcher, media, system controls, lock screen, screenshots,
clipboard, settings, wallpaper, CEF Apple Music integration, and shell IPC; survives native service,
Hermes, output, suspend/resume, and GPU lifecycle events; operates on niri and Nucleus Compositor;
and no longer requires a concurrent Noctalia process for any desktop-shell responsibility.
