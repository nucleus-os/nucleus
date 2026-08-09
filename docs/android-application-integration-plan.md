# Android Application Integration Plan

## Invariant

Android is an independently signed, architecture-specific downloadable add-on and an
ordinary client of the Nucleus desktop stack. The base OS contains no Android payload
or Android capability declaration. The compositor never learns about Android packages, activities,
tasks, Binder, container state, or Android-specific window roles. Every Android
presentation is a normal `xdg_toplevel`. Android's logical default display is a
framework-owned SurfaceFlinger virtual output created by
`NucleusHostDisplayAdapter` and backed by an opaque RGBX `AImageReader`
surface. The physical HWC display exists only to provide SurfaceFlinger pacing;
its client target is never presented to the desktop. The bring-up desktop
window presents frames from the framework-owned output, so boot animation,
lock screen, System UI, wallpaper, and Launcher3 remain on Android display 0.
Per-application windows use additional framework displays backed by the same
buffer-source and presentation machinery. Every source exports the same
dma-buf, allocation-lifetime, acquire-fence, release-fence, and configuration-
generation contract. The display host immediately returns a pending native
fence and signals it only after the compositor retires that exact buffer.
Each imported Android buffer owns its own release timeline because Wayland
permits buffers to be released out of commit order.
Every Android integration operation crosses a narrow bounded runtime protocol.
Same-build `SOCK_SEQPACKET` peers use exact packet size, operation, descriptor,
credential, identity, and state validation without magic bytes or speculative
protocol versions.

Status: active

The Android runtime boots in the background only when the session explicitly
requests the Android capability. `collider run --android` is the development
entry point; plain `collider run` launches the same compositor and shell
without Android. During bring-up, an Android-enabled session automatically
creates one desktop presentation for Android's primary display, so Launcher3
remains visible. That presentation uses the same window/display machinery as
application presentations. Productionization later removes the automatic
desktop-presentation request; it does not introduce a second renderer, a
compatibility mode, or a compositor feature flag.

Every base OS image omits the Android runtime broker, Android image, and its
session-capability declaration. A verified add-on generation contributes all three
without changing the compositor or shell binaries. Native application discovery and
launching remain fully functional when no Android application provider connects.

## Implementation Status

Status as of 2026-08-08:

| Phase | Status | Remaining gate |
| --- | --- | --- |
| 1. Production Android runtime | Implemented; agent-runnable build, image, and test gates pass | Validate owner-death cleanup and abandoned-runtime reconciliation in the next standard interactive session |
| 2. Platform-signed Android bridge | Implemented; the bridge connects after unlock and publishes two real launcher activities | Validate the new native-input handshake in the next standard interactive session |
| 3. Shell application model | Implemented; provider-neutral catalog, launch routing, dynamic provider lifecycle, namespaced identity, desktop provider, and unified icon resolution pass the Linux shell lane | Attach the Android broker as the second provider in Phase 4 |
| 4. Android application publication | Implementation complete; provider IPC, lifecycle-scoped `LauncherApps` publication, package deltas, and content-addressed icons pass the Linux shell lane; the first full AOSP image build has entered the main platform graph | Complete the full AOSP image build and validate publication on the running Android guest |
| 5. Window-first presentations | The desktop path uses the framework-owned primary host display, generation-tagged zero-copy frames, exact-size host commits, nonblocking explicit synchronization, and single-flight live relayout; obsolete Composer and RuntimeBridge presentation ownership is deleted | Validate the desktop path interactively, then add the framework-owned application-display factory and pass the two-presentation gate |
| 6. Android activity launch and tracking | Not started | Depends on Phase 5 |
| 7. Input and focus | Primary-display pointer/keyboard transport implemented through display-targeted Android input injection; native virtual-device, focus, gesture-generation, and presentation-scoped completion remains | Depends on Phase 6 |
| 8. Density, resize, and activation | Single-flight configure coalescing, exact-frame host geometry, and in-place framework host-display resize are implemented; output-derived density and activation remain | Depends on Phase 7 |
| 9. Clipboard | Not started | Depends on Phase 8 |
| 10. Notifications | Not started | Depends on Phase 9 |
| 11. Lifecycle integration and bring-up removal | Not started | Depends on Phase 10 |

Phase 1 now includes:

- generic session-capability declarations and supervisor-owned
  process launch, restart, and per-capability shutdown policy with no
  Android-specific supervisor role or capability-readiness channel;
- Android-owned lifecycle, image validation, host prerequisite resolution,
  mount/container supervision, health monitoring, diagnostics, and cleanup in
  `NucleusAndroidRuntimeCore`;
