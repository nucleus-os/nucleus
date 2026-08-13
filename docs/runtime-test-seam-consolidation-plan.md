# Runtime test seam consolidation plan

Status: complete

## Invariant

Production runtime objects have one construction model and one set of invariants. Tests and sanitizer harnesses exercise production behavior through explicit test-support targets, behavioral inputs, and independently constructible domain objects; they do not add fake variants, fault flags, mutable factories, silent fallback hosts, concrete test-type checks, or speculative compatibility hooks to production paths. Explicit in-memory application and scene-description tools remain supported, but every call site opts into that mode by name.

The `NucleusAppHostProtocols` capability boundary remains intact. Its fine-grained registration and lifecycle protocols express the dependency direction from portable core modules to host assembly and let resource values retain only the lifecycle capabilities they use. The libseat `NativeOperations` boundary also remains intact because it is a small, local wrapper around unsafe native lifetime operations rather than a parallel runtime architecture.

## Phase 1: Extract Android GPU submission lifetime state

Status: complete

Move submission serial allocation, buffer last-use tracking, retirement, completion, and terminal-result bookkeeping out of `nucleus_android_gpu` into one independently constructible lifetime-domain object. The real GPU owns exactly one initialized domain after Vulkan device creation and destroys it during normal GPU teardown. Buffer ownership names that domain directly, so lifetime operations never require a partially initialized GPU.

Delete `testing_force_fences_pending`, `testing_fail_next_post_submit`, the test-only GPU and buffer constructors, and every `nucleus_android_gpu_testing_*` entry point from `NucleusAndroidDrmC.c`. Delete the identity-forwarding functions and unchecked local declarations in `NucleusAndroidDrmCTestSupport.c`. Tests and the thread-sanitizer harness construct the extracted domain through checked declarations in their support target and drive submission completion explicitly. Vulkan integration tests exercise real fence-status and post-submit failure behavior at the real GPU boundary; domain tests cover deterministic retirement and concurrent ownership without pretending to own a Vulkan device.

Keep production fence collection branch-free with respect to test state. A real fence query determines readiness, and a real Vulkan result determines terminal submission failure.

Gate this phase with the Android graphics-platform tests, the Android thread-sanitizer harness, and `collider test android`. Confirm that the production DRM target exports no symbol containing `_testing_` and that `nucleus_android_gpu` has no test-only fields or alternate constructor path.

Achieved state: submission serials, buffer retirement, completion, reclamation, and terminal results now live in `nucleus_android_gpu_lifetime_domain`. The Vulkan GPU owns one real domain, buffers own domain resources, real fences are the only completion input in the GPU path, and the former test flags, partial GPU constructor, testing entry points, and identity forwarders are deleted. The sanitizer harness and behavioral tests construct the same domain directly through checked C declarations.

Gate evidence: `collider test android`, the final `collider test runtime`, and `collider test all` succeeded with 0 failed tasks; the deterministic lifetime-domain tests and ordinary sanitizer-harness builds passed within those graphs. Source inspection found no `_testing_` symbol or test-only GPU field in the DRM and support targets. The instrumented sanitizer gate reached the Swift build but the installed Linux arm64 SDK rejected `-sanitize=thread` before compiling Nucleus sources.

## Phase 2: Make the in-memory layers runtime an explicit mode

Status: complete

Remove `.inMemory()` defaults from the general `UIContext` and `ImageRequestPipeline` initializers. Require callers to provide the `LayerRuntimeHost` that owns their context identifiers, registrations, display-link source, and resource lifetimes. Update every first-party caller in the same phase.

Retain explicitly named entry points for non-rendering use: `LayerRuntimeHost.inMemory()`, `InMemoryCommitSink`, `InMemoryAppHost`, `WindowScene(inMemoryWindows:)`, and the package-scoped in-memory visual-context helper. Rename the private `Stub*` conformers to `InMemory*` so their names describe a deliberate mode rather than test doubles. Keep the `InMemoryCommitSink` initializer's in-memory-host default because selecting that concrete sink is already explicit opt-in.

The in-memory registrars continue to provide deterministic identities for portable scene construction, previews, measurement, and tests. General production-facing initialization can no longer return plausible resource handles while discarding rendering work because a caller omitted one argument.

Gate this phase with the NucleusUI, NucleusApp, NucleusLayers, embedder, and public source-contract tests through `collider test runtime`. Add behavioral coverage proving that explicit in-memory construction works, and let compilation of updated first-party and external-package fixtures enforce the required initializer arguments. Do not add declaration-shape or source-inspection tests.

Achieved state: `UIContext` and `ImageRequestPipeline` now require a runtime host, all first-party callers and the portable external-source fixture select their host explicitly, and the private host implementations use `InMemory*` names. Explicit sink, scene, application-host, and visual-context entry points retain their intentionally named in-memory defaults.

