# Swift 6.3 and 6.4 Modernization Plan

## Invariant

Nucleus uses Swift 6.4 as a single opinionated language baseline. Unsafe operations exist only at genuine C, C++, Vulkan, Wayland, io_uring, JNI, and kernel ABI boundaries, and each boundary is exposed to the rest of Swift through a small audited API. Ownership features are applied where they make lifetime, mutation, or exactly-once behavior statically enforceable. Foundation imports name the narrowest module that supplies the required API. The Linux reactor remains the sole authority for kernel event registration, deadlines, cancellation, and completion batching.

This modernization removes replaced spellings and APIs directly. It does not preserve old and new paths, add feature flags, or introduce compatibility wrappers.

## Outcomes

The completed work delivers these outcomes:

- Every first-party Swift target rejects unknown or misspelled language feature flags.
- Stable Swift 6.3 and 6.4 spellings replace obsolete attribute forms. Intentional module reexports retain `@_exported import` until Swift provides a stable spelling with the same semantics.
- Strict memory-safety checking is enabled across pure Swift targets and then extended through audited low-level boundaries.
- Retained render-tree mutation avoids unnecessary dictionary copy-out and write-back cycles.
- Exactly-once reactor resumption is enforced with noncopyable continuations where the state has a single waiter.
- Temporary C pointer arrays and binary readers use bounded span-based storage instead of repeated array construction or unchecked raw loads.
- Foundation usage is reduced to `FoundationEssentials`, `FoundationInternationalization`, or no Foundation wherever the required API permits it.
- Direct libdispatch usage stays narrow and preserves the io_uring reactor and dedicated image-decoding worker semantics.
- Deferred Swift features have explicit adoption gates instead of speculative wrappers.

## Execution Rules

The phases land in the order written below. A phase is complete only when its exit gate passes. A later phase does not begin while an earlier phase has outstanding compiler diagnostics, test failures, performance regressions, or unexplained dependency changes.

`tools/nucleus` sources `tools/host-env.sh` internally before it builds the workspace CLI or dispatches a command. Direct package compile and test commands run on the host after sourcing `tools/host-env.sh`. Complete-checkout validation uses `tools/nucleus`. Package-local commands are used only for focused iteration before the complete-checkout gate.

Tests verify behavior and runtime contracts. No test inspects source-code shape, import declarations, attribute presence, or removed declaration names.

## Progress Record

### 2026-07-22

