# Correctness and Maintainability Remediation Plan

## Invariant

Every defect below is either a lifetime/ownership hazard at a Swift/C/C++ seam, an
unbounded resource, an abort path reachable from ordinary operation, or a duplicated
source of truth that drifts silently. When this plan completes: no raw pointer crosses
a language boundary without an owning reference held for the duration of its use; no
per-frame bookkeeping structure grows without bound; no runtime state reachable by
hotplug, client request, or IPC aborts the compositor; the paint vocabulary has exactly
one definition; and the build configuration has one resolution path that SwiftPM's
manifest cache correctly invalidates.

## Findings index

| # | Finding | Phase |
|---|---|---|
| 1 | Verification gate invokes a deleted binary; GPU tests all disabled | 1 |
| 2 | Manifest env reads bypass SwiftPM cache invalidation | 2 |
| 3 | Three divergent native-SDK root resolutions across five manifests | 2 |
| 4 | `provisionSDK` mutates the filesystem during manifest evaluation | 2 |
| 5 | Five hand-maintained copies of the Skia archive link list | 2 |
| 6 | Text-layout resolver returns a raw pointer with no owning reference | 3 |
| 7 | `g_textLayoutResolver` is a non-atomic global behind a weak symbol | 3 |
| 8 | `gpuElapsedNs` grows without bound | 3 |
| 9 | `SubmissionCompletionToken` leaks when `insertRecording` fails | 3 |
| 10 | `submitWithUploadAndSemaphores` reports failure after partial application | 3 |
| 11 | Zero-display state aborts the compositor from three call sites | 4 |
| 12 | `ImageResidencyLedger.failed` is terminal; `register` traps on source change | 4 |
| 13 | Unbounded image decode is deferred onto the render thread | 4 |
| 14 | Xwayland spawned with protocol tracing, core dumps, and a fixed `/tmp` log | 5 |
| 15 | `AndroidHostCore` has unsynchronized mutable state and no thread contract | 6 |
| 16 | `hostFromSelfPointer` dereferences an unvalidated `jlong` | 6 |
| 17 | GPU-resource retirement keyed on `lastSubmittedSerial` | 6 |
| 18 | `SwiftTextLayoutManager` is not `Sendable` but is called cross-thread | 6 |
| 19 | Blocking `waitpid` and synchronous file IO on the main actor | 6 |
| 20 | Four parallel vocabularies for the same paint concepts | 7 |
| 21 | Per-byte payload copy on the paint-registration path | 7 |
| 22 | `set_buffer_scale` / `set_buffer_transform` accept out-of-range values | 8 |
| 23 | Dead code, stray tracked file, unmarked completed plans | 9 |
| 24 | `strictMemorySafety()` applied to leaves, absent from pointer-handling modules | 9 |

---

## Phase 1 — Restore the verification gate

Nothing else in this plan is verifiable until the workspace has a working automated
gate. `.github/workflows/ci.yml` invokes `tools/nucleus doctor`, `tools/nucleus
bootstrap`, and `tools/nucleus test all`. `tools/nucleus` was removed when repository
workflows moved under Collider; `tools/` now holds only `host-env.sh` and
`lsan-suppressions.txt`. Every step fails at exec.

Repoint the three steps at the installed `collider` command (`collider doctor`,
`collider bootstrap`, `collider test all`), preceded by `./collider-setup.sh` so a
fresh runner provisions the toolchain and installs the command on PATH.

The second half of this phase is the disabled GPU suites. Every test that touches
Vulkan, Graphite, or DRM carries `@Test(.disabled("requires a live GPU/Vulkan
device"))` or `.disabled("invokes the real Vulkan loader")` —
`NucleusVulkanResourcesTests`, `ScreenshotTests`, `TextureProducerTests`,
`BackdropTests`, `RendererModuleTests`, `SnapshotCaptureTests`,
`NucleusVulkanDispatchSmokeTests`, `NucleusVulkanCoreSmokeTests`. The Swift/Skia/Vulkan
boundary carries the highest defect density in the repository and has no automated
signal at all.

Add a software-rasterizer lane: provision a Mesa `lavapipe` ICD as a Collider
bootstrap artifact, add `collider test gpu` that sets `VK_ICD_FILENAMES` to it, and
convert the `.disabled` traits to a custom `.requiresVulkanDevice` trait that runs when
a device is present and skips with a distinct message when it is not. The lane runs as
part of `collider test all`.

