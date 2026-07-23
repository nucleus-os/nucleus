# Runtime Correctness and Simplification Plan

## Invariant

Nucleus has one explicit ownership path, one frame-demand path, and one authoritative implementation for every render feature.

- Background work never retains the object whose teardown must stop that work.
- An asynchronous result that changes visible output always generates frame demand.
- Wayland, D-Bus, pthread, Vulkan, DRM, and Swift/C++ boundaries state who owns every pointer, file descriptor, callback, and retained object.
- A rejected transaction leaves producer caches and renderer state unchanged without copying the complete retained scene.
- Idle processes sleep until real work or a protocol deadline exists.
- Public transaction fields reach the authoritative renderer or do not exist.
- Cross-module inversion uses typed Swift values and one justified protocol seam, not manually assembled callback tables.
- Generated and vendored code remains untouched. First-party callers are updated directly when an API is replaced.

## Scope

This plan changes first-party code in:

- `core/swift/Sources/NucleusRenderer`
- `core/swift/Sources/NucleusRenderModel`
- `core/swift/Sources/NucleusRenderHost`
- `core/swift/Sources/NucleusLayers`
- `core/swift/Sources/NucleusUI`
- `swift-wayland/Sources/WaylandClient`
- `shell/Sources`
- `compositor/compositor-core/Sources`
- `compositor/compositor/Sources`
- `react-native/swift/Sources`

The work excludes generated sources, the vendored React Native tree, Skia, and other third-party code.

Every build and test command starts after sourcing the host environment:

```sh
source tools/host-env.sh
```

Do not launch the compositor or shell as part of agent-run verification.

## Phase 1: Make asynchronous image decode owned and frame-producing

### Goal

Decoded images appear without an unrelated repaint, and an `ImageDecodeQueue` can always tear itself down without relying on a caller to break a retain cycle.

### Structural changes

1. Add a renderer-owned, thread-safe frame-wake abstraction in `NucleusRenderer`.

   Define one small `Sendable` interface whose only responsibility is signaling that asynchronous renderer work became visible:

   ```swift
   public protocol AsyncRenderWakeSink: Sendable {
       nonisolated func signalRenderWork()
   }
   ```

   The method must be safe on a pthread. It must not directly call main-actor compositor or shell state.

2. Require an `AsyncRenderWakeSink` when constructing `RenderCore`.

   Update `RenderCore.create`, its private initializer, `FrameDriver`, and every production/test caller. Do not preserve an optional callback or an overload that silently drops wakeups.

3. Replace `ImageDecodeQueue.onCompletion` with an immutable wake dependency.

   Pass the wake sink through `FrameDriver` into `ImageDecodeQueue`. Signal it only after a valid, non-cancelled result has been appended to the completion queue.

4. Separate worker state from queue ownership.

   Move these fields into a private shared worker-state object:

   - mutex
   - condition variable
   - pending requests
   - completed results
   - known handles
   - cancelled handles
   - running flag
   - immutable wake sink

   Worker pthreads retain only that state. They must not retain `ImageDecodeQueue`, `FrameDriver`, or `RenderCore`.

5. Make `ImageDecodeQueue` the sole pthread owner.

   The queue owns thread handles. Its teardown sets `running = false`, broadcasts, joins every worker, then releases state and destroys synchronization primitives in a defined order. Keep explicit `shutdown()` for ordered GPU teardown, but make `deinit` a real safety net.

6. Replace the pending request array’s `removeFirst()` behavior.

   Use a deque or a head index with periodic compaction so a burst of image work does not shift every remaining request.

7. Add host wake implementations.

   - The compositor implementation writes to a coalesced eventfd watched by the existing reactor. Draining that eventfd requests a frame on every attached output because the queue currently does not retain per-output dependency information.
   - The shell implementation writes to a coalesced eventfd included in its poll set. Draining it marks render work due.
   - Counting/no-op test implementations remain test-only. Production construction must supply a real wake sink.

### Behavioral tests

Add tests that prove:

- A completed decode signals exactly one coalesced wake for a completion burst.
- A cancelled or failed decode does not request a frame.
- A decode submitted during one frame becomes visible on the next frame triggered only by the wake sink.
- Dropping a queue without calling `shutdown()` releases the queue and terminates workers.
- Explicit shutdown remains idempotent and rejects later submissions.
- A burst of requests preserves completion correctness without relying on array-front removal.

