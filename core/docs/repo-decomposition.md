# Repository decomposition: core, RN platform, compositor, shell

## Invariant

Nucleus is four repositories with an acyclic dependency graph and one hard rule: **React
is a leaf, not a foundation.** The render/UI core knows nothing about React; the React
Native platform is an out-of-tree layer that binds React to the core; the compositor is a
pure Wayland/DRM compositor that links no React at all; the shell is an ordinary Wayland
client that talks to the compositor over standard protocols.

```
        nucleus  (render/UI core — Skia/Vulkan, layer tree, renderer, app-host; React-agnostic)
       ╱                                        ╲
react-native-nucleus                        nucleus-compositor
(RN ⇄ core platform + app SDK)              (pure Wayland/DRM/input + compositing;
       │                                     window management in Swift; render core only; no RN)
       │                                              ╎
nucleus-shell  ╌╌╌╌╌╌╌ standard protocols ╌╌╌╌╌╌╌╌╌╌╌╌╯
(bars/dock/launcher — a layer-shell client)   (layer-shell, foreign-toplevel, session-lock, screencopy)
```

`nucleus-compositor` and `nucleus-shell` have **no build-time relationship**. They meet only
at runtime, over standard Wayland protocols — niri and noctalia, not Mutter and its shell.
The compositor is swappable under the shell and the shell is swappable under the compositor.

The reason this is clean rather than aspirational: the dependency graph already has this
shape. `NucleusUI`, `NucleusLayers`, `NucleusRenderModel`, `NucleusRenderer`, and the
app-host products depend only on `NucleusTypes`; the `NucleusReactRuntime*` modules depend
*up* onto them and nothing in the core depends back. The React layer is already a leaf. The
compositor's only React coupling is its in-process shell overlay — the one thing this plan
deletes.

## The four repositories

**`nucleus` — the render/UI core.** Everything React-agnostic and portable: `NucleusTypes`,
`NucleusLayers`, `NucleusRenderModel`, `NucleusRenderer`, `NucleusRenderHost`, `NucleusUI`,
the Skia Graphite bridges, `Vulkan`/`VulkanC`, `NucleusAppHostProtocols`,
`NucleusAppHostBundle`, `Tracy`, `NucleusTextCxxBridge` with `skia_text_backend.cpp`
(Skia text *rendering*), and `platform-android` (the Android render host — it depends only on
the renderer, no React). Owns and provisions the **render native SDK**: Skia Graphite over
native Vulkan (`build-skia`, `build-skia-android`).

**`react-native-nucleus` — the out-of-tree RN platform + app SDK.** `NucleusReactRuntime`,
`NucleusReactRuntimeCxx`, `NucleusReactRuntimeHostCxx`, the `NucleusReactRuntimeCxxBridge`
facade, the RN paragraph registry (`TextRegistry.cpp`), and the developer-facing app SDK
(`<Window>`, desktop APIs, the JS npm package). Owns and provisions the **RN native SDK**:
Hermes, folly, ReactCommon/Fabric, glog, fmt, and the staged host-cxx archive
(`build-hermes`, `build-rn-support`, `build-rn-cxx`, `generate-rn-spec`, `provision-cxx-libs`).
Embeds `nucleus` and consumes its render SDK. This is what an app developer targets, exactly
as react-native-macos is what a macOS RN developer targets.

**`nucleus-compositor` — the pure compositor.** The Wayland/DRM/input/seat substrate, the DRM
renderer backend, window management, output management, the composition root, and the
`swift-system` io_uring loop. Its own UI — decorations, focus rings, overview, workspace
animations — draws on the render core, in Swift, with no React. Consumes `nucleus` and the
render SDK only. Serves the standard shell-facing protocols. Links zero React.

**`nucleus-shell` — the first-party shell.** An RN app built on `react-native-nucleus`, plus
the shell-bindings module it consumes (layer-shell, foreign-toplevel, session-lock, screencopy
native modules — a library layered on the platform, not part of it). A standard layer-shell
client: it draws its own surfaces and drives windows over standard protocols. It has no build
dependency on the compositor and is one of potentially several shells.

## The seams