- a root container launcher bound to the Android runtime owner by `pidfd`; loss
  of the runtime owner stops LXC even when normal Swift cancellation and cleanup
  cannot execute, and the next runtime reconciles any container and mount tree
  left by binaries predating this ownership contract;
- Android-owned Linux process, binderfs, pseudo-terminal, APEX, BPF, cgroup,
  and privileged-helper implementations;
- the persistent `nucleus-android-runtime` broker and
  `nucleus-android-runtime-privileged` helper;
- independent Android add-on staging, relocation validation, signed payload
  verification, atomic generation activation, and generation of an external
  `session-capabilities/android.json` declaration;
- installed `nucleus addon` product commands for status, installation, deactivation,
  and uninstall without a source checkout or Collider;
- the standard `collider run` path as the only desktop/session launch path;
- explicit `collider run --android` capability selection and terminal-owned
  sudo authentication before the background Android service starts;
- an Android runtime Kitty window owned by the `--android` launch lifetime and
  following the persistent kernel, logcat, graphics, display-host, and runtime
  event streams;
- a resizable bring-up presentation whose toplevel configure is coalesced behind
  at most one in-flight Android relayout; the matching generation and exact-size
  frame atomically update Wayland window geometry and pixels, then release the
  newest pending size to Android's framework-owned default display without HWC
  hotplug, task migration, stale-frame stretching, or a secondary HOME
  implementation;
- one zero-copy host presentation contract used by framework-owned Android
  display outputs, carrying Nucleus gralloc
  dma-bufs, allocation lifetime handles, acquire fences, Android display
  identity, configuration generation, and per-buffer compositor release
  timelines; a shared asynchronous coordinator translates actual compositor
  retirement into a pending native fence, so frame production never waits for
  the next frame to release the current one;
- default-display presentation from the first SurfaceFlinger frame, preserving
  the standard Android boot animation, lock screen, System UI, wallpaper, and
  Quickstep home lifecycle;
- primary-display pointer motion, buttons, scrolling, and physical keyboard
  events captured from `wl_seat`, mapped through the resizable viewport, and
  carried over a private host input socket without teaching the compositor
  about Android;
- display-targeted pointer and keyboard events injected by the dedicated
  platform bridge through `InputManager`, with the Wayland compositor remaining
  the sole visible cursor authority; bridge negotiation publishes either
  durable input readiness or the complete Android exception chain;
- Android pointer-icon semantics published by InputManagerService through the
  platform bridge and translated into `wp_cursor_shape_manager_v1` requests by
  the display host, so Android selects arrow, text, link, resize, grab, and
  related intent while the compositor renders the host cursor theme;
- deletion of the validation-only `framework-boot`, surface-probe, and
  presentation-qualification products and commands;
- Android runtime operation continuing until session cancellation, with
  Launcher3 and virtual-presentation evidence remaining in component logs
  rather than terminal success conditions;
- strict separation between ephemeral session state used for Wayland, sockets,
  mounts, and container ownership and persistent per-run diagnostics consumed
  by Collider.

The completed Phase 1 verification is:

- Android runtime-core, runtime-bridge/input integration, display-host, and
  container configuration behavioral tests pass;
- the Linux runtime-host process test proves children receive a clean signal
  mask even when launched from a thread with `SIGCHLD` blocked;
- all 15 session-supervisor acceptance tests pass, including capability
  process launch without a readiness dependency, declared graceful shutdown,
  restart policy, shared teardown,
  unavailable optional capability behavior, and a session with no capability
  declaration;
- all 6 core session-readiness tests and all 3 session-capability declaration tests
  pass;
- a real disposable session generation containing the four Android
  executables and its capability declaration passed ELF dependency and
  relocation validation;
- signed-image run `2026-07-29T21-51-37Z-518737` rebuilt the bridge APK,
  release-signed the APK/APEX partitions, assembled the images, and passed
  image validation;
- signed-image run `2026-07-29T22-30-57Z-744172` compiled the native
  virtual-mouse/virtual-keyboard bridge endpoint, release-signed the complete
  product, and passed APK, APEX, AVB, partition, and package validation;
- signed-image run `2026-07-29T23-49-45Z-1437397` compiled the
  topology-driven dynamic Composer mode path, release-signed the complete
  product, and passed APK, APEX, AVB, partition, and package validation;
- signed-image run `2026-07-30T00-30-00Z-1630181` compiled the native-input
  service handshake, release-signed the complete product, and passed APK,
  APEX, AVB, partition, and package validation;