Do not test declaration shape or source text.

### Verification gate

```sh
swift test --package-path core --filter ImageDecodeQueueTests
swift test --package-path core --filter NucleusRendererTests
swift test --package-path compositor/compositor-core
swift test --package-path shell
```

Phase 1 is complete when a static scene containing a newly decoded image has a verified frame-demand path in both production hosts.

## Phase 2: Replace the shell’s unconditional 60 Hz loop with demand-driven pacing

### Goal

The shell exits cleanly on compositor loss, sleeps while idle, and derives animation timing from the active output rather than a hard-coded 60 Hz prediction.

### Protocol and error handling

1. Change `WaylandConnection.flush()` to return the `wl_display_flush` result.

   Propagate the result through `ShellWaylandClient.flush()`. Treat fatal errors as a disconnected compositor. Preserve `EAGAIN` as write backpressure and include `POLLOUT` until flushing succeeds.

2. Handle terminal poll events explicitly.

   For the Wayland display, exit the loop on:

   - `POLLHUP`
   - `POLLERR`
   - `POLLNVAL`
   - a negative dispatch result
   - a fatal flush result

   Apply equivalent terminal handling to signalfd and authentication descriptors. D-Bus and accessibility failures close their service integration without leaving a permanently ready descriptor in the poll set.

3. Extract descriptor-result handling into a small event-loop unit.

   Keep the loop orchestration in `ShellHost`, but move `revents` classification and deadline selection into behavior-testable helpers.

### Frame demand and deadlines

4. Remove the default `timeoutMs = 16`.

   Start from an infinite poll timeout. Lower it only for an actual deadline:

   - key repeat
   - authentication
   - D-Bus timeout
   - accessibility timeout
   - tooltip activation
   - active semantic animation
   - a pending render frame paced to the output

5. Drain the Phase 1 renderer-wake eventfd in the shell loop.

   Coalesce multiple writes into one pending-render bit. Render only when the bit is set or retained-tree state requires an initial/pending presentation.

6. Wire `UIContext.setAnimationFrameRequestHandler`.

   The handler signals the same eventfd. After `advanceAnimations`, retain frame demand only while the return value says animations remain active.

7. Record output refresh information.

   Extend `WaylandOutput` to retain the current mode’s refresh value from `wl_output.mode`. Propagate output changes to each shell presentation surface.

8. Replace `now + 16_666_666` with a presentation deadline derived from the surface’s current output refresh.

   Maintain the next presentation deadline in the monotonic clock domain. Rebase it after stalls rather than accumulating old deadlines. Vulkan WSI remains responsible for swapchain backpressure.

9. Publish and render only when work exists.

   - Drain JS calls when the JS invoker wake or another host event indicates work.
   - Drain native commands when the command inbox eventfd is readable.
   - Advance animations only when animation demand is active.
   - Publish native scenes only after input, layout, animation, or accessibility state changed.
   - Call `renderFrame` only for pending render demand.

10. Delete the unused widget frame-tick API.

    Remove `BarWidget.wantsFrameTick`, `BarWidget.frameTick`, `BarView.wantsFrameTick`, and `BarView.frameTick`. No production widget overrides or invokes them. A future animated widget must use `UIContext` animation demand.

### Behavioral tests

Add tests using pipes/socketpairs and a fake clock:

- Closing the Wayland peer produces terminal loop state rather than another iteration.
- `POLLHUP`, `POLLERR`, and `POLLNVAL` are terminal even without `POLLIN`.
- `EAGAIN` from flush adds write interest without exiting.
- An idle loop chooses an infinite timeout.
- Key repeat, D-Bus, accessibility, tooltip, animation, and render deadlines choose the earliest timeout.
- A 120 Hz output produces a different presentation interval from a 60 Hz output.
- Multiple renderer/animation wake writes coalesce into one render turn.
- No animation or renderer demand means no publication or render call.

### Verification gate

```sh
swift test --package-path shell
swift test --package-path core --filter ValueAnimatorTests
```

Phase 2 is complete when no unconditional frame timer remains and every poll descriptor has an explicit error/lifecycle policy.

## Phase 3: Collapse the SHM import path to one owned pixel buffer

### Goal