Scope: `.github/workflows/ci.yml`, a new Collider bootstrap recipe for the ICD, one new
test trait in a shared test-support target, and the trait swap across the eight suites
above. Risk surface: none in product code.

## Phase 2 — Single-source the build configuration

Three independent problems in the ten `Package.swift` manifests, fixed together because
they touch the same declarations.

**Manifest cache invalidation.** Every manifest correctly reads
`NUCLEUS_SWIFT_DIAGNOSTIC_FEATURE` through `Context.environment`, which SwiftPM tracks
and which invalidates the cached manifest when it changes. The same files read `HOME`,
`XDG_CACHE_HOME`, `NUCLEUS_NATIVE_SDK_ROOT`, and `SWIFT_TOOLCHAIN` through
`ProcessInfo.processInfo.environment`, which SwiftPM does not track. Changing any of
those leaves a stale cached manifest holding the previous absolute paths, and the build
fails inside clang with an unrelated missing-header error. Convert every manifest env
read to `Context.environment`:
`core/Package.swift:38`, `react-native/Package.swift:22`,
`compositor/compositor-core/Package.swift:30`, `compositor/compositor/Package.swift:31`,
`shell/Package.swift:25`, `core/platform-android/Package.swift:40`,
`android-runtime/Package.swift:38`.

**Divergent SDK roots.** `core/` and `react-native/` resolve
`NUCLEUS_NATIVE_SDK_ROOT` → `XDG_CACHE_HOME` → `$HOME/.cache` → `/tmp`.
`compositor/compositor-core`, `compositor/compositor`, and `shell/` each carry a local
`provisionSDK` copy that hardcodes `$HOME/.cache` and honours neither override. Setting
`NUCLEUS_NATIVE_SDK_ROOT` therefore moves the core's SDK and not the compositor's,
producing a build where two packages compile against different Skia trees. With `HOME`
unset — container, systemd unit, some CI images — `home` is `""` and the manifests
resolve to `/.cache/...`.

**Manifest side effects.** `provisionSDK` creates directories and symlinks in
`~/.cache` during manifest evaluation, which SwiftPM treats as a pure, cached
description step. Every failure is swallowed by `try?`. Its
`else if fm.fileExists(atPath: path) { continue }` branch means a stale *real*
directory permanently shadows the current clone with no diagnostic, and two clones on
one machine contend for the same global path.

The fix for both is one shared resolution with no side effects. Add a single
`NativeSDK.swift` file next to the manifests, included in each by
`// swift-tools-version` manifest-adjacent source inclusion, exposing one
`nativeSDKRoot` computed from `Context.environment` with the same precedence
everywhere. Symlink provisioning moves out of manifest evaluation entirely and into the
Collider `bootstrap` recipe that already owns the render SDK's artifact fingerprints;
manifests only read the resolved path. A missing SDK becomes a `collider doctor`
failure with a directed message instead of a clang error.

**Skia link list.** `skiaLinkFlags` is duplicated verbatim across
`core/Package.swift`, `react-native/Package.swift`,
`compositor/compositor-core/Package.swift`, `compositor/compositor/Package.swift`, and
`shell/Package.swift` — 25 archives inside one `--start-group`, plus the parallel
`skiaAndroidLinkFlags` and the include-path lists. They are identical today. Move them
into the same shared manifest-adjacent file introduced above so an archive added to or
dropped from the Skia build config is a one-line change.

Dead code removed as part of this phase: `pkgConfig` in `core/Package.swift:102` is
defined and never called, and the comment above it says so.

Scope: ten manifests, one new shared manifest source, one Collider bootstrap recipe.
Risk surface: build-only; a mistake fails the link loudly rather than changing runtime
behaviour.

## Phase 3 — Close the render-facade lifetime and bookkeeping defects

Three defects inside `core/swift/Sources/NucleusSkiaGraphite/cxx/Graphite.cpp` and
`core/render-cxx/skia/skia_text_backend.cpp`, all at the Swift/C++ seam.

**The text-layout resolver discards its owning reference.**
`skia_text_backend.cpp:851-854`:

```cpp
extern "C" uintptr_t nucleus_text_layout_paragraph(uint64_t handle)
{
    return reinterpret_cast<uintptr_t>(nucleus::text::lookupParagraph(handle).get());
}
```