- interactive run `2026-07-29T21-32-44Z-388699` reached Launcher3, published
  two launchable activities, presented continuously, and completed runtime
  cleanup after session exit;
- `git diff --check` passes.

Phase 2 currently includes:

- a bounded `SOCK_SEQPACKET` bridge protocol with peer credential
  checks, runtime generations, reconnect semantics, duplicate-unlock
  rejection, and no file-descriptor transfer;
- the host-owned `broker.sock` mounted directly at
  `/dev/nucleus-runtime/broker.sock`, followed by a host/container
  device-and-inode equality check before the container starts;
- `NucleusRuntimeBridge` as a platform-signed, privileged,
  direct-boot-aware persistent app on `system_ext`;
- a protocol-owned OEM Android UID, `android.uid.nucleus_runtime` at numeric UID
  2900, with an image allowlist containing only
  `org.nucleus.android.runtimebridge`, matching host peer admission at
  `subordinateUID + 2900`;
- outbound bridge connection, protocol negotiation, current user serial,
  locked/unlocked runtime state, and one initial sorted launcher-activity
  snapshot after unlock;
- package add, change, remove, and replace observation followed by a complete
  refreshed activity snapshot;
- host and Android diagnostics for the mounted bridge directory, socket
  visibility, socket metadata, connection generations, unlock, snapshots, and
  disconnects;
- activity discovery remains internal runtime state and never gates session or
  capability startup;
- a dedicated `nucleus_runtime_bridge` SELinux domain and
  `nucleus_runtime_socket` core-domain socket label.

The first runtime validation exposed an incomplete identity contract: the
bridge package used an ordinary dynamically allocated app UID while the host
admitted a fixed mapped peer UID. The package, image policy, SELinux app
selector, and host credential check now share the dedicated UID 2900 contract.
The rebuilt Phase 2 AOSP gate compiled the Java app and SELinux policy,
installed the bridge APK and both UID-policy files under `system_ext`, and
published release-key-signed target-files and image archives. Artifact
inspection confirms the bridge manifest shared UID, sole-package allowlist,
OEM UID mapping, and `oem_2900` SELinux selector. The next runtime validation confirmed that the
bridge process runs as UID 2900, then exposed two host-side defects: the
container saw the mounted directory without `broker.sock`, and
the retired validation command simultaneously created a legacy direct runtime beside the
session capability. The direct runtime path is now removed, the capability is
the sole owner, and the socket itself is the mount source. The following
runtime validation exposed two ownership-boundary regressions: the optional
Android service was coupled to the core session through a readiness deadline,
and it placed diagnostics under the ephemeral session runtime while Collider
and Kitty observed the persistent run directory. Capabilities are now
supervised background processes whose startup is not a session-readiness
condition. The runtime uses separate session-runtime and diagnostics roots.
Diagnostic streams are
created before image validation starts, and image validation now runs only
inside the sole Android runtime owner. The next runtime validation reached
signed-image validation in three seconds but stopped on the first privileged
module load: Foundation launched sudo from a Swift executor thread whose signal
mask blocked `SIGCHLD`, leaving the completed child as a zombie and making
sudo unable to finish or respond to teardown. The Linux runtime host now
clears the complete signal mask synchronously around every child spawn and
restores the executor thread mask immediately afterward. The next validation
reached Launcher3 with the bridge connected, user 0 unlocked, the exact socket
mount verified, frame presentation active, and no SELinux denials. It also
proved the validation-era terminal readiness behavior was wrong: it stopped
the display services immediately and the one-second generic supervisor grace
then killed Android cleanup, leaving the container and cgroup behind. The
validation command and its probe/qualification products are now deleted. The
runtime has one long-lived lifecycle, production `nucleus-android-runtime-*`
instance naming, `android-runtime` diagnostics, runtime health/event types,
and a declared 60-second graceful shutdown interval before forced termination.
The container's independent privileged scope is now owned through a `pidfd`
watcher rather than process ancestry or best-effort cancellation. Startup
reconciles legacy `nucleus-framework-*` and abandoned
`nucleus-android-runtime-*` containers before creating a new instance. Native
input readiness is negotiated by the Android bridge after it successfully
creates both virtual devices; host-side `lxc-attach` polling is deleted.
The first legacy-runtime reconciliation stopped the orphan container but
exposed an invalid `findmnt` output-mode combination before its inherited
mount tree could be removed. Mount discovery now resolves the containing
mount hierarchy, filters it to the exact validated runtime instance, unmounts
deepest-first, and records reconciliation failures durably before the
capability supervisor applies restart policy.