A Wayland SHM commit performs one allocation/copy-conversion before deferred GPU upload, with checked dimensions and explicit pointer lifetime.

### API changes

1. Replace the array-based `RenderCore.registerSurfaceShm` input with a borrowed byte-buffer input.

   Accept `UnsafeRawBufferPointer` or an equivalent nonescaping borrowed buffer. Remove the array overload and update all callers and tests.

2. Keep the Wayland access bracket authoritative.

   `RouterSurfaceSceneDriver` calls `wl_shm_buffer_begin_access`, constructs a bounded borrowed buffer, invokes the synchronous registration method, and calls `wl_shm_buffer_end_access` on every path.

3. Remove the intermediate array in `RenderRuntime.uploadShm`.

   The method must not materialize `[UInt8](UnsafeBufferPointer(...))` before calling the renderer.

4. Convert directly into the pending upload’s final storage.

   Allocate one tightly packed RGBA buffer and convert each source row directly from the borrowed Wayland memory. Store that buffer in `PendingShmUpload`.

5. Put the conversion loop in the lowest appropriate native layer.

   Use a focused C/C++ conversion routine or an optimized Swift buffer loop with row pointers. It must support:

   - ARGB8888/BGRA memory to RGBA
   - XRGB8888/BGRX memory to opaque RGBA
   - source stride larger than tight row bytes

6. Validate every size calculation.

   Use checked multiplication for:

   - `width * 4`
   - `stride * height`
   - `width * height * 4`

   Reject zero, overflowing, undersized, unsupported-format, or inconsistent buffers before allocation or pointer indexing.

7. Preserve last-writer-wins coalescing.

   The queue continues holding at most one final converted buffer per surface while an output is unavailable.

### Behavioral and performance tests

Add tests for:

- ARGB and XRGB channel conversion.
- Padded source rows.
- Minimum and invalid strides.
- Unsupported formats.
- Overflowing dimensions and byte counts.
- Replacement/coalescing byte accounting.
- The borrowed source may be invalidated immediately after registration because no pointer escapes.

Add a benchmark or allocation counter for 1080p and 4K commits. The acceptance condition is one owned full-resolution allocation before GPU staging.

### Verification gate

```sh
swift test --package-path core --filter NucleusVulkanDmaBuf
swift test --package-path core --filter PendingShmUpload
swift test --package-path compositor/compositor-core
```

## Phase 4: Make view publication proportional to the changed subtree

### Goal

A one-view mutation stages and applies work proportional to that mutation. Transaction rejection remains atomic without cloning the complete retained cache.

### File decomposition

Split `ViewLayerPublisher.swift` into focused implementation files in `NucleusUI`:

- `ViewLayerPublisher.swift`: public/package entry points and owned state
- `ViewLayerTraversal.swift`: dirty-subtree traversal and snapshots
- `ViewLayerDiff.swift`: layer/property/placement diff construction
- `ViewLayerCacheDelta.swift`: speculative cache overlay and acceptance
- `ViewPaintCache.swift`: paint registration, lookup, and ownership
- `ViewPublicationMetrics.swift`: metrics and tracing

Keep these as concrete implementation types. Do not introduce protocols for internal single-owner behavior.

### Sparse cache staging

1. Add `PublicationCacheDelta`.

   It owns:

   - visual-layer upserts
   - visual-layer removals
   - placement-layer upserts
   - placement-layer removals
   - hidden-layer count delta
   - traversal-generation updates
   - staged paint-cache insertions and ownership changes

2. Read through an overlay.

   Cache lookup order is:

   - staged removal
   - staged upsert
   - accepted base dictionary

   This preserves intra-transaction visibility without copying base dictionaries.

3. Build the complete `LayerTransaction` against the overlay.

   Newly created layers remain tracked separately so rejection can remove them from `Context.layers`.

4. Apply the delta only after commit acceptance.

   Apply removals and upserts directly to `visualLayers` and `placementLayers`, then update traversal generations and aggregate counts. On rejection, discard the delta without touching accepted caches.

### Incremental paint-cache ownership

5. Store the accepted paint-cache key in `VisualLayerCache`.

   Do not recompute a recording hash while pruning unrelated layers.