- Overall status: complete.
- Current phase: Phase 11 complete.
- Phase 1 status: complete.
- Phase 2 status: complete.
- Phase 3 status: complete.
- Phase 4 status: complete.
- Phase 5 status: complete.
- Phase 6 status: complete.
- Phase 7 status: complete.
- Phase 8 status: complete.
- Phase 9 status: complete.
- Phase 10 status: complete.
- Phase 11 status: complete.
- Started from a dirty worktree containing unrelated toolchain, Chromium, CEF, and distribution-parity changes. Those changes remain untouched.
- Finding: the environment script lived under the core package while repository instructions named the root `tools/host-env.sh` location.
- Decision: move the single authoritative environment script to `tools/host-env.sh`. `tools/nucleus` sources it internally, while direct package commands source it explicitly.
- Decision: move the tracked direnv hook from `core/.envrc` to the workspace root so the optional interactive environment has the same repository-wide scope as the launcher and applies consistently in every first-party package.
- Verification: Bash and Zsh both source the relocated script from a clean environment, resolve the pinned toolchain and Swift Java JNI path, and `tools/nucleus help` builds and runs successfully without caller-side environment setup.
- Finding: the Android Gradle script's `repoRoot` value is the `core/` package root, so resolving the relocated environment and workspace CLI beneath that value produced stale `core/tools/...` paths.
- Decision: name the Gradle roots by scope. Keep `coreRoot` for Android package inputs and resolve the workspace launcher from a distinct `workspaceRootFile`.
- Finding: having Gradle source `host-env.sh`, assemble the SwiftPM cross-compile command, and call verification separately duplicated workspace orchestration and made the shell environment file part of Gradle's implementation contract.
- Decision: make `tools/nucleus android native` the single native Android build-and-verification boundary. Gradle invokes that command directly and passes only the selected Swift source generation; `tools/nucleus` remains the sole build-orchestration consumer of `host-env.sh`.
- Finding: the first native command reached the actual Android compile and exposed an existing platform leak: the shared Skia façade unconditionally included the Linux fontconfig font manager, while the Android Skia plugin output was not part of the native command or product link.
- Decision: `android native` incrementally provisions the Android Skia archive set before SwiftPM cross-compilation. The shared façade selects Skia's Android font manager for Android and fontconfig for Linux, and the Android target links only the Android archive set through the render SDK.
- Finding: after the Skia boundary compiled, Swift C++ interop imported Vulkan's `<stdint.h>` and `<stddef.h>` includes from inside upstream `extern "C"` regions as Clang modules, which Clang rejects for the Android SDK.
- Decision: the `VulkanC` umbrella imports those standard headers before entering Vulkan declarations and sets Vulkan's documented `VK_NO_STDINT_H` and `VK_NO_STDDEF_H` controls while including the vendored headers. This keeps standard-library module imports outside C linkage without patching vendored Vulkan headers.
- Finding: the next cross-compile reached portable UI and image-worker sources whose two-way Glibc/Darwin import branches treated every non-Glibc platform as Darwin.
- Decision: use explicit Glibc, Android, and Darwin import branches at these libc/math boundaries. Android secure-memory erasure uses Bionic's `explicit_bzero`, matching the Linux non-elidable erasure contract.
- Finding: the Android render engine relied on `NucleusRenderer` transitively exposing retained-model types even though its target already declares a direct `NucleusRenderModel` dependency.
- Decision: import `NucleusRenderModel` explicitly at the use site; do not turn the renderer module into an accidental reexport boundary.
- Finding: strict region isolation rejected capture of the mutating renderer value solely to read its sendable wake sink inside the main-actor closure.
- Decision: copy the sendable wake-sink reference into a local before entering `MainActor.assumeIsolated`, matching the existing local transfer of engine and retained-model state and avoiding a cross-isolation capture of the whole renderer.
- Finding: the first Android product link used a nonexistent aggregate `skunicode` name instead of Skia's emitted core and ICU archives, and `swift-tracy` requested Linux's separate `libpthread` on Android where pthread APIs are part of Bionic libc.
- Decision: link the complete emitted Android Skia archive closure explicitly and restrict Tracy's `pthread` link setting to Linux. Android retains its valid `dl` dependency.
- Finding: the native library and JNI contract passed, then Gradle rejected swift-java's generated Java because the Android modules still targeted Java 11 while current jextract output uses Java 16 pattern matching.
- Decision: set both the Android library and smoke application to the repository's JDK 17 source and bytecode baseline. Do not post-process generated swift-java source into an older dialect.
- Finding: SwiftKitCore's source set also contains optional `ThreadSafe` and `Unsigned` annotations decorated with JVM Flight Recorder metadata. `jdk.jfr` is not part of the Android API, and the generated `AndroidHost` surface uses neither annotation.
- Decision: exclude only those two unused JVM-only annotation sources from the Android source set. Keep consuming the public SwiftKitCore runtime sources unchanged and let any future generated Android API that actually requires either type fail explicitly until swift-java provides an Android-compatible definition.
- Finding: after Java compilation passed, the smoke application exposed a missing public Kotlin entry point: the native smoke symbol lived only on the internal `NucleusNative` object while the public `Nucleus.smokeValue()` contract had no implementation.
- Decision: keep raw JNI methods internal and expose the native library identity check through `Nucleus.smokeValue()`, whose object initialization also guarantees the native libraries are loaded before the call.
- Verification: every first-party manifest parses; all first-party host package tests pass with `StrictLanguageFeatures` promoted to an error; Wayland generation is deterministic and its generated dispatch tests pass; `tools/nucleus build` and the complete `tools/nucleus test` gate pass; no first-party Swift source contains `@inline(__always)`.
- Verification: `tools/nucleus android native` passes AArch64 cross-compilation plus ELF/JNI checks, and `tools/nucleus android build` passes native delegation, AAR verification, signed smoke APK assembly, signature verification, and zip alignment. Focused host regressions for core, Vulkan, and Tracy pass after the Android boundary fixes.
- Phase 2 finding: `String.replacingOccurrences(of:with:)` remains on the umbrella Foundation overlay rather than `FoundationEssentials` in the pinned toolchain.
- Phase 2 decision: use Swift's native `String.replacing(_:with:)` for literal replacement in UI text normalization and desktop-file identifier construction instead of retaining the umbrella import for an overlay convenience.
- Phase 2 finding: `NucleusCompositorServer/Window.swift` was classified as having an unused Foundation import, but its critically damped presentation spring calls C `exp`.
- Phase 2 decision: replace the umbrella with the explicit Glibc/Android/Darwin math module pattern instead of removing the dependency entirely.
- Phase 2 finding: corelibs Foundation's `.shortened` `Date.FormatStyle` drops the leading hour zero in 24-hour locales, unlike the existing `DateFormatter.timeStyle = .short` behavior.
- Phase 2 decision: build the value-typed style from `Locale.hourCycle`: zero-based 24-hour cycles use a two-digit hour with no day period, while 12-hour cycles use locale-default hour digits with an abbreviated day period. Minutes remain two digits. Fixed-locale behavior tests cover both contracts.
- Phase 2 finding: `FoundationEssentials.FileManager` exposes path-based directory listing and item attributes, but not URL enumeration, URL resource values, `Substring.trimmingCharacters(in:)`, or the legacy `localizedStandardCompare` overlay.
- Phase 2 decision: keep desktop application discovery on `FoundationEssentials` by using deterministic recursive path listing, refusing to recurse through symbolic links via file-type attributes, and trimming with native `Character.isWhitespace` traversal. Add `FoundationInternationalization` explicitly for modern `String.Comparator(options: [.numeric])` natural ordering instead of restoring the umbrella import.
- Phase 2 finding: the desktop application index had no focused behavior target, so recursive discovery, XDG precedence, field-code removal, hidden filtering, and natural numeric ordering were only exercised transitively.
- Phase 2 decision: add a cxx-free `NucleusCompositorShellSurfaceTests` target for the cxx-free production leaf and cover those runtime contracts with filesystem fixtures.
- Phase 2 finding: `DrmDevice.isBootVGA` was classified as having an unused Foundation import, but used Foundation solely to read and trim one sysfs byte.
- Phase 2 decision: read the `boot_vga` byte through the existing Glibc boundary with a close-on-exec descriptor. This removes Foundation without adding a value-layer filesystem dependency to the DRM boundary.
- Phase 2 finding: workspace orchestration, benchmark support, and one headless benchmark source retained umbrella imports for Essentials APIs or no Foundation API. Literal replacement and the old ISO formatter also kept overlay-only APIs alive.
- Phase 2 decision: narrow those sources to `FoundationEssentials`, remove the unused imports, use native `String.replacing(_:with:)`, and construct generation identifiers with `Date.ISO8601FormatStyle`. Retained umbrella imports now state their concrete `Process`, `FileHandle`, XML overlay, or regular-expression reason at the import site.
- Phase 2 dependency result: a Swift dependency scan of an Essentials-only program contains `FoundationEssentials` and no `Dispatch` or `FoundationInternationalization`; adding the explicit internationalization module adds `FoundationInternationalization` while still adding no `Dispatch`.
- Phase 2 finding: the release lifecycle stress gate exposed that a retained-observation test waited for asynchronous callbacks by yielding the main actor a fixed four times. Under the complete concurrent test load, that assumption sometimes observed the state before the second callback ran even though the token remained live and uncancelled.
- Phase 2 decision: synchronize that behavior test with the expected callback counts through a checked-continuation latch. Do not add sleeps, increase an arbitrary yield count, or change production observation scheduling to accommodate a test timing assumption.
- Phase 2 verification: focused core, shell, compositor, Linux, workspace, Wayland, Vulkan, and Tracy tests pass; the new desktop-index and shell-formatting behavior tests pass; `tools/nucleus build` passes every product including benchmark and sanitizer products; and the complete `tools/nucleus test` gate passes debug suites, release stress suites, C/C++ ABI headers, and the public API audit.
- Phase 3 finding: `NucleusLayers`, `NucleusAppHostProtocols`, `NucleusUIEmbedder`, `NucleusRenderHost`, `NucleusCompositorServerTypes`, `NucleusCompositorWindowScene`, and the out-of-package `NucleusShellProduct` policy target compile under `.strictMemorySafety()` without diagnostics or unsafe annotations.
- Phase 3 finding: `RenderPixelBuffer.contentHash` converted each scalar to an `UnsafeRawBufferPointer` solely to enumerate its bytes. That made a pure value-layer hash depend on an unsafe storage view and on the host scalar representation.
- Phase 3 decision: mix each scalar through explicit shifts and truncating byte conversion. The content-hash wire order is now explicitly little-endian, bounds-safe, and identical on Linux and Android rather than inherited from native memory layout.
- Phase 3 decision: stop the pure-target frontier at actual ABI ownership boundaries. `NucleusTypes` and `NucleusCompositorOverlayTypes` contain generated pointer-bearing transport records; `NucleusUI` owns secure allocation and image-decoder pointer seams; `NucleusAppHostBundle`, `NucleusApp`, the compositor server/shell targets, Linux platform targets, and shell services own C, POSIX, Wayland, Vulkan, or C++ operations. Those targets enter strict mode only through the Phase 4 boundary audit, not because their current compiler diagnostics happen to be quiet.
- Phase 3 verification: focused render-model, render-host, compositor window-scene, and shell-product behavior suites pass after strict-mode adoption. Manifest-only leaf builds for app-host protocols, UI embedding, and compositor server types also pass.
- Phase 3 verification: `tools/nucleus build` passes the complete product graph, including all sanitizer harness products. `tools/nucleus test` passes every debug suite, all six release stress suites, the C/C++ ABI header matrix, and the public API audit with the strict target settings active.
- Phase 4 finding: `SecureBytes` was a copyable reference owner whose public pointer callbacks carried no compiler-visible safety boundary, whose string initializer first materialized an ordinary byte array, and whose teardown invariants could not be observed by behavior tests.
- Phase 4 decision: make `SecureBytes` an `@safe`, noncopyable value owner of one exact-sized raw allocation. Construction initializes every byte directly, empty values allocate nothing, consuming authentication transfers the owner, explicit scrubbing and deinitialization use the same non-elidable erasure path, and raw-pointer callbacks are the only public `@unsafe` operations.
- Phase 4 decision: keep the production allocator fixed and expose only an internal lifecycle observer to tests. The observer receives allocation counts, a copied post-scrub byte snapshot, and deallocation events; it cannot access or retain the allocation. Runtime tests now cover requested capacity, empty storage, mutation, consuming moves, one-owner deallocation, and zeroization before release.
- Phase 4 finding: `ImageResource` constructed a `Span` through `withUnsafeBufferPointer` and `_unsafeElements` even though Swift 6.4 arrays expose a lifetime-bound `span` directly.
- Phase 4 decision: pass `Array.span` into the image registrar. `NucleusUI` now compiles under strict memory safety with `SecureBytes` as its sole raw-storage owner and no unsafe image-registration shim.
- Phase 4 decision: enable strict memory safety on `NucleusApp`, `NucleusAppHostBundle`, `NucleusCompositorShellSurface`, `NucleusShellServices`, `NucleusLinuxEnvironment`, and `NucleusLinuxAccessibility`. Their only C operations are checked one-value `clock_gettime`, `write`, and immutable-process-environment reads with the bounded lifetime invariants documented at each call.
- Phase 4 finding: the icon-theme service used raw `stat`, `opendir`, and `readdir` only for ordinary file and directory queries. Replacing them with `FoundationEssentials.FileManager` initially exposed a latent dependency on directory enumeration order in candidate selection.
- Phase 4 decision: use `FileManager` for icon discovery and rank candidates independently of traversal order: scalable, exact bitmap, smallest bitmap above the target, then largest bitmap below it. Sorted discovery is deterministic and no POSIX directory pointer crosses into service policy.
- Phase 4 finding: the shell text-input adapter is both the policy translation point and the owner of a `zwp_text_input_v3` proxy. Treating the entire target as unsafe would unnecessarily expose Wayland pointer semantics to the input router and NucleusUI clients.
- Phase 4 decision: make `ShellTextInput` an `@safe`, main-actor-confined proxy owner and enable strict memory safety for `NucleusShellInput`. Generated Wayland calls and proxy storage accesses are individually explicit; callback pointers are converted to scalar identities or copied strings during the callback before crossing to the main actor; proxy destruction precedes listener-owner release.
- Phase 4 boundary classification: Vulkan handles, extension chains, and mapped buffers remain owned by `swift-vulkan`, `NucleusRenderer`, the Android render core, and `NucleusCompositorRendererLinux`. Wayland resources and listeners remain owned by generated `swift-wayland` dispatch, its resource/global wrappers, `NucleusCompositorWaylandRuntime`, `NucleusShellWayland`, the audited shell input owner, and pasteboard protocol adapters. DRM, GBM, libinput, XCB/Xwayland, PAM, session supervision, pasteboard pipes, and systemd DBus calls remain in their existing OS-facing targets. io_uring, timerfd, eventfd, and completion-entry storage remain exclusively in `NucleusLinuxReactor`.
- Phase 4 boundary classification: Skia calls remain in `NucleusTextBackend` and `NucleusRenderer`; React Native and Hermes C++ handles remain in `NucleusReactRuntimeCxx`; Android native-window and asset handles remain in the Android C++-interop core; JNI pointers and `@c` entry points remain in the non-C++ `NucleusAndroidJNI` façade. None of these clang module graphs is pulled into a non-C++ consumer.
- Phase 4 deferred seam: `NucleusTypes.ScreenshotEvent`, `NucleusCompositorOverlayTypes.StringView`, `WindowMechanismHost` backdrop requirements, and `CompositorRenderService` snapshot delivery still expose Swift-owned pointer/count or raw-buffer representations. They block strict adoption of their value and consumer targets and move directly in Phase 5; string-valued in-process data becomes owned `String`, while genuinely borrowed sequences become `Span`.
- Phase 4 verification: all 13 secure-byte tests, 12 lock-screen product tests, 30 shell-service tests, 4 portal-environment tests, 12 accessibility tests including the live AT-SPI bus suite, 47 shell input/wire/lifecycle tests, and the focused compositor shell-surface test pass with the new strict settings. Ten AddressSanitizer/LeakSanitizer ownership suites and all five dedicated ThreadSanitizer executables pass. `tools/nucleus build` passes the complete product graph, and `tools/nucleus test` passes every debug suite, all six release stress suites, the C/C++ ABI header matrix, and the public API audit.
- Phase 5 finding: the repository contains no `std.swift.ProtocolCaller` implementation or caller and no remaining Zig relay. `WindowMechanismHost` was never used as an existential or generic protocol, its two pointer/count backdrop methods were called only by a legacy transport test, and the screenshot, notification, launcher, idle, and overlay pointer records were unreferenced remnants of the retired relay.
- Phase 5 decision: do not add toolchain machinery for a transport that no longer exists. Delete the unused host protocols, backdrop wire bridge, screenshot service and records, launcher/idle relay methods, overlay pointer records, obsolete ABI marker, and their source-shape-era tests. Keep the live `CompositorShellPolicy` seam and concrete `WindowManager` APIs.
- Phase 5 decision: the shell and overlay are in-process Swift modules, so notification publication carries owned `ShellOverlayNotificationInfo` values and scene submission carries `ShellOverlayEvent` directly. No pointer-backed string view or intermediate discriminated wire record remains between them.
- Phase 5 finding: the live borrowed-buffer seam is Wayland SHM import, not backdrop policy or snapshot delivery. The Wayland mapping is valid only between `wl_shm_buffer_begin_access` and `wl_shm_buffer_end_access`, while renderer registration already copies and converts the complete image synchronously.
- Phase 5 decision: construct one bounded `Span<UInt8>` at `wl_shm_buffer_get_data`, pass that non-escaping borrow through `CompositorRenderService`, `RendererRuntime`, `RendererClientBuffers`, and `RenderCoreClientResources`, and copy into renderer-owned RGBA storage before returning. Empty and undersized spans are rejected by the existing checked layout validation.
- Phase 5 decision: enable strict memory safety for `NucleusTypes`, `NucleusCompositorOverlayTypes`, `NucleusCompositorServer`, `NucleusCompositorOverlay`, and `NucleusCompositorOverlayScene` after removing their pointer transports. Their remaining POSIX clock and diagnostic writes are explicit unsafe boundary calls.
- Phase 5 verification: focused renderer SHM conversion and ownership tests pass, the typed render-service borrow test passes, and the newly strict compositor targets build. The complete compositor-core suite passes across server, shell, overlay, Wayland protocol, renderer, window policy, snapshot capture, and ownership tests. `tools/nucleus build` passes the complete product graph, and `tools/nucleus test` passes every debug suite, all six release stress suites, the C/C++ ABI header matrix, and the public API audit.
- Phase 6 finding: the Vulkan string-array helper rebuilt a growing pointer array at every recursive CString scope. The call sites use Vulkan's explicit pointer count, so a trailing null pointer is neither required nor correct to allocate as an unstated contract.
- Phase 6 decision: allocate the pointer table once with `withTemporaryAllocation`, append each initialized pointer through `OutputSpan`, and invoke the body only at the deepest nested `withCString` scope. The helper is explicitly `@unsafe` because its public contract exposes C pointers whose validity is bounded by the body call.
- Phase 6 finding: a noncopyable reader that stores `Span<UInt8>` requires a lifetime dependency annotation, but the pinned stable Swift 6.4 surface does not expose one; the compiler only suggests underscored experimental lifetime syntax.
- Phase 6 decision: keep the span in the enclosing `Data.withUnsafeBytes` borrow and pass it into an offset-only reader for every operation. This preserves one bounded borrow and statically prevents the reader from retaining it without enabling an underscored language feature. The reader validates every seek and range before indexing, decodes little-endian values bytewise, and allocates owned `Data` only for the selected image payload.
- Phase 6 finding: a strict-memory-safety diagnostic build of the complete `Vulkan` target reports its generated Vulkan handles, extension chains, callbacks, and C entry points—the Phase 4 ABI frontier—not new temporary-table violations. Enabling the target setting would require annotating the entire generated binding boundary and is not part of a pointer-table modernization.
- Phase 6 decision: retain the Vulkan module's audited ABI frontier and mark the changed pointer helper `@unsafe`. Enable strict memory safety permanently on `NucleusCompositorShell`, where the parser is ordinary bounded Swift once its single `Data` storage conversion is marked explicit.
- Phase 6 finding: enabling strict memory safety on the shell exposed `getpwuid`, whose returned static storage is non-reentrant and was used only to discover the launcher's login shell.
- Phase 6 decision: replace it with `getpwuid_r` and one `withUnsafeTemporaryAllocation` scratch buffer. This is the intended raw initialized-by-C case; the bytes never become an `OutputSpan`, and the shell path is copied to an owned `String` before the allocation ends.
- Phase 6 verification: the Vulkan suite passes empty, singleton, multiple, and Unicode string arrays. XCursor behavior tests pass closest-size selection, owned pixels after source mutation, truncated headers/tables/payloads, out-of-input offsets, invalid header lengths, and empty images. `NucleusCompositorShell` builds under strict memory safety, the complete compositor-core suite passes, `tools/nucleus build` passes the product graph, and `tools/nucleus test` passes every debug suite, all six release stress suites, the ABI header matrix, and the public API audit.
- Phase 7 baseline: a fresh release build ran seven identical iterations into `.build/nucleus-benchmarks/phase7-before-core/report.json`. `transaction-apply-snapshot-10000` recorded samples 32,283,795 / 18,892,618 / 18,588,539 / 18,459,402 / 17,658,747 / 18,837,365 / 18,581,842 ns, with an 18,588,539 ns median. `animation-completion-batch-1000` recorded 1,994,080 / 1,899,129 / 1,899,191 / 1,923,965 / 1,884,895 / 1,883,685 / 1,892,587 ns, with a 1,899,129 ns median. Both passed their deterministic structural budgets.
- Phase 7 decision: obtain one dictionary index for each known layer and build a narrowly scoped `MutableRef` from `tree.layers.values[index]`. Animation add/remove, animation tick, presentation-damage clearing, existing-layer creation updates, and sparse property updates now mutate the retained `Layer` in place without a second hash lookup or copy-out/write-back assignment. Animation tick and presentation clearing snapshot dictionary indices first so their mutable references never overlap a live dictionary iterator.
- Phase 7 finding: constructing the reference from a force-unwrapped key subscript instead of the dictionary value index produced a repeatable transaction-workload regression. Keep the index-based form; it is both the explicit proof of key presence and the faster compiler lowering in the pinned toolchain.
- Phase 7 decision: keep `Layer`, `LayerTree`, transactions, and snapshots copyable. A behavior test mutates a handed-out snapshot and confirms the live store remains unchanged, proving dictionary copy-on-write still separates external snapshots before an in-place mutation. Do not introduce `UniqueArray` or `UniqueBox` into this value-semantic state.
- Phase 7 lower-priority audit: texture registry release, surface presentation commits, Wayland inhibitor state, buffer-release queues, and compositor data-exchange records still contain copy-out/write-back shapes. No retained-tree benchmark or profile attributes material cost to those paths, so this phase leaves them unchanged as required.
- Phase 7 benchmark result: the accepted seven-iteration report is `.build/nucleus-benchmarks/phase7-after-core-final/report.json`. `transaction-apply-snapshot-10000` recorded 26,951,898 / 18,140,620 / 18,147,627 / 17,693,075 / 17,732,439 / 17,578,858 / 17,883,172 ns, with a 17,883,172 ns median, 3.8% below baseline. `animation-completion-batch-1000` recorded 1,648,840 / 1,562,660 / 1,576,788 / 1,548,144 / 1,546,203 / 1,555,858 / 1,536,950 ns, with a 1,555,858 ns median, 18.1% below baseline. Structural budgets remained identical.
- Phase 7 verification: retained-tree mutation/removal, child ordering, transaction rejection/rollback, animation tick, completion, and explicit snapshot-isolation behavior pass. The complete core suite passes 737 UI tests, 46 render-model tests, renderer, host, embedder, lifecycle, and resource suites. All five ThreadSanitizer harnesses pass for core image workers, the Linux reactor, compositor callbacks, shell callbacks, and React Native runtime workers.
- Phase 8 finding: Swift 6.4 accepts `borrow` and `mutate` accessor syntax, but the pinned compiler rejects both the original nested projection through `current.auxiliary` and a projection through a separate `WlSurface.auxiliary` class property as invalid accessor return values in the real module. A direct stored property already provides the compiler's in-place nested-mutation path and needs no forwarding accessor.
- Phase 8 decision: make `aux` direct `WlSurface` storage and remove it from `SurfaceCurrentState`. Do not retain an ordinary get/set wrapper, enable underscored `_read`/`_modify`, or add a redundant accessor solely to demonstrate the language feature. The surface still owns one value-semantic `SurfaceAuxState`; only its physical placement changes.
- Phase 8 finding: syncobj commit observers intentionally mutate a transaction-local `capturedAux` value before the commit is accepted. That path must remain local `inout` state so invalid points cannot leak into the current surface; only accepted `syncAcquire` and `syncRelease` values reach direct `surface.aux` storage during `applyLatch`.
- Phase 8 exclusivity result: each sticky viewport and sync-point field mutation is a complete stored-property access before transaction effects, scene publication, role callbacks, or child commit application. A new behavior test executes an applied effect that re-enters and reads `surface.aux`, proving the mutable access has ended and the fully latched value is visible.
- Phase 8 test finding: the legacy `WaylandSyncobjFixture.swift` is excluded from the Swift Testing target and implements a retired delegate callback, so it was not valid current coverage. A new wire-level test uses the production dmabuf requirement, verifies acquire/release points latch into `surface.aux`, verifies timeline destruction returns the imported handle, and verifies conflicting points raise protocol error 6.
- Phase 8 benchmark finding: the repository has no compositor or surface-commit benchmark product; the benchmark command covers core, Linux, and React Native workloads. Do not add a production visibility seam or synthetic public API only to time this internal four-field record. Direct storage structurally removes the forwarding get-modify-set operation, while the focused runtime tests and complete compositor gate measure the relevant behavior and regression surface.
- Phase 8 strict-memory result: a diagnostic-only strict build of `NucleusCompositorWaylandRuntime` reaches the already classified generated Wayland/C resource-pointer frontier immediately in background-effect, blur, cursor, and other protocol owners. It reports no new storage issue attributable to `SurfaceAuxState`; permanent strict adoption still belongs to the full ABI-boundary annotation effort, not this storage change.
- Phase 8 verification: the runtime target builds; surface transaction, geometry, subsurface topology, and all 26 wire-level protocol conformance tests pass, including syncobj lifecycle and protocol errors. All five ThreadSanitizer harnesses pass for core image workers, the Linux reactor, compositor callbacks, shell callbacks, and React Native runtime workers.
- Phase 9 finding: `Continuation` is noncopyable and `Mutex` supports a noncopyable protected value, so `ReactorWaitSignal.State` can store `Continuation<UInt64?, Never>?` directly. The state is explicitly `~Copyable`, and signal delivery uses `Optional.take()` to move the continuation out while restoring the locked field to `nil` in the same operation.
- Phase 9 finding: with the package's `Lifetimes` feature enabled, consuming the `withContinuation` parameter directly inside the inline `Mutex.withLock` closure is rejected because it consumes a closure capture. The supported transfer shape moves it into a local optional, captures that storage, and calls `take()` inside a dedicated `install` function; this reinitializes the capture before the lock closure exits.
- Phase 9 decision: `install` consumes the continuation exactly once and returns a noncopyable optional. It either stores the continuation under the mutex or returns ownership for an immediate resume when a signal was already pending. `signal` similarly takes the stored value under the mutex and exhaustively consumes the result outside the critical section. No reference box, unsafe lock API, checked continuation, or underscored ownership feature remains in the single-waiter path.
- Phase 9 cancellation result: task cancellation keeps the existing cancellation handler, whose reactor wake produces a completion-source signal and consumes the installed continuation. A new behavior test cancels a suspended waiter, observes `.cancelled`, then issues another wake and shuts down, covering the no-double-resume terminal path.
- Phase 9 scope decision: `ReactorShutdownSignal` remains on its checked-continuation array. UI clock and pasteboard continuations also remain unchanged because their collection or cancellation-coordinator ownership needs a distinct noncopyable container design.
- Phase 9 verification: the reactor target builds with `Lifetimes`; all 13 host-reactor behavior tests and all 6 fault/model tests pass in debug and release, covering preexisting readiness, suspension, deadline, stale completion, shutdown, repeated wake, and new cancellation behavior. The dedicated Linux reactor ThreadSanitizer harness passes 256 wait/wake cycles, concurrent wake bursts, shutdown, and post-shutdown descriptor-reuse checks.
- Phase 10 dependency result: the complete production-source scan contains two direct `Dispatch` imports. `NucleusLinuxReactor/LinuxHostReactor.swift` owns the completion-eventfd `DispatchSourceRead`; `NucleusReactRuntimeCxx/MountConsumerSmoke.swift` intentionally uses `DispatchQueue.concurrentPerform` to exercise the C-exposed RN contention smoke. All other imports are confined to benchmark or sanitizer-harness sources.
- Phase 10 compiler result: `swiftc -emit-imported-modules` for the reactor reports exactly `Dispatch`, `Glibc`, `NucleusLinuxReactorC`, `Synchronization`, and `SystemPackage`. Dispatch is explicit rather than arriving through Foundation. The Phase 2 FoundationEssentials dependency scan remains unchanged: Essentials and the explicitly selected Internationalization module do not add Dispatch.
- Phase 10 reactor decision: retain one `DispatchSourceRead` only to drain the io_uring completion eventfd and resume the main-actor reactor turn. io_uring continues to own client descriptor polling, timerfd deadlines, the control eventfd, cancellation, completion budgeting, and kernel batching; no `DispatchIO` or per-interest Dispatch source enters the design.
- Phase 10 decode-pool decision: retain `ImageDecodeQueue`'s pthread mutex, condition variable, and bounded worker array. Blocking Skia/C++ decode work stays off both Swift's cooperative executor and libdispatch's shared pool. Generation-aware cancellation drops pending and stale in-flight results, completion bursts coalesce their render wake, and shutdown broadcasts then joins every worker synchronously.
- Phase 10 verification: all 13 reactor tests and 6 fault/model tests pass in debug and release, and the post-migration Linux ThreadSanitizer harness passes. All 19 image-decode queue tests pass cancellation, resubmission, decode failure, completion coalescing, raw input, bounded worker, in-flight shutdown, idempotent shutdown, and deinit joining behavior. The concurrent RN mount batching smoke passes with one ordered drain per burst. No source-shape test or allowed-import list was added.
- Decision: enable `StrictLanguageFeatures` with `-Werror StrictLanguageFeatures` through the same per-package Swift settings path that already supplies `-warnings-as-errors`.
- Decision: remove forced inlining from generator, bridge, and clock helpers. Retain it with the stable `@inline(always)` spelling only on tiny Vulkan loader, render tuple comparison, Wayland identity-token, and Android hash primitives.
- Finding: the first Wayland regeneration removed hand-maintained request-vtable definitions for core protocol requests newer than the system `wayland-server-protocol.h`; the generated `WlSurface` dispatch then failed because the system struct lacks `get_release`.
- Decision: generate all core Wayland request-vtable layouts from the vendored XML. Extension protocols continue to alias the matching `wayland-scanner` structs. This removes the hand-maintained generated-header exception and keeps the ABI tied to the selected protocol source.
- Finding: `public import` is import access control, not module reexport syntax. The pinned compiler diagnosed `public import NucleusUI` as an unused public import in the reexport-only front door.
- Decision: retain the three intentional `@_exported import` boundaries. A direct stable replacement does not exist in the pinned language, and forwarding aliases would preserve only selected declarations rather than the module surface.
- Phase 11 repeat result: `cancellationResumesAnOutstandingWaitExactlyOnce` and `appliedEffectCanReenterCommittedAuxiliaryState` each pass 100 consecutive repeat-until-fail iterations. `writesCoalesceAndPublishOneRetainedMutation` passes on the first iteration of a 25-iteration repeat-until-pass run. None reproduces a flaky or timing-sensitive failure.
- Phase 11 test-policy result: no diagnostic is intentionally non-failing, and runtime parameter discovery invalidates no test case. Warning-severity issues and dynamic test cancellation are therefore not introduced.
- Phase 11 audit mechanism: every first-party manifest accepts `NUCLEUS_SWIFT_DIAGNOSTIC_FEATURE` and appends the selected `-enable-upcoming-feature` only to targets declared by that manifest. This keeps package-by-package audits reproducible without forcing a Swift 7 mode into vendored dependencies or changing the ordinary build configuration.
- Phase 11 finding: applying a diagnostic globally with `-Xswiftc` also applies it to the vendored Swift 5 `swift-system` package. `ExistentialAny` then reports the upstream `Error` existential and other Swift 7 diagnostics produce hundreds of vendor errors unrelated to first-party source.
- Phase 11 decision: keep the diagnostic hook manifest-scoped and do not patch or audit vendored `swift-system` as first-party Swift 6.4 code. Its `Error` existential is recorded as the only observed upstream boundary.
- Phase 11 diagnostic result: `ExistentialAny`, then `InternalImportsByDefault`, then `MemberImportVisibility` pass in strict order for `swift-tracy`, `swift-vulkan`, `swift-wayland`, `core`, `platform-linux`, `react-native`, `compositor/compositor-core`, `compositor/compositor`, `shell`, and the root workspace package.
- Phase 11 import-ownership finding: `MemberImportVisibility` exposed implementation files that called members on façade aliases without importing the defining render-model, generated wire-type, Wayland, UI-embedder, Foundation, Linux service, or shell service module. It also exposed extension files that relied on imports present only in another file of the same target.
- Phase 11 decision: add file-local imports for the defining module. Use public imports only when a public façade signature exposes the defining declaration, package imports only for package API, and internal imports for implementation dependencies. Selectively import a noncolliding declaration when importing an entire geometry module would make names such as `Rect`, `ContentSample`, or `BackgroundEffectRegions` ambiguous.
- Phase 11 dependency result: export `NucleusCompositorServerTypes` as an explicit compositor-core product and depend on it directly from `NucleusCompositorRuntime`, because the executable reads members of the wire value types. The compositor ThreadSanitizer harness likewise depends directly on `NucleusCompositorWaylandRuntime` because it calls runtime methods returned by test support. These replace accidental transitive product dependencies.
- Phase 11 final import-access finding: re-running `InternalImportsByDefault` after the member-visibility fixes caught `LayerHost.init` exposing the `GeometryRect` alias while `NucleusTypes` was still imported at inferred internal access. Make that import public; the signature intentionally carries the defining type. The final core and downstream `InternalImportsByDefault` builds and the core `MemberImportVisibility` build pass after the correction.
- Phase 11 generator result: generated Wayland sources carry the import access needed by their public API, and the Vulkan generator retains the accepted stable `@inline(always)` spelling for its benchmark-justified tiny loader primitives. Generator determinism remains part of the final gate.
- Phase 11 concurrency decision: do not enable `InferIsolatedConformances`, `NonisolatedNonsendingByDefault`, or `ImmutableWeakCaptures` in this migration. Their executor and isolation semantics require a separately scoped adoption with focused behavior coverage after every gate in this plan passes.
- Phase 11 final verification: `tools/nucleus build` passes all runtime, benchmark, and sanitizer products. `tools/nucleus test` passes every debug package suite, all six release stress suites, the C/C++ ABI header matrix, and the core public API audit.
- Phase 11 sanitizer result: `tools/nucleus sanitize all` passes all ten AddressSanitizer/LeakSanitizer workloads, all five UndefinedBehaviorSanitizer workloads, and all five ThreadSanitizer harnesses with the fixed seed `0x4e55434c455553`.
- Phase 11 generator verification: a second `generate-wayland` run leaves the complete five-directory generated output hash manifest byte-identical, and a second `generate-vulkan` run leaves `Sources/Vulkan/Vulkan.swift` byte-identical.
- Phase 11 benchmark result: `tools/nucleus benchmark` passes every structural budget and writes the core, Linux, and React Native `nucleus.headless.v3` reports. The initial three-sample run was host-noisy in the retained render workloads, so the final seven-sample core report at `.build/nucleus-benchmarks/phase11-final-core-7/report.json` was compared with the accepted Phase 7 seven-sample report. `transaction-apply-snapshot-10000` records an 18,151,498 ns median versus 17,883,172 ns in Phase 7, and `animation-completion-batch-1000` records 1,532,250 ns versus 1,555,858 ns. This confirms no material retained-tree regression.
- Phase 11 hygiene result: `git diff --check` passes. The pre-existing concurrent Chromium, CEF, toolchain, and distribution-parity work remains in the dirty worktree and was not reverted.

