# Noctalia-to-Nucleus Shell Migration Plan

## State invariant

`nucleus-shell` replaces Noctalia as an out-of-process Wayland shell written in Swift against
the public AppKit-like Nucleus APIs.

Across every phase boundary:

1. **NucleusUI is the product-authoring API.** Shell views, controls, layout, input, animation,
   and accessibility are authored in Swift against `NucleusUI`. Product code does not emit raw
   layer or renderer commands.
2. **Swift owns the whole first implementation.** Swift owns UI, controllers, services,
   authoritative state, security-sensitive behavior, native resources, and process lifecycle.
   Completing the shell does not depend on Hermes, Fabric, Yoga, or a JavaScript bridge.
3. **The renderer remains a substrate.** NucleusLayers, Skia Graphite, Vulkan, and Wayland WSI
   implement NucleusUI; shell product code reaches them only through narrow platform-host and
   specialized-resource seams.
4. **Noctalia remains the behavioral specification until replacement.** A responsibility moves
   only when its Swift implementation passes the same functional, lifecycle, and visual behavior
   required in daily use.
5. **React Native is deferred.** After the native Swift shell is complete, selected surfaces may
   be reconsidered for React Native in a separate plan. The initial port does not build two UI
   implementations or shape its architecture around a hypothetical later migration.
6. **Wayland remains the compositor boundary.** The shell communicates with niri, Nucleus
   Compositor, and other conformant compositors through standard Wayland protocols and explicit
   shell IPC.

This is a native Swift port of the product, not a line-by-line source translation. Noctalia's
retained UI architecture, controls, behavior, metrics, and visual output inform the design of
reusable NucleusUI APIs. Its C++ renderer implementation and application-specific ownership do not
become a second framework inside the Swift shell.

## Target architecture

```text
Swift shell product (`NucleusShellProduct`)
  views, controls, controllers, navigation, configuration UI
                         │
                 public NucleusUI
  drawing, text, layout, events, focus, scrolling, editing, accessibility
                         │
        NucleusLayers + NucleusRenderer
          Skia Graphite + Vulkan WSI
                         │
                    Wayland

Swift services and state
  D-Bus, PipeWire, config, IPC, authentication, CEF, process management
                         │
       typed Swift models and commands
                         │
             Swift views/controllers
```

The ownership boundary is stable:

- NucleusUI views own presentation state and react to typed Swift models.
- Swift services own external connections, persistence, subprocesses, and long-lived state.
- Controllers translate user intent into typed service commands; views do not speak D-Bus,
  PipeWire, CEF C++, or Wayland protocol objects directly.
- The shell platform host owns Wayland objects, render presenters, event-loop integration, and
  mapping platform input into NucleusUI events.
- Specialized native resources such as CEF frames and screencopy buffers use explicit render-host
  contracts while appearing to product code as NucleusUI views or controls.

## Relationship to the AppKit API plan

The native shell is the forcing client for
`core/docs/appkit-api-plan.md`. Framework work and shell work proceed in strict consumer-driven
order:

1. AppKit Phases 5–6 complete drawing and the one shared paint-registration path.
2. AppKit Phase 7 publishes the stable NucleusUI hosting seam required by the shell.
3. AppKit Phase 8 completes events, responders, focus, keyboard, and pointer capture.
4. AppKit Phase 9 completes measure/arrange and the native layout scheduler.
5. AppKit Phase 10 adds secure single-line editing and the Wayland input-method bridge when the
   lock screen needs them.
6. AppKit Phase 11 adds native scrolling when the first panel needs it.
7. AppKit Phase 12 adds multiline editing when a real shell editor needs it.

The shell does not wait for a speculative catalog of controls. Each vertical slice extends
NucleusUI only with reusable capability required by that slice, lands behavioral and headless
coverage in `core`, and then consumes the public API from `shell`. Shell-specific raw drawing,
layout, or event backdoors are not accepted as shortcuts.

The existing React Native bar remains a useful integration proof and must continue to build while
shared APIs change. It is not the product foundation or a migration milestone.