Gate evidence: the final `collider test runtime` and `collider test all` succeeded with 0 failed tasks after compiling the complete runtime and external-source graph. `UIHostServicesTests.explicitInMemoryRuntimeAllocatesStableContextIdentities` covers explicit in-memory host identity allocation. Source inspection finds no `Stub*` layers host implementation and no omitted runtime-host default on `UIContext` or `ImageRequestPipeline`.

## Phase 3: Move completion semantics into commit sinks

Status: complete

Remove every `context.commitSink is InMemoryCommitSink` check from NucleusUI. The publisher always queries the runtime host's display-link source for animation timing and always submits the same transaction semantics regardless of sink implementation.

Make `InMemoryCommitSink.commit` resolve the accepted transaction completion token and every accepted animation completion token through its own `LayerRuntimeHost.presentationCompletions`. A rejecting sink remains responsible only for throwing; the publisher resolves rejected handles through the existing failure path. Keep completion ownership at the commit boundary so any future recording or tooling sink defines its behavior directly instead of acquiring behavior through concrete-type recognition elsewhere.

Update in-memory display-link data to be internally coherent and deterministic for authored animations. Exercise accepted and rejected transaction completions, animation completions, and presentation timestamps through the same public publishing operations used with the real sink.

Gate this phase with the NucleusUI animation, publication-authority, compositor window-scene, and render-host tests through `collider test runtime`. Confirm that production sources contain no concrete type check for `InMemoryCommitSink`.

Achieved state: the publisher queries display-link timing for every authored animation and no longer branches on sink type. `InMemoryCommitSink` resolves accepted transaction and animation completion tokens itself, while publisher rejection continues to fail every registered completion. The in-memory display link reports a deterministic, coherent frame interval.

Gate evidence: `collider test runtime` succeeded with 0 failed tasks, including 743 NucleusUI tests plus embedder, compositor window-scene, and render-host coverage. The added accepted-transaction and presentation-timing assertions passed, existing rejection coverage passed, and production source inspection finds no `InMemoryCommitSink` type check.

## Phase 4: Remove test implementations and mutable factories from production UI sources

Status: complete

Move `ManualUIClock` out of `NucleusUI` production sources into a shared test-and-benchmark support target. Keep `UIClock` and its continuous implementation in NucleusUI because interaction deadlines, cancellation, cache expiry, and menu scheduling require the clock contract in production. Point the UI test-support trait and headless resource benchmark at the shared manual-clock implementation.

Delete the mutable `ImageRequestPipeline.resourceFactory`. Image resource creation always follows the production registration path through the supplied `LayerRuntimeHost`. Replace factory-based tests with a recording `ImageRegistrar` and matching lifecycle conformer assembled into an explicit runtime host; assert registration requests, handles, cache reuse, cancellation, and release behavior at that real boundary.

Gate this phase with NucleusUI tests and headless resource benchmarks through `collider test runtime` and the narrow resource benchmark selection exposed by `collider benchmark`. Confirm that NucleusUI production sources contain neither `ManualUIClock` nor a mutable resource-construction closure.

Achieved state: `ManualUIClock` now lives in the lightweight shared resource-support target used by UI tests and headless benchmarks. `ImageRequestPipeline` always constructs `ImageResource` through its runtime host; the mutable resource factory is deleted. Pipeline tests install a recording `ImageRegistrar` and `ImageLifecycle` in a real host graph and cover requests, handle reuse, cancellation, memory-pressure release, and cache bounds.

Gate evidence: `collider test runtime` succeeded with 0 failed tasks and compiled the headless benchmark product. `collider benchmark` built all benchmark products successfully but Collider then attempted to execute `NucleusHeadlessBenchmarks` from a missing `.collider/products` export path, so the benchmark runner failed before starting a workload. Production-source inspection finds neither `ManualUIClock` nor `resourceFactory` in NucleusUI.

## Phase 5: Delete the unused React device-event compatibility hook

Status: complete

Remove the `globalThis.__nucleusEmitDeviceEvent` lookup and its cached-function branch from `DeviceEventEmitter`. Resolve the public React Native-compatible device emitter directly through the runtime installation contract used by Nucleus. Do not retain a fallback for hypothetical runtime shims.

Add behavioral coverage around the installed React Native emitter: event name and payload delivery, a missing emitter diagnostic, shutdown before queued delivery, and repeated emission through the cached supported function. The tests install the same JavaScript-side contract as production rather than a Nucleus-only global.

Gate this phase with the React runtime native and JavaScript tests through `collider test runtime`. Confirm that `__nucleusEmitDeviceEvent` no longer appears in first-party source or tests.

