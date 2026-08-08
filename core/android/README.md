# Nucleus Android application host

This directory contains the Gradle packaging scaffold for the Swift Android application host.

SwiftPM cross-compiles the native host from `core/platform-android`; AGP owns Kotlin compilation, AAR/APK packaging, signing, alignment, and device tasks. The AAR packages `libnucleus-android.so`, `libc++_shared.so`, the Kotlin lifecycle wrapper, manifest, and host metadata.

Build and verify without launching a device:

```sh
collider build android
```

Build only the native Swift artifact with:

```sh
collider build android-native
```

`dev.nucleus.android.NucleusView` owns the Android view lifecycle and forwards surface, configuration, input, and frame callbacks to the Swift host. `AndroidRenderEngine` and `AndroidVulkanPresenter` own the Vulkan presentation path; no Zig or software-framebuffer implementation remains.

Device installation and interactive validation are explicit user-run steps after the build succeeds.