## Final Ownership

| Component | Owns | Must not own |
| --- | --- | --- |
| Session supervisor | Starting declared session capabilities, descriptor inheritance, lifetime and restart policy | Android boot commands, package knowledge, Android readiness rules |
| Shell application services | Merged application catalog, launcher UI, provider-neutral launch dispatch, activation | Container boot, Binder calls, Android display allocation |
| Android runtime broker | Container lifecycle, runtime state, bridge connection, presentation orchestration, Android provider implementation | Compositor policy, Android framework internals |
| Android display host | Wayland toplevels, configure/scale/output state, dma-buf import, explicit synchronization, frame presentation, Wayland input capture | Package discovery, activity launches, task policy |
| Nucleus host display adapter | SurfaceFlinger output creation, Android logical-display publication, buffer-source geometry, and framework relayout | Wayland, packages, activities, host window policy |
| Nucleus Android bridge | User/package observation, activity launch, application-display requests, display-ID resolution, task observation, display-associated virtual input devices, clipboard and notifications | Primary-display presentation, Wayland, Vulkan, host desktop policy |
| Compositor | Standard Wayland surface composition, focus, activation, window management | Any Android-specific protocol or privileged-client rule |

The runtime data flow is:

```text
Launcher UI
    |
    v
Shell application catalog ---- generic provider IPC ---- Android runtime broker
                                                         |              |
                                               host control IPC   Android bridge IPC
                                                         |              |
                                                         v              v
                                                 Android display host  Android framework
                                                         |
                                                         v
                                                 ordinary xdg_toplevel
                                                         |
                                                         v
                                                    compositor
```

## Core Contracts

### Application provider contract

The shell stops treating every launchable application as a desktop file plus an
executable. It consumes providers through a source-neutral contract:

- `ApplicationID`: a stable namespaced identifier.
- `ApplicationRecord`: ID, display name, icon reference, categories, provider
  ID, and opaque provider launch ID.
- `ApplicationIconReference`: either a freedesktop theme name or a
  content-addressed raster asset.
- `ApplicationCatalogChange`: full snapshot, insert/update, or removal.
- `ApplicationLaunchRequest`: application ID plus a compositor-issued
  activation token.
- `ApplicationLaunchResult`: created, activated existing presentation, or a
  structured failure.
- `ApplicationProvider`: publishes catalog changes and accepts launch requests.

Native desktop files become one provider implementation. The Android broker
becomes another. Provider disappearance removes only that provider's records.
The launcher remains usable with zero remote providers.

Android application IDs use
`android:<user-serial>:<package-name>/<activity-class>`. Android numeric user IDs
are not stable identity. Icon payloads are written by the broker into its
session-owned cache under a digest filename; catalog messages carry the digest
and path, not unbounded image bytes.

### Android runtime protocol

Use a private `SOCK_SEQPACKET` protocol with bounded messages and peer
credential validation. Keep lifecycle and application operations independent
of the display-control and frame-presentation protocols.
The protocol contains:

- runtime state: `runtimeStarted`, `userUnlocked`, `bridgeConnected`, and
  `runtimeFailed`;
- catalog: `replaceActivities`, `upsertActivity`, `removeActivity`, and icon
  asset metadata;
- presentations: `createPresentation`, `presentationConfigured`,
  `displayAvailable`, `closePresentation`, and `presentationClosed`;
- activities/tasks: `launchActivity`, `launchOutcome`, `taskChanged`, and
  `taskVanished`;
- input: pointer, scroll, button, touch, key, text/IME, focus, and cancel;
- clipboard: generation-tagged host and Android changes;
- notifications: post, replace, remove, and activate;
- diagnostics: request ID, presentation ID, Android display ID, package,
  activity, task ID, and failure code where applicable.

Every request that can race carries a broker-generated request ID. Every
presentation carries an opaque 128-bit presentation ID from creation through
teardown. Unknown IDs, stale generations, oversized packets, unexpected file
descriptors, and messages invalid for the current state are protocol errors.

### Presentation state machine

Every Android window follows one state machine:

```text
requested
  -> wayland_configured
  -> android_display_connecting
  -> android_display_available
  -> activity_launching
  -> active
  -> closing
  -> closed
```

The display host creates and configures the `xdg_toplevel`. For the desktop
presentation, the framework-owned host display adapter already owns Android
display 0 and its `AImageReader`. For an application presentation, the broker
asks Android to create an additional framework display backed by the same host
display buffer-source implementation. Android reports the framework display ID
with the presentation, allowing input and activity launch to target the display
without correlating physical Composer topology. An activity is launched only
after the display ID is acknowledged, using
`ActivityOptions.setLaunchDisplayId`.