**The React/render seam is the layer tree, and it stays in-process.** Every consumer — an app,
the shell — runs its own React reconciler that produces a `NucleusLayers` tree, rendered
in-process by the core renderer. There is no cross-process scene protocol and no serialized
layer tree: a shell is a normal client that renders its own buffers, not a description the
compositor renders on its behalf. This is the direct consequence of dropping "React lays out
app windows" — the compositor owns window layout, so nothing needs to hand it a scene.

**The compositor/shell seam is standard Wayland protocols.** The compositor implements the
server side of layer-shell (panels, docks, backgrounds, overlays, exclusive zones),
foreign-toplevel (window enumeration and control for taskbars and switchers), session-lock,
and screencopy/image-copy-capture (thumbnails, screenshots). A shell — first-party or
third-party — is any client speaking them. The compositor never embeds a client's surface into
another client's tree; that boundary is Wayland's, and honoring it is what keeps the two
repositories independent.

**The native SDK splits along the repo line.** The provisioned SDK becomes two: a render SDK
(Skia/Vulkan) that `nucleus` produces and everyone consumes, and an RN SDK (Hermes/Fabric/folly)
that `react-native-nucleus` produces and only RN consumers consume. The compositor consumes the
render SDK alone. The host-cxx archive and the RN half of provisioning leave the compositor's
world entirely — the coupling apparatus built while the compositor still linked React is
retired, not maintained. The monorepo root owns bootstrap ordering through
`tools/nucleus bootstrap`; components do not carry independent bootstrap scripts.

**The text backend un-shares.** `skia_text_backend.cpp` is Skia text rendering and stays in the
core; `TextRegistry.cpp` is the React paragraph registry and moves with the platform. The
cross-repo shared `.cpp` disappears.

## Status

Phases 1–2 are **complete**. The native SDK is split (`render`/`rn`); `react-native-nucleus`
is extracted and builds standalone; the core is render-only (zero React Native, source or
third-party); the `@_spi(NucleusCompositor)` contract carries both the compositor and the RN
platform; and the compositor consumes the nested topology. The root Swift orchestrator owns
fresh-clone bootstrap for the complete monorepo and for individual components.

**Phase 5's React removal is landed** (in `nucleus-compositor`): the compositor now links
**zero React**. Deleted the `NucleusCompositorOverlayReactRuntime` target + source, the
executable's `ReactShellAttach` driver + its two call sites (bring-up attach, loop pump), every
RN product/dependency/flag/link (Hermes/Fabric/folly + the host-cxx archive) from both
manifests, and the dead `topbar.hbc` staging from the install plugin. Both manifests parse and
resolve with `NucleusReactNative` fully absent from the graph.

**The text-backend un-share is landed** (see `docs/shared-infrastructure.md` Phase 2). The core
text-layout headers/impl moved out of the RN tree into `nucleus/render-cxx/skia`, and the text
backend is now a core `NucleusTextBackend` SwiftPM product the compositor, shell, and RN
platform **link** — the per-consumer `.cpp` symlinks are deleted.

**The submodule collapse is landed too — Phase 5 is complete.** With zero React linked and no
text `.cpp` symlinks, the compositor embeds the render/UI core **directly** as a `nucleus`
submodule; the `react-native-nucleus` wrapper it nested purely to reach the shared core is gone.
Both compositor manifests point at `../nucleus`, and the diamond that forced the nesting no
longer exists for the compositor. `nucleus-compositor` is now a pure Wayland/DRM compositor
consuming only the render core.

**Phase 4's `nucleus-shell` skeleton + bar vertical slice is built** (new `nucleus-shell`
repo). It stands up the out-of-process layer-shell RN client end to end: the client Wayland
bindings (the client twin of the compositor's codegen — connection, registry, layer-shell,
foreign-toplevel, session-lock/screencopy drivers), a `VK_KHR_wayland_surface` Vulkan-WSI
render backend (`PresentationBackend` conformer modeled on the Android presenter), the RN app
host booting via the `NucleusReactRuntime.Host` facade, and the bar RN component (clock +
foreign-toplevel taskbar) with its native module. Three small **additive** core changes land in
`nucleus` for it: a Wayland-WSI Vulkan header include, a `VkRequirements.PresentationMode`
`.waylandClientWSI` extension set, and a defaulted `RenderCore.create(presentation:)` param.
The whole package graph resolves (`swift package dump-package`, nine targets); runtime behaviour
is compositor/hardware-gated. Session-lock/screencopy clients and the desktop-services sort are
scaffolded (real shapes) beyond the one-surface slice. See `nucleus-shell/docs/shell-architecture.md`.

