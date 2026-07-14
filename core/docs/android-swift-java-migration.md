# Android JNI via swift-java

## Invariant

The Android JNI boundary is generated, not hand-written. Every native method
the JVM calls is a `public` Swift declaration on a swift-java-extracted type;
`swift-java` (jextract, JNI mode) emits both the Java binding and the
`Java_…` Swift thunk. The only hand-written JNI that survives is the code that
must touch live NDK handles behind a `JNIEnv*` — `Surface → ANativeWindow`,
`AssetManager → AAssetManager`, and the `jstring` marshalling in
`NucleusAndroidC`. Object lifetime is owned by swift-java's `SwiftArena` /
`JNISwiftInstance` self-pointer model; the hand-rolled `NSLock`-guarded
`[UInt64: AndroidHost]` registry is deleted.

The Swift runtime is statically linked into `libnucleus-android.so`. The APK's
`jniLibs` contains that host library, `libSwiftJava.so`, and `libc++_shared.so`;
it does not carry a parallel set of Swift runtime `.so`s. The toolchain exempts
host build-tool products from Android static-stdlib linking. swift-java's
generated bindings auto-load `libSwiftJava.so` then the module library through
`SwiftLibraries.loadLibraryWithFallbacks`, so both must be present as `jniLibs`.

## Why the host module is split in two

swift-java's generated `@_cdecl` JNI thunks require the C-style `jni.h`
(`JNIEnv` as a function-table pointer, raw `jclass`). The Android host needs
C++ interop to call NucleonRenderer's C++ Skia-Graphite interface, and under
C++ interop the NDK `jni.h` imports `JNIEnv` as the C++ `_JNIEnv` struct and
`jclass` as `UnsafeMutablePointer<_jclass>` — types `@_cdecl` cannot represent.
The two are irreconcilable in one module. So the host is split:

- **`NucleusAndroidCore`** (cxx-interop) — `AndroidHostCore` (the full state
  machine) plus the renderer/runtime/Vulkan files. Its `public` API is
  primitive / `String` / opaque-pointer only; no C++ type crosses the boundary.
- **`NucleusAndroidJNI`** (no cxx-interop) — the swift-java-extracted
  `AndroidHost` facade wrapping `AndroidHostCore`, the generated thunks, and the
  hand-written NDK-handle thunks. This is the product's root target;
  `NucleusAndroidCore` links in as a dependency, so the single
  `libnucleus-android.so` carries both.

The facade does **not** `import NucleusAndroidCore`: importing a cxx-interop
Swift module makes the compiler load that module's recorded clang module graph
(including a C++ module a non-cxx target cannot build). Instead the facade calls
`AndroidHostCore` through a C ABI — `@_cdecl nucleus_core_*` functions in
`AndroidHostCoreABI.swift`, declared `@_silgen_name` in the facade and resolved
at link time. The opaque core handle is an `Unmanaged<AndroidHostCore>`; only
primitives and opaque pointers cross. The core keeps its render imports
`internal` so they never reach the facade.

## Components

- `third-party/swift-java/` — the Nucleus `swiftlang/swift-java` fork, tracked as a
  top-level git submodule. Provides the `SwiftJava` runtime library, the
  `JExtractSwiftPlugin` build-tool plugin, and the `SwiftKitCore` Java runtime.
- `platform-android/swift/AndroidHost.swift` — reshaped so the migratable
  surface is `public` instance methods on a `public final class AndroidHost`.
- `platform-android/swift/AndroidJNI.swift` — keeps only `JNI_OnLoad` and the
  hand-written thunks for the NDK-handle entry points; the rest are deleted.
- `platform-android/c/nucleus_android_jni.{c,h}` — unchanged; still the sole
  owner of `jni.h` / NDK includes.
- `android/nucleus/.../dev/nucleus/android/` — the generated `AndroidHost.java`
  binding replaces the hand-written `Nucleus` `external fun` block;
  `NucleusHost.kt` drives the generated type through a `SwiftArena`.

## Phase 1 — Bring swift-java into the build

Add `third-party/swift-java/` as a submodule. Add it to
`platform-android/Package.swift` as `.package(name: "swift-java", path:
"../../third-party/swift-java")`, give `NucleusAndroidHost` a dependency on the
`SwiftJava` product and the `JExtractSwiftPlugin` plugin, and add
`platform-android/swift/swift-java.config` (`"mode": "jni"`, `"javaPackage":
"dev.nucleus.android"`). The package builds for the Android SDK on the dynamic
stdlib path with the current toolchain; this phase lands no behavioral change
beyond the plugin running and emitting (initially unused) bindings.