Closing a host window first unmaps it, asks the bridge to finish/remove its
owned task group, waits for task disappearance, releases the virtual display
and frame source, and destroys the Wayland objects. If Android finishes the task first,
the same teardown begins from `taskVanished`. Broker, bridge, or display-host
failure closes every presentation through this path. A disappearing secondary
display must never move an abandoned task onto the Launcher3 desktop.

The initial Launcher3 window is a presentation with purpose `desktop` and is
requested automatically by the broker during bring-up. Application windows use
purpose `application`. Both use the same display-control,
configuration-generation, frame-stream, and display-host contracts. Only the
desktop presentation is eligible to become Android's logical default display.

## Phase 1: Extract the Production Android Runtime

The Android-owned runtime executable is the sole owner of container and display
lifecycle. Collider installs the capability and launches the standard session;
it contains no Android-specific live-session command.

Add:

- `NucleusAndroidRuntimeCore` for image validation, mount/container setup,
  process supervision, startup, shutdown, health monitoring, and diagnostics;
- `nucleus-android-runtime` as the background broker executable;
- an Android runtime session-capability declaration derived only after an
  independently signed Android add-on passes compatibility and payload validation;
- generic session-supervisor support for declared capability processes and
  their descriptor attachments.

The supervisor does not gain an `androidRuntime` process role or Android
conditionals. It launches an installed capability declaration using the generic
service mechanism. The capability publishes an application-provider endpoint
to the shell and owns its internal bridge/display-host endpoints.

Delete Collider's duplicated launch path and the bounded presentation
qualification products in the same phase. The broker is the single owner of
Android runtime lifetime. A broker exit tears down the container, display
host, sockets, mounts, and catalog provider.

Verification gate:

- A normal session starts the broker in the background when the Android
  capability is installed.
- A session without the capability reaches compositor and shell readiness with
  no Android files, descriptors, waits, or log errors.
- Terminating the session leaves no Android processes, mounts, sockets, or
  presentation windows.

## Phase 2: Add the Platform-Signed Android Bridge

Add `android-runtime/aosp/packages/apps/NucleusRuntimeBridge` as a
platform-signed privileged system app built into the Nucleus product. It is
direct-boot aware only for establishing runtime state; it does not publish apps
or accept launches until user 0 is unlocked.

The bridge:

- connects outbound to the broker's mounted Unix socket;
- authenticates the peer and runtime generation;
- reports `ACTION_USER_UNLOCKED` and the current user serial;
- uses platform APIs for launcher activity queries, display observation,
  activity/task control, input injection, clipboard, and notification access;
- reconnects after framework/service restart and replaces all previously
  published state with a new generation.

Add only the exact privileged permissions and SELinux rules required by those
operations. Keep `ro.control_privapp_permissions=enforce`. Do not add a custom
HAL, a custom Wayland protocol, a framework-wide service, or broad device
access.

Treat `sys.boot_completed`, Launcher3 drawing, and virtual presentation as
diagnostic signals rather than runtime gates. The session capability startup handshake occurs
after the bridge reports user unlock and supplies its initial activity
snapshot; it does not terminate or tear down the runtime.

Verification gate:

- The bridge connects before unlock but exposes no launchable applications.
- Unlock produces exactly one `userUnlocked` transition and one initial
  snapshot.
- Bridge restart replaces stale state without restarting Android or the
  compositor.
- Permission and SELinux denials are absent from the boot log.

## Phase 3: Generalize the Shell Application Model

Status: complete.

Replace the executable-shaped `LaunchableAppRecord` model in
`DesktopApplicationIndex.swift` with the provider-neutral contracts above.
Rename the merged index to `ApplicationCatalog`. Move desktop-file parsing and
process spawning behind `DesktopApplicationProvider`.

Update `LauncherService` to:

- own the merged catalog;
- attach/detach providers dynamically;
- route launch requests back to the record's provider;
- pass the user gesture's activation token;
- publish catalog changes to launcher UI state without reconstructing shell
  services;
- keep deterministic sorting and deduplication within each provider namespace.

Extend icon resolution once so shell UI accepts both theme names and raster
assets. Do not synthesize `.desktop` files or wrapper executables for Android
apps.

Verification gate:

- Existing native application discovery, preferred-app behavior, and process
  launch tests pass through `DesktopApplicationProvider`.
- Adding, updating, and removing a fake remote provider changes the live
  catalog deterministically.
