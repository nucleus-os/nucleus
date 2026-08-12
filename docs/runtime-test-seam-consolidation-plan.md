# Runtime test seam consolidation plan

Status: active

## Invariant

Production runtime objects have one construction model and one set of invariants. Tests and sanitizer harnesses exercise production behavior through explicit test-support targets, behavioral inputs, and independently constructible domain objects; they do not add fake variants, fault flags, mutable factories, silent fallback hosts, concrete test-type checks, or speculative compatibility hooks to production paths. Explicit in-memory application and scene-description tools remain supported, but every call site opts into that mode by name.

The `NucleusAppHostProtocols` capability boundary remains intact. Its fine-grained registration and lifecycle protocols express the dependency direction from portable core modules to host assembly and let resource values retain only the lifecycle capabilities they use. The libseat `NativeOperations` boundary also remains intact because it is a small, local wrapper around unsafe native lifetime operations rather than a parallel runtime architecture.

## Phase 1: Extract Android GPU submission lifetime state

Move submission serial allocation, buffer last-use tracking, retirement, completion, and terminal-result bookkeeping out of `nucleus_android_gpu` into one independently constructible lifetime-domain object. The real GPU owns exactly one initialized domain after Vulkan device creation and destroys it during normal GPU teardown. Buffer ownership names that domain directly, so lifetime operations never require a partially initialized GPU.

Delete `testing_force_fences_pending`, `testing_fail_next_post_submit`, the test-only GPU and buffer constructors, and every `nucleus_android_gpu_testing_*` entry point from `NucleusAndroidDrmC.c`. Delete the identity-forwarding functions and unchecked local declarations in `NucleusAndroidDrmCTestSupport.c`. Tests and the thread-sanitizer harness construct the extracted domain through checked declarations in their support target and drive submission completion explicitly. Vulkan integration tests exercise real fence-status and post-submit failure behavior at the real GPU boundary; domain tests cover deterministic retirement and concurrent ownership without pretending to own a Vulkan device.

Keep production fence collection branch-free with respect to test state. A real fence query determines readiness, and a real Vulkan result determines terminal submission failure.

Gate this phase with the Android graphics-platform tests, the Android thread-sanitizer harness, and `collider test android`. Confirm that the production DRM target exports no symbol containing `_testing_` and that `nucleus_android_gpu` has no test-only fields or alternate constructor path.

## Phase 2: Make the in-memory layers runtime an explicit mode

Remove `.inMemory()` defaults from the general `UIContext` and `ImageRequestPipeline` initializers. Require callers to provide the `LayerRuntimeHost` that owns their context identifiers, registrations, display-link source, and resource lifetimes. Update every first-party caller in the same phase.

Retain explicitly named entry points for non-rendering use: `LayerRuntimeHost.inMemory()`, `InMemoryCommitSink`, `InMemoryAppHost`, `WindowScene(inMemoryWindows:)`, and the package-scoped in-memory visual-context helper. Rename the private `Stub*` conformers to `InMemory*` so their names describe a deliberate mode rather than test doubles. Keep the `InMemoryCommitSink` initializer's in-memory-host default because selecting that concrete sink is already explicit opt-in.

The in-memory registrars continue to provide deterministic identities for portable scene construction, previews, measurement, and tests. General production-facing initialization can no longer return plausible resource handles while discarding rendering work because a caller omitted one argument.

Gate this phase with the NucleusUI, NucleusApp, NucleusLayers, embedder, and public source-contract tests through `collider test runtime`. Add behavioral coverage proving that explicit in-memory construction works, and let compilation of updated first-party and external-package fixtures enforce the required initializer arguments. Do not add declaration-shape or source-inspection tests.

## Phase 3: Move completion semantics into commit sinks

Remove every `context.commitSink is InMemoryCommitSink` check from NucleusUI. The publisher always queries the runtime host's display-link source for animation timing and always submits the same transaction semantics regardless of sink implementation.

Make `InMemoryCommitSink.commit` resolve the accepted transaction completion token and every accepted animation completion token through its own `LayerRuntimeHost.presentationCompletions`. A rejecting sink remains responsible only for throwing; the publisher resolves rejected handles through the existing failure path. Keep completion ownership at the commit boundary so any future recording or tooling sink defines its behavior directly instead of acquiring behavior through concrete-type recognition elsewhere.

Update in-memory display-link data to be internally coherent and deterministic for authored animations. Exercise accepted and rejected transaction completions, animation completions, and presentation timestamps through the same public publishing operations used with the real sink.

