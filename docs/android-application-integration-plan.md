# Android Application Integration Plan

## Invariant

Android is an optional session capability and an ordinary client of the Nucleus
desktop stack. The compositor never learns about Android packages, activities,
tasks, Binder, container state, or Android-specific window roles. Every Android
presentation is a normal `xdg_toplevel`, every frame continues through the
existing composer/display-host path, and every Android integration operation
crosses a narrow versioned runtime protocol.

The Android runtime boots in the background with the user session. During
bring-up, it automatically creates one desktop presentation for Android's
primary display, so Launcher3 remains visible. That presentation uses the same
window/display machinery as application presentations. Productionization later
removes the automatic desktop-presentation request; it does not introduce a
second renderer, a compatibility mode, or a compositor feature flag.

An OS image without Android omits the Android runtime broker, Android image, and
its session-capability declaration. It uses the same compositor and shell
binaries. Native application discovery and launching remain fully functional
when no Android application provider connects.

## Implementation Status

Status as of 2026-07-29:

| Phase | Status | Remaining gate |
| --- | --- | --- |
| 1. Production Android runtime | Implementation complete; non-interactive gates pass | Run a normal installed session through Launcher3 and verify post-session process, mount, socket, and window cleanup when interactive validation is requested |
| 2. Platform-signed Android bridge | Implementation complete through the signed-image gate | Validate direct boot, one unlock transition, one initial snapshot, reconnect, and denial-free logs in a runtime session |
| 3. Shell application model | Not started | Begin after the Phase 2 image and protocol gates pass |
| 4. Android application publication | Not started | Depends on Phase 3 |
| 5. Window-first presentations | Not started | Depends on Phase 4 |
| 6. Android activity launch and tracking | Not started | Depends on Phase 5 |
| 7. Input and focus | Not started | Depends on Phase 6 |
| 8. Density, resize, and activation | Not started | Depends on Phase 7 |
| 9. Clipboard | Not started | Depends on Phase 8 |
| 10. Notifications | Not started | Depends on Phase 9 |
| 11. Lifecycle integration and bring-up removal | Not started | Depends on Phase 10 |

Phase 1 now includes:

- generic, versioned session-capability declarations and supervisor-owned
  start, restart, and teardown policy with no Android-specific supervisor role;
- Android-owned lifecycle, image validation, host prerequisite resolution,
  mount/container supervision, health monitoring, diagnostics, and cleanup in
  `NucleusAndroidRuntimeCore`;
- Android-owned Linux process, binderfs, pseudo-terminal, APEX, BPF, cgroup,
  and privileged-helper implementations;
- the persistent `nucleus-android-runtime` broker and
  `nucleus-android-runtime-privileged` helper;
- optional Android payload staging, relocation validation, and generation of
  `share/nucleus/session-capabilities/android.json`;
- Collider reduced to a frontend over the Android-owned lifecycle rather than
  a second Android runtime owner.

The completed Phase 1 verification is:

- 16 Android runtime/bridge protocol tests and the container configuration
  contract test pass;
- all 14 session-supervisor acceptance tests pass, including capability
  readiness ordering, restart policy, shared teardown, unavailable optional
  capability behavior, and a session with no capability declaration;
- all 26 focused Collider framework-boot tests pass;
- a real disposable session generation containing the four Android
  executables and its capability declaration passed ELF dependency and
  relocation validation;
- `git diff --check` passes.

Phase 2 currently includes:

- a bounded, versioned `SOCK_SEQPACKET` bridge protocol with peer credential
  checks, runtime generations, reconnect semantics, duplicate-unlock
  rejection, and no file-descriptor transfer;
- a host-owned bridge socket directory mounted read-only at
  `/dev/nucleus-runtime` inside Android;
- `NucleusRuntimeBridge` as a platform-signed, privileged,
  direct-boot-aware persistent app on `system_ext`;
- outbound bridge connection, protocol negotiation, current user serial,
  locked/unlocked runtime state, and one initial empty activity snapshot after
  unlock;
- a dedicated `nucleus_runtime_bridge` SELinux domain and
  `nucleus_runtime_socket` core-domain socket label.

The Phase 2 AOSP gate compiled the Java app, installed its APK at
`system_ext/priv-app/NucleusRuntimeBridge`, passed SELinux policy compilation,
and published a signed image generation. The first policy pass correctly
rejected a generic socket type; the endpoint is now classified as a
`coredomain_socket`. No runtime-session claim is made until the subsequent
denial-free boot validation finishes.

## Final Ownership

| Component | Owns | Must not own |
| --- | --- | --- |
| Session supervisor | Starting declared session capabilities, descriptor inheritance, lifetime and restart policy | Android boot commands, package knowledge, Android readiness rules |
| Shell application services | Merged application catalog, launcher UI, provider-neutral launch dispatch, activation | Container boot, Binder calls, Android display allocation |
| Android runtime broker | Container lifecycle, runtime readiness, bridge connection, presentation orchestration, Android provider implementation | Compositor policy, Android framework internals |
| Android display host | Wayland toplevels, configure/scale/output state, composer display topology, frame presentation, Wayland input capture | Package discovery, activity launches, task policy |
| Nucleus Android bridge | User/package observation, activity launch, display-ID resolution, task observation, input injection, clipboard and notifications | Wayland, Vulkan, dma-buf presentation, host desktop policy |
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