6. Give each paint-cache entry an accepted live-reference count.

   - Increment when an accepted visual layer begins using the entry.
   - Decrement when that layer changes paint content or is removed.
   - Remove the entry when the count reaches zero.
   - Stage new registrations and count changes inside `PublicationCacheDelta`.

7. Hash only new or changed recordings.

   Retain full equality checking within a digest bucket to handle collisions. Do not iterate every payload byte of every live layer after each commit.

8. Remove `prunePaintCache(liveLayers:)`.

   Cache reclamation becomes a direct consequence of accepted layer mutations.

### Behavioral and performance tests

Add tests proving:

- Rejected publication changes neither accepted dictionaries nor paint ownership.
- A one-leaf mutation does not recreate or rehash unaffected paint registrations.
- Removing the last layer using a recording releases its registration.
- Two layers sharing identical paint use one registration until both are removed.
- Reparenting and root-placement changes read staged state correctly.
- Traversal-generation updates occur only after acceptance.
- New-layer cleanup remains correct after a failed commit.

Add a large-tree benchmark with one dirty leaf. Track:

- nodes visited
- cache upserts/removals
- recordings hashed
- paint payload bytes hashed
- registrations created

The changed-leaf case must remain constant with respect to unrelated retained-layer count after traversal finds the dirty path.

### Verification gate

```sh
swift test --package-path core --filter ViewPublication
swift test --package-path core --filter Paint
swift test --package-path core --filter NucleusUITests
```

## Phase 5: Give D-Bus subscriptions real token ownership

### Goal

Dropping or cancelling a subscription synchronously prevents further callbacks, and closing a connection invalidates every token without retaining the bus.

### Ownership changes

1. Make `DBusSubscription.cancel()` the authoritative operation.

   It must:

   - return immediately if already cancelled
   - move the slot out
   - set `slot = nil`
   - call `sd_bus_slot_unref` exactly once

2. Call `cancel()` from `DBusSubscription.deinit`.

3. Stop strongly retaining tokens in `DBusConnection`.

   Replace `[DBusSubscription]` with weak registrations used only so `close()` can cancel still-live tokens before unrefing the bus.

4. Compact dead weak registrations on subscribe, process, cancel, and close.

5. Make `DBusConnection.cancel(_:)` forward to the token’s cancellation operation.

   Preserve it only if current service call sites benefit from connection-scoped spelling. Do not duplicate slot ownership in the connection.

6. Keep callback userdata safe.

   The callback borrows the token only while its slot is active. Main-actor isolation ensures cancellation and callback dispatch cannot race. Token cancellation unrefs the slot before the token can deinitialize.

7. Close in strict order.

   Cancel live subscriptions, flush if appropriate, unref the bus, then set `bus = nil`.

### Behavioral tests

Extend `DBusConnectionTests`:

- Emit a matching signal after `cancel`; the handler must not run.
- Store a token in an optional, set it to `nil`, emit a matching signal, and verify no delivery.
- Retain a token after `connection.close()` and verify later token cancellation is harmless.
- Cancel twice and drop afterwards without double-unref.
- Closing with multiple live tokens cancels all of them.

Use a real session bus when available and preserve the existing skip behavior when it is unavailable.

### Verification gate

```sh
swift test --package-path shell --filter DBusConnectionTests
swift test --package-path shell --filter UPowerService
```

## Phase 6: Delete dormant commit and presentation-transition pipelines

### Goal

The retained renderer exposes only behavior that reaches the live transaction path. No public transaction method records data that lowering silently discards.

### Commit queue removal

1. Delete:

   - `core/swift/Sources/NucleusRenderModel/RenderCommitQueue.swift`
   - `core/swift/Tests/NucleusRenderModelTests/RenderCommitQueueTests.swift`

2. Remove queue-only envelope and group types.

3. Keep `RenderTransactionApply.swift`.

   It is live through `RenderTransactionLowering` and `RetainedTreeStore`; update its stale “dormant” comments to describe the current authoritative path.

### Presentation-transition removal

4. Delete:

   - `RenderPresentationOperationService.swift`
   - its tests
   - the unused presentation-operation/fence types that have no remaining live caller

5. Remove transition recording from `NucleusLayers`.

   Delete:

   - `LayerTransaction.beginTransition`
   - `LayerTransaction.clearTransition`
   - `EncodedTransaction.transitions`
   - `TransitionRecord` when no remaining live user exists

