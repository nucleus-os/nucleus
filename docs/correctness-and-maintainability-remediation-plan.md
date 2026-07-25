# Correctness and Maintainability Remediation Plan

## Invariant

Nucleus has one enforceable owner for every cross-language lifetime, bounded
bookkeeping on every persistent path, and an explicit recoverable state for ordinary
hardware and resource loss. Production work does not block the main actor on
child-process or filesystem IO. Every mandatory
Vulkan, Graphite, DRM, JNI, image, and IPC contract has a behavioral test that runs on
a lane capable of exercising it; a missing promised capability fails that lane instead
of silently returning from the test. The renderer stores one Swift paint vocabulary
and lowers it once at the C++ facade. Every first-party Swift target compiles with
strict memory safety.

Status: active

## Execution rules

The phases land strictly in the order below. A phase is complete only after its listed
behavioral verification passes. Later phases may rely on the contracts established by
earlier phases and must not carry temporary compatibility paths forward.

All host verification runs after:

```sh
source tools/host-env.sh
```

The compositor and applications are not launched as part of this plan. Tests exercise
the runtime contracts through fixtures, headless rendering, and dedicated hardware
lanes.

## Audited findings

| Finding | Disposition | Phase |
|---|---|---|
| `gpuElapsedNs` retains unconsumed timing samples indefinitely | replace with a bounded presentation-timing ring | 1 |
| Upload-plus-frame submission can insert one recording and reject the next | eliminate paired recording insertion | 1 |
| Skia `InsertStatus` detail is collapsed into a boolean | preserve and act on the exact status | 1 |
| Text rendering crosses the facade as a raw paragraph pointer | replace with a scoped borrow | 2 |
| Text-renderer installation depends on a weak symbol and static initialization | replace with explicit composition-root installation | 2 |
| Failed image decodes are discarded before the render owner sees them | deliver typed success and failure completions | 3 |
| Image retry, replacement, and stale-completion behavior are implicit or trapping | replace with a generation-based state machine | 3 |
| An unbounded encoded image can defer actual decoding to the render thread | require bounded eager worker decode | 3 |
| Removing the last output reaches three `preconditionFailure` paths | add an explicit no-output runtime state | 4 |
| Xwayland enables verbose tracing, core dumps, and a predictable `/tmp` log | harden executable, environment, and log handling | 5 |
| Hand-written Android JNI calls dereference an unvalidated `jlong` | replace with a weak opaque-handle registry | 6 |
| Android renderer correctness depends on an unenforced owner-thread contract | enforce the UI/Choreographer owner thread | 6 |
| PAM response parsing and child reaping can block the main actor | use nonblocking pipes and integrate `pidfd` completion into the reactor | 7 |
| Cursor and icon theme lookup performs synchronous filesystem IO on the main actor | move lookup to bounded filesystem workers | 7 |
| Paint concepts are duplicated across two Swift models and a facade mapping | collapse to one Swift model and one C++ lowering | 8 |
| Paint payload registration copies bytes one at a time | use one checked contiguous copy | 8 |
| Pointer-heavy first-party targets do not consistently enable strict memory safety | migrate every first-party target | 9 |
| The root `--help` file, dead manifest code, and undocumented plan status remain | remove and index them | 10 |

The audit also ruled out several proposed defects. They are recorded under
“Deliberately preserved contracts” so implementation does not introduce a regression
while trying to repair behavior that is already correct.

---

## Separated Collider work

Collider verification lanes, native-SDK ownership, provisioning, artifact storage,
retention, pruning, and cleaning are owned by
[`collider-storage-lifecycle-plan.md`](collider-storage-lifecycle-plan.md). Its
completed Phase 1 is the verification foundation for this plan. Its storage ownership
phase lands before native-SDK migration begins.

---

## Phase 1 — Make one recording the unit of submission

Status: complete

### Outcome

One logical renderer submission inserts exactly one Graphite recording. Failure status
preserves Skia's recoverability information, completion telemetry is bounded, and no
caller can observe an upload as “not applied” after it was already inserted.

### Changes

1. Stop recording client uploads on a second long-lived recorder. A client commit
   stores the latest validated CPU upload payload for that surface and generation.
   Coalesce superseded payloads before they reach Graphite.