Use a private versioned `SOCK_SEQPACKET` protocol with bounded messages and peer
credential validation. Keep it independent of the composer frame protocol.
The protocol contains:

- runtime state: `frameworkStarted`, `userUnlocked`, `bridgeReady`, and
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

The display host creates and configures the `xdg_toplevel` before publishing the
composer display. The composer hotplugs the display only after a nonzero logical
size, scale, refresh rate, and density are known. The Android bridge resolves
the resulting framework display ID and acknowledges it before an activity is
launched with `ActivityOptions.setLaunchDisplayId`.

Closing a host window first unmaps it, asks the bridge to finish/remove its
owned task group, waits for task disappearance, disconnects the composer
display, and destroys the Wayland objects. If Android finishes the task first,
the same teardown begins from `taskVanished`. Broker, bridge, or display-host
failure closes every presentation through this path. A disappearing secondary
display must never move an abandoned task onto the Launcher3 desktop.

The initial Launcher3 window is a presentation with purpose `desktop`. It owns
the primary Android display and is requested automatically by the broker during
bring-up. Application windows use purpose `application` and secondary displays.
There is still one display-host/composer implementation.

## Phase 1: Extract the Production Android Runtime

Move reusable Android boot/container orchestration out of
`ColliderCommands/AndroidFrameworkBoot.swift` into Android-owned Swift targets.
Keep Collider as a command frontend that calls the same runtime library used by
the session executable.

Add:

- `NucleusAndroidRuntimeCore` for image validation, mount/container setup,
  process supervision, readiness, shutdown, and diagnostics;
- `nucleus-android-runtime` as the background broker executable;
- an Android runtime session-capability declaration installed only with the
  Android product payload;
- generic session-supervisor support for declared capability processes and
  their descriptor attachments.

The supervisor does not gain an `androidRuntime` process role or Android
conditionals. It launches an installed capability declaration using the generic
service mechanism. The capability publishes an application-provider endpoint
to the shell and owns its internal bridge/display-host endpoints.

Replace Collider's duplicated launch and cleanup path in the same phase. The
broker becomes the single owner of Android runtime lifetime. A broker exit
tears down the container, display host, sockets, mounts, and catalog provider.

Verification gate:

- Collider's framework-boot command still reaches the existing Launcher3
  screenshot through `NucleusAndroidRuntimeCore`.
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
- authenticates the protocol version and runtime generation;
- reports `ACTION_USER_UNLOCKED` and the current user serial;
- uses platform APIs for launcher activity queries, display observation,
  activity/task control, input injection, clipboard, and notification access;
- reconnects after framework/service restart and replaces all previously
  published state with a new generation.

Add only the exact privileged permissions and SELinux rules required by those
operations. Keep `ro.control_privapp_permissions=enforce`. Do not add a custom
HAL, a custom Wayland protocol, a framework-wide service, or broad device
access.

Change runtime readiness so `sys.boot_completed` means only that Android booted.
The application provider becomes ready only after the bridge reports user
unlock and supplies its initial activity snapshot.

Verification gate:

- The bridge connects before unlock but exposes no launchable applications.
- Unlock produces exactly one `userUnlocked` transition and one initial
  snapshot.
- Bridge restart replaces stale state without restarting Android or the
  compositor.
- Permission and SELinux denials are absent from the boot log.

## Phase 3: Generalize the Shell Application Model

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

## Phase 4: Publish Android Applications

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

## Phase 5: Make Presentations Window-First

Refactor `NucleusAndroidDisplayHostCore` so physical `wl_output` discovery no
longer creates Android displays or fullscreen Android windows. A broker control
request creates an `AndroidPresentation`; Wayland configure establishes its
logical dimensions and the `wl_surface` output membership establishes the
owning output's scale, refresh, transform, and density.

Extend `ComposerOutputTopologyState` and the native composer protocol so
presentations can be added, reconfigured, and removed independently. Preserve
the existing dma-buf, explicit-sync, and release-fence frame path. Assign each
presentation a stable composer display token that the Android bridge can
correlate with the framework display's unique ID.

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

- The desktop presentation still renders Launcher3 through the refactored path.
- Two synthetic presentations hotplug as two independent Android displays and
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
3. The configured presentation is hotplugged into Android.
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

The bridge constructs display-targeted Android input events and injects them
through `InputManager` with the minimum platform permission. Enable Android's
per-display focus policy in the Nucleus product overlay. Focus enter updates the
focused Android display/task; focus leave cancels active touch/button state.
Key repeat is generated in one layer only. Text input and IME use a dedicated
text-input transaction rather than synthesizing Unicode keycodes.

Do not create host `/dev/uinput` devices, associate evdev ports with displays,
or forward a privileged input device into the container.

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

Apply presentation resize as an Android display mode/configuration change.
Coalesce superseded Wayland configure events, but acknowledge every configure
according to Wayland rules. Keep one current geometry generation shared by
frame validation and input transformation.

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

- Source `tools/host-env.sh`, build the complete checkout through Collider, and
  run all affected Swift and Android integration tests.
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
