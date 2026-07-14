package dev.nucleus.android

import android.content.Context
import android.os.Build
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.Surface
import java.io.File
import org.swift.swiftkit.core.ClosableSwiftArena
import org.swift.swiftkit.core.SwiftArena

/**
 * Lifecycle-owning wrapper over the native host.
 *
 * The host itself is the swift-java-generated [AndroidHost]; its native memory is
 * owned by a confined [SwiftArena] tied to this object and freed in [close] (which
 * runs the Swift `deinit`, releasing any retained ANativeWindow). The NDK-handle
 * entry points (Surface / AssetManager) go through [NucleusNative], which takes the
 * host's swift-java self-pointer. There is no longer a native handle registry.
 */
class NucleusHost() : AutoCloseable {
    private val arena: ClosableSwiftArena
    private val host: AndroidHost
    private var closed = false

    init {
        // Load libc++_shared / libnucleus-android (and, transitively, libSwiftJava)
        // before the first native call. The Swift runtime is embedded in the host.
        Nucleus.ensureLoaded()
        arena = SwiftArena.ofConfined()
        host = AndroidHost.init(arena)
    }

    constructor(context: Context) : this() {
        configure(context)
    }

    /** The swift-java self-pointer the hand-written NDK-handle thunks reconstruct from. */
    private val selfPointer: Long
        get() = host.`$memoryAddress`()

    fun isClosed(): Boolean = closed

    fun start() {
        checkOpen()
        requireNative(host.start(), "native host start")
    }

    fun stop() {
        checkOpen()
        requireNative(host.stop(), "native host stop")
    }

    fun windowAttached() {
        checkOpen()
        requireNative(host.windowAttached(), "native window attach")
    }

    fun windowDetached() {
        checkOpen()
        requireNative(host.windowDetached(), "native window detach")
    }

    fun windowFocusChanged(hasFocus: Boolean) {
        checkOpen()
        requireNative(host.windowFocusChanged(hasFocus), "native window focus")
    }

    fun configure(context: Context) {
        checkOpen()
        val appContext = context.applicationContext ?: context
        val density = context.resources.displayMetrics.density
        requireNative(
            NucleusNative.configureHost(
                selfPointer,
                appContext.assets,
                pathOrEmpty(appContext.filesDir),
                pathOrEmpty(appContext.cacheDir),
                appContext.packageName,
                density,
                Build.VERSION.SDK_INT,
            ),
            "native host configure",
        )
    }

    fun configurationChanged(width: Int, height: Int, density: Float) {
        checkOpen()
        requireNative(host.configurationChanged(width, height, density), "native configuration change")
    }

    fun surfaceCreated(surface: Surface) {
        checkOpen()
        requireNative(NucleusNative.surfaceCreated(selfPointer, surface), "native surface attach")
    }

    fun surfaceChanged(format: Int, width: Int, height: Int) {
        checkOpen()
        requireNative(NucleusNative.surfaceChanged(selfPointer, format, width, height), "native surface change")
    }

    fun surfaceDestroyed() {
        checkOpen()
        requireNative(NucleusNative.surfaceDestroyed(selfPointer), "native surface detach")
    }

    fun frame(frameTimeNanos: Long) {
        checkOpen()
        requireNative(host.frame(frameTimeNanos), "native frame")
    }

    fun touchEvent(event: MotionEvent) {
        checkOpen()
        val pointerCount = event.pointerCount
        var pointerIndex = event.actionIndex
        if (pointerIndex < 0 || pointerIndex >= pointerCount) {
            pointerIndex = 0
        }
        requireNative(
            host.touchEvent(
                event.actionMasked,
                event.getPointerId(pointerIndex),
                pointerCount,
                event.getX(pointerIndex),
                event.getY(pointerIndex),
                event.getPressure(pointerIndex),
                event.eventTime * 1_000_000L,
            ),
            "native touch event",
        )
    }

    fun keyEvent(event: KeyEvent) {
        checkOpen()
        requireNative(
            host.keyEvent(
                event.action,
                event.keyCode,
                event.repeatCount,
                event.metaState,
                event.eventTime * 1_000_000L,
            ),
            "native key event",
        )
    }