2. Introduce a submission scope owned by `FrameDriver`. The scope:

   - creates the recorder for one frame, capture, or immediate renderer operation,
   - materializes all required pending uploads on that recorder,
   - records the draw/copy work,
   - snaps exactly one recording,
   - inserts and submits it with the submission's waits, signals, target surface,
     target texture state, completion serial, and optional timing request.

   A scope is consumed by submit and cannot be reused.

3. Delete `uploadRecorder`, `uploadsStaged`,
   `submitWithUploadAndSemaphores`, and `submitForPresentWithUpload`. Update frame,
   capture, snapshot, and immediate-copy paths to use the single-recording API. If
   materializing an upload fails, abandon the unsnapped scope and preserve the last
   resident texture; do not insert a partial submission.

4. Replace boolean handling of `Context::insertRecording` with an explicit facade
   result:

   - `kSuccess` proceeds to `Context::submit`.
   - `kInvalidRecording` and `kPromiseImageInstantiationFailed` reject that
     submission without claiming it was queued.
   - `kAddCommandsFailed`, `kAsyncShaderCompilesFailed`, and
     `kOutOfOrderRecording` mark the Graphite context unrecoverable. The render owner
     stops accepting work, tears down the failed renderer, and recreates it from the
     current output topology. If recreation fails, it remains explicitly renderer
     unavailable and retries only on the next topology or device-recovery event.

   Preserve the Skia diagnostic message in the facade result and runtime log. Do not
   add a generic “partially applied” status that leaves the caller guessing whether
   the context is usable.

5. Keep a completion context alive until Skia invokes its finish callback. Skia
   guarantees that the callback runs for successful submission and for failures that
   prevent submission, so callback storage must never be reclaimed merely because a
   ring wrapped. Keep the current per-in-flight token allocation unless profiling
   justifies a different stable-address allocator.

6. Replace the unbounded `gpuElapsedNs` dictionary with a fixed-capacity ring of 256
   completed presentation samples. Each slot contains the submission serial, elapsed
   time, and callback result. New completed samples overwrite the oldest unconsumed
   sample and increment a dropped-sample counter. Resource-retirement progress remains
   a separate monotonic completed serial and is never dropped.

7. Request `kElapsedTime` only for DRM or swapchain presentation submissions that have
   a timing consumer. Offscreen capture, snapshot, and other asynchronous submissions
   use the finish callback without GPU statistics.

### Behavioral verification

- Use Skia's simulated `InsertStatus` support to exercise every status and assert the
  facade result, context-usability decision, callback delivery, and diagnostic.
- Stage an upload and force frame recording to fail before snap; assert no recording
  is inserted and the prior resident texture remains visible.
- Submit more than 256 presentation completions without consuming timings; assert
  bounded storage, monotonic retirement progress, and the exact dropped-sample count.
- Submit capture and snapshot work; assert they create no timing sample.
- Exercise frame, swapchain-present, DRM, offscreen, capture, and immediate-copy paths
  through the phase 1 headless or DRM lane as appropriate.

### Exit gate

Every facade submission inserts one recording, no paired-submit API remains, exact
`InsertStatus` values reach the render owner, and completed telemetry has a tested
fixed bound.

---

## Phase 2 — Replace the text raw pointer with an explicit scoped borrow

Status: complete

### Outcome

Text painting cannot outlive the `Paragraph` ownership acquired for it, and text
renderer availability is established explicitly during composition rather than by
weak linking and static initialization.

### Changes

1. Add an internal C++ composition target, `NucleusTextRenderingBridge`, that depends
   on both `NucleusTextBackendNative` and `NucleusSkiaGraphiteBridge`. This target is
   the only place that connects the text registry to the Graphite facade. Keep the
   lower-level targets independent.

2. Replace `nucleus_text_layout_paragraph(handle) -> uintptr_t` with a synchronous
   borrow function:

   ```cpp
   using TextLayoutBorrowBody =
       void (*)(uintptr_t paragraph, void *bodyContext);
   using TextLayoutBorrow =
       bool (*)(uint64_t handle, void *bodyContext, TextLayoutBorrowBody body);
   ```

   The registry looks up a `shared_ptr<Paragraph>`, retains it in a local, invokes the
   body synchronously, and releases it only after the body returns. The body must not
   store the pointer.