Gate this phase with the NucleusUI animation, publication-authority, compositor window-scene, and render-host tests through `collider test runtime`. Confirm that production sources contain no concrete type check for `InMemoryCommitSink`.

## Phase 4: Remove test implementations and mutable factories from production UI sources

Move `ManualUIClock` out of `NucleusUI` production sources into a shared test-and-benchmark support target. Keep `UIClock` and its continuous implementation in NucleusUI because interaction deadlines, cancellation, cache expiry, and menu scheduling require the clock contract in production. Point the UI test-support trait and headless resource benchmark at the shared manual-clock implementation.

Delete the mutable `ImageRequestPipeline.resourceFactory`. Image resource creation always follows the production registration path through the supplied `LayerRuntimeHost`. Replace factory-based tests with a recording `ImageRegistrar` and matching lifecycle conformer assembled into an explicit runtime host; assert registration requests, handles, cache reuse, cancellation, and release behavior at that real boundary.

Gate this phase with NucleusUI tests and headless resource benchmarks through `collider test runtime` and the narrow resource benchmark selection exposed by `collider benchmark`. Confirm that NucleusUI production sources contain neither `ManualUIClock` nor a mutable resource-construction closure.

## Phase 5: Delete the unused React device-event compatibility hook

Remove the `globalThis.__nucleusEmitDeviceEvent` lookup and its cached-function branch from `DeviceEventEmitter`. Resolve the public React Native-compatible device emitter directly through the runtime installation contract used by Nucleus. Do not retain a fallback for hypothetical runtime shims.

Add behavioral coverage around the installed React Native emitter: event name and payload delivery, a missing emitter diagnostic, shutdown before queued delivery, and repeated emission through the cached supported function. The tests install the same JavaScript-side contract as production rather than a Nucleus-only global.

Gate this phase with the React runtime native and JavaScript tests through `collider test runtime`. Confirm that `__nucleusEmitDeviceEvent` no longer appears in first-party source or tests.

## Phase 6: Consolidate Wayland allocation-failure coverage

Remove `ResourceFactory` from the production `WaylandResource.create` and `createChild` call graph. Each production entry point calls `wl_resource_create` directly once. Extract the post-allocation owner installation, publication, rollback, and parent `post_no_memory` decisions into small package-scoped operations that accept the allocation result they operate on. Tests pass a missing allocation result to those operations to cover deterministic failure without replacing the native allocator used by production entry points.

Preserve the ordering contracts currently covered by the injection seam: request conformance is validated before allocation, failed owner construction destroys the resource, failed child publication destroys the child, installation happens only after publication succeeds, and a failed server-created child allocation reports no-memory on the live parent. Delete the forwarding overloads and comments that exist only to advertise allocator injection.

Gate this phase with Wayland server ownership, loopback protocol-error, generated-dispatch, and compositor Wayland tests through `collider test runtime`. Confirm that `WaylandResource` has one native allocation path per creation operation and no replaceable allocator callable.

## Phase 7: Isolate shared test and sanitizer support

Move `NucleusAndroidGfxstreamAdaptersTestSupport` and `NucleusRenderServerTestSupport` out of production `Sources` directories into explicit `Tests/Support` directories while retaining ordinary SwiftPM targets where sanitizer executables or cross-package integration tests need to depend on them. Normal runtime, library, and application targets must not depend on either support target.

Replace the gfxstream C++ `CHECK_OR_RETURN` integer-line protocol with a structured failure result containing the check name, source location, and concise diagnostic. Swift tests report that information directly on failure. Keep the native behavioral implementation in C++ so the tests continue exercising the actual adapter types rather than recreating their logic in Swift.

Audit every first-party target whose name contains `TestSupport`, every sanitizer harness dependency, and every product dependency closure. Test and harness support remains shareable where needed, but no support target enters a normal library or executable product graph.

Gate this phase with the gfxstream adapter tests, render-server integration tests, both affected sanitizer harnesses, and `collider test all`. Inspect the final product dependency graph and confirm that test-support code is reachable only from tests, benchmarks, and sanitizer harness products.

## Completion state

When all phases are complete, record concise gate evidence in each phase, change this document to `Status: complete`, and remove it from the active execution order. Keep it under completed architecture consolidation until the durable runtime construction, in-memory-mode, native lifetime, and test-support invariants have moved into their owning architecture and contract documents; then delete this plan.