6. Remove `WindowSceneAuthor.clearTransition`.

   It currently authors a record that `RenderTransactionLowering` explicitly drops.

7. Remove unreachable renderer transition state and branches.

   Delete the operation ID, transition state, material/hold structures, null transition sink, `.contents` animation handling, transition-specific damage flags, and transition draw branches that cannot be produced by the live model.

8. Preserve ordinary property animation.

   Frame, opacity, transform, shadow, backdrop, and completion-token animation remains in `RetainedTreeStore` and the renderer.

9. Remove transition-only tests and rewrite mixed tests around the remaining runtime behavior.

10. Update comments that still refer to later migration slices, the old render server, or a future operation-service installation.

### Verification gate

```sh
swift test --package-path core
swift test --package-path compositor/compositor-core
tools/check-api-tiers.sh
```

Phase 6 is complete when repository-wide symbol search finds no dormant queue, operation service, transition record, or null presentation sink.

## Phase 7: Replace the render callback table with one typed module seam

### Goal

The Wayland substrate calls a required render service through typed values. Raw pointers are confined to the libwayland edge and obsolete parameters are removed.

### Service design

1. Define one `@MainActor` class-bound protocol in `NucleusCompositorServer`:

   ```swift
   public protocol CompositorRenderService: AnyObject {
       // Typed buffer, presentation, sync, gamma, and capture methods.
   }
   ```

   One protocol is justified by the package DAG. Do not replace the callback table with many single-implementation micro-protocols.

2. Add neutral value types in the same non-C++ module:

   - `RenderShmImport`
   - `RenderDmabufPlane`
   - `RenderDmabufImport`
   - `RenderDmabufProbe`
   - `RenderSyncPoint`
   - `RenderGammaRamp`
   - `RenderCaptureRegion`
   - `RenderDmabufCapture`

3. Use arrays of typed plane records.

   Remove parallel `fds`, `offsets`, and `strides` pointers from the Swift module seam. Document that file descriptors are borrowed for the synchronous call and duplicated by the render owner before return.

4. Delete `acquireFenceFd` from the surface-import path.

   The only caller supplies `-1`; explicit synchronization already travels through syncobj handle/point values and is exported into the actual fence used by Vulkan/KMS.

5. Make the live render runtime instance conform to `CompositorRenderService`.

   Replace static forwarding closures with instance methods on the runtime owner.

6. Replace `NucleusCompositorServer.shared.renderUpload` with a weak required service reference.

   Install it only after render bring-up succeeds. Clear it before render shutdown begins. Calls before installation or after teardown fail explicitly at the protocol edge.

7. Simplify `RenderBridge`.

   Retain compositor-specific output intersection and frame-request logic. Remove wrappers whose only behavior is positional forwarding into `RenderUploadSink`.

8. Delete `RenderUploadSink` and its initializer.

### Behavioral tests

Add a typed service spy and verify:

- SHM and DMA-BUF imports preserve every field.
- Plane order and FD borrowing semantics are explicit.
- Syncobj acquire/release points reach the renderer unchanged.
- Import is unavailable before successful bring-up and after teardown.
- Failed bring-up leaves no partially installed render service.
- Screencopy region and cursor-overlay parameters are not positionally swapped.
- No acquire-fence FD is accepted or silently closed by the surface import API.

### Verification gate

```sh
swift test --package-path compositor/compositor-core
swift test --package-path compositor/compositor
swift test --package-path core
tools/check-api-tiers.sh
```

## Phase 8: Batch the React Native mount handoff

### Goal

Fabric mount work crosses C++→Swift with event-specific data and schedules at most one main-actor drain for a burst of completed transactions.

### Event representation

1. Replace the broad `MountEvent` record with a tagged enum.

   Each case stores only fields used by that mutation:

   - create
   - delete
   - insert
   - remove
   - update

2. Move component classification to the bridge snapshot boundary.

   Convert the component name to `MountComponentKind` once. Retain the original string only where registry/factory behavior requires it.

3. Copy text, text attributes, native ID, and image source only for create/update events whose component kind uses those values.

4. Preserve Swift-native values across the module seam.

   Do not expose C++ types in public Swift signatures, and do not patch React Native.

### Drain architecture

5. Extend `IncomingState` with:

   - ordered completed batches
   - `drainScheduled`
   - per-surface generation
   - per-surface in-flight batch counts