3. Give the Graphite facade a required one-time installation API for the borrow
   function. Store the installed pointer atomically with release/acquire ordering
   because layout creation and drawing can occur on different threads. Reject a
   second different installation and fail renderer bring-up when no provider is
   installed.

4. Call installation from `SkiaTextLayoutBackend.install(in:)` through the new
   composition target before any text handle can be registered or painted. Delete the
   weak setter declaration, static registration object, raw-pointer resolver, and
   silent “resolver absent” rendering path.

5. Keep `TextLayoutLease` ownership in registered paint content. The scoped borrow is
   a boundary guarantee in addition to that higher-level lease, not a replacement for
   it.

### Behavioral verification

- Borrow a registered paragraph, release its registry handle concurrently while the
  body is blocked, then prove painting completes before destruction.
- Verify an unknown or already-released handle returns `false` without invoking the
  body.
- Verify bring-up fails with a directed error when installation is omitted and rejects
  conflicting double installation.
- Run text measurement and headless text painting from their real Swift and Fabric
  call paths.

### Exit gate

No paragraph pointer-returning C ABI, weak text-renderer symbol, or static installer
remains. Every paragraph paint occurs inside a synchronous owning borrow.

---

## Phase 3 — Make image residency failure-aware, replaceable, and bounded

Status: complete

### Outcome

Every decode request reaches one terminal result for its generation. Failure is visible
to the render owner, retry and source replacement are explicit, stale completions
cannot overwrite new state, and decoding never moves unbounded work onto the render
thread.

### Changes

1. Make `ImageDecodeQueue` return a completion for every worker result:

   ```swift
   struct ImageDecodeCompletion: Sendable {
       let handle: UInt64
       let generation: UInt64
       let result: Result<DecodedImage, ImageDecodeFailure>
   }
   ```

   Define stable failure reasons for unreadable input, unsupported format, invalid
   dimensions, limit exceeded, decode failure, cancellation, and upload failure. Do
   not discard invalid images before enqueueing the completion.

2. Replace implicit ledger transitions with this generation state machine:

   ```text
   registered(generation)
       -> decoding(generation)
       -> ready(generation) | failed(generation, reason)
   ```

   `failed` is terminal for the same source generation. A draw lookup reads state and
   never converts failure back to `registered`.

3. Add explicit mutation operations:

   - `registerNew(handle:source:)` accepts only a new handle.
   - `retry(handle:)` increments the generation for the same source.
   - `replace(handle:with:)` cancels the old generation, releases its resident image,
     increments the generation, and registers the new source.
   - `evict(handle:)` cancels work and removes all state.

   An ordinary `RenderImageStore` source replacement allocates a new source-bound
   handle. Callers that intentionally preserve a handle must call `replace`; no
   source mismatch traps or silently no-ops.

4. Include the generation in jobs and completions. Draining accepts a completion only
   when both handle and generation match current state. A stale success releases its
   decoded resource without installing it; a stale failure has no effect.

5. Separate registration from per-frame lookup. `image(...)` may schedule the first
   decode for a registered generation, but repeated draws of `.decoding` or `.failed`
   do not enqueue more work. Coalesce queued jobs by `(handle, generation)` and keep
   only the latest non-started generation per handle.

6. Delete the deferred encoded-image path from `Graphite.cpp`. Worker decode produces
   actual pixels or an explicit failure before reporting success.

7. Require every rasterization request to carry positive target pixel bounds. Add a
   metadata-probe operation for callers that need intrinsic dimensions before choosing
   bounds. Apply non-negotiable limits before allocation:

   - encoded input: 64 MiB,
   - either target dimension: 32,768 pixels,
   - decoded pixels: 64 million,
   - decoded RGBA storage: 256 MiB.

   Use checked multiplication for row bytes and total bytes. SVG and other
   vector/decompression paths obey the same target and decoded-storage limits. A
   limit violation is a normal `ImageDecodeFailure.limitExceeded`.

8. Surface failure to the owning resource store and diagnostic counters. File-backed
   resources retry only on explicit invalidation, a changed source identity, or an
   observed file-version change; they do not retry once per frame.

### Behavioral verification