`lookupParagraph` returns `std::shared_ptr<Paragraph>` by value. The temporary is
destroyed at the end of the return statement, so the raw pointer escapes with no strong
reference. `Canvas::drawTextLayout` (`Graphite.cpp:1073-1099`) then calls
`paragraph->paint(canvas, 0, 0)` on it. Every other `lookupParagraph` caller in
`skia_text_backend.cpp` — lines 663, 677, 695, 723, 749, 799 — holds the `shared_ptr`
across the use. Only the cross-boundary resolver drops it.

This is currently latent: registration and release are `@MainActor` (`TextSystem.swift:272`
and `:316`), and painting runs on the same actor. It stops being latent the moment
paragraph creation or release moves off-main, which the React Native direction already
implies — `SwiftTextLayoutManagerBridge::measure` runs on Fabric's shadow thread and
already reaches `nucleus::text` from a second thread.

Replace the pointer-returning resolver with a scoped borrow, so the side holding the
refcount keeps it alive for exactly the duration of the use:

```cpp
using TextLayoutBorrow = void (*)(uint64_t handle, void *ctx,
                                  void (*body)(uintptr_t paragraph, void *ctx));
extern "C" void nucleus_skia_set_text_layout_borrow(TextLayoutBorrow borrow);
```

The text backend's implementation holds the `ParagraphPtr` in a local across the
`body` call. `drawTextLayout` passes its paint work as `body`. No handle can be freed
mid-paint, and there is no release call for a caller to forget.

**The resolver slot is a non-atomic global behind a weak symbol.**
`g_textLayoutResolver` (`Graphite.cpp:126`) is a plain pointer written from a static
initializer and read from the render path.
`skia_text_backend.cpp:849` declares the setter `__attribute__((weak))` and registers
only `if (nucleus_skia_set_text_layout_resolver)`. That weak declaration exists because
`NucleusTextBackendNative` does not declare a dependency on `NucleusSkiaGraphiteBridge`
— so if the target set or link order ever changes, text rendering silently stops with
no diagnostic. Make the slot `std::atomic<TextLayoutBorrow>` with release/acquire
ordering, declare the real dependency in `core/Package.swift`
(`NucleusTextBackendNative` gains `NucleusSkiaGraphiteBridge`; the edge is acyclic), and
drop the weak attribute so a missing symbol is a link error.

**Unbounded submission bookkeeping and a leaked token.**
`attachSubmissionCompletion` (`Graphite.cpp:95-118`) allocates
`new SubmissionCompletionToken` per submission and inserts
`gpuElapsedNs[serial]` on completion. The only consumer is
`takeCompletedSubmissionGpuElapsedNs` (`Graphite.cpp:1531`), reached solely from the
DRM page-flip handler (`RendererPresentation.swift:44`) for that output's scanout
serial. Every `submitAsync` from the pixel-capture and snapshot paths
(`RenderCoreCapture.swift:142` and `:268`) inserts an entry nobody removes, as does
every frame whose flip is dropped by the `notePageFlipComplete()` or
`binding.generation == generation` guards. The `new` also leaks whenever
`insertRecording` returns false before invoking the finish proc.

Replace both mechanisms with one fixed-capacity slot ring owned by
`SubmissionCompletionState`, sized to the maximum in-flight submission count. A
submission claims a slot; the completion callback writes into it and marks it free;
`fFinishedContext` points at the pooled slot instead of a fresh allocation. A slot whose
callback never fires is reclaimed when the ring wraps. Bounded by construction, and no
per-submission allocation exists to leak. Alongside this, `submitAsync` stops setting
`fGpuStatsFlags = kElapsedTime` — the capture path has no consumer for the timing and
should not request the query.

**Partial application reported as failure.** `submitWithUploadAndSemaphores`
(`Graphite.cpp:1393-1429`) inserts the upload recording, then returns
`Status::recordingFailed` if the frame insert fails — leaving the upload inserted in the
context's pending queue with no way for the caller to know. Insert both recordings only
after both are validated, and add a `Status::partiallyApplied` case for the residual
window so the caller can force a full redraw rather than assume nothing happened.

Scope: `Graphite.cpp`, `Graphite.hpp`, `skia_text_backend.cpp`,
`TextRegistry.{hpp,cpp}`, `core/Package.swift`, `PaintRasterizer.swift`,
`FrameDriver.swift`, `RenderCoreCapture.swift`. Risk surface: the entire render path.
Verified by the phase 1 GPU lane plus a new headless facade test that submits an invalid
recording under LSan and asserts no growth in the completion ring.

