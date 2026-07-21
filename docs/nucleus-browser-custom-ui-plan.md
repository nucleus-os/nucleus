# Nucleus Browser Custom UI Plan

## State invariant

Nucleus Browser is a native Swift application shell built with `NucleusUI`. Chromium remains the
web engine, browser-service implementation, and multi-process security boundary; Chromium Views
does not remain the product UI.

Across every phase boundary:

1. **NucleusUI owns browser chrome.** Windows, tabs, sidebars, spaces, toolbars, menus, settings,
   prompts, and product animations are authored in Swift against public `NucleusUI` APIs.
2. **Chromium owns web semantics.** `Profile`, `BrowserContext`, `WebContents`, navigation,
   extensions, downloads, permissions, history, sessions, media, DevTools, printing, and renderer
   process lifetime remain authoritative in Chromium C++.
3. **The integration is in-process.** Swift and the Chromium browser adapter live in the browser
   process. Chromium renderer, GPU, network, and utility processes retain their production process
   boundaries and sandboxes.
4. **The bridge is a narrow C ABI.** It carries opaque handles, scalars, immutable value snapshots,
   callbacks, and commands. Chromium C++ types, STL types, and Swift object representations never
   cross it.
5. **There is one owner for each state.** Chromium owns engine and resource lifetime; Swift owns
   Nucleus product organization and presentation. The bridge reports state rather than maintaining
   a second authoritative copy.
6. **Web content remains on the on-screen Chromium path.** Blink and Viz render through
   Graphite/Dawn/Vulkan and Ozone Wayland. A page is never converted into a CEF OSR stream, CPU
   bitmap, or periodically copied texture for the custom browser UI.
7. **Browser chrome remains on the Nucleus renderer.** NucleusUI renders through the native Nucleus
   Graphite/Vulkan stack. Chromium and Nucleus select the compositor-presenting Vulkan device and
   exchange explicit fences at their shared presentation boundary.
8. **Wayland composition is explicit and atomic.** One browser-process Ozone Wayland connection owns
   the toplevel and child surfaces. Content and native chrome are committed through one coordinated,
   synchronized surface transaction.
9. **There is one shipped UI.** The current Chromium Views browser remains a bring-up and diagnostic
   reference only until feature parity. It is not retained as a runtime fallback after cutover.
10. **The source tree is shared.** The custom browser, reference Chromium browser, and CEF build from
    the same pinned Chromium checkout and common patch foundation. Product UI work does not create a
    second Chromium build system or source fork.

## Context

The existing Nucleus Browser work establishes the engine and presentation foundation:

- native Wayland presentation;
- Skia Graphite through Dawn Vulkan;
- compositor-GPU selection;
- DMA-BUF and explicit synchronization;
- accelerated VA-API video decode;
- the Chromium sandbox and site-isolated process model;
- a repeatable browser build, install, launch, and diagnosis path.

Its current product surface is still Chromium's Views UI with Nucleus-specific branding and
defaults. The experimental Chromium-Views glass styling has been removed rather than expanded:
it proved the limits of maintaining a custom visual system inside Chrome's view hierarchy. That
engine bring-up client is not the intended final Nucleus product architecture. Restyling
`BrowserView`, the tab strip, omnibox, and Views bubbles would make the product increasingly
dependent on upstream hierarchy churn while leaving NucleusUI outside the browser.

The next step is to replace the product shell while preserving the engine that now works. The
existing `core/docs/appkit-api-plan.md` makes `NucleusUI` the AppKit-like authoring front door. The
browser becomes its second demanding production client after the native shell: the shell proves
desktop controls and services, while the browser proves hosted content, dense navigation,
transient UI, accessibility, text input, drag and drop, and high-frequency window composition.

## Historical precedent

Arc used the same broad product split. The Browser Company publicly described Arc as Chromium-based
for website and extension compatibility while building its application shell in Swift. Its
historical account describes replacing an early Electron direction with Swift, and Arc engineer
Nate Parrott described a Chromium-wrapping browser SDK consumed by the Swift application.

References:

- [Arc FAQ: Chromium and Swift](https://arc.net/faq)
- [The Browser Company: switching from Electron to Swift](https://podcasts.apple.com/ca/podcast/repositioning-the-entire-company-towards-one-goal/id1758984150?i=1000668460241)
- [Arc engineering interview: Chromium SDK and Swift shell](https://shoptalkshow.com/545/)
- [The Browser Company's Swift/WinRT C-ABI tooling](https://github.com/thebrowsercompany/swift-winrt)

Arc's private embedding implementation is not a specification for Nucleus. The durable lesson is
the ownership split: retain Chromium's web platform and browser machinery, then replace the product
shell rather than continuing to modify Chrome's shell.

## Target architecture

```text
NucleusBrowserProduct (Swift, public NucleusUI)
  window composition, sidebar, tabs, spaces, toolbar, menus, settings
                              │
                       typed Swift models
                              │
NucleusBrowserRuntime (Swift platform host)
  event routing, hosted-content geometry, presentation coordination
                              │
                    NucleusBrowserCoreC ABI
  opaque window/tab/profile handles, commands, snapshots, callbacks
                              │
NucleusBrowserCore (C++, Chromium browser process)
  BrowserWindowInterface, Profile, WebContents, Chrome services
                              │
       Chromium renderer/GPU/network/utility processes
  Blink → Viz → Graphite/Dawn/Vulkan → DMA-BUF → Ozone Wayland

Nucleus browser chrome
  NucleusUI → NucleusRenderer → Graphite/Vulkan → DMA-BUF
                              │
           coordinated Ozone Wayland surface transaction
                              │
                         compositor
```

The browser process is the integration unit. Swift is not a remote frontend controlling a hidden
browser daemon. A separate UI process would require a new protocol for focus, input methods,
accessibility, drag and drop, transient windows, page popups, cursor state, window lifetime, and
frame synchronization while also preventing straightforward Wayland subsurface ownership. That
protocol does not improve the product or security model; Chromium already provides the relevant
process isolation below the browser process.

## Ownership model

| Responsibility | Authoritative owner | Nucleus-facing representation |
|---|---|---|
| Profile and storage partition | Chromium | opaque profile handle and immutable profile summary |
| `WebContents` and renderer lifetime | Chromium | opaque tab handle |
| Navigation history and loading state | Chromium | tab snapshot plus ordered events |
| Extension execution and permissions | Chromium | commands and presentation requests |
| Downloads and browser permissions | Chromium | observable models backed by Chromium services |
| Spaces, pinned organization, sidebar grouping | Swift | native product model |
| Window and view hierarchy | Swift/NucleusUI | `NucleusBrowserProduct` |
| Focused page, active tab, and key window | joint transaction | Chromium tab identity applied by Swift window intent |
| Page pixels | Chromium Viz | hosted content surface |
| Browser chrome pixels | NucleusRenderer | native chrome surface |
| Wayland toplevel and child-surface lifecycle | Chromium Ozone host | narrow runtime host operations |

Swift may persist Nucleus-specific organization such as spaces and pinned grouping. Chromium
persists browsing data and engine session state. Restoration joins the two through stable Nucleus
tab identifiers mapped to new opaque Chromium handles; neither side serializes the other's object
graph.

## Chromium integration boundary

The implementation reuses `chrome/browser`, not merely `content_shell`.

`content::WebContents` and `//content/public` are designed for embedders, but a complete browser also
depends on services above `//content`: extensions, autofill, history, downloads, permissions,
credentials, session restore, Safe Browsing integration, DevTools, printing, and browser-level
media behavior. Rebuilding those services in Swift would discard mature Chromium behavior and
create a permanent security and maintenance burden.

The principal C++ seam is a Nucleus implementation of Chromium's current browser abstractions:

- `BrowserWindowInterface` for the browser window and window-scoped feature host;
- `tabs::TabInterface` and existing tab collections for tab identity and lifecycle;
- `Profile` and `BrowserContext` for user data and storage;
- `content::WebContents` for hosted page content;
- `BrowserWindowFeatures`, `TabFeatures`, and `//components` services for reusable behavior;
- explicit presentation delegates for UI that Chromium normally implements with Views.

Legacy code that still requires `Browser`, `BrowserView`, or a Views-specific bubble is migrated by
feature. The underlying controller or service remains; only its presentation adapter changes. New
Nucleus product behavior never calls into Views.

## ABI contract

The C ABI is compiled from the same source tree and therefore has no version, schema, or capability
negotiation. A mismatch is a build failure.

The ABI uses:

- reference-counted or explicitly retained opaque handles for profiles, windows, and tabs;
- caller-owned UTF-8 strings and byte spans with explicit lifetime;
- fixed-layout value structs for geometry, modifiers, navigation state, and presentation requests;
- callback tables registered during startup;
- explicit create, retain, release, and shutdown operations;
- a browser-UI-thread rule for all state mutation;
- task posting for calls originating outside that thread;
- monotonically increasing event sequence numbers only where asynchronous ordering requires them.

The ABI does not use:

- raw C++ pointers as Swift identities;
- C++ exceptions across the boundary;
- STL containers or Chromium smart pointers in exported declarations;
- Swift closures retained by C++ without an explicit cancellation token;
- synchronous C++ calls into arbitrary Swift UI code while Chromium is inside a re-entrant
  lifecycle callback.

Swift product modules do not import a C++ module. `NucleusBrowserRuntime` consumes a C target that
declares the ABI, following the workspace's existing non-C++ module boundary rules.

## Hosted page composition

`BrowserContentView` is a specialized NucleusUI view whose content is owned by Chromium. Product
code treats it as a normal view for layout, clipping, visibility, focus, and accessibility
containment; it cannot access a Vulkan image or DMA-BUF.

The Wayland host implements it with three roles on one Ozone connection:

1. a commit-only toplevel container surface;
2. a Chromium content child surface presented by the existing Ozone DMA-BUF presenter;
3. a transparent Nucleus chrome child surface presented from NucleusRenderer-owned buffers.

The chrome surface may cover the window while using a precise Wayland input region so page input
passes directly to Chromium outside interactive chrome. Reserved chrome such as a sidebar changes
the content surface geometry; overlay chrome remains above it. Synchronized subsurface state and a
single parent commit make geometry, damage, scale, and visibility changes atomic.

NucleusRenderer renders browser chrome into exportable images on the same Vulkan device. It hands
the image, damage, and render-complete fence to the Ozone presentation coordinator. Ozone attaches
the image without a copy and returns compositor release before Nucleus reuses it. Chromium content
uses its existing corresponding lifecycle. The coordinator never waits on a GPU fence on the UI
thread.

This preserves:

- Chromium's normal on-screen rendering and hardware-video path;
- Nucleus's native Graphite/Vulkan renderer;
- compositor-provided blur behind transparent Nucleus chrome;
- fractional scale, output changes, explicit synchronization, and presentation feedback;
- independent damage for page content and browser chrome;
- a future unified frame cadence without a timer-driven pixel transport.

## Product surface policy

Every user-visible browser surface receives an explicit owner:

- **NucleusUI:** tabs, sidebar, spaces, toolbar, omnibox presentation, command palette, menus,
  settings, download UI, permission UI, extension action UI, history UI, bookmarks UI, window
  controls, profile UI, and product notifications.
- **Chromium content:** webpages, PDF content, DevTools content, extension pages, WebUI content kept
  as page content, HTML select popups whose renderer contract requires Chromium ownership, and
  page-created fullscreen or picture-in-picture content.
- **Platform host:** file dialogs, compositor window roles, clipboard, drag and drop, input methods,
  cursors, accessibility export, and native portal interactions.

Using a Chromium WebUI page for complex browser data does not make it browser chrome. NucleusUI
owns the surrounding product presentation and navigation. A WebUI page is hosted as content only
when retaining the upstream implementation has material security or maintenance value.

## Sequential implementation

### Phase 0 — Freeze the engine reference

Preserve the current Nucleus Browser executable as the engine reference while the custom shell is
incomplete.

- Keep the working Graphite/Dawn/Vulkan, Wayland, sandbox, VA-API, Widevine, and installer paths.
- Stop adding product design to Chromium Views.
- Limit Views patches to correctness required by the reference executable.
- Record the browser behaviors that the native client must replace: window lifecycle, navigation,
  tabs, profile restoration, downloads, permissions, extensions, DevTools, fullscreen, PiP,
  dialogs, accessibility, input methods, drag and drop, and crash recovery.
- Add a separate custom-shell build target using the same checkout and common patch foundation.

**Lands with:** the reference browser and custom-shell target build from one source preparation and
one set of engine patches.

### Phase 1 — Establish the native product and ABI

Create the first-party browser package and native adapter without introducing UI parity work.

- Add `browser/Package.swift`.
- Add `NucleusBrowserProduct`, importing public `NucleusUI` only for product views.
- Add `NucleusBrowserRuntime` for lifecycle, event delivery, and hosted-surface integration.
- Add a C target containing the `NucleusBrowserCoreC` declarations.
- Add canonical C++ adapter sources under the workspace's Chromium integration directory; source
  preparation stages them into the Chromium checkout rather than encoding new source files as
  large patches.
- Add a custom Chromium executable target whose C++ entry point initializes Chromium and the Swift
  product in one browser process.
- Establish browser-UI-thread dispatch, explicit shutdown, and callback cancellation.

**Acceptance:** a native Nucleus window starts and exits cleanly while Chromium initializes a real
profile, with no `WebContents` yet created and no Views UI instantiated.

### Phase 2 — Implement atomic Wayland hosting

Build the presentation boundary before building product UI on top of it.

- Make Ozone the sole owner of the browser-process Wayland connection.
- Create the toplevel container and synchronized content/chrome child surfaces.
- Add the Nucleus external presentation target that exports a chrome buffer and render-complete
  fence without CPU readback.
- Return compositor release fences before buffer reuse.
- Coordinate child geometry, input regions, scale, damage, and parent commits.
- Drive frame demand from Wayland frame callbacks and presentation feedback.
- Handle zero extent, resize, output migration, fractional scale, suspend/resume, and surface
  destruction.
- Require matching Vulkan device UUID and DRM render node for Chromium and Nucleus.

**Acceptance:** a NucleusUI test surface and a Chromium-colored test surface resize and animate in
one toplevel with synchronized commits, correct transparency, clean Vulkan validation, and stable
buffer/fence counts.

### Phase 3 — Host one real `WebContents`

Create the smallest real browser vertical slice.

- Implement the initial `NucleusBrowserWindow` and required `BrowserWindowInterface` behavior.
- Create one normal profile and one `WebContents` through Chromium's production browser services.
- Expose it to Swift as an opaque tab handle.
- Add `BrowserContentView` to `NucleusUI`/`NucleusUIEmbedder` as the hosted-content abstraction.
- Map its layout, clip, visibility, scale, and focus to the content child surface.
- Forward pointer, keyboard, cursor, and wheel behavior without synthetic OSR events.
- Show renderer and GPU crashes as an explicit native error state while Chromium recovery runs.

**Acceptance:** the custom Nucleus window loads an arbitrary webpage, supports navigation and
hardware-accelerated video, and remains interactive through resize, scale changes, renderer crash,
GPU-process restart, and window close.

### Phase 4 — Build the native browser model and primary chrome

Move the core browsing workflow into Swift.

- Implement the native sidebar, tab collection, active-tab selection, pinned organization, and
  spaces model.
- Implement toolbar commands, back/forward/reload/stop, location editing, security-state
  presentation, and page loading state.
- Keep Chromium authoritative for navigation entries and tab lifetime.
- Persist only Nucleus-specific organization in Swift.
- Add native window restoration that rejoins persisted organization with restored Chromium tabs.
- Implement split-view product state while retaining one `WebContents` and hosted surface per pane.

**Acceptance:** daily browsing, tab creation/closure/reordering, spaces, pinned tabs, navigation,
split view, restart restoration, and crash recovery work without a visible Chromium tab strip,
toolbar, or omnibox.

### Phase 5 — Complete input, focus, and accessibility

Make the mixed native/content hierarchy behave as one application.

- Define one first-responder transition between Nucleus controls and `WebContents`.
- Complete IME preedit, commit, surrounding text, selection, deletion, and input-panel behavior.
- Route browser accelerators before page input while preserving web application shortcuts.
- Implement pointer capture, cursor requests, drag thresholds, autoscroll, and mouse history buttons.
- Bridge clipboard and drag-and-drop offers without duplicating payload ownership.
- Export one accessibility tree with native chrome nodes and a hosted Chromium subtree.
- Restore focus deterministically after menus, permission prompts, fullscreen, tab changes, and
  renderer replacement.

**Acceptance:** keyboard-only browsing, screen-reader traversal, text composition, drag and drop,
clipboard, pointer capture, and browser/page shortcuts match the reference browser.

### Phase 6 — Replace transient browser UI

Replace the Views surfaces that mature browser services request.

- Add a presentation-request vocabulary for anchored bubbles, modal sheets, menus, toasts, and
  window-scoped prompts.
- Implement permissions, authentication, certificate errors, downloads, find-in-page, zoom,
  translation, password/autofill prompts, and blocked-content indications in NucleusUI.
- Provide native anchors derived from Nucleus view geometry.
- Preserve Chromium controller lifetime and decision semantics.
- Guarantee exactly one completion for every prompt during accept, cancel, tab close, window close,
  renderer crash, and shutdown.

**Acceptance:** no common browsing action constructs a Views widget or becomes blocked on a hidden
Chromium prompt.

### Phase 7 — Complete extensions and browser-owned pages

Retain Chromium's extension engine while replacing its browser chrome.

- Surface extension actions, badges, context menus, permissions, install confirmation, and error
  reporting through NucleusUI.
- Host extension pages, settings pages, history, downloads, bookmarks, and retained upstream WebUI
  implementations as content views inside native Nucleus navigation.
- Integrate DevTools as a hosted tab, docked hosted surface, or separate native Nucleus window.
- Preserve extension keyboard commands, side panels, popups, and content-script behavior.

**Acceptance:** supported Chrome extensions install, update, expose actions, open popups, request
permissions, and survive restart without exposing the Chromium toolbar.

### Phase 8 — Complete window and media roles

Implement all nonstandard browser windows through the native host.

- Multiple normal windows and profiles.
- Browser popups and page-created windows.
- HTML fullscreen with browser accelerator interception and correct restoration.
- Document and video picture-in-picture.
- Installed web apps and app popups.
- File chooser, print preview, PDF handling, capture indicators, and media permission surfaces.
- Niri and conformant-compositor placement, activation, fullscreen, blur, and animation behavior.

**Acceptance:** every Chromium `BrowserWindowInterface::Type` retained by Nucleus has a deliberate
native role and lifecycle; unsupported product types fail explicitly rather than constructing a
partial Views window.

### Phase 9 — Harden scheduling, recovery, and performance

Make the native shell at least as stable and responsive as the reference client.

- Use presentation feedback to coordinate Nucleus chrome and Chromium content cadence.
- Preserve independent damage so static chrome does not repaint with animated web content.
- Eliminate UI-thread fence waits, queue-idle waits, frame polling, and redundant full-window
  redraws.
- Bound retained surfaces and inactive-tab resources.
- Complete monitor-off, output removal, suspend/resume, GPU-process restart, renderer crash,
  compositor reconnect, and browser-process shutdown behavior.
- Verify VA-API decode, overlays, WebGL, WebGPU, Widevine, transparency, and compositor blur through
  the custom shell.

**Acceptance:** validation is clean; frame pacing follows the active output; animations remain
smooth at 120 Hz; monitor power transitions and output changes do not lose windows; browser chrome
adds no persistent copy to the page frame path.

### Phase 10 — Cut over to the native product

Make NucleusUI the only product shell.

- Install and launch the custom executable as Nucleus Browser.
- Remove the remaining vertical-tab defaults and branding behavior implemented by patching
  Chromium Views; the experimental glass styling was retired before this phase.
- Remove custom-shell dependencies on `BrowserView` and Views bubble implementations.
- Retain the unmodified reference Chromium target only as a developer engine diagnostic.
- Update `docs/nucleus-browser-plan.md` so the engine plan points to this document for product UI.
- Document the final ABI ownership, surface transaction, shutdown, and recovery contracts.

**Final acceptance:** Nucleus Browser presents a complete native Swift/NucleusUI product shell,
hosts Chromium pages through the production on-screen Graphite/Dawn/Vulkan path, retains Chromium's
sandboxed browser behavior, and contains no runtime fallback to the modded Chromium UI or CEF OSR.

## Verification matrix

Every phase adds behavioral coverage at the owning layer:

- **ABI:** handle lifetime, callback cancellation, UI-thread dispatch, shutdown, and re-entrancy.
- **NucleusUI:** browser layout, sidebar/toolbar interaction, focus, accessibility, menus, prompts,
  and restoration using an in-memory browser-core test double.
- **Chromium adapter:** `BrowserWindowInterface`, tab/profile lifecycle, feature-controller
  presentation requests, renderer replacement, and session restoration.
- **Presentation:** child-surface transactions, resize, damage, input regions, explicit fences,
  scale changes, output migration, and release-before-reuse.
- **Browser behavior:** navigation, extensions, downloads, permissions, authentication, DevTools,
  fullscreen, PiP, printing, PDFs, and installed apps.
- **Media/GPU:** Graphite/Dawn/Vulkan, WebGL, WebGPU, VA-API NV12/P010, overlays, AAC/H.264, Widevine,
  GPU-process recovery, and Vulkan validation.
- **Live Wayland:** niri placement, blur, transparency, 120 Hz pacing, multiple outputs, monitor
  power-off/on, suspend/resume, compositor restart, and fractional scaling.

## Relationship to existing plans

- `docs/nucleus-browser-plan.md` remains authoritative for Chromium engine configuration,
  Graphite/Dawn/Vulkan, Ozone Wayland presentation, GPU selection, sandboxing, and hardware video.
- `core/docs/appkit-api-plan.md` remains authoritative for the public NucleusUI authoring contract.
- `shell/docs/noctalia-migration-plan.md` remains authoritative for the native desktop shell port.
- This document owns the browser product shell, Chromium-to-Swift boundary, hosted page surface,
  and removal of Chromium Views from the shipped Nucleus Browser UI.

Framework capability shared by the native shell and browser lands in NucleusUI. Browser semantics
and Chromium service adapters remain in the browser workstream. Shell behavior does not become a
browser dependency, and browser integration does not become a privileged backdoor into NucleusUI.
