package dev.nucleus.android

// The native host surface is now split: the lifecycle / frame / input / runtime /
// diagnostics methods are the swift-java-generated [AndroidHost]; the NDK-handle
// entry points (Surface / AssetManager) are [NucleusNative]. This object retains the
// shared error / render-status / diagnostic code constants and the library load.
object Nucleus {
    const val ERROR_NONE: Int = 0
    const val ERROR_INVALID_HANDLE: Int = 1
    const val ERROR_ALLOCATION_FAILED: Int = 2
    const val ERROR_REGISTRY_FAILED: Int = 3
    const val ERROR_SURFACE_NULL: Int = 4
    const val ERROR_SURFACE_ACQUIRE_FAILED: Int = 5
    const val ERROR_NO_SURFACE: Int = 6
    const val ERROR_NOT_STARTED: Int = 7
    const val ERROR_CONTEXT_NULL: Int = 8
    const val ERROR_ASSET_MANAGER_FAILED: Int = 9
    const val ERROR_ASSET_OPEN_FAILED: Int = 10
    const val ERROR_ASSET_READ_FAILED: Int = 11
    const val ERROR_ASSET_PATH_REJECTED: Int = 12
    const val ERROR_RUNTIME_NOT_ATTACHED: Int = 13
    const val ERROR_RENDER_NOT_STARTED: Int = 14

    const val RENDER_STATUS_NONE: Int = 0
    const val RENDER_STATUS_POSTED: Int = 1
    const val RENDER_STATUS_NO_SURFACE: Int = 2
    const val RENDER_STATUS_INVALID_SURFACE: Int = 3
    const val RENDER_STATUS_LOCK_FAILED: Int = 4
    const val RENDER_STATUS_POST_FAILED: Int = 5
    const val RENDER_STATUS_UNSUPPORTED_FORMAT: Int = 6

    const val DIAGNOSTIC_PLATFORM_CONFIGURED: Int = 1
    const val DIAGNOSTIC_HOST_STARTED: Int = 2
    const val DIAGNOSTIC_WINDOW_ATTACHED: Int = 3
    const val DIAGNOSTIC_WINDOW_FOCUSED: Int = 4
    const val DIAGNOSTIC_SURFACE_ATTACHED: Int = 5
    const val DIAGNOSTIC_SURFACE_WIDTH: Int = 6
    const val DIAGNOSTIC_SURFACE_HEIGHT: Int = 7
    const val DIAGNOSTIC_SURFACE_FORMAT: Int = 8
    const val DIAGNOSTIC_SURFACE_GENERATION: Int = 9
    const val DIAGNOSTIC_HOST_FRAME_COUNT: Int = 10
    const val DIAGNOSTIC_HOST_LAST_FRAME_TIME_NANOS: Int = 11
    const val DIAGNOSTIC_VIEW_WIDTH: Int = 12
    const val DIAGNOSTIC_VIEW_HEIGHT: Int = 13
    const val DIAGNOSTIC_DENSITY_MILLI: Int = 14
    const val DIAGNOSTIC_CONFIGURATION_GENERATION: Int = 15
    const val DIAGNOSTIC_TOUCH_EVENT_COUNT: Int = 16
    const val DIAGNOSTIC_LAST_TOUCH_ACTION: Int = 17
    const val DIAGNOSTIC_LAST_TOUCH_POINTER_ID: Int = 18
    const val DIAGNOSTIC_LAST_TOUCH_POINTER_COUNT: Int = 19
    const val DIAGNOSTIC_LAST_TOUCH_X_MILLI: Int = 20
    const val DIAGNOSTIC_LAST_TOUCH_Y_MILLI: Int = 21
    const val DIAGNOSTIC_LAST_TOUCH_PRESSURE_MILLI: Int = 22
    const val DIAGNOSTIC_LAST_TOUCH_TIME_NANOS: Int = 23
    const val DIAGNOSTIC_KEY_EVENT_COUNT: Int = 24
    const val DIAGNOSTIC_LAST_KEY_ACTION: Int = 25
    const val DIAGNOSTIC_LAST_KEY_CODE: Int = 26
    const val DIAGNOSTIC_LAST_KEY_REPEAT_COUNT: Int = 27
    const val DIAGNOSTIC_LAST_KEY_META_STATE: Int = 28
    const val DIAGNOSTIC_LAST_KEY_TIME_NANOS: Int = 29
    const val DIAGNOSTIC_IME_ACTIVE: Int = 30
    const val DIAGNOSTIC_QUEUED_EVENT_COUNT: Int = 31
    const val DIAGNOSTIC_DROPPED_EVENT_COUNT: Int = 32
    const val DIAGNOSTIC_HOST_START_COUNT: Int = 33
    const val DIAGNOSTIC_HOST_STOP_COUNT: Int = 34
    const val DIAGNOSTIC_WINDOW_ATTACH_COUNT: Int = 35
    const val DIAGNOSTIC_WINDOW_DETACH_COUNT: Int = 36
    const val DIAGNOSTIC_WINDOW_FOCUS_COUNT: Int = 37
    const val DIAGNOSTIC_SURFACE_ATTACH_COUNT: Int = 38
    const val DIAGNOSTIC_SURFACE_CHANGE_COUNT: Int = 39
    const val DIAGNOSTIC_SURFACE_DETACH_COUNT: Int = 40
    const val DIAGNOSTIC_IME_CHANGE_COUNT: Int = 41
    const val DIAGNOSTIC_ASSET_SMOKE_VALUE: Int = 42
    const val DIAGNOSTIC_ASSET_SMOKE_COUNT: Int = 43
    const val DIAGNOSTIC_RUNTIME_ATTACHED: Int = 44
    const val DIAGNOSTIC_RUNTIME_STARTED: Int = 45
    const val DIAGNOSTIC_RUNTIME_ATTACH_COUNT: Int = 46
    const val DIAGNOSTIC_RUNTIME_START_COUNT: Int = 47
    const val DIAGNOSTIC_RUNTIME_FRAME_COUNT: Int = 48
    const val DIAGNOSTIC_RUNTIME_DRAINED_EVENT_COUNT: Int = 49
    const val DIAGNOSTIC_RUNTIME_STOP_COUNT: Int = 50
    const val DIAGNOSTIC_RUNTIME_DETACH_COUNT: Int = 51
    const val DIAGNOSTIC_RUNTIME_LAST_FRAME_TIME_NANOS: Int = 52
    const val DIAGNOSTIC_RUNTIME_LAST_EVENT_HASH: Int = 53
    const val DIAGNOSTIC_RENDER_ATTACHED: Int = 54
    const val DIAGNOSTIC_RENDER_STARTED: Int = 55
    const val DIAGNOSTIC_RENDER_ATTEMPT_COUNT: Int = 56
    const val DIAGNOSTIC_RENDER_POST_COUNT: Int = 57
    const val DIAGNOSTIC_RENDER_FAILURE_COUNT: Int = 58
    const val DIAGNOSTIC_RENDER_STATUS_CODE: Int = 59
    const val DIAGNOSTIC_RENDER_LAST_BUFFER_WIDTH: Int = 60
    const val DIAGNOSTIC_RENDER_LAST_BUFFER_HEIGHT: Int = 61
    const val DIAGNOSTIC_RENDER_LAST_BUFFER_STRIDE: Int = 62
    const val DIAGNOSTIC_RENDER_LAST_BUFFER_FORMAT: Int = 63
    const val DIAGNOSTIC_RENDER_LAST_LOCK_RESULT: Int = 64
    const val DIAGNOSTIC_RENDER_LAST_POST_RESULT: Int = 65