    fun imeStateChanged(active: Boolean) {
        checkOpen()
        requireNative(host.imeStateChanged(active), "native IME state")
    }

    fun assetSmokeValue(assetPath: String): Int {
        checkOpen()
        val value = host.assetSmokeValue(assetPath)
        if (value < 0) {
            throw NucleusException("native asset smoke", host.lastErrorCode())
        }
        return value
    }

    fun eventQueueSmokeValue(): Int {
        checkOpen()
        val value = host.eventQueueSmokeValue()
        if (value < 0) {
            throw NucleusException("native event queue smoke", host.lastErrorCode())
        }
        return value
    }

    fun runtimeAttach() {
        checkOpen()
        requireNative(host.runtimeAttach(), "native runtime attach")
    }

    fun runtimeStart() {
        checkOpen()
        requireNative(host.runtimeStart(), "native runtime start")
    }

    fun runtimeFrame(frameTimeNanos: Long) {
        checkOpen()
        requireNative(host.runtimeFrame(frameTimeNanos), "native runtime frame")
    }

    fun runtimeStop() {
        checkOpen()
        requireNative(host.runtimeStop(), "native runtime stop")
    }

    fun runtimeDetach() {
        checkOpen()
        requireNative(host.runtimeDetach(), "native runtime detach")
    }

    fun runtimeSmokeValue(): Int {
        checkOpen()
        val value = host.runtimeSmokeValue()
        if (value < 0) {
            throw NucleusException("native runtime smoke", host.lastErrorCode())
        }
        return value
    }

    fun runtimeVerificationValue(): Int {
        checkOpen()
        val value = host.runtimeVerificationValue()
        if (value < 0) {
            throw NucleusException("native runtime verification", host.lastErrorCode())
        }
        return value
    }

    fun renderSmokeValue(): Int {
        checkOpen()
        val value = host.renderSmokeValue()
        if (value < 0) {
            throw NucleusException("native render smoke", host.lastErrorCode())
        }
        return value
    }

    fun renderStatusCode(): Int {
        checkOpen()
        val value = host.renderStatusCode()
        if (value < 0) {
            throw NucleusException("native render status", host.lastErrorCode())
        }
        return value
    }

    fun diagnostics(): Diagnostics {
        checkOpen()
        return Diagnostics.from(this)
    }

    override fun close() {
        if (closed) return
        closed = true
        // Closing the arena runs the Swift deinit, which releases any retained
        // ANativeWindow and frees the host core.
        arena.close()
    }

    private fun checkOpen() {
        check(!closed) { "NucleusHost is closed" }
    }

    private fun requireNative(ok: Boolean, operation: String) {
        if (!ok) {
            throw NucleusException(operation, host.lastErrorCode())
        }
    }

    private fun diagnosticValue(code: Int): Long {
        checkOpen()
        return host.diagnosticValue(code)
    }

    private fun diagnosticBoolean(code: Int): Boolean = diagnosticValue(code) != 0L

    private fun diagnosticInt(code: Int): Int = diagnosticValue(code).toInt()

    private fun pathOrEmpty(dir: File?): String = dir?.absolutePath ?: ""