## Swift package and module placement

The port grows inside the existing `shell/` SwiftPM package. It does not create a second shell
package:

- `NucleusShellProduct` is the native product module. It owns Swift views, controllers, product
  composition, and app-facing state. It imports public `NucleusUI` and typed shell service models,
  not `NucleusLayers`, `NucleusRenderer`, or React Native.
- `NucleusShellRuntime` is the privileged platform host. It owns Wayland/render integration,
  event-loop and process lifecycle, host installation, and the adapters that deliver platform
  events and service state to the product.
- `NucleusShellWayland` and `NucleusShellRender` remain focused platform modules.
- `NucleusShell` remains the thin executable bootstrap.

Phase 1 creates `NucleusShellProduct` when the first public `GraphicsContext` view lands. That
same module then grows into the real bar, panels, lock screen, notifications, and settings; later
phases do not replace a temporary fixture with a different product tree. This is the concrete
out-of-module client boundary used by the AppKit API plan: `NucleusShellProduct` lives outside
package `Nucleus`, while all code remains in one workspace and one shell package.

## Existing foundation

Nucleus already provides the destination platform's core pieces:

- `NucleusShellWayland` connects as a Wayland client and implements the initial layer-shell,
  foreign-toplevel, session-lock, and screencopy clients.
- `NucleusShellRender` presents client-owned surfaces through Vulkan WSI and the shared Nucleus
  Skia Graphite renderer.
- `NucleusShellRuntime` installs the render host, drives the Wayland/frame loop, and contains a
  bar-specific composition-root prototype that must become a general native application host.
- `NucleusUI`, `NucleusLayers`, `NucleusRenderHost`, and `NucleusRenderer` supply retained state,
  transactions, text, images, effects, animation primitives, resource hosting, and rendering.
- The existing Fabric bar proves that the render host can attach an out-of-process shell surface,
  publish a retained tree, and present it through Vulkan. The native shell reuses that lower
  infrastructure without making Fabric its view hierarchy.
- The workspace CEF patch stack and Noctalia integration implement the Wayland-only
  Graphite/Dawn/Vulkan producer, explicit DMA-BUF transport, external BeginFrame scheduling, and
  Vulkan/Graphite consumer contract. Final build and runtime validation remain separate from
  integrating that contract into `nucleus-shell`.

The current shell is a platform vertical slice, not a usable replacement. Its host is bar-specific,
its loop polls at a fixed cadence, input routing is incomplete, screencopy is scaffolded, and most
services and product surfaces do not exist. The migration grows this package into the native shell;
it does not add another shell package or retain parallel native and React product trees.

## Subsystem mapping

| Noctalia subsystem | Nucleus destination | Required work |
|---|---|---|
| Scene renderer | NucleusRenderer + Skia Graphite + Vulkan WSI | Use the existing renderer; complete scheduling, recovery, and multi-surface lifecycle |
| Custom UI controls | Public NucleusUI views and controls | Generalize proven Noctalia behavior into reusable AppKit-like Swift APIs |
| Layer-shell surfaces | NucleusShellWayland + native surface host | Generalize the bar-only host into multi-output, multi-role native windows |
| Window/taskbar state | ForeignToplevelManager + Swift models | Complete projection, actions, icons, and lifecycle |
| Workspaces | ext-workspace client + Swift models | Add the shell client, commands, and observable state |
| Session lock | SessionLockClient + native NucleusUI windows | Complete per-output surfaces, input, authentication, and fail-closed lifecycle |
| Screenshots | ScreencopyClient + native capture UI | Complete negotiation, import, selection, annotation, saving, and feedback |
| Animations | NucleusUI + NucleusLayers | Drive animation and invalidation from presentation timing |
| Text and images | Nucleus text/resource hosts + NucleusUI | Complete loading, caching, SVG/raster decoding, icons, editing, and selection |
| D-Bus integrations | Swift services with narrow C shims where necessary | Rebuild discovery, exported interfaces, object managers, and reconnect behavior |
| Configuration | Typed Swift model and store | Add persistence, validation, migrations, live reload, and native settings UI |
| CEF | CEF C ABI + synchronized external-image resource + native NucleusUI view | Preserve exact Vulkan synchronization, input, profile, scheduling, and lifecycle |

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
- Configuration persistence, migration, live reload, theme data, and bar/panel layout.
- Shell IPC, panel commands, compositor keybind integration, and process supervision.
- Wallpaper, output configuration, weather, calendar, HTTP, hardware telemetry, and hooks.