    init {
        System.loadLibrary("c++_shared")
        System.loadLibrary("nucleus-android")
    }

    /**
     * Force this object's static initializer to run, which loads `libc++_shared.so`
     * then `libnucleus-android.so` (whose libSwiftJava dependency the dynamic linker
     * resolves from the same jniLibs directory; the Swift runtime is embedded). Call
     * this before the first [AndroidHost] is constructed so `libc++_shared` is loaded first; `const`
     * references do not trigger the initializer, so an explicit call is needed.
     */
    @JvmStatic
    fun ensureLoaded() {
    }

    /** Verify that the packaged native library matches this Kotlin API. */
    @JvmStatic
    fun smokeValue(): Int = NucleusNative.smokeValue()

    @JvmStatic
    fun describeError(code: Int): String = when (code) {
        ERROR_NONE -> "no error"
        ERROR_INVALID_HANDLE -> "invalid native host handle"
        ERROR_ALLOCATION_FAILED -> "native host allocation failed"
        ERROR_REGISTRY_FAILED -> "native host registry update failed"
        ERROR_SURFACE_NULL -> "surface was null"
        ERROR_SURFACE_ACQUIRE_FAILED -> "ANativeWindow_fromSurface failed"
        ERROR_NO_SURFACE -> "no surface is attached"
        ERROR_NOT_STARTED -> "native host is not started"
        ERROR_CONTEXT_NULL -> "Android context data was null"
        ERROR_ASSET_MANAGER_FAILED -> "AAssetManager_fromJava failed"
        ERROR_ASSET_OPEN_FAILED -> "asset open failed"
        ERROR_ASSET_READ_FAILED -> "asset read failed"
        ERROR_ASSET_PATH_REJECTED -> "asset path was rejected"
        ERROR_RUNTIME_NOT_ATTACHED -> "runtime is not attached"
        ERROR_RENDER_NOT_STARTED -> "renderer is not started"
        else -> "unknown native error $code"
    }
}
