package dev.nucleus.android

import android.content.res.AssetManager
import android.view.Surface

/**
 * The hand-written JNI surface swift-java cannot generate: entry points whose
 * parameters are Android framework objects requiring a live `JNIEnv*` —
 * `Surface → ANativeWindow` and `AssetManager → AAssetManager`. Everything else on
 * the host is the swift-java-generated [AndroidHost].
 *
 * Each method takes the host's monotonic opaque registry ID as a `Long`; the matching
 * `Java_dev_nucleus_android_NucleusNative_*` thunk in AndroidJNI.swift performs a
 * weak registry lookup and owner-thread validation. It never reconstructs a Swift
 * pointer from Java data.
 */
internal object NucleusNative {
    /** Link/smoke marker (6404) — proves the native library is loaded and matched. */
    @JvmStatic external fun smokeValue(): Int

    @JvmStatic external fun configureHost(
        hostId: Long,
        assetManager: AssetManager,
        filesDir: String,
        cacheDir: String,
        packageName: String,
        density: Float,
        sdkInt: Int,
    ): Boolean

    @JvmStatic external fun surfaceCreated(hostId: Long, surface: Surface): Boolean

    @JvmStatic external fun surfaceChanged(hostId: Long, format: Int, width: Int, height: Int): Boolean

    @JvmStatic external fun surfaceDestroyed(hostId: Long): Boolean
}