## Phase 1: Harden the Swift 6.4 Language Surface

### Objective

Make the pinned compiler reject accidental legacy or misspelled language configuration, and adopt stable language spellings where they preserve runtime and module behavior before changing runtime behavior.

### Changes

1. Add the `StrictLanguageFeatures` diagnostic group as an error to every first-party Swift target.

   - Pass `-Werror StrictLanguageFeatures` through the common Swift settings used by each package.
   - Apply the setting to Swift targets only.
   - Retain the existing warnings-as-errors policy.
   - Remove any language feature flag that the pinned compiler reports as unknown instead of suppressing the diagnostic.

2. Validate import access against reexport semantics.

   - Retain `@_exported import NucleusUI` in `core/swift/Sources/NucleusApp/FrontDoor.swift`.
   - Retain `@_exported import Vulkan` in `core/swift/Sources/NucleusRenderer/render/NucleusVulkanSupport.swift`.
   - Retain `@_exported import NucleusReactRuntimeCxx` in `react-native/swift/Sources/NucleusReactRuntime/Reexports.swift`.
   - Do not use `public import` as a replacement: it permits imported declarations in public API but does not reexport the imported module, and the pinned compiler diagnoses it as unused in a reexport-only file.
   - Do not add forwarding typealiases. Replace these imports only when Swift exposes a stable import form with equivalent reexport behavior.