- Provider failure removes its records while native launching continues.
- Theme icons and content-addressed raster icons render through one shell icon
  API.

Complete. `ApplicationCatalog` owns deterministic records from dynamically
attached providers and routes activation-bearing launch requests to the owning
provider. `DesktopApplicationProvider` exclusively owns desktop-file parsing,
opaque executable arguments, process launch, and launched-process lifetime.
Application IDs are namespaced, provider detach removes only that namespace,
and `LauncherService` no longer knows about desktop files or executable-shaped
records. Theme icons and content-addressed raster assets resolve through one
shell API. `collider test shell` passes the provider lifecycle, launch routing,
desktop discovery, icon, shell, and broader Linux test graph.

## Phase 4: Publish Android Applications

Status: implementation complete; full AOSP image compile in progress.

After unlock, the bridge queries enabled exported activities matching
`ACTION_MAIN` plus `CATEGORY_LAUNCHER` for the unlocked user. It publishes
component identity, label, categories, enabled state, and density-independent
icon source. The broker normalizes icons into bounded PNG assets and publishes
the initial provider snapshot.

Register package and user lifecycle callbacks for add, replace, remove, enable,
disable, suspension, and label/icon changes. Re-query only the affected package
and emit catalog deltas. A user stop or lock withdraws that user's records.

Exclude `FallbackHome`, non-exported activities, disabled components, suspended
packages, and activities that do not satisfy Android's launcher resolution
rules. Launcher3 itself remains discoverable as an application record even
while its desktop presentation is already visible.

Verification gate:

- The shell catalog matches `LauncherApps.getActivityList` after unlock.
- Package install, update, disable, enable, and uninstall each produce the
  correct incremental catalog change.
- Duplicate labels do not collide because component identity is authoritative.
- Icon cache replacement and garbage collection never leave a catalog record
  pointing at a missing asset.

Implemented. The session protocol now owns a same-UID, provider-neutral
`SOCK_SEQPACKET` publication channel. The Android broker publishes the
`android` provider through that channel, translates full and package-scoped
bridge snapshots into deterministic catalog changes, and stores bounded PNG
assets by content digest under the session runtime directory. Publication
precedes icon garbage collection, so a live record never references a removed
asset. Lock, user-stop, bridge-disconnect, and provider-disconnect paths
withdraw Android records without disturbing the desktop provider.

The platform-signed bridge now uses `LauncherApps.getActivityList` for the
current unlocked user, filters disabled, suspended, non-exported, fallback, and
non-launcher activities, preserves component identity independently of labels,
and emits package-scoped replacements for install, update, removal, enablement,
suspension, label, and icon changes. The bridge renders bounded launcher icons
to PNG and sends each content-addressed asset before any record references it.

`collider test shell` passes the provider transport, remote-provider lifecycle,
Android bridge validation, Android catalog publication, icon lifecycle, shell,
and broader Linux test graph. The canonical AOSP remote, exact manifest lock,
translated x86_64 Soong bootstrap on the arm64 Linux guest, and case-sensitive
AOSP output ownership are corrected. `collider build android-image` now passes
source synchronization, Soong bootstrap, case-sensitivity validation, Soong
graph generation, and Kati generation and has entered the main platform build.
Completing that image and validating publication on the running guest closes
the phase.

## Phase 5: Make Presentations Window-First

Refactor `NucleusAndroidDisplayHostCore` so physical `wl_output` discovery no
longer creates Android displays or fullscreen Android windows. A broker control
request creates an `AndroidPresentation`; Wayland configure establishes its
logical dimensions and the `wl_surface` output membership establishes the
owning output's scale, refresh, transform, and density.

The desktop presentation consumes the framework-owned host display output.
Application presentations use additional framework displays backed by opaque
RGBX `AImageReader` surfaces. Every framework display emits the same normalized
frame record: Nucleus gralloc dma-buf, allocation lifetime descriptor, acquire
fence, display identity, configuration generation, geometry, and damage. The
display host imports each source into an ordinary Wayland surface and returns a
pending native fence that is signaled after compositor retirement. Assign each
application presentation a stable opaque ID and carry its framework display ID
with its frames. Composer topology provides SurfaceFlinger pacing only; it does
not carry visible pixels or own host-display resize.

Window metadata is:

- desktop presentation: app ID `nucleus.android.desktop`, title `Android`;
- application presentation: stable app ID derived from package/activity and
  title from the Android application label;
- normal shell-managed size and placement, never direct fullscreen ownership;
- standard `xdg_activation_v1` activation, never compositor privilege.

