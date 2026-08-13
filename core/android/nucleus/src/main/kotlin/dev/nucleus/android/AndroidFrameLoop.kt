package dev.nucleus.android

import android.view.Choreographer
import java.util.IdentityHashMap

internal fun interface AndroidFrameCallback {
    fun doFrame(frameTimeNanos: Long)
}

internal interface AndroidFrameScheduler {
    fun post(callback: AndroidFrameCallback)

    fun remove(callback: AndroidFrameCallback)
}

internal class ChoreographerFrameScheduler(
    private val choreographer: Choreographer,
) : AndroidFrameScheduler {
    private val frameworkCallbacks =
        IdentityHashMap<AndroidFrameCallback, Choreographer.FrameCallback>()

    override fun post(callback: AndroidFrameCallback) {
        check(frameworkCallbacks[callback] == null) { "frame callback already posted" }
        val frameworkCallback =
            Choreographer.FrameCallback { frameTimeNanos ->
                frameworkCallbacks.remove(callback)
                callback.doFrame(frameTimeNanos)
            }
        frameworkCallbacks[callback] = frameworkCallback
        choreographer.postFrameCallback(frameworkCallback)
    }

    override fun remove(callback: AndroidFrameCallback) {
        val frameworkCallback = frameworkCallbacks.remove(callback) ?: return
        choreographer.removeFrameCallback(frameworkCallback)
    }
}

/**
 * Owns the one framework callback used by an Android presentation surface.
 *
 * Eligibility is the conjunction of host start, a live surface, and runtime
 * start. Repeated lifecycle notifications cannot post duplicates. Losing
 * eligibility removes the callback before native runtime or surface teardown.
 */
internal class AndroidFrameLoop(
    private val scheduler: AndroidFrameScheduler,
    private val deliver: (Long) -> Unit,
) {
    private var eligible = false
    private var posted = false
    private val callback = AndroidFrameCallback(::onFrame)

    fun setEligible(eligible: Boolean) {
        this.eligible = eligible
        if (eligible) {
            postIfNeeded()
        } else {
            removeIfPosted()
        }
    }

    private fun onFrame(frameTimeNanos: Long) {
        if (!posted) {
            return
        }
        posted = false
        if (!eligible) {
            return
        }
        deliver(frameTimeNanos)
        postIfNeeded()
    }

    private fun postIfNeeded() {
        if (!eligible || posted) {
            return
        }
        posted = true
        scheduler.post(callback)
    }

    private fun removeIfPosted() {
        if (!posted) {
            return
        }
        posted = false
        scheduler.remove(callback)
    }
}