3. Make module qualification unambiguous in generated code.

   - Change the Swift Wayland generator in `swift-wayland/Sources/SwiftWaylandGen/main.swift` to emit `Swift::min` instead of `Swift.min`.
   - Regenerate all affected Wayland server dispatch sources from the generator.
   - Use `Swift::min` in `react-native/swift/Sources/NucleusReactRuntimeCxx/DefaultTextLayoutHandler.swift`.
   - Audit other generator templates for module-qualified declarations and use the `Module::declaration` form wherever a generated identifier could shadow the declaration.
   - Do not manually maintain a different spelling in generated output.

4. Audit forced inlining.

   - Remove forced inlining from build-time generator helpers in `swift-vulkan/Tools/VulkanGen/IdRender.swift` and `swift-vulkan/Tools/VulkanGen/Emitter.swift`.
   - Remove forced inlining from large functions such as `bridgeDispatch` in `compositor/compositor-core/Sources/NucleusCompositorShell/KeybindService.swift`.
   - Inspect the display-clock helpers in `compositor/compositor-core/Sources/NucleusCompositorServer/DisplayLink.swift`; retain forced inlining only when a benchmark demonstrates a benefit.
   - Inspect the remaining small render, Vulkan, Wayland router, and Android hash helpers individually.
   - Spell retained uses as `@inline(always)`.
   - Do not add specialization attributes in this phase. A specialization requires a benchmark that identifies a concrete generic instantiation as a material cost.