- Corrupt bytes produce one `.failed` completion and no repeated job under repeated
  draws.
- Explicit retry advances generation and can transition to `.ready`.
- Source replacement while an old decode is blocked installs only the new result.
- Eviction during decode leaves no resident image when the completion arrives.
- Oversized encoded input, dimensions, pixel counts, SVG targets, and checked-byte
  overflow all fail before allocation.
- A valid large image decodes on the worker, reaches `.ready`, and incurs no decode
  work during the subsequent render call.

### Exit gate

Every queued decode resolves to a typed result, all mutation paths are generation-safe,
and no API represents “unbounded deferred decode.”

---

## Phase 4 — Treat zero outputs as a suspended runtime state

Status: complete

### Outcome

Disconnecting the last output keeps the compositor and clients alive. Output-dependent
work suspends until an output returns, and IPC reports absence as a typed error.

### Changes

1. Make `Spaces.overlayDisplayID`, `fallbackOutput`, and `placementOutput` return
   optionals. Propagate the optional through placement, overlay, frame-demand, input,
   and shell-host callers. Delete the zero-display `preconditionFailure` paths.

2. Add an explicit runtime availability state:

   ```swift
   enum OutputAvailability {
       case available
       case suspendedNoOutputs
   }
   ```

   `OutputTopologyReconciler` transitions to suspension after withdrawing the last
   applied output and back to available after attaching the first output.

3. On entry to `suspendedNoOutputs`:

   - cancel output frame demand and pending presentation,
   - stop scene authoring and overlay publication,
   - clear output-bound pointer placement and focus state where required,
   - release withdrawn output resources through normal retirement,
   - retain client surfaces, spaces, application state, and non-output protocol
     objects.

4. On return to `available`, select placement from the newly applied topology,
   republish shell overlay facts, mark retained content damaged, and request a fresh
   frame. Do not reuse withdrawn output IDs or stale generations.

5. Change `ServerHost.spacesOverlayDisplayID()` and every other output-required IPC
   operation to throw a specific `HostCallError.noOutputs`. The shell treats it as a
   transient state and waits for the topology notification.

### Behavioral verification

- Start with one modeled output, withdraw it, and assert no frame, overlay, placement,
  or IPC path aborts.
- Assert output-required IPC returns `noOutputs` and non-output IPC remains usable.
- Attach a new output with a different ID and assert retained content is placed,
  damaged, and rendered against only the new generation.
- Exercise repeated zero/one/many-output transitions and stale page-flip events.

### Exit gate

No ordinary empty-topology path traps. The runtime has one tested suspension/resume
transition and a typed IPC failure for output-required requests.

---

## Phase 5 — Harden the Xwayland subprocess boundary

### Outcome

Xwayland starts from a verified absolute executable, receives a minimal production
environment, cannot follow or truncate an attacker-controlled path, and cannot grow an
unbounded production log.

### Changes

1. Extend Collider host discovery to resolve Xwayland once, validate that it is an
   executable regular file, and place its absolute path in the compositor host
   configuration. `collider doctor` reports the resolved path or a directed missing
   dependency. `XwaylandProcess` receives that path through runtime configuration and
   never invokes `/usr/bin/env` or searches `PATH`.

2. Remove `WAYLAND_DEBUG=client`, `-core`, and `-verbose 10` from the production
   argument and environment construction. Start with `DISPLAY` removed and only the
   explicit environment required by Xwayland.

3. Validate `$XDG_RUNTIME_DIR` as an absolute directory owned by the current UID with
   no group/world access. Create or open a `nucleus` child directory with mode `0700`
   using directory-relative, no-follow operations and validate the opened inode with
   `fstat`.

4. In normal mode, send Xwayland stdout and stderr to `/dev/null`. In explicit
   diagnostic mode (`NUCLEUS_XWAYLAND_TRACE=1`), connect them to a nonblocking pipe
   drained by the existing compositor reactor. The drain writes private
   `xwayland-<random>.log` files created relative to the validated runtime directory
   with `O_CREAT | O_EXCL | O_NOFOLLOW` and mode `0600`.

5. Bound diagnostic logs to three 8 MiB files. Rotate before accepting more bytes and
   account for dropped bytes if the sink cannot keep up. A trace sink failure degrades
   to `/dev/null`; it does not stop the compositor or block Xwayland.