    class Diagnostics private constructor(host: NucleusHost) {
        @JvmField val platformConfigured: Boolean = host.diagnosticBoolean(Nucleus.DIAGNOSTIC_PLATFORM_CONFIGURED)
        @JvmField val hostStarted: Boolean = host.diagnosticBoolean(Nucleus.DIAGNOSTIC_HOST_STARTED)
        @JvmField val windowAttached: Boolean = host.diagnosticBoolean(Nucleus.DIAGNOSTIC_WINDOW_ATTACHED)
        @JvmField val windowFocused: Boolean = host.diagnosticBoolean(Nucleus.DIAGNOSTIC_WINDOW_FOCUSED)
        @JvmField val surfaceAttached: Boolean = host.diagnosticBoolean(Nucleus.DIAGNOSTIC_SURFACE_ATTACHED)
        @JvmField val surfaceWidth: Int = host.diagnosticInt(Nucleus.DIAGNOSTIC_SURFACE_WIDTH)
        @JvmField val surfaceHeight: Int = host.diagnosticInt(Nucleus.DIAGNOSTIC_SURFACE_HEIGHT)
        @JvmField val surfaceFormat: Int = host.diagnosticInt(Nucleus.DIAGNOSTIC_SURFACE_FORMAT)
        @JvmField val surfaceGeneration: Long = host.diagnosticValue(Nucleus.DIAGNOSTIC_SURFACE_GENERATION)
        @JvmField val hostFrameCount: Long = host.diagnosticValue(Nucleus.DIAGNOSTIC_HOST_FRAME_COUNT)
        @JvmField val hostLastFrameTimeNanos: Long = host.diagnosticValue(Nucleus.DIAGNOSTIC_HOST_LAST_FRAME_TIME_NANOS)
        @JvmField val viewWidth: Int = host.diagnosticInt(Nucleus.DIAGNOSTIC_VIEW_WIDTH)
        @JvmField val viewHeight: Int = host.diagnosticInt(Nucleus.DIAGNOSTIC_VIEW_HEIGHT)
        @JvmField val densityMilli: Int = host.diagnosticInt(Nucleus.DIAGNOSTIC_DENSITY_MILLI)
        @JvmField val configurationGeneration: Long = host.diagnosticValue(Nucleus.DIAGNOSTIC_CONFIGURATION_GENERATION)
        @JvmField val touchEventCount: Long = host.diagnosticValue(Nucleus.DIAGNOSTIC_TOUCH_EVENT_COUNT)
        @JvmField val lastTouchAction: Int = host.diagnosticInt(Nucleus.DIAGNOSTIC_LAST_TOUCH_ACTION)
        @JvmField val lastTouchPointerId: Int = host.diagnosticInt(Nucleus.DIAGNOSTIC_LAST_TOUCH_POINTER_ID)
        @JvmField val lastTouchPointerCount: Int = host.diagnosticInt(Nucleus.DIAGNOSTIC_LAST_TOUCH_POINTER_COUNT)
        @JvmField val lastTouchXMilli: Int = host.diagnosticInt(Nucleus.DIAGNOSTIC_LAST_TOUCH_X_MILLI)
        @JvmField val lastTouchYMilli: Int = host.diagnosticInt(Nucleus.DIAGNOSTIC_LAST_TOUCH_Y_MILLI)
        @JvmField val lastTouchPressureMilli: Int = host.diagnosticInt(Nucleus.DIAGNOSTIC_LAST_TOUCH_PRESSURE_MILLI)
        @JvmField val lastTouchTimeNanos: Long = host.diagnosticValue(Nucleus.DIAGNOSTIC_LAST_TOUCH_TIME_NANOS)
        @JvmField val keyEventCount: Long = host.diagnosticValue(Nucleus.DIAGNOSTIC_KEY_EVENT_COUNT)
        @JvmField val lastKeyAction: Int = host.diagnosticInt(Nucleus.DIAGNOSTIC_LAST_KEY_ACTION)
        @JvmField val lastKeyCode: Int = host.diagnosticInt(Nucleus.DIAGNOSTIC_LAST_KEY_CODE)
        @JvmField val lastKeyRepeatCount: Int = host.diagnosticInt(Nucleus.DIAGNOSTIC_LAST_KEY_REPEAT_COUNT)
        @JvmField val lastKeyMetaState: Int = host.diagnosticInt(Nucleus.DIAGNOSTIC_LAST_KEY_META_STATE)
        @JvmField val lastKeyTimeNanos: Long = host.diagnosticValue(Nucleus.DIAGNOSTIC_LAST_KEY_TIME_NANOS)
        @JvmField val imeActive: Boolean = host.diagnosticBoolean(Nucleus.DIAGNOSTIC_IME_ACTIVE)
        @JvmField val queuedEventCount: Int = host.diagnosticInt(Nucleus.DIAGNOSTIC_QUEUED_EVENT_COUNT)
        @JvmField val droppedEventCount: Long = host.diagnosticValue(Nucleus.DIAGNOSTIC_DROPPED_EVENT_COUNT)
        @JvmField val hostStartCount: Long = host.diagnosticValue(Nucleus.DIAGNOSTIC_HOST_START_COUNT)
        @JvmField val hostStopCount: Long = host.diagnosticValue(Nucleus.DIAGNOSTIC_HOST_STOP_COUNT)
        @JvmField val windowAttachCount: Long = host.diagnosticValue(Nucleus.DIAGNOSTIC_WINDOW_ATTACH_COUNT)
        @JvmField val windowDetachCount: Long = host.diagnosticValue(Nucleus.DIAGNOSTIC_WINDOW_DETACH_COUNT)
        @JvmField val windowFocusCount: Long = host.diagnosticValue(Nucleus.DIAGNOSTIC_WINDOW_FOCUS_COUNT)
        @JvmField val surfaceAttachCount: Long = host.diagnosticValue(Nucleus.DIAGNOSTIC_SURFACE_ATTACH_COUNT)
        @JvmField val surfaceChangeCount: Long = host.diagnosticValue(Nucleus.DIAGNOSTIC_SURFACE_CHANGE_COUNT)
        @JvmField val surfaceDetachCount: Long = host.diagnosticValue(Nucleus.DIAGNOSTIC_SURFACE_DETACH_COUNT)
        @JvmField val imeChangeCount: Long = host.diagnosticValue(Nucleus.DIAGNOSTIC_IME_CHANGE_COUNT)
        @JvmField val assetSmokeValue: Int = host.diagnosticInt(Nucleus.DIAGNOSTIC_ASSET_SMOKE_VALUE)
        @JvmField val assetSmokeCount: Long = host.diagnosticValue(Nucleus.DIAGNOSTIC_ASSET_SMOKE_COUNT)
        @JvmField val runtimeAttached: Boolean = host.diagnosticBoolean(Nucleus.DIAGNOSTIC_RUNTIME_ATTACHED)
        @JvmField val runtimeStarted: Boolean = host.diagnosticBoolean(Nucleus.DIAGNOSTIC_RUNTIME_STARTED)
        @JvmField val runtimeAttachCount: Long = host.diagnosticValue(Nucleus.DIAGNOSTIC_RUNTIME_ATTACH_COUNT)
        @JvmField val runtimeStartCount: Long = host.diagnosticValue(Nucleus.DIAGNOSTIC_RUNTIME_START_COUNT)
        @JvmField val runtimeFrameCount: Long = host.diagnosticValue(Nucleus.DIAGNOSTIC_RUNTIME_FRAME_COUNT)
        @JvmField val runtimeDrainedEventCount: Long = host.diagnosticValue(Nucleus.DIAGNOSTIC_RUNTIME_DRAINED_EVENT_COUNT)
        @JvmField val runtimeStopCount: Long = host.diagnosticValue(Nucleus.DIAGNOSTIC_RUNTIME_STOP_COUNT)
        @JvmField val runtimeDetachCount: Long = host.diagnosticValue(Nucleus.DIAGNOSTIC_RUNTIME_DETACH_COUNT)
        @JvmField val runtimeLastFrameTimeNanos: Long = host.diagnosticValue(Nucleus.DIAGNOSTIC_RUNTIME_LAST_FRAME_TIME_NANOS)
        @JvmField val runtimeLastEventHash: Int = host.diagnosticInt(Nucleus.DIAGNOSTIC_RUNTIME_LAST_EVENT_HASH)
        @JvmField val renderAttached: Boolean = host.diagnosticBoolean(Nucleus.DIAGNOSTIC_RENDER_ATTACHED)
        @JvmField val renderStarted: Boolean = host.diagnosticBoolean(Nucleus.DIAGNOSTIC_RENDER_STARTED)
        @JvmField val renderAttemptCount: Long = host.diagnosticValue(Nucleus.DIAGNOSTIC_RENDER_ATTEMPT_COUNT)
        @JvmField val renderPostCount: Long = host.diagnosticValue(Nucleus.DIAGNOSTIC_RENDER_POST_COUNT)
        @JvmField val renderFailureCount: Long = host.diagnosticValue(Nucleus.DIAGNOSTIC_RENDER_FAILURE_COUNT)
        @JvmField val renderStatusCode: Int = host.diagnosticInt(Nucleus.DIAGNOSTIC_RENDER_STATUS_CODE)
        @JvmField val renderLastBufferWidth: Int = host.diagnosticInt(Nucleus.DIAGNOSTIC_RENDER_LAST_BUFFER_WIDTH)
        @JvmField val renderLastBufferHeight: Int = host.diagnosticInt(Nucleus.DIAGNOSTIC_RENDER_LAST_BUFFER_HEIGHT)
        @JvmField val renderLastBufferStride: Int = host.diagnosticInt(Nucleus.DIAGNOSTIC_RENDER_LAST_BUFFER_STRIDE)
        @JvmField val renderLastBufferFormat: Int = host.diagnosticInt(Nucleus.DIAGNOSTIC_RENDER_LAST_BUFFER_FORMAT)
        @JvmField val renderLastLockResult: Int = host.diagnosticInt(Nucleus.DIAGNOSTIC_RENDER_LAST_LOCK_RESULT)
        @JvmField val renderLastPostResult: Int = host.diagnosticInt(Nucleus.DIAGNOSTIC_RENDER_LAST_POST_RESULT)