### Verification

- Build every first-party package with the pinned Swift 6.4 compiler.
- Regenerate Wayland output and verify a second generation produces no changes.
- Run the Swift Wayland generator tests and generated-dispatch tests.
- Run the React Native Swift runtime tests that compile the reexport surface.
- Run the core renderer and app module tests that consume the reexport boundaries.
- Pass the complete-checkout `tools/nucleus build` and `tools/nucleus test` gates.

### Exit Gate

All first-party targets compile with `StrictLanguageFeatures` treated as an error, no first-party source contains `@inline(__always)`, the three intentional `@_exported import` sites remain documented reexport boundaries, and generated module qualification is deterministic.

## Phase 2: Narrow Foundation Dependencies

### Objective

Make every production source import only the Foundation layer it uses. Remove accidental transitive dependence on libdispatch and internationalization from targets that need only value types, paths, files, dates, URLs, or data.

### Changes

1. Remove unused umbrella imports.

   Remove `import Foundation` from these files after confirming they use only the standard library or already imported platform modules:

   - `compositor/compositor-core/Sources/NucleusCompositorServer/DataExchangeService.swift`
   - `compositor/compositor-core/Sources/NucleusCompositorServer/Window.swift`
   - `compositor/compositor-core/Sources/NucleusCompositorShell/KeybindService.swift`
   - `compositor/compositor-core/Sources/NucleusCompositorRendererLinux/drm/DrmDevice.swift`
   - `core/swift/Sources/NucleusTextBackend/SkiaTextLayoutBackend.swift`

