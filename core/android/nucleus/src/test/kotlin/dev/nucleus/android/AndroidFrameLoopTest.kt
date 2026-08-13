package dev.nucleus.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidFrameLoopTest {
    @Test
    fun repeatedEligibilityPostsOneCallback() {
        val scheduler = RecordingFrameScheduler()
        val loop = AndroidFrameLoop(scheduler) {}

        loop.setEligible(true)
        loop.setEligible(true)

        assertEquals(1, scheduler.postCount)
        assertEquals(1, scheduler.callbacks.size)
    }

    @Test
    fun eachFrameDeliversAndRearmsOnce() {
        val scheduler = RecordingFrameScheduler()
        val delivered = mutableListOf<Long>()
        val loop = AndroidFrameLoop(scheduler, delivered::add)
        loop.setEligible(true)

        scheduler.fire(123L)

        assertEquals(listOf(123L), delivered)
        assertEquals(2, scheduler.postCount)
        assertEquals(1, scheduler.callbacks.size)
    }

    @Test
    fun stopRemovesTheRetainedCallback() {
        val scheduler = RecordingFrameScheduler()
        var delivered = false
        val loop = AndroidFrameLoop(scheduler) { delivered = true }
        loop.setEligible(true)

        loop.setEligible(false)

        assertEquals(1, scheduler.removeCount)
        assertTrue(scheduler.callbacks.isEmpty())
        assertFalse(delivered)
    }

    @Test
    fun surfaceReplacementDoesNotDuplicateTheCallback() {
        val scheduler = RecordingFrameScheduler()
        val loop = AndroidFrameLoop(scheduler) {}
        loop.setEligible(true)

        loop.setEligible(false)
        loop.setEligible(true)
        loop.setEligible(true)

        assertEquals(2, scheduler.postCount)
        assertEquals(1, scheduler.removeCount)
        assertEquals(1, scheduler.callbacks.size)
    }
}

private class RecordingFrameScheduler : AndroidFrameScheduler {
    val callbacks = mutableListOf<AndroidFrameCallback>()
    var postCount = 0
    var removeCount = 0

    override fun post(callback: AndroidFrameCallback) {
        postCount += 1
        callbacks += callback
    }

    override fun remove(callback: AndroidFrameCallback) {
        removeCount += 1
        callbacks.removeAll { it === callback }
    }

    fun fire(frameTimeNanos: Long) {
        val callback = callbacks.removeAt(0)
        callback.doFrame(frameTimeNanos)
    }
}