6. Append completed batches under the existing mutex.

   The mutex acquisition order becomes the accepted transaction order. Remove global sequence numbers and the main-actor `completedBatches` reorder dictionary.

7. Schedule only on the idle-to-pending transition.

   `didFinishTransaction` creates a main-actor task only when `drainScheduled` changes from false to true.

8. Drain all available batches in one main-actor turn.

   Pull batches from the mutex-owned queue in order, apply current-generation work, and loop until empty. Clear `drainScheduled` atomically with the empty check so a concurrent producer cannot lose a wakeup.

9. Keep surface retirement fail-closed.

   Discard mutations for retired surfaces. Reject batches whose captured generation no longer matches.

10. Reclaim per-surface bookkeeping.

    Remove generation, retirement, and in-flight entries after the surface has no queued or scheduled batch capable of referring to the old generation.

### Behavioral and performance tests

Add tests for:

- Multiple concurrent producers preserve completed-batch order.
- A burst creates one scheduled main-actor drain.
- A transaction arriving while the drain is finishing is not lost.
- Unregister discards pending and late work.
- Re-registering a surface cannot accept a prior generation.
- Repeated surface creation/destruction returns bookkeeping counts to baseline.
- Create/update copy required content; insert/remove/delete do not retain unrelated strings or text attributes.

Add tracing for:

- completed batches queued
- drain tasks scheduled
- batches drained per task
- mutations materialized
- stale batches rejected
- copied text/native-ID/image byte counts

### Verification gate

```sh
swift test --package-path react-native
swift test --package-path shell
swift test --package-path core --filter NucleusUIEmbedderTests
```

## Phase 9: Complete repository-wide validation

### Goal

Every first-party package builds against the new ownership and demand contracts, and all agent-runnable gates pass without launching an interactive process.

### Static validation

1. Run API-tier validation:

   ```sh
   tools/check-api-tiers.sh
   ```

2. Search for removed or forbidden remnants:

   ```sh
   rg "RenderUploadSink|acquireFenceFd|RenderCommitQueue|PresentationOperationService|beginTransition|clearTransition|onCompletion" \
     core compositor shell react-native
   ```

   Every result must be a deliberate current API or the search must return no matches.

3. Search for newly introduced front-removal hot paths and unmanaged ownership:

   ```sh
   rg "removeFirst\\(|passUnretained|takeUnretainedValue|@unchecked Sendable" \
     core/swift/Sources compositor/compositor-core/Sources shell/Sources react-native/swift/Sources
   ```

   Review each remaining occurrence against an explicit lifetime invariant.

### Package validation

Run:

```sh
swift test --package-path core
swift test --package-path react-native
swift test --package-path compositor/compositor-core
swift test --package-path compositor/compositor
swift test --package-path shell
```

Then run the complete-checkout gates:

```sh
tools/nucleus doctor
tools/nucleus build
tools/nucleus test
```

Do not wipe `.build` or other caches unless an independently diagnosed cache failure requires it.

### Performance validation

Capture automated benchmarks or tracing assertions for:

- Decode completion-to-frame-demand latency.
- Idle shell loop wake count.
- SHM import allocations and bytes copied at 1080p and 4K.
- One-leaf view publication in small and large retained trees.
- Paint bytes hashed per sparse publication.
- RN mount batches per scheduled main-actor task.

The final implementation must demonstrate:

- zero unconditional shell frame wakes while idle
- one full-size owned SHM allocation before GPU staging
- no full retained-cache copy for a sparse accepted publication
- no full-scene paint-cache prune
- one main-actor mount drain task per burst
- no live dormant transaction or transition pipeline

## User validation handoff

After every automated gate passes, the remaining user-owned validation is interactive:

- Start the compositor and shell.
- Confirm static images appear as soon as decoding completes.
- Disconnect or restart the compositor and confirm the shell exits cleanly without a CPU spike.
- Exercise 60 Hz and high-refresh outputs.
- Exercise animated native UI, key repeat, tooltips, battery updates, and accessibility.
- Run SHM-heavy clients and inspect frame-time and allocation traces.
- Exercise React Native surface creation, updates, teardown, and recreation.

Interactive validation does not block completion once implementation and every agent-runnable verification gate are complete.
