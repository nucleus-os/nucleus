# Android Swift/Java qualification plan

Status: active.

## Invariant

The Android library uses generated swift-java bindings for ordinary Swift/Java
API and a narrow handwritten JNI surface only for Android platform objects that
the generated interface cannot represent directly. `NucleusAndroidJNI` imports
`NucleusAndroidCore` through the selected swift-java and JNI-core commits; there
is no separate C facade between those Swift targets.

Generated `AndroidHost` calls carry ordinary values. Handwritten Surface and
AssetManager entry points use the weak monotonic `AndroidHostRegistry`; the ID
is never a native memory address, never reused, and never extends host lifetime.
Kotlin owns the Android view and lifecycle integration while Swift owns retained
Nucleus state and rendering.

The source migration, Gradle tasks, generated bindings, JNI library packaging,
and registry implementation are complete. This plan owns end-to-end
qualification only.

## Phase 1 — Qualify generated and handwritten boundaries

Regenerate swift-java sources, compile the Android Swift products with the
official Android Swift SDK, and run the generated API, registry lifetime,
Surface, AssetManager, exception, and teardown tests.

Gate: generated sources are reproducible, JNI symbols resolve from the packaged
libraries, and late calls through a retired registry ID fail safely.

## Phase 2 — Qualify Gradle packaging

Build the Android library and sample application from clean Gradle and Swift
derived state. Inspect every packaged architecture, loader path, Swift runtime,
native dependency, and libc++ dependency.

Gate: the APK/AAR contains only the declared architecture closure and loads
without source-tree or host-toolchain reach-through.

## Phase 3 — Qualify on device

Install the sample on a supported Android 17 device or emulator, create and
resize the Nucleus view, exercise generated API calls, Surface replacement,
AssetManager access, pause/resume, process recreation, and repeated teardown.

Gate: lifecycle and rendering behavior pass without stale registry entries,
JNI exceptions, native leaks, or crashes.

## Phase 4 — Close the migration

Move the durable JNI ownership rules into the Android architecture contract and
remove this qualification plan.