Secondary application displays suppress Android system decorations. Android
dialogs, child activities, and additional tasks created within an application's
flow stay within that presentation's display. This phase does not extract
SurfaceFlinger layers or map Android task IDs to compositor surfaces.

Verification gate:

- The desktop presentation shows primary-display boot animation, lock screen,
  System UI, wallpaper, and Launcher3 through the framework host-display path.
- Two synthetic presentations create two independent Android virtual displays and
  present frames in two ordinary toplevels.
- Moving a window between mixed-density outputs updates its Android density
  without changing compositor scale policy.
- Resize, maximize, restore, output removal, and close produce ordered topology
  changes with no stale frame or descriptor leaks.

## Phase 6: Launch and Track Android Activities

Implement the provider launch transaction:

1. The shell validates the catalog record and sends the opaque activity ID plus
   activation token to the broker.
2. The broker requests an application presentation from the display host.
3. The bridge creates the configured Android virtual display and frame source.
4. The bridge resolves and acknowledges the Android display ID.
5. The bridge starts the exact component as the unlocked user with
   `FLAG_ACTIVITY_NEW_TASK` and `ActivityOptions.setLaunchDisplayId`.
6. Task observation reports the actual task/display outcome.
7. The broker binds the task group to the presentation and activates the
   toplevel.

Android remains authoritative about task reuse. If Android reuses an existing
task, the bridge reports its bound presentation and the broker closes the unused
new presentation, then activates the existing toplevel. A rejected,
non-exported, removed, or policy-blocked activity closes the provisional
presentation and returns a structured launch failure.

Track root-task lifecycle with platform task callbacks. Do not poll `dumpsys`.
One presentation owns one application task group; dialogs and same-flow tasks
remain Android-composed inside it.

Verification gate:

- Launching a catalog record opens the requested activity on its own secondary
  display and never flashes Launcher3 in that window.
- Relaunch activates Android's actual reused task instead of creating an empty
  duplicate window.
- App finish, force-stop, crash, package removal, host close, and runtime
  shutdown all converge on the presentation teardown state machine.
- The primary Launcher3 task remains on the desktop presentation throughout.

## Phase 7: Route Input and Focus

Add Wayland seat handling to each presentation for pointer motion/buttons,
axis scrolling, touch, keyboard, focus, and cancellation. Normalize coordinates
in logical window space, then transform them into the current Android display
pixel space using the same configure generation that produced the display mode.

The bridge owns one Android `VirtualMouse` and `VirtualKeyboard` for each
active presentation display. It converts the bounded host input protocol into
native virtual-device events; Android's existing uinput, InputReader, and
InputDispatcher pipeline owns hover movement, button choreography, key layouts,
repeat, modifiers, accessibility, and application dispatch. The Wayland
compositor remains the sole visible cursor authority; the bridge disables
Android pointer-icon composition for each host-presented display while its
virtual mouse exists and restores it during teardown. InputManagerService
publishes successful pointer-icon type changes to the platform bridge. The
broker retains the latest type for every display and replays it when a display
host connects; the display host maps standard Android pointer intent onto
`wp_cursor_shape_manager_v1` and applies it with the active pointer-enter
serial. Absolute touch uses a display-sized `VirtualTouchscreen`. Enable
Android's per-display focus policy in the Nucleus product overlay. Focus enter
updates the focused Android display/task; focus leave cancels active
touch/button/key state and presentation teardown closes its virtual devices.
Text input and IME use a dedicated text-input transaction rather than
synthesizing Unicode keycodes.

Do not synthesize framework `MotionEvent` or `KeyEvent` objects, create host
virtual input devices that re-enter Android through evdev, associate host
evdev ports with displays, forward host input-event devices into the
container, or adopt Waydroid's custom `/dev/input/wl_*` transport. The private
container `/dev/uinput` endpoint exists only so Android's own
`VirtualInputDevice` implementation can create its native devices.

Verification gate:

- Pointer, scrolling, multitouch, keyboard, repeat, modifiers, and focus target
  the correct display with two Android windows open.
- Resize during an active gesture either preserves the configure generation or
  cancels the gesture; it never injects coordinates using mixed generations.
- Closing or losing focus clears pressed keys, buttons, and touch contacts.
- Android IME composition works without stealing focus from another Android or
  native window.

## Phase 8: Complete Density, Resize, and Activation Semantics

Remove the hard-coded `ro.sf.lcd_density=160` policy. Use a product baseline only
until a presentation joins a host output, then derive Android density from that
output's logical-to-physical mapping. Clamp only to Android's supported density
range and preserve the exact host value in diagnostics.