Phases 3–5's remaining work (the full shell breadth + the Phase-5 tail) continues from here. A survey of
the compositor reframes them from what an earlier draft assumed: **the shell-facing protocols
and the shell/substrate seam already exist inside the compositor.** The server side of
layer-shell (`LayerShell.swift`), foreign-toplevel (`ForeignToplevel.swift`), session-lock
(`SessionLock.swift`), and screencopy (`Screencopy.swift`) is implemented, alongside a deeper
substrate (xdg-activation/foreign/output, viewporter, fractional-scale, pointer-constraints,
dmabuf/syncobj, tearing-control, full Xwayland). The in-process overlay is already decoupled
through the `CompositorShellPolicy` protocol seam, and an import-audit area DAG forbids the
substrate from importing `NucleusCompositorShell`/`NucleusCompositorOverlay` directly. So the
remaining phases do not *build* the seam — they **prove it against a real external client, move
the shell across it, and delete the in-process hosting path.** Phase 3 is an audit-and-harden
pass, not greenfield; Phase 4 carries a services sort the protocols alone don't imply.

**Phase 3 audit + fixes are landed** (in `nucleus-compositor`), covering ~20 conformance gaps:
the foreign-toplevel minimize dead-end and missing `minimized`/`parent` state; layer-shell's
`already_constructed`/buffer-before-configure enforcement and the exclusive-zone leak on
`destroy`/null-buffer unmap plus anchor/size/layer error correctness; screencopy buffer
validation and region clamping; and session-lock's inert-second-locker, `dimensions_mismatch`,
the compositor-policy input-gating leak while locked, and scene-author blanking. **Two facts
bound the rest of Phase 3.** First, the compositor's scene/present path is **dormant mid-cutover**
— `authorFrame` and the render bridge's present-ack path have no live driver (the Zig frame loop
was removed), so end-to-end runtime proof (blanking, the `locked` emit via
`SessionLockGate.noteOutputPresented`, and stock-client testing on a VT) relights with the render
bridge. The session-lock blanking filter and `noteOutputPresented` are correct-by-construction
and wired to that path; they activate when it does. Second, the in-process wire-fixture harness
(`WaylandTestClient`/`WireBuilder`/`WireMessage`) was **orphaned from the build** since the cutover
— its ~24 `@main` parity fixtures aren't referenced by any SwiftPM target.

That harness is now **revived as a swift-testing target** (`NucleusCompositorWaylandRuntimeTests`,
scoped via `sources` to the harness plus a `WaylandProtocolConformanceTests` suite), so the router's
protocol behaviour is regression-tested in-process — no DRM, no live present path. The suite
proves eight fixes across all four protocols: layer-shell (`invalid_anchor`, `invalid_layer`,
`already_constructed`), foreign-toplevel (`minimized` state both directions, and the
`unminimize` routing via a real `RouterWindowDriver`), session-lock (inert second-locker,
`dimensions_mismatch`), and screencopy (`invalid_buffer`) — with an shm-buffer helper (memfd +
SCM_RIGHTS) for the buffer-backed cases. The only fix left audit-verified rather than tested is the
session-lock render-blanking pair (`authorFrame` filter + the `locked` emit), which cannot be
exercised until the present-path relights. The 24 legacy `@main` fixtures remain unconverted.

## Phases

### Phase 1 — Split the native SDK along the render/RN line — done

Divide the single provisioned SDK into a render SDK (Skia Graphite, native Vulkan) and an RN SDK
(Hermes, folly, ReactCommon/Fabric, glog, fmt, the host-cxx archive). The core locator
provisions the render half; a second locator provisions the RN half. Every manifest's flags are
re-pointed at whichever half they consume: the render/UI targets and the compositor take the
render SDK, the `NucleusReactRuntime*` targets take both. This lands entirely in-tree, before
any repository moves, so the division is proven against the existing build.

### Phase 2 — Extract `react-native-nucleus` — done