## Phase 4 — Remove abort-on-state paths from the compositor

**Zero displays.** `Spaces.overlayDisplayID` (`Spaces.swift:151`),
`Spaces.fallbackOutput` (`:222`), and `Spaces.placementOutput` (`:301`) each
`preconditionFailure` when `layout.displays` is empty. That state is reachable:
`OutputTopologyReconciler.withdraw()` removes outputs with no floor, so unplugging the
last monitor — dock, DP-MST hub, link loss, lid close — empties the layout while the
compositor is running. Bring-up guards against it (`CompositorBringup.swift:127`) and two
call sites guard against it (`ScanoutFacts.swift:98`, `DisplayFrameDemand.swift:58`), so
the hazard was already noticed, but `DisplayFrameDemand.overlayOutputID()`
(`DisplayFrameDemand.swift:181`) and `ServerHost.spacesOverlayDisplayID()`
(`ServerHost.swift:338`) do not. The second is an IPC host call, so the out-of-process
shell can abort the compositor and every client's session.

Make the state explicit rather than asserting it away. The three APIs return optionals
(`DisplayID?`, `Display?`). `CompositorRuntime` gains an explicit `outputsAvailable`
gate that suspends scene authoring, frame demand, and shell-overlay publication while
the applied set is empty and resumes on the next reconcile that attaches an output.
`spacesOverlayDisplayID` throws `HostCallError` instead of aborting. The
`preconditionFailure` calls are deleted, not softened.

**Terminal image failure and a trapping re-registration.**
`ImageResidencyLedger.allowsTransition` (`ImageResourceManager.swift:132-147`) has no
edge out of `.failed`, so one decode failure pins a handle permanently — a wallpaper
written a moment later, a transient read error, an icon theme still being installed.
Only `evict` clears it, and nothing calls `evict` on failure. Add a
`.failed → .registered` edge taken when a new registration arrives for the handle, so
the next frame retries.

`ImageResidencyLedger.register` (`:54-66`) uses
`precondition(entry.source == source, "an image handle cannot change source before
eviction")`, aborting the compositor when a handle is reused with a different source.
Evict and re-register instead. `consume` (`:68-71`) uses a bare
`precondition(entries[handle] != nil)` with no message; make it a no-op for an unknown
handle, matching how the rest of the registry treats unknown handles.

**Deferred decode on the render thread.** `ImageDecodeQueue`'s documented contract is
that decode happens on the worker and the render thread receives an immutable image.
`decodeEncodedData` (`Graphite.cpp:790-801`) breaks that for the unbounded case:
`maxWidth <= 0 || maxHeight <= 0` returns `SkImages::DeferredFromEncodedData`, so the
decode actually runs on the render thread at first draw — precisely the large-image case
the queue exists to move off it. `isValid()` is also `true` for a deferred image whose
bytes are undecodable, so a corrupt file reports success and fails silently at draw
time.

Remove the deferred path. `decodeEncodedData` always decodes eagerly; an unbounded
request decodes at full size. `isValid()` then means the pixels exist. Callers that know
a draw size already pass bounds; those that do not now pay the decode on the worker
where it belongs.

Scope: `Spaces.swift`, `ServerHost.swift`, `DisplayFrameDemand.swift`,
`CompositorRuntime.swift`, `OutputTopologyReconciler.swift`,
`ImageResourceManager.swift`, `Graphite.cpp`. Risk surface: compositor availability and
image residency. Verified by new hotplug-to-zero and image-retry suites in
`compositor/compositor-core/Tests` and `core/swift/Tests/NucleusRendererTests`.

## Phase 5 — Harden the Xwayland process boundary

`XwaylandProcess.buildArgv` (`XwaylandProcess.swift:230-244`) spawns Xwayland with
`WAYLAND_DEBUG=client`, `-verbose 10`, and `-core`. `WAYLAND_DEBUG=client` makes
Xwayland format and write every Wayland protocol message it sends or receives; combined
with `-verbose 10` that is continuous CPU cost proportional to X11 traffic and unbounded
log growth over a session. `-core` enables core dumps. All three are debugging
instrumentation on the production path.