Services expose Swift values, observation, and typed commands. They do not depend on a particular
view hierarchy and do not store duplicate UI-owned state. Views may disappear and be recreated
without dropping D-Bus ownership, media discovery, notification history, browser state, or native
resources.

## Execution discipline

The migration proceeds as complete native vertical slices. Each slice includes:

- any reusable NucleusUI capability it proves is missing;
- the minimum service and state required by the feature;
- the Swift view/controller implementation;
- platform input, surface, persistence, and IPC integration;
- startup, shutdown, reconnect, and recovery behavior;
- visual and behavioral comparison against Noctalia.

Before transferring a responsibility from Noctalia, record:

- the owner of every Wayland role, D-Bus name, protocol object, native resource, and subprocess;
- the configuration source and persistence owner;
- the compositor keybind and shell IPC target;
- startup, shutdown, restart, and failure behavior;
- how Noctalia disables the migrated responsibility during coexistence.

No exclusive role or bus name may have two active owners. A responsibility is removed from
Noctalia's active configuration only after its Nucleus replacement passes its acceptance gate.
Noctalia remains active for responsibilities that have not moved.

Niri is the primary development and daily-use environment. Nucleus Compositor receives focused
protocol and surface-lifecycle checks as corresponding features become available; unrelated
compositor incompleteness does not block shell feature development.

No compatibility protocol is introduced between first-party packages built from the same source
tree. The compiler enforces their interface. Observable state may carry a monotonically increasing
revision where ordering or resynchronization requires one; there is no schema or capability
negotiation with the same executable.

## Phase 1 — Native NucleusUI authoring foundation

Finish the framework surface required to author the shell without raw layer or renderer access.

- Land `GraphicsContext`, public paths, gradients, transforms, clipping, text/image drawing,
  effects, blend behavior, and the shared paint-registration seam.
- Migrate the existing React Native committer to the same registration seam only as required to
  delete the replaced command vocabulary and keep the repository coherent.
- Publish the stable NucleusUI window, scene, and hosted-surface API needed by an out-of-process
  Swift shell while keeping genuinely renderer-privileged objects behind the host boundary.
- Complete the native event vocabulary, responder chain, first-responder/key-window behavior,
  pointer capture, hover/drag transitions, modifiers, character production, and key repeat.
- Complete constrained measure/arrange, flex distribution, text wrapping in measurement, dirty
  scheduling, and child-local coordinate behavior.
- Keep drawing and layout behavior headless-testable without a GPU or compositor.
- Create `NucleusShellProduct` and author its first real custom view using only public NucleusUI
  drawing, layout, and event APIs.

Acceptance requires `NucleusShellProduct` to construct, lay out, hit-test, draw, and publish a
native Swift view tree through public NucleusUI APIs; borders, clipping, gradients, text, images,
and a runtime effect must render correctly; and the existing RN prototype must still build without
its parallel paint-lowering path.

## Phase 2 — General native shell host and presentation loop

Replace the bar-specific composition root with a reusable multi-surface NucleusUI application host.

- Introduce a surface registry owning bars, backgrounds, docks, floating panels, overlays,
  notifications, lock surfaces, and per-output instances.
- Give every surface an independent Wayland role, NucleusUI window/root view, logical and pixel
  dimensions, scale, focus state, visibility state, damage state, and render presenter.
- Support output discovery, hotplug, logical geometry, transforms, integer and fractional scaling,
  and deterministic surface recreation.
- Translate pointer, keyboard, touch, scroll, focus, cursor-shape, and dismissal events into the
  appropriate NucleusUI window and responder chain.