6. Keep inherited file descriptors explicit in the spawn file actions. Close the log
   pipe, readiness pipe, WM socket, listen sockets, and Wayland socket in the correct
   parent/child sides on every spawn failure.

### Behavioral verification

- Argument/environment tests prove production mode contains none of the removed debug
  settings and uses the configured absolute executable.
- Filesystem tests reject a symlinked runtime directory, wrong owner/mode, and
  pre-created log name without modifying the target.
- Concurrent process fixtures receive distinct log files.
- A trace flood rotates at the exact bound while the pipe continues draining.
- Forced failures at each spawn-action step leave no descriptor or child-process leak.

### Exit gate

Xwayland has no fixed `/tmp` path, PATH lookup, production protocol trace, core-dump
flag, or unbounded log sink.

---

## Phase 6 — Enforce Android owner-thread and native-handle lifetimes

### Outcome

Hand-written Android JNI entry points cannot dereference stale memory, and every host,
surface, Choreographer, and renderer mutation occurs on one checked owner thread.

### Changes

1. Keep `AndroidHostCore` and `AndroidRenderer` owner-thread confined. Do not claim
   arbitrary-thread safety by wrapping the state in a mutex: renderer methods currently
   enter `@MainActor` through `MainActor.assumeIsolated`, so mutex protection alone
   would preserve a false contract.

2. Establish the Android UI/Choreographer thread as the owner:

   - Kotlin calls every hand-written NDK entry point from the main looper.
   - Construction captures an owner-thread token.
   - Every JNI thunk validates the current thread before entering the actor-isolated
     implementation.
   - A violation records a directed native diagnostic and returns `JNI_FALSE` or the
     entry point's neutral value without touching host state.

   Surface attach/detach, frame callbacks, input, lifecycle, runtime, and error state
   all obey this check.

3. Replace `hostFromSelfPointer` with a process-wide
   `Mutex<[UInt64: WeakAndroidHost]>`. Allocate monotonic nonzero IDs that are never
   reused during the process. `AndroidHost` exposes its ID through the generated
   Swift-Java surface; the six hand-written JNI calls accept that opaque ID.

4. Register after host construction is complete. Add an idempotent `close()` called by
   the Kotlin lifecycle before its Swift arena is released, and unregister again in
   `deinit` as a safety net. Registry values are weak so registration cannot keep an
   abandoned host alive. Lookup retains a strong local host for the duration of the JNI
   call.

5. Make `ANativeWindow` transfer explicit. Attach adopts one acquired reference on the
   owner thread. Detach removes it from renderer state before returning it for release
   on that same thread. Shutdown detaches before unregistering the host.

6. Declare `SwiftTextLayoutManager: Sendable`. Its stored handler remains immutable
   and `Sendable`; do not add mutable cross-thread state to this class.

7. Document and test the existing GPU-retirement invariant in
   `RenderCoreClientResources` and `RenderCoreTeardown`: client commits, recording, and
   submission are serialized on the main actor, so a replaced resource retires at
   `lastSubmittedSerial`. Do not move retirement to a future serial; that can retain a
   resource forever when no subsequent frame is submitted.

8. Add the missing ownership comment to `WaylandResourceReference`: its
   unretained-self destroy listener is valid because registration, explicit release,
   and libwayland destruction are serialized on the Wayland event-loop owner.

### Behavioral verification

- A stale, zero, random, and already-closed Android handle returns failure without
  dereference.
- Host close racing a registry lookup either lets the retained in-progress call finish
  or rejects the lookup; it never accesses a deinitialized host.
- Invoke each JNI entry point from a non-owner test thread and assert it rejects the
  call without mutating state.
- Exercise attach, replace, detach, and shutdown while counting exact
  `ANativeWindow_acquire`/`release` balance.
- Replace and release a GPU resource with and without a later frame; assert retirement
  occurs at completion of the last submission that could reference it.
- Run Fabric measurement concurrently through the declared `Sendable` manager.

### Exit gate

No hand-written JNI path reconstructs a Swift pointer from Java. Android renderer
state has one enforced owner thread, and native window/resource lifetime tests balance
exactly.