The destination is `/tmp/nucleus-xwayland.log` (`:105`), opened
`O_WRONLY | O_CREAT | O_TRUNC` with no `O_EXCL` and no `O_NOFOLLOW` on a fixed,
predictable path in a world-writable directory. Another local user can pre-create it as
a symlink and have the compositor truncate an arbitrary file the compositor's user can
write, and two users on one machine collide.

Remove `WAYLAND_DEBUG=client`, `-core`, and drop `-verbose 10` to the default. Route
stdout and stderr to `$XDG_RUNTIME_DIR/nucleus/xwayland.log`, opened with
`O_CREAT | O_EXCL | O_NOFOLLOW` against a fresh per-session name, falling back to
`/dev/null` when the runtime directory is unavailable. Protocol tracing becomes opt-in
through a `NUCLEUS_XWAYLAND_TRACE` environment variable that `collider doctor` reports
when set.

Alongside this, resolve the Xwayland binary by absolute path rather than
`posix_spawn(..., "/usr/bin/env", ...)` with `Xwayland` looked up on `PATH`, and add the
path to the `collider doctor` host contract so a missing Xwayland is a directed
diagnostic instead of a spawn that succeeds and then exits.

Scope: `XwaylandProcess.swift`, one `collider doctor` check. Risk surface: X11 client
support only.

## Phase 6 — Make thread contracts explicit and enforced

Four places where correctness depends on an invariant that is neither documented nor
checked.

**`AndroidHostCore` has no synchronization.** `AndroidHostCore`
(`AndroidHostCore.swift:263`) is a plain `final class` with mutable `var` state —
`platform`, `surface`, `frame_clock`, `input`, `events`, `runtime`, `lifecycle`,
`last_error` — mutated from JNI thunks that Android drives from the UI thread,
`SurfaceHolder.Callback`, and the Choreographer callback. There is no actor, no
`Sendable` conformance, no lock, and no comment stating a thread contract. It is
probably serialized today because every caller happens to be on the UI thread; nothing
states or enforces that, and `detachSurface` returning a window the JNI thunk then
releases (`AndroidJNI.swift:183-185`) is a use-after-free the moment a render thread
holds it.

Move the whole of `AndroidHostCore`'s state behind a `Synchronization.Mutex` and
conform `AndroidHostCore` and `AndroidHost` to `Sendable`. The JNI thunks then become
correct from any thread and the undocumented invariant disappears rather than being
written down.

**`hostFromSelfPointer` dereferences an unvalidated pointer.**
`AndroidJNI.swift:47-52` reconstructs the host with
`UnsafeMutablePointer<AndroidHost>(bitPattern: Int(selfPointer))!.pointee` on a `jlong`
supplied by Java. A stale or wrong value is an immediate wild dereference. The Android
Activity and SurfaceView lifecycle — `surfaceDestroyed` arriving after the arena has
finalized the host — is exactly where native peers are used after free, and there is no
guard.

Replace the self-pointer convention in the hand-written thunks with a handle registry:
a `Mutex<[UInt64: AndroidHost]>` populated at construction and cleared at arena
finalization, with JNI passing the opaque id. A stale handle resolves to `nil` and the
thunk returns `JNI_FALSE`. One dictionary lookup per JNI call is immaterial next to a
frame. The generated swift-java thunks keep their own convention; only the six
hand-written NDK-handle entry points change.

**Retirement keyed on the wrong serial.** `registerSurfaceTexture`,
`materializeShmUpload`, and `releaseSurfaceTexture`
(`RenderCoreClientResources.swift:102, 112, 258, 269, 288, 291`) retire replaced GPU
resources at `lastSubmittedSerial` — the serial of the frame already submitted. That is
correct only because client commits and frame recording never interleave on the main
actor; a recording in progress that still references the old image would have it
released as soon as the previous frame completes. Retire at the serial the *next*
submission will use instead, which is conservative under any interleaving, and state the
invariant in `RenderCoreTeardown.releaseRetiredGpuResources`.

**`SwiftTextLayoutManager` is not `Sendable`.**
`react-native/swift/Sources/NucleusReactRuntimeCxx/TextLayoutManager.swift:20` is a
`public final class` held as a `mutable` member of `SwiftTextLayoutManagerBridge` and
called from Fabric's shadow thread. It stores only a `let` of a `Sendable` existential,
so the conformance is sound; declare it, so the C++ side's cross-thread use is honest
rather than unchecked.