Apply presentation resize in place to both the `AImageReader` surface geometry
and Android logical display. Coalesce superseded Wayland configure events at
display cadence, but acknowledge every configure according to Wayland rules.
Tag the Android relayout and every resulting frame with one current geometry
generation shared by frame validation and input transformation. Retire frames
from older generations without committing them. Commit new window geometry
only with a frame whose generation and dimensions exactly match the requested
configuration. Never scale or stretch a stale Android frame as a resize
preview.

Carry the original shell activation token through the launch transaction.
Subsequent Android-originated activation requests go to the shell policy
service, which may mint or deny a compositor activation token using the same
rules as native applications.

Verification gate:

- Android resources select the expected density buckets on 1x, fractional, and
  high-density outputs.
- Configuration changes reach the activity after resize without display
  reconnect or app restart unless Android itself requires recreation.
- Launch focus obeys the initiating activation token, and background Android
  processes cannot unconditionally steal focus.

## Phase 9: Bridge the Clipboard

Integrate Android `ClipboardManager` with the shell's native clipboard service
through the broker. Start with UTF-8 plain text. Carry MIME type, source side,
and monotonic generation so mirrored updates do not loop. Read clipboard data
lazily where the source protocol supports it and enforce payload bounds.

Clipboard ownership belongs to the shell service, not the compositor and not
the display host. Android runtime disappearance withdraws Android-owned
clipboard offers without affecting native ownership.

Verification gate:

- Copy/paste works in both directions between native and Android applications.
- Repeated identical content and rapid alternating changes do not echo-loop.
- Runtime shutdown, user lock, and source exit invalidate inaccessible offers.

## Phase 10: Bridge Notifications

The Android bridge observes notifications with a narrowly privileged
notification-listener implementation and sends normalized post/replace/remove
events to the broker. The broker exposes them to `NotificationService` through
a provider-neutral notification source contract.

Map Android notification key, application identity, title, body, icon, urgency,
progress, and supported actions. Activation returns through the broker so the
bridge executes the notification's `PendingIntent`; the shell applies normal
activation policy before the resulting presentation is focused.

Do not duplicate Android SystemUI notification chrome in application windows.
The native Nucleus notification surface is the host presentation.

Verification gate:

- Post, update, grouping replacement, dismissal, app cancellation, action, and
  runtime shutdown maintain one consistent native notification state.
- Activating a notification launches or focuses the resulting Android task
  through the presentation transaction.
- No arbitrary Android intent or host command can be supplied by notification
  payload data.

## Phase 11: Integrate Lifecycle and Remove Bring-Up Paths

Make the background broker the only supported Android session path. Delete
replaced Collider-only orchestration, output-driven display creation, fixed
density, direct screenshot readiness assumptions, and any obsolete launch
wrappers in the same change as their final callers move.

Expose structured diagnostics for:

- container and framework generation;
- user-unlock and bridge generation;
- provider snapshot/delta sequence;
- presentation state and configure generation;
- composer token and Android display ID;
- launch request, component, task, and activation result;
- input drops, clipboard generation, and notification key;
- teardown reason and resource counts.

Extend Collider's Android integration harness to exercise background session
boot, unlock readiness, catalog publication, application launch, two concurrent
presentations, input, resize/density, clipboard, notifications, package
mutation, app crash, and clean shutdown. Behavioral tests assert protocol and
runtime outcomes, not declaration or source shape.

Final verification gate:

- Use the installed `collider` command to build the complete checkout and run
  all affected Swift and Android integration tests; its workspace launcher owns
  host-environment derivation and release-executable refresh.
- Boot a clean generated Android data image and pass every phase's behavioral
  gate without manual setup.
- Boot the non-Android product composition and demonstrate identical native
  compositor, shell, application, clipboard, and notification behavior.
- The compositor binary, compositor protocols, and compositor policy contain
  no Android-specific branch, identifier, or privileged-client exception.

## Explicit Non-Goals

- No Waydroid vendor window/task/display/clipboard HAL.
- No task-ID grouping in HWC and no SurfaceFlinger layer extraction.
- No Android-owned Wayland connection.
- No single-window versus multi-window rendering modes.
- No Trebuchet/Lineage dependency, GApps default, fingerprint spoofing, or
  graphics fallback matrix.
- No synthesized desktop files, shell scripts, or subprocess wrappers for
  Android applications.
- No compositor feature flag for Android and no Android dependency in the
  compositor package graph.
- No replacement of Launcher3 during this phase set.