## Phase 2 — Reshape AndroidHost into the extracted type

Promote `AndroidHost` to `public final class` and expose the migratable methods
as `public` instance methods with primitive / `String` / handle-free
signatures: lifecycle (`start`, `stop`, `windowAttached`, `windowDetached`,
`windowFocusChanged`, `configurationChanged`), frame (`frame`), input
(`touchEvent`, `keyEvent`, `imeStateChanged`), runtime (`runtimeAttach`,
`runtimeStart`, `runtimeFrame`, `runtimeStop`, `runtimeDetach`,
`runtimeSmokeValue`, `runtimeVerificationValue`), render/diagnostics
(`renderSmokeValue`, `renderStatusCode`, `diagnosticValue`, `lastErrorCode`),
and the event-queue / asset / runtime smoke values that take only primitives or
`String`. Construction (`nativeCreateHost`) becomes the swift-java designated
initializer; teardown (`nativeDestroyHost`) becomes arena finalization. jextract
emits `AndroidHost.java` and the matching `Java_…AndroidHost_…` thunks.

## Phase 3 — Keep the NDK-handle entry points hand-written

`nativeConfigureHost` (takes `AssetManager`), `nativeSurfaceCreated` (takes
`Surface`), `nativeSurfaceChanged`, and `nativeSurfaceDestroyed` stay as
hand-written `@c Java_…` thunks in `AndroidJNI.swift`, because their parameters
are Android framework objects that require `AAssetManager_fromJava` /
`ANativeWindow_fromSurface` against a live `JNIEnv*`. They call into the same
`public` `AndroidHost` instance, resolved from its swift-java self-pointer
(`long`) passed from Kotlin, rather than from the deleted registry. `JNI_OnLoad`
remains a stub returning `JNI_VERSION_1_6`; registration stays by-name.

## Phase 4 — Move the Kotlin side onto the generated binding

Delete the `external fun` block and the `ERROR_*` / `RENDER_STATUS_*` /
`DIAGNOSTIC_*` mirror constants' dependence on hand-written natives. The Android
Gradle module adds `third-party/swift-java/SwiftKitCore/src/main/java` and the
plugin's generated Java output directory as source sets. `NucleusHost.kt` holds
an `AndroidHost` (the generated type) created in a `SwiftArena` tied to the
view's lifecycle; `close()` closes the arena. The hand-written surface/configure
calls invoke the retained thunks, passing `host.$memoryAddress()`.

## Phase 5 — Package the runtime and update verification

`android/nucleus/build.gradle.kts` copies `libSwiftJava.so` into
`jniLibs/arm64-v8a` next to `libnucleus-android.so` and `libc++_shared.so`.
The Swift runtime is already embedded in the host. `tools/nucleus android verify`
stops parsing `Nucleus.kt` for `external fun`s and instead asserts the generated
`Java_…AndroidHost_…` thunks plus the retained hand-written NDK-handle thunks
are exported, that the static Swift runtime is present, and that no dynamic
`libswiftCore.so` dependency remains.

## Status

The Swift side is implemented and verified: `swift build --swift-sdk
swift-release-6.4.x_android --static-swift-stdlib -c release` produces `libnucleus-android.so` (with
`libSwiftJava.so`), and `tools/nucleus android verify` passes — 25 generated
`AndroidHost` thunks, the 5 hand-written `NucleusNative` thunks, `JNI_OnLoad`,
and the Vulkan bringup probe all export; the Swift runtime is embedded and
libSwiftJava remains `NEEDED`. The Kotlin (`Nucleus`/`NucleusHost`/`NucleusNative`), Gradle (source
sets + jniLibs), and the verify script are written but await an Android/Gradle
build to confirm end to end (no Android toolchain in the Swift build env).

swift-java pulls build-time transitive dependencies (swift-syntax,
swift-argument-parser, swift-system, swift-collections, swift-subprocess);
these are currently network-resolved. Vendoring them as submodules for a fully
hermetic build is a follow-up.

## Deployment note

The Android host has one deployment path: `--static-swift-stdlib`. Host tools
such as the swift-java CLI and build-tool plugins continue to use the host
runtime, while the cross-compiled library embeds the Android Swift runtime.