- Replace fixed 16 ms polling with Wayland frame callbacks, presentation deadlines, explicit frame
  demand, animation demand, and damage-driven rendering.
- Replace the fixed poll array with an event-source registry that adds Wayland, timers, signals,
  subprocess pipes, D-Bus, PipeWire, inotify, and CEF sources as their first consumers land.
- Define popup positioning, exclusive zones, keyboard interactivity, click shields, layer
  selection, and panel placement as typed native surface descriptors.
- Preserve service and Wayland state when a view hierarchy or surface is recreated.
- Establish main-actor ownership of Wayland, NucleusUI, and render state, with explicit handoff
  boundaries for service I/O, resource loading, decoding, and background work.

Acceptance requires a native Swift bar, background, centered panel, and notification overlay to
render and receive input concurrently on multiple outputs under niri, with presentation-derived
frame pacing and no fixed-rate redraw loop. The same surface primitives receive a focused
compatibility check on Nucleus Compositor.

## Phase 3 — Native state spine, failure UI, and lock-screen proof

Establish the minimum durable state infrastructure and prove the native security boundary.

- Add observable Swift stores with immutable snapshots where snapshot semantics are useful and
  typed commands for mutations.
- Implement only the D-Bus, configuration, logging, IPC, timer, subprocess, and reconnect
  primitives required by this phase and the following bar slice.
- Add the NucleusUI editor model and secure single-line `TextField`.
- Bind the shell-side `zwp_text_input_v3` client and bridge enable/disable, surrounding text,
  content type, cursor rectangle, preedit, commit, deletion, and composition into the active
  NucleusUI editor.
- Bind the corresponding server behavior in Nucleus Compositor so the same shell path works there.
- Create per-output session-lock surfaces through the generalized surface registry.
- Keep credentials, authentication, input routing, and failure presentation inside native Swift;
  disable copying, logging, persistence, and ordinary text exposure for secure fields.
- Add startup, renderer, service, and view-construction failure UI that remains available without
  any optional higher-level runtime.
- Define fail-closed behavior for renderer failure, output removal, compositor reconnect, and
  service restart while locked.

Acceptance requires a session to lock, accept composed text securely, authenticate, and unlock on
every active output with no React Native or JavaScript runtime present. Native state and protocol
ownership must survive destruction and recreation of the visible lock views.

## Phase 4 — Native bar and first ownership transfer

Build the first daily-usable product slice entirely with Swift views and transfer one visible shell
responsibility.

- Establish the NucleusUI shell design system: text and icon metrics, semantic colors, spacing,
  effects, focus treatment, motion, accessibility semantics, and reusable control styles.
- Implement configurable start, center, and end widget regions using native measure/arrange.
- Implement clock, workspaces, active window, and taskbar first.
- Add tray, media, audio, network, Bluetooth, battery, power profile, notifications, and session
  widgets one service-backed slice at a time.
- Add persistent widget ordering, per-widget settings, visibility policies, responsive sizing,
  overflow behavior, and ellipsis rules.
- Complete foreign-toplevel actions, application identity, and icon resolution.
- Record and execute the bar ownership transfer: Wayland surface, exclusive zone, configuration,
  IPC/keybind routing, and service ownership.

Acceptance requires the native Nucleus bar to replace Noctalia's bar for normal daily operation
while Noctalia continues providing panels and other responsibilities not yet migrated.

## Phase 5 — Native scrolling, panel framework, and control-center slice

Add the next NucleusUI primitive through a real stateful panel rather than a framework-only demo.

- Implement native `ScrollView` clipping, wheel input, drag scrolling, pointer capture, content
  sizing, inertial motion, overscroll behavior, presentation-driven animation, and nested responder
  behavior.
- Implement panel open, close, toggle, exclusivity, placement, focus restoration, keyboard modes,
  dismissal, click shields, animations, output selection, and IPC addressing.
- Implement the control-center shell, native navigation model, and one page backed by a real Swift
  service.
- Validate text, clipping, rounded corners, backdrop effects, scrolling, keyboard traversal,
  accessibility, and fractional scaling in the real panel.
