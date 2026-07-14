package dev.nucleus.android

import android.content.Context
import android.content.res.Configuration
import android.util.AttributeSet
import android.view.Choreographer
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.SurfaceView

class NucleusView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0,
) : SurfaceView(context, attrs, defStyleAttr),
    SurfaceHolder.Callback,
    AutoCloseable {
    private val host = NucleusHost(context)
    private val choreographer = Choreographer.getInstance()
    private val frameCallback = Choreographer.FrameCallback { frameTimeNanos -> doFrame(frameTimeNanos) }

    private var closed = false
    private var started = false
    private var windowAttached = false
    private var surfaceAttached = false
    private var runtimeAttached = false
    private var runtimeStarted = false
    private var frameCallbackPosted = false

    init {
        holder.addCallback(this)
        isFocusable = true
        isFocusableInTouchMode = true
    }

    fun host(): NucleusHost = host

    fun isClosed(): Boolean = closed

    fun isStarted(): Boolean = started

    fun isSurfaceAttached(): Boolean = surfaceAttached

    fun isRuntimeStarted(): Boolean = runtimeStarted

    fun diagnostics(): NucleusHost.Diagnostics {
        checkOpen()
        return host.diagnostics()
    }

    fun start() {
        checkOpen()
        if (started) {
            return
        }
        requestFocus()
        host.start()
        started = true
        maybeStartRuntime()
        maybePostFrameCallback()
    }

    fun stop() {
        if (closed || !started) {
            return
        }
        removeFrameCallback()
        stopRuntime()
        started = false
        host.stop()
    }

    fun setImeActive(active: Boolean) {
        checkOpen()
        host.imeStateChanged(active)
    }

    override fun close() {
        if (closed) {
            return
        }
        removeFrameCallback()
        stopRuntime()
        if (surfaceAttached) {
            surfaceAttached = false
            host.surfaceDestroyed()
        }
        if (started) {
            started = false
            host.stop()
        }
        if (windowAttached) {
            windowAttached = false
            host.windowDetached()
        }
        closed = true
        holder.removeCallback(this)
        host.close()
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        if (closed) {
            return
        }
        windowAttached = true
        host.windowAttached()
        notifyConfiguration()
        maybePostFrameCallback()
    }

    override fun onDetachedFromWindow() {
        if (!closed && windowAttached) {
            removeFrameCallback()
            windowAttached = false
            host.windowDetached()
        }
        super.onDetachedFromWindow()
    }

    override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
        super.onWindowFocusChanged(hasWindowFocus)
        if (!closed) {
            host.windowFocusChanged(hasWindowFocus)
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (!closed) {
            notifyConfiguration()
        }
    }

    override fun onSizeChanged(width: Int, height: Int, oldWidth: Int, oldHeight: Int) {
        super.onSizeChanged(width, height, oldWidth, oldHeight)
        if (!closed) {
            notifyConfiguration()
        }
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        checkOpen()
        if (surfaceAttached) {
            host.surfaceDestroyed()
            surfaceAttached = false
        }
        host.surfaceCreated(holder.surface)
        surfaceAttached = true
        maybeStartRuntime()
        maybePostFrameCallback()
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        checkOpen()
        if (surfaceAttached) {
            host.surfaceChanged(format, width, height)
            host.configurationChanged(width, height, resources.displayMetrics.density)
        }
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        if (closed || !surfaceAttached) {
            return
        }
        removeFrameCallback()
        stopRuntime()
        surfaceAttached = false
        host.surfaceDestroyed()
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        checkOpen()
        requestFocus()
        host.touchEvent(event)
        return true
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        checkOpen()
        host.keyEvent(event)
        return true
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean {
        checkOpen()
        host.keyEvent(event)
        return true
    }

    private fun doFrame(frameTimeNanos: Long) {
        frameCallbackPosted = false
        if (closed || !started || !surfaceAttached) {
            return
        }
        host.frame(frameTimeNanos)
        host.runtimeFrame(frameTimeNanos)
        maybePostFrameCallback()
    }

    private fun maybePostFrameCallback() {
        if (closed || !started || !surfaceAttached || !runtimeStarted || frameCallbackPosted) {
            return
        }
        frameCallbackPosted = true
        choreographer.postFrameCallback(frameCallback)
    }

    private fun removeFrameCallback() {
        if (!frameCallbackPosted) {
            return
        }
        choreographer.removeFrameCallback(frameCallback)
        frameCallbackPosted = false
    }

    private fun maybeStartRuntime() {
        if (closed || !started || !surfaceAttached || runtimeStarted) {
            return
        }
        if (!runtimeAttached) {
            host.runtimeAttach()
            runtimeAttached = true
        }
        host.runtimeStart()
        runtimeStarted = true
    }

    private fun stopRuntime() {
        if (runtimeStarted) {
            runtimeStarted = false
            host.runtimeStop()
        }
        if (runtimeAttached) {
            runtimeAttached = false
            host.runtimeDetach()
        }
    }

    private fun notifyConfiguration() {
        host.configurationChanged(width, height, resources.displayMetrics.density)
    }

    private fun checkOpen() {
        check(!closed) { "NucleusView is closed" }
    }
}