---

## Phase 7 — Remove main-actor child-process and filesystem stalls

### Outcome

PAM authentication and theme discovery progress through reactor/worker completions.
The main actor never performs a blocking child wait or theme filesystem traversal.

### Changes

1. Hard-require Linux `pidfd_open` for the shell host and add it to Collider doctor.
   Create the helper pipes with close-on-exec and nonblocking parent ends. After
   spawning the PAM helper, open a pidfd and register both the response pipe and pidfd
   with `ShellHost+Reactor`.

2. Replace `PamAuthenticator.reap` with a nonblocking state machine:

   ```text
   awaitingResponse(attemptDeadline)
       -> responseReceived(result, exitDeadline)
       -> exited(status)
       -> complete(result)
   ```

   Use a 30-second monotonic deadline for the whole attempt and a one-second exit grace
   after a complete response. Process exit may arrive before or after the response. A
   readable pidfd permits one `waitpid(..., WNOHANG)` reap. At either deadline, send
   `SIGKILL`, continue polling the pidfd, reap, and complete as unavailable. No
   main-actor path calls `waitpid(..., 0)`.

3. Replace `readExactly` on the parent response path with an incremental bounded
   parser. Each readable event drains until `EAGAIN`, accumulates no more than the
   fixed header plus `maximumMessageBytes`, and produces a result only when the entire
   frame is present. EOF with an incomplete frame is unavailable. A partial or
   malicious helper response can never block the reactor.

4. Bound the request before spawn. Limit the UTF-8 service name to 256 bytes, keep the
   existing password limit, calculate the framed request size with checked arithmetic,
   and require it to fit in one Linux `PIPE_BUF` write. Reserve the exact capacity
   before the first append, perform the one retry-on-`EINTR` write to the initially
   empty pipe, and zero the entire initialized byte range on every success, error,
   cancellation, and timeout path.

5. Handle every setup failure fail-closed. If pidfd creation or reactor registration
   fails after spawn, terminate the helper, arrange nonblocking reap through the
   reactor's child cleanup path, scrub request storage, and return unavailable.

6. Add one bounded `ThemeAssetIO` worker service per process. The worker owns filesystem
   traversal and file reads; callers send immutable, `Sendable` request values and
   receive immutable results on the main actor. Do not reuse the renderer-private image
   decode queue.

7. Convert cursor resolution to cache-first asynchronous behavior. A miss returns the
   built-in cursor immediately, coalesces one worker request for the theme/name/size
   key, and wakes cursor state when the result arrives. Capture XDG and cursor search
   roots once at service construction.

8. Convert icon-theme indexing and resolution to the same request/completion model.
   Build immutable per-theme indexes off-main, preserve inheritance and fallback
   ordering, and atomically replace the main-actor snapshot on completion.

9. Bound each service:

   - at most 256 queued, non-started keys,
   - coalesce duplicate keys,
   - a 16 MiB decoded cursor-image LRU,
   - a 4,096-entry icon-resolution LRU.

   Evict least-recently-used completed entries. When the pending-key bound is reached,
   drop the oldest non-started request and retain the built-in/fallback result.

### Behavioral verification

- A helper that writes a verdict and lingers cannot block a main-actor sentinel; it is
  killed and reaped at the deadline.
- Exit-before-response, response-before-exit, partial response, oversized response,
  malformed response, cancellation, both deadlines, pidfd-setup failure, and helper
  crash each complete exactly once and leak no child or descriptor.
- Request-buffer tests force maximum field sizes and every error path, then verify the
  initialized buffer is zeroed without reallocation.
- Block a fake theme filesystem worker and assert input/main-actor work continues.
- Cursor and icon tests cover inheritance, fallback, coalescing, stale completion,
  LRU eviction, queue overflow, and worker failure.

### Exit gate

No main-actor `waitpid(..., 0)`, cursor file read, icon directory traversal, or icon
file read remains. Child, descriptor, queue, and cache bounds are behaviorally tested.

---

## Phase 8 — Collapse paint storage to one Swift vocabulary

### Outcome

Paint commands have one stored Swift representation and one validated lowering into
the C++ facade. Adding a paint case cannot silently render as a fallback, and payload
registration uses one contiguous copy.