2. Replace Foundation imports used only for C math.

   - Move `core/swift/Sources/NucleusUI/TextSystem.swift` to the repository's Darwin/Glibc math import pattern for `ceil`.
   - Move `core/swift/Sources/NucleusUI/Transform.swift` to that pattern for `cos`, `sin`, and `abs`.
   - Move `core/swift/Sources/NucleusUI/ValueAnimator.swift` to that pattern for `exp`, `cos`, and `sin`.
   - Keep the public numeric types in the standard library. Do not introduce Foundation numeric wrappers.

3. Use `FoundationEssentials` for value, file, environment, URL, date, and data APIs.

   Apply `import FoundationEssentials` to the files that use only APIs supplied there, including:

   - `core/swift/Sources/NucleusUI/CollectionReordering.swift`
   - `core/swift/Sources/NucleusUI/DragDrop.swift`
   - `shell/Sources/NucleusShellPasteboard/ShellWaylandDragDropAdapter.swift`
   - `shell/Sources/NucleusShellServices/IconThemeResolver.swift`
   - `shell/Sources/NucleusShellRuntime/ShellHost+Wallpaper.swift`
   - `compositor/compositor-core/Sources/NucleusCompositorShell/DesktopApplicationIndex.swift`
   - `compositor/compositor-core/Sources/NucleusCompositorShell/CursorTheme.swift`
   - `compositor/compositor-core/Sources/NucleusCompositorShell/XCursor.swift`
   - `compositor/compositor-core/Sources/NucleusCompositorShell/ScreenshotService.swift`
   - `platform-linux/Sources/NucleusSessionSupervisor/main.swift`

4. Remove legacy Foundation path operations.

   - Replace the `NSString.lastPathComponent` use in `compositor/compositor/Sources/NucleusCompositorRuntime/SessionIsolation.swift` with URL or native String path handling, then import `FoundationEssentials` for `FileManager` if it remains necessary.
   - Replace `NSHomeDirectory()` in `shell/Sources/NucleusShellServices/IconThemeResolver.swift` with the process environment and the existing explicit fallback policy.
   - Replace `NSString.expandingTildeInPath` in `shell/Sources/NucleusShellRuntime/ShellHost.swift` with URL-based or explicit home-directory path construction.
   - Keep path values structured as `URL` for filesystem operations and convert to `String` only at C or protocol boundaries that require a path string.

5. Replace the shell clock formatter.

   - Remove the retained `DateFormatter` from `shell/Sources/NucleusShellRuntime/ShellHost.swift`.
   - Store a value-typed `Date.FormatStyle` or construct the stable value-typed style at the formatting site.
   - Import `FoundationEssentials` and `FoundationInternationalization` in the shell runtime files that use localized date formatting.
   - Preserve the visible clock format and locale behavior with behavior tests.

6. Give locale-dependent accessibility code an explicit internationalization dependency.

   - Import `FoundationEssentials` and `FoundationInternationalization` in `platform-linux/Sources/NucleusLinuxAccessibility/AtSPIService.swift`.
   - Preserve `Locale.current.identifier` behavior.

7. Retain umbrella Foundation only for APIs that are not supplied by the narrower modules.

   - Keep it in `compositor/compositor-core/Sources/NucleusCompositorShell/LauncherService.swift` for `Process` and `FileHandle`.
   - Keep it in `compositor/compositor-core/Sources/NucleusCompositorShell/ShellServices.swift` while it writes through `FileHandle.standardError`.
   - Keep the generator dependencies required by `swift-wayland/Sources/SwiftWaylandGen/main.swift` for XML parsing and standard file handles. Add `FoundationXML` explicitly when required by the Linux module split.
   - Review every remaining umbrella import against the compiler's module interfaces. Do not rely on an umbrella import because another file in the target uses it.

8. Verify dependency effects.

   - Scan the module dependency graph for each changed target.
   - Confirm targets using only `FoundationEssentials` no longer acquire Dispatch or Foundation internationalization through their direct import.
   - Treat a remaining transitive dependency as acceptable only when another declared target dependency genuinely requires it.

### Verification

- Run focused tests for drag/drop payload encoding, collection reordering, cursor parsing, cursor-theme discovery, desktop application indexing, screenshots, session supervision, shell wallpaper path resolution, and accessibility locale reporting.
- Add or update shell clock behavior tests for the visible format and locale contract.
- Run all package build and test gates after the import changes.
- Inspect linked and scanned dependencies; do not assert import text in a test.

### Exit Gate

Every production `import Foundation` has a documented API reason in its source target. Data, URL, FileManager, ProcessInfo, and Date-only users import `FoundationEssentials`; locale formatting adds `FoundationInternationalization`; math-only and unused imports are gone.

## Phase 3: Enable Strict Memory Safety in Pure Swift Targets

### Objective

Establish strict memory safety where no ABI boundary requires unsafe operations, then use those targets as the baseline for the low-level audit.

### Changes

1. Enable SwiftPM `.strictMemorySafety()` for `NucleusLayers`.
2. Resolve every diagnostic by using safe APIs or narrowing the dependency surface.
3. Enable SwiftPM `.strictMemorySafety()` for `NucleusRenderModel` only after `NucleusLayers` passes its exit checks.
4. Resolve every diagnostic without applying target-wide unsafe annotations.
5. Continue through the remaining pure model and policy targets in dependency order.
6. Mark an imported declaration `@unsafe` only when it actually exposes a memory-safety precondition that the compiler cannot enforce.
7. Do not mark a wrapper `@safe` until it checks or internally establishes every pointer lifetime, initialization, alignment, bounds, aliasing, and thread-safety precondition of the wrapped operation.

### Verification

- Run each target's behavior tests immediately after enabling the setting.
- Run render-model transaction, retained-tree, animation, geometry, serialization, and snapshot tests.
- Build all downstream packages after each target becomes strict-memory-safe.
- Confirm sanitizer harnesses still compile against the changed public surface.

### Exit Gate

All pure Swift model and policy targets compile under `.strictMemorySafety()` without broad suppressions, and every downstream package passes its existing behavior tests.

## Phase 4: Audit Unsafe Boundary Ownership

### Objective

Confine unsafe operations to reviewed boundary implementations and expose safe, ownership-correct Swift APIs to callers.

### Changes

1. Audit `core/swift/Sources/NucleusUI/SecureBytes.swift` as a security boundary.

   - Preserve `explicit_bzero` or `memset_s` semantics.
   - Keep allocation, deallocation, and zeroing in one noncopyable owner.
   - Document the exact initialization, capacity, and lifetime invariants next to the unsafe operations.
   - Expose the wrapper as `@safe` only after every operation establishes those invariants internally.
   - Add runtime tests that verify move behavior, requested capacity, empty storage, and zeroization through an injectable test allocator or observation seam. Do not test source declarations.

2. Classify all remaining unsafe sites by boundary type.

   - Vulkan handles and chained structures
   - Wayland resources, listeners, and generated dispatch
   - io_uring submissions and completion entries
   - POSIX file descriptors, timerfd, and eventfd
   - Skia and React Native C++ opaque handles
   - JNI and `@c @implementation` entry points

