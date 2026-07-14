package dev.nucleus.android

import android.content.res.AssetManager
import android.view.Surface

/**
 * The hand-written JNI surface swift-java cannot generate: entry points whose
 * parameters are Android framework objects requiring a live `JNIEnv*` —
 * `Surface → ANativeWindow` and `AssetManager → AAssetManager`. Everything else on
 * the host is the swift-java-generated [AndroidHost].
 *
 * Each method takes the swift-java self-pointer of the host (`AndroidHost.$memoryAddress()`)
 * as a `Long`; the matching `Java_dev_nucleus_android_NucleusNative_*` thunk in
 * AndroidJNI.swift reconstructs the Swift facade from it. There is no handle registry.
 */
internal object NucleusNative {
    /** Link/smoke marker (6404) — proves the native library is loaded and matched. */
    @JvmStatic external fun smokeValue(): Int

    @JvmStatic external fun configureHost(
        selfPointer: Long,
        assetManager: AssetManager,
        filesDir: String,
        cacheDir: String,
        packageName: String,
        density: Float,
        sdkInt: Int,
    ): Boolean

    @JvmStatic external fun surfaceCreated(selfPointer: Long, surface: Surface): Boolean

    @JvmStatic external fun surfaceChanged(selfPointer: Long, format: Int, width: Int, height: Int): Boolean

    @JvmStatic external fun surfaceDestroyed(selfPointer: Long): Boolean
}