### Changes

1. Make `NucleusTypes.PaintCommand` the stored command throughout resource
   registration, render modeling, paint content, and rasterization. Preserve its
   packed wire representation.

2. Move ergonomic concepts needed by the renderer into `NucleusTypes`: stroke cap,
   stroke join, transform, flag accessors, and typed shading/blend/path accessors. Add
   computed properties rather than a second stored command model.

3. Delete `PaintDrawCommand` and its companion kind, shading, blend, stroke, join, and
   transform definitions from `NucleusRenderModel`. Update every constructor, matcher,
   content store, dependency scan, and rasterizer call site to consume
   `PaintCommand` directly.

4. Delete the Swift command/kind/shading/blend translation functions from
   `SwiftResourceHostConformers`. Registration validates payload ranges once and
   stores the command array without element-wise remapping.

5. Keep the C++ Skia facade as a language boundary, not a second Swift domain model.
   Validate incoming raw values before forming C++ enums. Lower each valid Nucleus enum
   through an exhaustive switch with no rendering fallback. An invalid raw value
   rejects registration or drawing with a typed diagnostic; it never becomes
   `SrcOver`, `Fill`, or another plausible-looking default.

6. Give intentional Swift/C++ wire values explicit constants and test them through
   the public registration/rasterization behavior. Do not depend on Skia's enum raw
   values; the final facade-to-Skia switch remains explicit.

7. Replace the payload byte loop with one checked
   `Array(unsafeUninitializedCapacity:)` copy from the contiguous span. Handle an empty
   span without manufacturing a non-null base address, and validate count conversion
   before allocation.

### Behavioral verification

- Construct and rasterize every blend mode, path verb, paint style, cap, join, shading
  form, flag combination, and transform through the real registration boundary.
- Feed invalid raw values and malformed payload ranges; assert a typed rejection and
  no draw.
- Compare headless pixel results for representative fill, stroke, gradient, image,
  path, blend, and runtime-effect commands before and after the model collapse.
- Register empty, small, and maximum accepted payloads and verify exact bytes and one
  allocation/copy operation through an instrumented buffer fixture.

### Exit gate

No `PaintDraw*` stored model or Swift mapping layer remains. All valid paint cases
reach an explicit C++ lowering and invalid cases fail closed.

---

## Phase 9 — Enable strict memory safety throughout first-party Swift

### Outcome

Every first-party Swift target opts into Swift 6.4 strict memory safety. Unsafe
operations are narrow, reviewed, and locally annotated; no package receives a blanket
escape hatch.

### Changes

Migrate packages in dependency order, completing each package's build and tests before
editing the next group:

1. `swift-wayland`, `swift-vulkan`, and `swift-tracy`.
2. `core/` Swift targets, including the Swift targets that import C++ facades.
3. `platform-linux/`.
4. `compositor/compositor-core`.
5. `compositor/compositor`.
6. `shell/`.
7. `android-runtime/` and `core/platform-android/`.
8. `react-native/`.
9. `collider/engine`, its checked-in SwiftPM fixture packages, and `collider`.
10. Remaining first-party SwiftPM targets under `chromium/` and
    `swift-toolchain/`.

For each group:

1. Add `.strictMemorySafety()` to every first-party Swift target, including tests and
   executable targets.

2. Classify each diagnostic:

   - replace avoidable pointer use with typed or scoped APIs,
   - put pointer formation and lifetime assumptions in the owning C/C++ shim when that
     is the correct boundary,
   - annotate an irreducibly unsafe declaration or operation locally with its
     lifetime, alignment, mutability, and thread preconditions,
   - reject APIs whose safety cannot be stated and enforced.

3. Do not use module-wide warning suppression, blanket `@preconcurrency`, or unchecked
   `Sendable` merely to make the build pass.

4. Split Vulkan feature-chain APIs by mutability. A query chain supplies a mutable
   pointer to `vkGetPhysicalDeviceFeatures2`; a device-enable chain supplies a const
   view after construction. Remove `UnsafeMutablePointer(mutating:)` from
   `supportsFeatures` rather than casting away the API mismatch.

5. Run the package's Collider-owned build/test tasks after each group. Build Collider
   itself with:

   ```sh
   swift build --package-path collider
   ```

   Do not defer diagnostics to a final all-workspace pass.