Move the RN platform to its own repository: the `NucleusReactRuntime*` modules, the facade
bridge, the paragraph registry, the RN native stack with its SDK provisioning and the host-cxx
staging, and the app SDK. It embeds `nucleus` as a submodule and consumes the render SDK, the
same submodule-and-provisioning pattern the compositor already uses. `skia_text_backend.cpp`
stays in the core; `TextRegistry.cpp` moves with the platform, ending the shared `.cpp`. The
core is now purely React-agnostic render/UI plus the Android render host. The existing
compositor is unaffected: it consumes `react-native-nucleus` as a dependency for its in-process
overlay, unchanged, until Phase 5 removes that overlay.

### Phase 3 — Harden the shell-facing protocols against a real external client

The server side of layer-shell, foreign-toplevel, session-lock, and screencopy already exists.
It has only ever been exercised by the in-process overlay — a privileged, cooperative client —
so Phase 3 is an audit-and-close pass, not new construction. It audits each protocol against its
spec (every request/event, version negotiation, error/destroy ordering, resource-leak-on-
disconnect), then proves the four against stock third-party clients rather than our own: a
layer-shell panel, a locker, a screencopy consumer, a toplevel taskbar. Session-lock's
security-critical path — an unresponsive locker must keep the session blocked — gets adversarial
testing. Whatever the audit surfaces gets closed. This is compositor-only work, no cross-repo
moves and no React, and it de-risks Phase 4 before `nucleus-shell` exists.

### Phase 4 — Build `nucleus-shell` as a layer-shell client, and sort the services

The in-process shell is two things that split differently. Its **Swift `NucleusUI` overlay
views** — menu bar, menus, notifications, the hotkey overlay — are desktop-shell UI and are
*reconstituted* as React components rendering to layer-shell surfaces, not moved: a layer-shell
client draws its own buffers and is a different program from an embedded overlay. Its
**`NucleusCompositorShell` services** do not all move; they sort by whether they are compositor
policy or desktop-shell backend:

| Stays in the compositor (session/window policy) | Moves to `nucleus-shell` (desktop services) |
| --- | --- |
| session keybind table, idle policy | notification daemon |
| cursor theme/host | launcher + desktop-application index |
| screenshot (the screencopy *producer* side) | appearance portal |
| | notification/menu D-Bus relays |

`nucleus-shell` is an RN app on `react-native-nucleus` plus the shell-bindings module it consumes
— the client-side counterparts to Phase 3's server protocols (layer-shell client, foreign-
toplevel client, session-lock client, screencopy consumer), a library layered on the platform,
not part of it. The **RN in-process hosting path** — the overlay's React runtime and the
`.hbc`-bundle attach driven by `NUCLEUS_RN_SHELL_BUNDLE` — is not carried forward; a layer-shell
client is not mounted into the compositor's overlay scene. Wallpaper is the one open call: it
currently draws on the compositor's layer tree through `@_spi(NucleusCompositor)`, which argues
compositor-side, while standard-protocol purity argues for a shell-drawn layer-shell background
surface; decide it explicitly when the phase reaches it.

### Phase 5 — Make `nucleus-compositor` pure

With the shell out of process, delete the compositor's React. The removal surface is traced and
mechanical: the overlay React-runtime target and the RN parts of the overlay scene; the
executable's RN attach path (the live reference that keeps the statically-linked RN runtime in
the link — removing it drops RN); the `NucleusReactNative` package dependency, the two C-bridge
include paths, and the RN product deps in the compositor manifest; and RN SDK consumption
entirely, so the host-cxx archive link leaves the compositor's world. The last cross-repo
compile-time symlink goes with it: `skia_text_backend.cpp` converts from a compiled symlink into
a prebuilt lib from the render SDK (`TextRegistry.cpp` already left with the platform in Phase 2).
What remains draws on the render core with zero React — window decorations, focus rings, chrome,
overview, workspace animation are Swift-on-render-core already. Once RN is gone the nested
`react-native-nucleus/` submodule can collapse back to a direct `nucleus/` submodule, since the
diamond that forced nesting no longer exists. This is the phase that pays back the compositor's
share of the coupling built earlier — it deletes it rather than carrying it.
