# Nucleus Android Scaffold

This directory is the Android packaging scaffold for the native Nucleus Android host.

The Gradle build uses the Android Gradle Plugin. Zig still owns the native
`libnucleus-android.so` build, and AGP owns Java compilation, AAR packaging, APK
packaging, debug signing, alignment, and device install tasks.

The checked-in baseline is:

- AGP `9.2.1`
- Gradle wrapper `9.4.1`
- `compileSdk` API `37.0`
- app `targetSdk` API `37`
- `minSdk` API `24`
- NDK `30.0.14904198` for the Swift Android artifactbundle/toolchain path

The Android framework and smoke app source are Kotlin under `src/main/kotlin`.
This uses AGP 9's built-in Kotlin compilation path; there is no separate Kotlin
Gradle plugin in the scaffold.

The `:nucleus` AAR packages:

- `classes.jar` with the Java loader and host lifecycle wrapper
- `assets/nucleus-android.properties` with ABI, SDK, Swift source, and native library metadata
- `jni/arm64-v8a/libnucleus-android.so`
- `jni/arm64-v8a/libc++_shared.so`
- `AndroidManifest.xml`

Build and verify the AAR plus signed debug smoke APK artifacts without launching a device:

```sh
../../tools/collider android build
```

By default the root Swift orchestrator asks Gradle to cross-compile the host and
then verifies its ELF and JNI contract. The underlying native step runs:

```sh
<monorepo-root>/tools/collider android native
```

This keeps toolchain selection, SwiftPM invocation, and native verification in
the workspace entry point. Gradle owns Android packaging and consumes the
verified native products.

The signed smoke APK is:

```sh
../zig-out/android-gradle/smoke-app/outputs/apk/debug/smoke-app-debug.apk
```

Once a device is connected and authorized, install and start the smoke app with:

```sh
./gradlew :smoke-app:startDebugDevice
```

Watch the render status with:

```sh
adb logcat -s NucleusSmoke
```

The smoke app logs lifecycle and native diagnostics under `NucleusSmoke`. A healthy device run should show `renderStatus=posted`, increasing host/runtime/render frame counters, surface attach/change counts, and touch/key counters after input.

The Android framework entry point is `dev.nucleus.android.NucleusView`. It owns a `NucleusHost`, forwards `SurfaceHolder` lifecycle to native, configures the native host from the Android `Context`, and posts Choreographer frame callbacks only while started and attached to a surface.

`NucleusView` also forwards window attachment, focus, configuration, touch, key, and placeholder IME state into the native host. `NucleusHost.diagnostics()` exposes a snapshot of native lifecycle, surface, configuration, input, event queue, runtime, and render counters for smoke validation. The AAR includes `assets/nucleus-smoke.txt`, and `NucleusHost.assetSmokeValue("nucleus-smoke.txt")` exercises the native `AAssetManager` read path for future runtime validation.

Native host events are queued through a bounded drainable event buffer, assets flow through `AssetProvider.zig`, and `RuntimeHost.zig` owns the runtime attach/start/frame/stop contract. `AndroidRenderer.zig` now has the first software frame path: it locks `ANativeWindow`, writes a deterministic RGBA/RGB565 pattern when a supported buffer is available, posts it, and records render status for smoke verification.