**Blocking work on the main actor.** `PamAuthenticator.reap`
(`PamAuthenticator.swift:216`) is a blocking `waitpid(pid, &status, 0)` on the main
actor. The helper normally writes its verdict and exits immediately, but a PAM module
that lingers past the write hangs the lock screen with no deadline. Switch to `WNOHANG`
with a bounded retry driven by the existing poll set, treating expiry as
`.unavailable`. `CursorTheme.swift:26` and `:67` and
`IconThemeResolver.swift:216` perform synchronous file and directory reads on the main
actor during theme resolution; move them to the image-decode worker's queue, which
already exists for exactly this shape of work.

Also as part of this phase: `PamAuthenticator` scrubs its request buffer
(`PamAuthenticator.swift:85`), but the buffer is grown with `append`, so a reallocation
would leave an unscrubbed copy of the password in freed heap. It is safe today only
because the password is the last field appended. Reserve the full capacity before the
first `encodeField` so the guarantee does not depend on field order.

Scope: `AndroidHostCore.swift`, `AndroidJNI.swift`, `AndroidHost.swift`,
`RenderCoreClientResources.swift`, `RenderCoreTeardown.swift`, `TextLayoutManager.swift`,
`PamAuthenticator.swift`, `CursorTheme.swift`, `IconThemeResolver.swift`. Risk surface:
Android host lifecycle and lock-screen authentication.

## Phase 7 — Collapse the paint vocabularies to one

Four parallel definitions describe the same concepts:

- `NucleusTypes.PaintCommand`, `PaintCommandKind`, `PaintCommandFlags`,
  `PaintShading`, `PaintBlendMode`, `PaintPathVerb`
- `NucleusRenderModel.PaintDrawCommand`, `PaintDrawCommandKind`, `PaintDrawShading`,
  `PaintDrawBlendMode`, `PaintDrawStrokeCap`, `PaintDrawStrokeJoin`, `PaintDrawTransform`
- `nucleus::skia::Paint`, `BlendMode`, `PathVerb`, `PaintStyle`, `StrokeCap`, `StrokeJoin`
- Skia's own `SkBlendMode`, `SkPathVerb`

Adding one blend mode touches six declarations plus three hand-written switches
(`SwiftResourceHostConformers.swift:124`, `:137`, `:147`) and
`PaintRasterizer.skiaBlendMode` (`PaintRasterizer.swift:178`). The Swift switches are
exhaustive with no `default`, so a missed case breaks the build — that part is right.
The C++ side falls back (`Graphite.cpp:148`, `return SkBlendMode::kSrcOver;`), so a
value that drifts out of sync renders silently wrong.

`NucleusRenderModel` already reaches `NucleusTypes` transitively through
`NucleusAppHostProtocols`. Make `NucleusTypes.PaintCommand` the single stored type:
keep its packed representation (flags option set, flat transform fields) and add
computed accessors — `stroke`, `antialias`, `evenOddFill`, `tintsImage`, `strokeCap`,
`strokeJoin`, `transform` — so the renderer's ergonomics survive the collapse. Delete
`PaintDrawCommand` and its six companion types from `RenderPaintContent.swift`, delete
the three mapping functions from `SwiftResourceHostConformers.swift`, and leave
`PaintRasterizer` as the one place a Nucleus enum maps to a Skia façade enum.

Make that remaining boundary drift-proof: give `nucleus::skia::BlendMode`,
`PathVerb`, `PaintStyle`, `StrokeCap`, and `StrokeJoin` raw values identical to their
Swift counterparts, and add a headless test that iterates every Swift case and asserts
the mapped raw value matches. The C++ fallback then becomes unreachable rather than
load-bearing.

Alongside this, `SwiftResourceHostConformers.swift:209-211` copies the payload blob one
byte at a time:

```swift
var payloadBytes = [UInt8]()
payloadBytes.reserveCapacity(payload.count)
for i in 0..<payload.count { payloadBytes.append(payload[i]) }
```

This runs on the paint-registration path — every repaint of any view carrying a path,
gradient, or runtime effect. Replace it with a bulk copy through
`Array(unsafeUninitializedCapacity:)` and the span's contiguous storage.