3. For each boundary, place unsafe code in the owning low-level target and return opaque handles, scalars, spans, value snapshots, or noncopyable owners to higher layers.
4. Remove unsafe declarations from pure consumers after the owner exposes the required safe operation.
5. Preserve the existing C++ interop rule: non-C++ modules do not import C++ modules directly.
6. Enable `.strictMemorySafety()` on the audited low-level target only after its unsafe surface is explicit.

### Verification

- Run AddressSanitizer and ThreadSanitizer harnesses owned by each changed package.
- Run boundary behavior tests with empty buffers, maximum legal counts, invalid handles, cancellation, and teardown.
- Run the headless renderer and protocol harness tests without launching the compositor.
- Pass all downstream package builds before enabling strict memory safety on the next low-level target.

### Exit Gate

Unsafe diagnostics in each migrated target map to an identified external boundary, safe wrappers establish their complete preconditions, and no higher-level target reaches through the wrapper to raw storage.

## Phase 5: Remove Obsolete Pointer Transports and Bound Live Borrows

### Objective

Delete pointer-bearing transports that no longer represent a live boundary, carry in-process data as Swift values, and expose the genuine borrowed SHM mapping as a bounded span.

### Changes

1. Confirm whether the presumed `std.swift.ProtocolCaller` and Zig relay still exist before designing a span transport for them.
2. Delete `WindowMechanismHost`, `ShellPolicyHost`, `BackdropPolicyWireBridge`, `ShellServiceHost`, `ScreenshotService`, and the screenshot/overlay pointer records because no production caller remains.
3. Keep concrete `WindowManager` policy methods and the live `CompositorShellPolicy` conformance. Rename the surviving implementation files around those concrete responsibilities.
4. Publish notifications as owned `ShellOverlayNotificationInfo` and submit `ShellOverlayEvent` directly between in-process Swift modules.
5. Replace the raw SHM buffer request with `Span<UInt8>` from the Wayland mapping through renderer conversion. Construct the span exactly once at the C boundary and synchronously copy it before `wl_shm_buffer_end_access`.
6. Preserve checked width, height, stride, multiplication-overflow, source-length, DRM-format, and destination-capacity validation before any span indexing.
7. Enable strict memory safety on value and compositor targets unblocked by the deleted pointer records, marking only the remaining POSIX calls explicitly unsafe.

### Verification

- Test empty, undersized, padded-row, copied-ownership, full-HD, and 4K SHM inputs plus unsupported DRM formats.
- Test that the render-service spy owns its snapshot after the span borrow ends.
- Run compositor shell, overlay, window-manager, Wayland-runtime, renderer, and server suites.
- Pass the complete checkout build and test gates with the newly strict targets.

### Exit Gate

No obsolete host transport or screenshot relay remains, in-process strings are owned Swift values, the SHM mapping converts to a span exactly once at Wayland entry, and all consumers copy before the borrow ends.

## Phase 6: Modernize Temporary Storage and Binary Parsing

### Objective

Use Swift 6.4 bounded temporary storage for initialized output and eliminate avoidable pointer-array copies and unchecked binary loads.

### Changes

1. Rewrite `withCStringArray` in `swift-vulkan/Sources/Vulkan/VulkanErgonomics.swift`.

   - Allocate the pointer table once with `withTemporaryAllocation`.
   - Fill an `OutputSpan<UnsafePointer<CChar>?>` while nested `withCString` scopes keep every C string alive.
   - Invoke the body only at the deepest scope after all entries are initialized.
   - Preserve null termination if the Vulkan call contract requires it.
   - Remove recursive `acc + [c]` construction.

2. Modernize `compositor/compositor-core/Sources/NucleusCompositorShell/XCursor.swift`.

   - Keep the parser's readable bytes as one span in the enclosing storage borrow and pass it to an offset-only reader. Do not use underscored lifetime attributes to store the span.
   - Perform checked offset advancement before every read.
   - Decode little-endian integers from bounded bytes instead of using unchecked `UnsafeRawBufferPointer.loadUnaligned` calls.
   - Create owned `Data` only for the pixel payload that escapes the parser.
   - Reject integer overflow, truncated tables, and payload lengths that exceed the input span.

3. Retain `withUnsafeTemporaryAllocation` for POSIX calls that initialize previously uninitialized memory, including raw read scratch buffers.
4. Do not convert a raw buffer to `OutputSpan` when the callee is C and initialization is known only through the C return count.

### Verification

- Test Vulkan string arrays with zero, one, and multiple strings and verify pointer validity only within the body scope.
- Run generated Vulkan ergonomic tests.
- Add XCursor tests for valid images, truncated headers, overflowed offsets, invalid chunk sizes, empty payloads, and multiple image sizes.
- Build the shell target with strict memory safety enabled. Run strict-memory-safety diagnostics over the Vulkan target and keep the pointer helper explicitly unsafe while the generated Vulkan ABI frontier remains target-wide.

### Exit Gate

The Vulkan pointer table has one bounded allocation, XCursor parsing performs no unchecked raw loads, and the behavior tests cover all bounds and lifetime contracts.

## Phase 7: Apply In-Place Ownership to Retained Render State

### Objective

Remove repeated dictionary lookup and copy-out/write-back work from retained-tree mutation without changing copyable snapshot semantics.

### Changes

1. Record the existing retained-tree transaction and animation benchmark results before editing mutation paths.
2. Start with `core/swift/Sources/NucleusRenderModel/RetainedTreeStore.swift`.

   - Identify loops that retrieve `tree.layers[id]`, mutate the `Layer`, assign it back, and then retrieve it again.
   - Prove key presence once.
   - Create a narrowly scoped `MutableRef` to the dictionary value.
   - Perform all mutations through `ref.value` while the reference is live.
   - End the `MutableRef` scope before reading or mutating the dictionary through another path.

3. Apply the same pattern to `core/swift/Sources/NucleusRenderModel/RenderTransactionApply.swift` where one transaction mutates the same layer repeatedly.
4. Preserve `Layer`, render transactions, and exported snapshots as copyable value types.
5. Inspect lower-priority copy-out/write-back paths in texture registries, surface presentation state, Wayland seats, and compositor registries only after retained-tree measurements pass.
6. Change a lower-priority site only when profiling shows repeated hashing, retain/release, or COW work in that path.
7. Do not introduce `UniqueArray` into public render-model state. Its noncopyable semantics conflict with current snapshot behavior.
8. Do not replace shared escaping resource boxes with `UniqueBox`; those boxes intentionally represent shared lifetimes.

### Verification

- Run retained-tree mutation, layer deletion, child ordering, animation tick, transaction rollback, and snapshot isolation tests.
- Run the same benchmark inputs recorded before the change.
- Require no regression in transaction throughput or animation tick cost.
- Confirm snapshot mutation does not affect retained live state.
- Run ThreadSanitizer harnesses for render-model consumers.

### Exit Gate

The primary retained-tree hot paths mutate dictionary values in place, value snapshots remain isolated, all behavior tests pass, and benchmark results are at least neutral.

## Phase 8: Eliminate Forwarded Surface Storage

### Objective

Allow nested mutation of substantial surface state without implicit get-modify-set copies or a redundant ownership projection.

### Changes

1. Remove the ordinary forwarding accessor for `aux` in `compositor/compositor-core/Sources/NucleusCompositorWaylandRuntime/WlSurface.swift`.
2. Store `SurfaceAuxState` directly as `WlSurface.aux`; remove the field from `SurfaceCurrentState`.
3. Keep syncobj observer capture transaction-local and write only accepted points into direct surface storage during `applyLatch`.
4. Verify exclusivity around surface storage and ensure callbacks run only after each nested mutation access ends.
5. Audit other forwarding properties only when the forwarded value is substantial and nested mutation occurs in a measured path.
6. Leave scalar and cheap value forwarding properties as ordinary get/set accessors.

### Verification

- Run surface commit, syncobj timeline, acquire/release point, destruction, and protocol-error tests.
- Exercise re-entrant callback cases through existing Wayland runtime harnesses.
- Run ThreadSanitizer and strict memory-safety checks for compositor-core.
- Confirm the benchmark catalog contains no internal surface-commit workload; do not create a production visibility seam solely for a synthetic benchmark.

### Exit Gate

`SurfaceAuxState` is direct `WlSurface` storage, nested mutation reaches it in place, exclusivity is preserved, and no broad accessor conversion has been applied to cheap scalar properties.

## Phase 9: Enforce Exactly-Once Reactor Resumption

### Objective

Move the single-waiter reactor signal's exactly-once continuation invariant from manual reasoning into Swift's noncopyable type system.

### Changes

