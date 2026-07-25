// Hand-written JNI entry points that swift-java cannot generate: the ones whose
// parameters are Android framework objects requiring a live JNIEnv* —
// `Surface → ANativeWindow` and `AssetManager → AAssetManager`. Everything else is
// generated from AndroidHost's `public` surface by swift-java.
//
// These bind to the small hand-written Kotlin `NucleusNative` class. Each takes the
// AndroidHost's monotonic opaque registry ID as a jlong. A lookup retains the weakly
// registered host for the call, and the owner-thread check runs before any host state
// is touched. No Java value is ever interpreted as a Swift pointer.
//
// This module is non-cxx and does not import NucleusAndroidCore, so the error codes
// the host can set are mirrored here as raw Int32 values (the source of truth is
// AndroidErrorCode in the core); they cross the C-ABI as Int32.
//
// JNI ABI mapping (these thunks predate cxx-interop's jni.h and stay on raw pointers):
//   JNIEnv* / jobject / jclass / jstring -> UnsafeMutableRawPointer?
//   jint -> Int32, jlong -> Int64, jfloat -> Float, jboolean -> UInt8

import NucleusAndroidC

public enum NucleusAndroidSmoke {
    public static let linkedMarker: Int32 = 4
}

private let JNI_VERSION_1_6: Int32 = 0x0001_0006
private let JNI_TRUE: UInt8 = 1
private let JNI_FALSE: UInt8 = 0

// Mirror of the AndroidErrorCode raw values this layer sets (core is the source of truth).
private enum JNIError {
    static let surfaceNull: Int32 = 4
    static let surfaceAcquireFailed: Int32 = 5
    static let contextNull: Int32 = 8
    static let assetManagerFailed: Int32 = 9
    static let assetOpenFailed: Int32 = 10
    static let assetReadFailed: Int32 = 11
    static let assetPathRejected: Int32 = 12
}

private func boolToJni(_ value: Bool) -> UInt8 {
    return value ? JNI_TRUE : JNI_FALSE
}

private func registeredOwner(
    _ hostID: Int64,
    operation: StaticString
) -> AndroidHost? {
    guard let host = AndroidHostRegistry.lookup(hostID),
          host.acceptsHandwrittenCall(operation)
    else {
        return nil
    }
    return host
}

func assetProviderErrorCode(_ error: Error) -> Int32 {
    switch error {
    case AssetReadError.pathRejected: return JNIError.assetPathRejected
    case AssetReadError.openFailed: return JNIError.assetOpenFailed
    case AssetReadError.readFailed: return JNIError.assetReadFailed
    default: return JNIError.assetReadFailed
    }
}

// MARK: - Load / smoke

@c
public func JNI_OnLoad(_ vm: UnsafeMutableRawPointer?, _ reserved: UnsafeMutableRawPointer?) -> Int32 {
    return JNI_VERSION_1_6
}

@c
public func Java_dev_nucleus_android_NucleusNative_smokeValue(
    _ env: UnsafeMutableRawPointer?,
    _ clazz: UnsafeMutableRawPointer?
) -> Int32 {
    return 6400 + NucleusAndroidSmoke.linkedMarker
}

// MARK: - Configure (AssetManager → AAssetManager)