        fun density(): Float = densityMilli / 1000.0f

        override fun toString(): String =
            "host{configured=$platformConfigured" +
                ",started=$hostStarted" +
                ",starts=$hostStartCount" +
                ",stops=$hostStopCount" +
                ",frames=$hostFrameCount" +
                "} window{attached=$windowAttached" +
                ",focus=$windowFocused" +
                ",attach=$windowAttachCount" +
                ",detach=$windowDetachCount" +
                ",focusChanges=$windowFocusCount" +
                "} surface{attached=$surfaceAttached" +
                ",size=${surfaceWidth}x$surfaceHeight" +
                ",format=$surfaceFormat" +
                ",generation=$surfaceGeneration" +
                ",attach=$surfaceAttachCount" +
                ",change=$surfaceChangeCount" +
                ",detach=$surfaceDetachCount" +
                "} config{view=${viewWidth}x$viewHeight" +
                ",density=${density()}" +
                ",generation=$configurationGeneration" +
                "} input{touches=$touchEventCount" +
                ",lastTouch=$lastTouchAction/$lastTouchPointerId" +
                "@$lastTouchXMilli,$lastTouchYMilli" +
                ",keys=$keyEventCount" +
                ",lastKey=$lastKeyAction/$lastKeyCode" +
                ",ime=$imeActive" +
                "} events{queued=$queuedEventCount" +
                ",dropped=$droppedEventCount" +
                "} runtime{attached=$runtimeAttached" +
                ",started=$runtimeStarted" +
                ",attach=$runtimeAttachCount" +
                ",start=$runtimeStartCount" +
                ",frames=$runtimeFrameCount" +
                ",drained=$runtimeDrainedEventCount" +
                ",stop=$runtimeStopCount" +
                ",detach=$runtimeDetachCount" +
                "} render{attached=$renderAttached" +
                ",started=$renderStarted" +
                ",status=$renderStatusCode" +
                ",attempts=$renderAttemptCount" +
                ",posted=$renderPostCount" +
                ",failures=$renderFailureCount" +
                ",buffer=${renderLastBufferWidth}x$renderLastBufferHeight" +
                "/$renderLastBufferStride" +
                ",format=$renderLastBufferFormat" +
                ",lock=$renderLastLockResult" +
                ",post=$renderLastPostResult" +
                "}"

        companion object {
            internal fun from(host: NucleusHost): Diagnostics = Diagnostics(host)
        }
    }
}