1. Convert `ReactorWaitSignal.State.continuation` in `platform-linux/Sources/NucleusLinuxReactor/LinuxHostReactor.swift` from `CheckedContinuation<UInt64?, Never>` to noncopyable `Continuation<UInt64?, Never>`.
2. Create it with `withContinuation`.
3. Transfer the continuation out of mutex-protected state and consume it exactly once during event delivery, timeout, or shutdown.
4. Keep all state transitions under the existing `Synchronization.Mutex`.
5. Define cancellation behavior explicitly: task cancellation does not silently abandon a stored continuation, and every terminal path removes and resumes it.
6. Preserve the existing wake-generation and stale-wake handling semantics.
7. Do not convert `ReactorShutdownSignal` in this phase. Its collection of waiters requires a noncopyable collection design and a separate migration.
8. Do not convert UI clock or pasteboard continuations while they remain stored in ordinary arrays or reference-owned cancellation coordinators.

### Verification

- Test event arrival before suspension, after suspension, during timeout registration, during shutdown, and concurrently with cancellation.
- Test repeated wake signals and stale generation values.
- Run the Linux reactor stress tests and ThreadSanitizer harness.
- Verify every path consumes the continuation exactly once at compile time and at runtime.

### Exit Gate

The single reactor waiter uses noncopyable `Continuation`, every terminal path compiles with exactly-once consumption, and reactor timing and cancellation behavior remain unchanged.

## Phase 10: Preserve Linux Execution Ownership and Audit Dispatch Coupling

### Objective

Keep libdispatch only where it provides the intended thread or event-source semantics, and prevent Foundation cleanup from disguising accidental Dispatch dependencies.

### Changes

1. Retain the `DispatchSourceRead` in `platform-linux/Sources/NucleusLinuxReactor/LinuxHostReactor.swift` solely for draining the io_uring completion eventfd and scheduling the main-actor drain.
2. Keep io_uring as the owner of file-descriptor interests, timerfd, eventfd, cancellation, completion queue budgeting, and kernel batching.
3. Do not replace reactor registrations with `DispatchIO` or a collection of Dispatch sources.
4. Retain the dedicated pthread worker pool in `core/swift/Sources/NucleusRenderer/render/ImageDecodeQueue.swift`.

   - Preserve its bounded worker count.
   - Preserve cancellation of pending decode work.
   - Preserve synchronous worker joining during shutdown.
   - Keep blocking C++ decode work off the cooperative Swift executor and the shared Dispatch pool.

5. Retain explicit Dispatch use in sanitizer harnesses, benchmarks, and React Native smoke code where the test intentionally creates OS-thread contention.
6. Scan production target dependencies after the Foundation migration and remove any direct Dispatch dependency that has no explicit source import and runtime purpose.
7. Do not add a source-shape test for the allowed import list. Enforce the architecture through target dependencies, compiler module scans, and review of runtime ownership.

### Verification

- Run reactor stress, deadline, cancellation, and shutdown tests.
- Run image decode queue cancellation, bounded-concurrency, failure, and shutdown tests.
- Run ThreadSanitizer harnesses that intentionally use Dispatch.
- Inspect the compiled module dependency graph and confirm the reactor is the only ordinary production source with an intentional direct Dispatch dependency.

### Exit Gate

The io_uring reactor and dedicated decode pool retain their current ownership semantics, intentional Dispatch uses are explicit, and narrowed Foundation imports do not reintroduce unexplained Dispatch coupling.

## Phase 11: Complete Compiler and Test Workflow Adoption

### Objective

Finish the migration with compiler modes and testing workflows that expose future issues without adopting unavailable or semantically inappropriate APIs.

### Changes

1. Use Swift Testing's repeat-until-pass and repeat-until-fail modes to reproduce existing flaky or timing-sensitive reactor, compositor, and concurrency tests.
2. Use warning-severity test issues only for diagnostics that intentionally do not fail the test contract.
3. Use dynamic test cancellation only when runtime parameter discovery proves the remaining test cases invalid; do not use cancellation to hide failures.
4. Trial Swift 7 language diagnostics one package at a time in this order:

   1. `ExistentialAny`
   2. `InternalImportsByDefault`
   3. `MemberImportVisibility`

5. Fix every diagnostic directly before advancing to the next package or feature.
6. Migrate concurrency semantic switches in a separate follow-on only after this plan passes:

   - `InferIsolatedConformances`
   - `NonisolatedNonsendingByDefault`
   - `ImmutableWeakCaptures`

7. Require focused actor-isolation and executor-behavior tests before enabling a concurrency semantic switch.

### Verification

- Run the full Swift Testing suite with the ordinary configuration.
- Use repeat modes on the known stress-test subset and record any reproducible failure as a defect rather than weakening assertions.
- Build each package under the selected Swift 7 diagnostic mode before applying it to the next package.
- Pass the complete-checkout build, test, sanitizer, generator-determinism, and benchmark gates.

### Exit Gate

The Swift 6.4 modernization is fully validated, the first three Swift 7 diagnostic modes have a recorded package-by-package result, and no concurrency semantic switch has landed without behavior coverage.

## Deferred Features and Adoption Gates

These features do not enter the implementation phases above until their gates are satisfied.

### Standard-Library `FilePath`

Do not migrate filesystem code until the pinned Swift toolchain exposes the standard-library `FilePath` described in `core/docs/wwdc26-swift-whatsnew.txt`. Once available, migrate icon themes, desktop application indexing, shell configuration, session paths, and wallpaper paths in one direct change. Keep `URL` for Foundation filesystem APIs and convert only at the boundary.

Do not introduce a broad temporary `swift-system` dependency solely to bridge the period before the standard-library type lands.

### `Dictionary.mapKeyedValues`

Do not add a local compatibility extension. Adopt the standard-library operation only after it type-checks in the pinned toolchain, then replace matching dictionary transformations directly.

### `BorrowingSequence`

Do not add it without a real custom sequence whose elements must borrow noncopyable storage. The current codebase has no qualifying production sequence.

### `UniqueArray`

Do not replace ordinary render-model arrays. Their copyable snapshot semantics are part of the design. Revisit `UniqueArray` only for an internal collection of noncopyable values, such as a future multi-waiter noncopyable continuation store.

### `UniqueBox`

Do not replace shared escaping renderer resource boxes. Use `UniqueBox` only when ownership is singular, transfer is explicit, and no closure or registry shares the owner.

### `withTaskCancellationShield`

Do not add cancellation shielding to pasteboard writes or reactor waits. Pasteboard cancellation intentionally prevents a write before commit, and reactor teardown already owns continuation completion. Use shielding only for a future short commit-or-rollback region that must finish after externally visible mutation starts.

### Async `defer`

Do not rewrite explicit shell shutdown solely to use async `defer`. Adopt it only when one lexical scope acquires an async resource and has multiple exits that currently duplicate async cleanup.

### `ProgressManager`

Do not introduce progress reporting without a structured, long-running, user-visible operation. Bootstrap or provisioning can adopt it later if those operations move behind a Swift UI or service boundary.

### Swift Subprocess 1.0

Do not code against the transcript's Subprocess 1.0 surface until that version is available and pinned. At that point, replace duplicated test command-launch helpers first. Keep `Foundation.Process` in `LauncherService` until Subprocess provides the exact detached GUI lifecycle, environment, termination, and retention behavior required there.

## Completion Criteria

The plan is complete when all of the following are true:

- Stable Swift 6.4 language spellings are used throughout first-party code and generators except for the three documented module reexports that have no stable equivalent.
- Unknown language feature configuration is an error in every first-party Swift target.
- Pure Swift targets and audited low-level targets compile under strict memory safety.
- Unsafe operations are confined to explicit ABI owners with documented and tested safety invariants.
- Swift-owned pointer/count protocol seams use spans.
- Vulkan temporary C-string arrays and XCursor binary parsing use bounded storage.
- Retained-tree in-place mutation passes behavior and performance gates.
- The single reactor waiter uses noncopyable continuation ownership.
- Foundation imports are minimal and the production dependency graph contains no unexplained Dispatch coupling.
- The io_uring reactor and image decode worker pool retain their kernel and thread-ownership semantics.
- Complete-checkout builds, tests, sanitizers, generators, and affected benchmarks pass on the host.

## Source Basis

This plan is based on the feature inventory in `core/docs/wwdc26-swift-whatsnew.txt`, direct source auditing of the first-party Swift packages, type-check probes against the pinned Swift 6.4 development compiler, and the official Swift documentation for strict memory safety, Foundation, libdispatch, Swift Testing, and Subprocess.