- Preserve controller and service state across close/reopen, output changes, surface recreation,
  and configuration reload.
- Transfer the control-center surface and IPC/keybind responsibility only after the slice is
  suitable for daily use.

Acceptance requires a native Nucleus panel to match Noctalia's interaction and visual behavior,
scroll smoothly at the output refresh rate, and preserve state when its window and view hierarchy
are destroyed and recreated.

## Phase 6 — Native CEF and Apple Music integration

Integrate the codec-enabled CEF producer through a specialized native resource boundary.

- Package CEF and its helper process as standalone workspace components consumed by the shell.
- Keep CEF's Wayland-only Graphite/Dawn/Vulkan producer, accelerated-paint-only contract, exact
  frame identity, explicit synchronization, external BeginFrame scheduling, device selection, and
  persistent profile behavior.
- Reuse Noctalia's proven DMA-BUF format/modifier, acquire/release, queue-family/layout, buffer
  lifetime, backpressure, and device-recovery rules rather than designing a second transport.
- Expose CEF through a C-compatible API so the non-C++ Swift service graph does not import CEF's
  C++ module graph.
- Keep browser, profile, Widevine, audio, scheduler, and frame-ring state in a process-lifetime
  native service.
- Add a specialized synchronized external-image resource to the render host. The generic external
  content handle is insufficient because CEF frames carry producer completion, exact identity, and
  consumer release obligations.
- Present the resource through a native NucleusUI browser view that owns input routing, focus,
  resize, cursor shape, visibility, and accessibility integration while the service owns browser
  lifetime.
- Consume Chromium's process-specific MPRIS player through the shared Swift MPRIS service.
- Preserve browser navigation, authentication, playback, and profile state when the Apple Music
  window closes or its view hierarchy is recreated.

Acceptance requires interactive Apple Music playback, Widevine, AAC, native MPRIS metadata and
controls, zero-copy presentation, transparent panel composition, autonomous animation, correct CSS
backdrop filtering, bounded resource use, and clean browser-process shutdown with Vulkan validation
clean.

## Phase 7 — Primary panels, editors, and service expansion

Build remaining primary product surfaces as independent native Swift vertical slices.

- Complete control-center audio, network, Bluetooth, media, power, and system pages.
- Implement launcher indexing, fuzzy search, application launching, and keyboard-first navigation.
- Implement notification center and daemon ownership, session panel, calendar, clipboard, and
  settings.
- Add multiline `TextView` on the editor model and native ScrollView when the first real editor
  lands; complete selection, caret affinity, preedit, bidi behavior, and large-document scrolling.
- Implement settings editors only after their typed configuration sections exist, including
  themes, bars, widgets, panels, services, keybind commands, and import/export.
- Add collection virtualization only when a real application, notification, clipboard, or settings
  collection demonstrates the need.
- Transfer each slice's surfaces, protocol ownership, bus names, configuration, and IPC routes
  together.

Acceptance requires every migrated primary panel to preserve state across close/reopen, output
changes, configuration reload, native-service reconnect, and surface recreation, with text editing
correct for composed, bidirectional, combining-mark, emoji, and secure text cases.

## Phase 8 — Desktop and transient surfaces

Complete the remaining non-security shell surfaces.

- Implement per-output wallpaper and backdrop surfaces.
- Implement dock, desktop widgets, overview, window switcher, and workspace interaction.
- Implement volume, brightness, media, lock-key, keyboard-layout, privacy, and profile OSDs.
- Complete screenshot capture, region selection, annotation, saving, clipboard export, and
  feedback.
- Implement notification toasts, tooltips, context menus, transient dialogs, and file pickers.
- Implement hot corners, screen corners, idle inhibition, gamma/night-light, and output controls.

Acceptance requires correct stacking, focus, damage, scaling, accessibility, and lifecycle behavior
across every surface role and output configuration.

## Phase 9 — Security completion, full parity, and Noctalia retirement

Complete session-critical breadth, close remaining product gaps, and perform the final ownership
transfer.