@c
public func Java_dev_nucleus_android_NucleusNative_configureHost(
    _ env: UnsafeMutableRawPointer?,
    _ clazz: UnsafeMutableRawPointer?,
    _ hostID: Int64,
    _ assetManagerObject: UnsafeMutableRawPointer?,
    _ filesDir: UnsafeMutableRawPointer?,
    _ cacheDir: UnsafeMutableRawPointer?,
    _ packageName: UnsafeMutableRawPointer?,
    _ density: Float,
    _ sdkInt: Int32
) -> UInt8 {
    guard let host = registeredOwner(
        hostID,
        operation: "NucleusNative.configureHost")
    else { return JNI_FALSE }

    if unsafe assetManagerObject == nil
        || filesDir == nil
        || cacheDir == nil
        || packageName == nil
    {
        host.setError(JNIError.contextNull)
        return JNI_FALSE
    }

    guard let assetManager = unsafe nucleus_android_asset_manager_from_java(
        env,
        assetManagerObject)
    else {
        host.setError(JNIError.assetManagerFailed)
        return JNI_FALSE
    }

    guard let filesChars = unsafe nucleus_jni_get_string_utf_chars(env, filesDir) else {
        host.setError(JNIError.contextNull)
        return JNI_FALSE
    }
    defer {
        unsafe nucleus_jni_release_string_utf_chars(env, filesDir, filesChars)
    }

    guard let cacheChars = unsafe nucleus_jni_get_string_utf_chars(env, cacheDir) else {
        host.setError(JNIError.contextNull)
        return JNI_FALSE
    }
    defer {
        unsafe nucleus_jni_release_string_utf_chars(env, cacheDir, cacheChars)
    }

    guard let packageChars = unsafe nucleus_jni_get_string_utf_chars(
        env,
        packageName)
    else {
        host.setError(JNIError.contextNull)
        return JNI_FALSE
    }
    defer {
        unsafe nucleus_jni_release_string_utf_chars(
            env,
            packageName,
            packageChars)
    }

    return boolToJni(unsafe host.configureContext(
        assetManager,
        density,
        sdkInt,
        filesChars,
        cacheChars,
        packageChars
    ))
}

// MARK: - Surface (Surface → ANativeWindow)

@c
public func Java_dev_nucleus_android_NucleusNative_surfaceCreated(
    _ env: UnsafeMutableRawPointer?,
    _ clazz: UnsafeMutableRawPointer?,
    _ hostID: Int64,
    _ surface: UnsafeMutableRawPointer?
) -> UInt8 {
    guard let host = registeredOwner(
        hostID,
        operation: "NucleusNative.surfaceCreated")
    else { return JNI_FALSE }

    if unsafe surface == nil {
        host.setError(JNIError.surfaceNull)
        return JNI_FALSE
    }

    guard let window = unsafe nucleus_android_window_from_surface(env, surface) else {
        host.setError(JNIError.surfaceAcquireFailed)
        return JNI_FALSE
    }
    // ANativeWindow_fromSurface returns one acquired reference. Ownership transfers
    // to the host only after attachSurface returns; every replaced reference is
    // released on this same owner thread.
    let width = unsafe nucleus_android_window_get_width(window)
    let height = unsafe nucleus_android_window_get_height(window)
    let format = unsafe nucleus_android_window_get_format(window)

    let oldWindow = unsafe host.attachSurface(window, width, height, format)
    if let old = unsafe oldWindow {
        unsafe nucleus_android_window_release(old)
    }
    return JNI_TRUE
}

@c
public func Java_dev_nucleus_android_NucleusNative_surfaceChanged(
    _ env: UnsafeMutableRawPointer?,
    _ clazz: UnsafeMutableRawPointer?,
    _ hostID: Int64,
    _ format: Int32,
    _ width: Int32,
    _ height: Int32
) -> UInt8 {
    guard let host = registeredOwner(
        hostID,
        operation: "NucleusNative.surfaceChanged")
    else { return JNI_FALSE }
    return boolToJni(host.updateSurface(width, height, format))
}

@c
public func Java_dev_nucleus_android_NucleusNative_surfaceDestroyed(
    _ env: UnsafeMutableRawPointer?,
    _ clazz: UnsafeMutableRawPointer?,
    _ hostID: Int64
) -> UInt8 {
    guard let host = registeredOwner(
        hostID,
        operation: "NucleusNative.surfaceDestroyed")
    else { return JNI_FALSE }
    guard let window = unsafe host.detachSurface() else { return JNI_FALSE }
    unsafe nucleus_android_window_release(window)
    return JNI_TRUE
}