### Behavioral verification

- Existing behavior and phase-specific tests pass after every package group.
- JNI, Wayland listener, Vulkan chain, Graphite callback, text borrow, image worker,
  and PAM buffer tests run with the strict annotations in place.
- The final workspace build emits no strict-memory-safety diagnostic from a
  first-party target.

### Exit gate

Every first-party Swift target and test target has strict memory safety enabled, with
no blanket suppression or unexplained unchecked conformance.

---

## Phase 10 — Remove residue and close the documentation lifecycle

### Outcome

The workspace contains no artifact left by the replaced designs, and documentation
clearly distinguishes active work from completed or superseded plans.

### Changes

1. Delete the tracked root file `--help`.

2. Delete dead declarations, tests, comments, flags, and helper types made obsolete by
   phases 1–9. Remove replaced APIs and fix every caller in the same phase; do not
   leave deprecated wrappers.

3. Add a `Status:` line to every plan under `docs/`, using exactly `active`,
   `complete`, or `superseded by <kebab-case.md>`. Determine status from the current
   implementation rather than the document's age.

4. Add `docs/README.md` with separate active, complete, and superseded sections. Each
   entry links to the plan and states its invariant in one sentence. This plan remains
   active until the final exit gate passes, then changes to complete.

5. Run final repository audits for:

   - disabled first-party GPU tests,
   - paired Graphite submission APIs,
   - raw text paragraph pointer APIs and weak resolver symbols,
   - unbounded image decode requests,
   - zero-output traps,
   - fixed Xwayland log paths and production trace flags,
   - Android self-pointer reconstruction,
   - blocking main-actor child/filesystem work,
   - `PaintDraw*` declarations,
   - first-party targets missing strict memory safety.

   These searches are review aids, not tests that assert source-code shape. Runtime
   contracts remain covered by the behavioral suites introduced in prior phases.

### Behavioral verification

Run the complete host gate:

```sh
source tools/host-env.sh
collider doctor
collider test all
```

Run `collider test gpu-drm` on the render-node lane. Build the Collider package with
`swift build --package-path collider`. Review every prior phase's exit gate and the
documentation index.

### Exit gate

All agent-runnable verification passes, the hardware lane is green, the audits find no
replaced path, and this document is indexed as complete. Manual compositor/application
validation remains a user-owned handoff and does not keep the plan active.

---

## Deliberately preserved contracts

These points were verified during the audit and must not be “fixed” as defects:

- **Graphite finish callbacks:** Skia guarantees that the configured finish callback
  runs even when insertion or submission fails. The per-submission completion token
  is therefore not leaked by a failed `insertRecording`. Tokens must remain alive
  until that callback and must never be reclaimed by wrapping an in-flight pool.

- **Paragraph registry ownership:** The text registry's map currently retains the
  paragraph after a temporary `shared_ptr` lookup is destroyed, and registered paint
  content retains `TextLayoutLease`s. Phase 2 replaces the raw-pointer seam because
  scoped ownership is the correct enforceable boundary, not because the current call
  immediately dereferences freed storage.

- **GPU retirement serial:** Under the single-main-actor renderer, a replaced resource
  retires at `lastSubmittedSerial`, the last submission that could reference it.
  Retiring at an unsubmitted future serial can leak indefinitely.

- **Wayland surface validation:** `WlSurfaceResource` already rejects
  `set_buffer_scale <= 0` and transforms outside `0...7` with the required protocol
  errors before calling the accepted-state setters. Keep the defensive downstream
  clamps unless every internal construction path is also represented by a validated
  type.

- **Single-owner architecture:** Wayland dispatch, input, window management, scene
  authoring, rendering, and GPU submission remain owner-serialized. Worker services
  return immutable completions; they do not fragment mutable compositor ownership
  across actors.

- **`WaylandResourceReference` destruction listener:** The unretained listener is
  correct in both destruction orders under the single Wayland event-loop owner. Phase
  8 documents and tests that assumption without changing the mechanism.

- **`SwiftTextLayoutManager` sendability:** Its immutable stored handler is already
  `Sendable`, so declaring the conformance is sound. The phase does not add locking or
  mutable cross-thread state.