Scope: `NucleusTypes/Types.swift`, `NucleusTypes/PaintPayload.swift`,
`NucleusRenderModel/RenderPaintContent.swift`,
`NucleusAppHostBundle/SwiftResourceHostConformers.swift`,
`NucleusRenderer/render/PaintRasterizer.swift`, `Graphite.hpp`, and every call site that
constructs or matches a `PaintDrawCommand`. Risk surface: the widest in this plan — it
touches the paint path end to end. It lands after phase 3 so the façade is already
stable, and after phase 1 so the GPU lane can catch rendering regressions.

## Phase 8 — Bring Wayland surface-state validation to spec

`WlSurface.setBufferScale` (`WlSurface.swift:356`) and `setBufferTransform` (`:357`)
store whatever `Int32` the client sent. The spec requires `wl_surface.error.invalid_scale`
for a scale of zero or less and `invalid_transform` for a transform outside `0...7`.
Downstream code clamps defensively — `Double(max(1, bufferScale))` in
`resolveSurfaceLogicalSize` (`SurfacePendingState.swift:33`), `UInt32(max(1, ...))` in
`SessionLock.swift:231` — so there is no divide-by-zero, but a client bug renders at the
wrong size instead of failing loudly, and the compositor has no signal that the client
is wrong.

Post the protocol errors from the request handlers and drop the downstream `max(1, ...)`
clamps, since an invalid value can no longer reach them. The clamps currently hide the
bug; removing them alongside the validation keeps exactly one place responsible for the
invariant.

Scope: `WlSurface.swift`, `SurfacePendingState.swift`, `SessionLock.swift`, and the
`NucleusCompositorWaylandRuntimeTests` protocol-conformance suite. Risk surface:
clients that currently send invalid values and are silently tolerated.

## Phase 9 — Repository hygiene and documentation lifecycle

**Stray tracked file.** A file literally named `--help`, containing a CEF license
header, is tracked at the repository root. Delete it.

**Inconsistent memory-safety opt-in.** `strictMemorySafety()` is applied to nine targets
in `core/Package.swift` and eight in `compositor/compositor-core/Package.swift`, three in
`shell/Package.swift`, two in `platform-linux/Package.swift`, and zero in
`compositor/compositor/Package.swift`, `react-native/Package.swift`,
`swift-wayland/Package.swift`, `swift-vulkan/Package.swift`, `collider/Package.swift`,
`collider/engine/Package.swift`, and `android-runtime/Package.swift`. It therefore covers
the pure-Swift leaves and is absent from every module that actually handles pointers.
A reader cannot tell from the flag which guarantee holds where.

Enable it on all first-party targets and annotate the genuinely unsafe operations. One
such operation is already a latent problem: `supportsFeatures`
(`NucleusVulkanResources.swift:76`) writes through
`UnsafeMutablePointer(mutating: pointer)` on a pointer obtained from `withUnsafePointer`,
which is formally undefined and currently sits in a module with no opt-in. Restructure
it to use `withUnsafeMutablePointer` on the feature chain head so the write is
well-defined.

**Plan lifecycle.** `docs/` holds roughly 9,200 lines across fourteen plan documents with
no completion markers and no index. `collider-cli-plan.md` still describes deleting
`tools/nucleus`, which happened several changes ago. With zero `TODO`, `FIXME`, or
`HACK` markers anywhere in the code, these documents are the only record of incomplete
work, and nothing distinguishes a live plan from archaeology. Add a `Status:` line to
each document's header — `active`, `complete`, or `superseded by <file>` — and a
`docs/README.md` index that lists them in that order. This document is `active` until
phase 9 closes.

Scope: repository root, ten manifests, `NucleusVulkanResources.swift`, `docs/`. Risk
surface: build-only, plus whatever `strictMemorySafety()` surfaces target by target.

---

## Deliberately unchanged

The single-actor design is deliberate and stays. Wayland dispatch, input, window
management, scene authoring, layout, painting, and GPU submission all run on
`@MainActor`, with the image-decode queue as the only worker. Phase 6 removes the
concrete stalls on that actor — the blocking `waitpid`, the synchronous theme file
reads — rather than fragmenting the ownership model that makes the renderer's lifetime
invariants tractable in the first place.

The `WaylandResourceReference` unretained-self listener
(`swift-wayland/Sources/WaylandServer/WaylandResource.swift:86`) is correct in both
destruction orders and depends only on libwayland's event loop being single-threaded,
which it is. It gains a comment stating that dependency as part of phase 6 and no code
change.