Achieved state: `DeviceEventEmitter` resolves and caches only `globalThis.RCTDeviceEventEmitter.emit`; the Nucleus-only compatibility global and its fallback branch are deleted. Fabric runtime tests install that supported JavaScript contract, verify name and JSON payload delivery, replace the property between emissions to prove the resolved function is cached, exercise the missing-emitter diagnostic/drop path, and queue an event from another thread before destroying the real C++ facade without draining it.

Gate evidence: `collider test runtime` succeeded with 0 failed tasks after compiling and running the React native and JavaScript runtime suites. Source inspection finds no `__nucleusEmitDeviceEvent` occurrence in first-party React source or tests.

## Phase 6: Consolidate Wayland allocation-failure coverage

Status: complete

Remove `ResourceFactory` from the production `WaylandResource.create` and `createChild` call graph. Each production entry point calls `wl_resource_create` directly once. Extract the post-allocation owner installation, publication, rollback, and parent `post_no_memory` decisions into small package-scoped operations that accept the allocation result they operate on. Tests pass a missing allocation result to those operations to cover deterministic failure without replacing the native allocator used by production entry points.

Preserve the ordering contracts currently covered by the injection seam: request conformance is validated before allocation, failed owner construction destroys the resource, failed child publication destroys the child, installation happens only after publication succeeds, and a failed server-created child allocation reports no-memory on the live parent. Delete the forwarding overloads and comments that exist only to advertise allocator injection.

Gate this phase with Wayland server ownership, loopback protocol-error, generated-dispatch, and compositor Wayland tests through `collider test runtime`. Confirm that `WaylandResource` has one native allocation path per creation operation and no replaceable allocator callable.

Achieved state: every `WaylandResource.create` and `createChild` production operation calls `wl_resource_create` directly. Package-scoped installation operations accept the resulting optional resource and own typed-reference creation, owner binding, publication ordering, rollback, and parent no-memory reporting. Tests now pass `nil` allocation results into those operations and use real allocation for every success and post-allocation failure case; `ResourceFactory` and every forwarding overload are deleted.

Gate evidence: `collider test runtime` succeeded with 0 failed tasks, including Wayland ownership, loopback protocol-error, generated dispatch, and compositor Wayland suites. Source inspection finds no `ResourceFactory`, `using: wl_resource_create`, allocator closure, or injected creation overload in the Wayland resource call graph.

## Phase 7: Isolate shared test and sanitizer support

Status: complete

Move `NucleusAndroidGfxstreamAdaptersTestSupport` and `NucleusRenderServerTestSupport` out of production `Sources` directories into explicit `Tests/Support` directories while retaining ordinary SwiftPM targets where sanitizer executables or cross-package integration tests need to depend on them. Normal runtime, library, and application targets must not depend on either support target.

Replace the gfxstream C++ `CHECK_OR_RETURN` integer-line protocol with a structured failure result containing the check name, source location, and concise diagnostic. Swift tests report that information directly on failure. Keep the native behavioral implementation in C++ so the tests continue exercising the actual adapter types rather than recreating their logic in Swift.

Audit every first-party target whose name contains `TestSupport`, every sanitizer harness dependency, and every product dependency closure. Test and harness support remains shareable where needed, but no support target enters a normal library or executable product graph.

Gate this phase with the gfxstream adapter tests, render-server integration tests, both affected sanitizer harnesses, and `collider test all`. Inspect the final product dependency graph and confirm that test-support code is reachable only from tests, benchmarks, and sanitizer harness products.

Achieved state: gfxstream adapter behavior and the shared render-server wire fixture now live under explicit `Tests/Support` directories while remaining ordinary targets for cross-package tests and the render-server sanitizer harness. The C++ adapter checks return a structured result with the failed expression, source file, line, and diagnostic; Swift records that complete failure directly. The manifest's normal library and application targets do not depend on either moved support target, and no `TestSupport` target lives under a production `Sources` directory.

Gate evidence: `collider test all` succeeded with 0 failed tasks, including gfxstream adapter, render-server, integration, Android, and GPU selections. The subsequent sanitizer gate reached the configured instrumented Swift builds, but the installed Linux arm64 Swift SDK rejected both `-sanitize=thread` and `-sanitize=address` before compiling project sources. Manifest and product inspection confirms the moved targets are reachable only from their tests/integration tests and `NucleusRenderServerThreadSanitizerHarness`; neither appears in a normal library or application product closure.

## Completion state

When all phases are complete, record concise gate evidence in each phase, change this document to `Status: complete`, and remove it from the active execution order. Keep it under completed architecture consolidation until the durable runtime construction, in-memory-mode, native lifetime, and test-support invariants have moved into their owning architecture and contract documents; then delete this plan.