- Harden the proven session-lock and authentication path for reconnects, suspend/resume, device
  loss, output hotplug, and service failure.
- Implement the Polkit agent and native authentication dialogs.
- Integrate logind lock, unlock, suspend, reboot, shutdown, lid, idle, and session-state changes.
- Implement greeter/session selection behavior required by the deployment environment.
- Port lower-priority widgets, weather, calendar providers, hardware telemetry, scripting, hooks,
  plugin behavior, custom buttons, theming breadth, and compositor-specific integrations.
- Provide a one-way configuration importer that maps supported Noctalia settings into the Nucleus
  typed configuration model and reports settings requiring manual replacement.
- Audit keyboard navigation, screen-reader semantics, localization, reduced motion, high-DPI and
  multi-output behavior, service reconnects, suspend/resume, memory pressure, and GPU recovery.
- Validate startup, idle CPU, animation pacing, frame latency, memory, and power behavior against
  explicit product budgets.
- Audit the ownership ledger and remove reliance on Noctalia only after the Nucleus shell owns
  every required surface, protocol, bus name, configuration section, IPC route, and subprocess.

Acceptance requires native lock and authentication to remain functional through all supported
failure cases, every required shell responsibility to pass daily-use validation under niri,
focused protocol compatibility on Nucleus Compositor, and Noctalia to be unnecessary as a
concurrent shell process.

## Deferred post-parity React Native direction

React Native adoption begins only after Phase 9 and is not part of this migration's completion
criteria.

This document deliberately does not choose surfaces, ordering, component boundaries, or state
bridges for that later work. Those decisions receive a separate plan based on the completed Swift
product and measurements available then. The existing RN prototype may continue serving as an
integration and regression fixture; no new shell responsibility depends on it during the native
port.

## Principal risks

### NucleusUI maturity

The renderer is substantially more complete than the public authoring API. Drawing, publication,
events, layout, scrolling, editing, accessibility, and failure propagation must become real
client-facing contracts as the first shell slices consume them. Shell-specific escape hatches would
hide framework gaps and recreate Noctalia's private UI framework inside the application.

### Runtime and presentation maturity

The client WSI path has limited real-hardware coverage. Multi-output, resize, hotplug, focus,
fractional scaling, presentation timing, device loss, suspend/resume, and compositor reconnect must
be proven before feature breadth grows.

### Native integration breadth

Noctalia's visible UI hides extensive D-Bus, PipeWire, system, configuration, process, and
compositor behavior. Service parity is tracked independently from visual parity so a matching
screenshot cannot conceal missing lifecycle or ownership behavior.

### Input and accessibility

A desktop shell requires consistent responder routing, keyboard navigation, focus restoration,
text input, IME, pointer capture, drag behavior, screen-reader semantics, reduced motion, and secure
input. These are platform prerequisites, not late visual polish.

### CEF external images

Noctalia consumes accelerated CEF frames through Vulkan external memory and Graphite, while the
patched CEF producer renders with Graphite/Dawn/Vulkan. Extracting that contract behind a C ABI and
native synchronized external-image resource must preserve exact frame identity, format/modifier
handling, explicit synchronization, queue-family/layout ownership, device-loss recovery, external
BeginFrame completion, and buffer lifetime. A generic integer texture handle is not the protocol.

### Configuration compatibility

Preserving Noctalia's configuration format as the new shell's internal model would constrain the
new architecture. Compatibility is a one-way importer into a typed Nucleus configuration, not a
permanent dual configuration pipeline.

## Completion criteria

The native migration is complete when `nucleus-shell`, authored in Swift against NucleusUI,
independently provides the bar, panels, desktop surfaces, notifications, tray, launcher, media,
system controls, lock screen, screenshots, clipboard, settings, wallpaper, CEF Apple Music
integration, and shell IPC; survives service, view, output, suspend/resume, compositor, and GPU
lifecycle events; operates on niri with focused compatibility on Nucleus Compositor; and no longer
requires Noctalia, Hermes, Fabric, or a JavaScript runtime for any desktop-shell responsibility.
