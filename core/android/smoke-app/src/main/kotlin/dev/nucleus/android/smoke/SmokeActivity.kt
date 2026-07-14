package dev.nucleus.android.smoke

import android.app.Activity
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import android.view.KeyEvent
import android.view.MotionEvent
import dev.nucleus.android.Nucleus
import dev.nucleus.android.NucleusHost
import dev.nucleus.android.NucleusView

class SmokeActivity : Activity() {
    private var view: NucleusView? = null
    private var resumed = false
    private val diagnosticsReporter = object : Runnable {
        override fun run() {
            reportDiagnostics("periodic")
            val currentView = view
            if (resumed && currentView != null && !currentView.isClosed()) {
                currentView.postDelayed(this, 1_000)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.i(TAG, "onCreate savedState=${savedInstanceState != null}")
        runHeadlessSmoke()

        val smokeView = NucleusView(this)
        smokeView.setOnTouchListener { target, _ ->
            target.post { reportDiagnostics("touch") }
            false
        }
        smokeView.setOnKeyListener { target, _, _ ->
            target.post { reportDiagnostics("key") }
            false
        }
        view = smokeView
        setContentView(smokeView)
    }

    override fun onResume() {
        super.onResume()
        resumed = true
        Log.i(TAG, "onResume")
        view?.let {
            it.start()
            scheduleDiagnostics(250)
        }
    }

    override fun onPause() {
        Log.i(TAG, "onPause")
        resumed = false
        view?.let {
            it.removeCallbacks(diagnosticsReporter)
            reportDiagnostics("pause-before-stop")
            it.stop()
            reportDiagnostics("pause-after-stop")
        }
        super.onPause()
    }

    override fun onDestroy() {
        Log.i(TAG, "onDestroy finishing=$isFinishing")
        view?.let {
            it.removeCallbacks(diagnosticsReporter)
            reportDiagnostics("destroy-before-close")
            it.close()
            view = null
        }
        super.onDestroy()
    }

    private fun scheduleDiagnostics(delayMillis: Long) {
        val currentView = view
        if (currentView == null || currentView.isClosed()) {
            return
        }
        currentView.removeCallbacks(diagnosticsReporter)
        currentView.postDelayed(diagnosticsReporter, delayMillis)
    }

    private fun runHeadlessSmoke() {
        val combined = Nucleus.smokeValue()
        check(combined == 6404) { "Nucleus smoke value did not match" }

        NucleusHost(this).use { host ->
            val assetSmoke = host.assetSmokeValue("nucleus-smoke.txt")
            check(assetSmoke > 0) { "Nucleus asset smoke value did not match" }
            host.windowAttached()
            host.windowFocusChanged(true)
            host.configurationChanged(1, 1, resources.displayMetrics.density)
            host.imeStateChanged(false)

            val now = SystemClock.uptimeMillis()
            val touch = MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, 2.0f, 3.0f, 0)
            try {
                host.touchEvent(touch)
            } finally {
                touch.recycle()
            }
            host.keyEvent(KeyEvent(now, now, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_A, 0))

            val inputDiagnostics = host.diagnostics()
            check(inputDiagnostics.touchEventCount == 1L && inputDiagnostics.keyEventCount == 1L) {
                "Nucleus input diagnostics did not match"
            }
            check(inputDiagnostics.configurationGeneration != 0L && inputDiagnostics.imeChangeCount != 0L) {
                "Nucleus lifecycle diagnostics did not match"
            }

            val eventSmoke = host.eventQueueSmokeValue()
            check(eventSmoke > 0) { "Nucleus event smoke value did not match" }
            host.runtimeAttach()
            host.runtimeStart()
            host.runtimeFrame(1_000_000L)
            host.runtimeStop()
            val renderSmoke = host.renderSmokeValue()
            check(renderSmoke > 0) { "Nucleus render smoke value did not match" }
            val renderStatus = host.renderStatusCode()
            check(renderStatus == Nucleus.RENDER_STATUS_NO_SURFACE || renderStatus == Nucleus.RENDER_STATUS_POSTED) {
                "Nucleus render status did not match"
            }
            val runtimeSmoke = host.runtimeSmokeValue()
            check(runtimeSmoke > 0) { "Nucleus runtime smoke value did not match" }
            val runtimeVerification = host.runtimeVerificationValue()
            check(runtimeVerification > 0) { "Nucleus runtime verification value did not match" }
            host.runtimeDetach()
            host.start()
            host.stop()

            val diagnostics = host.diagnostics()
            check(
                diagnostics.hostStartCount != 0L &&
                    diagnostics.hostStopCount != 0L &&
                    diagnostics.runtimeAttachCount != 0L &&
                    diagnostics.runtimeDetachCount != 0L,
            ) {
                "Nucleus runtime diagnostics did not match"
            }
            Log.i(TAG, "headless diagnostics $diagnostics")
        }
    }

    private fun reportDiagnostics(marker: String) {
        val currentView = view
        if (currentView == null || currentView.isClosed()) {
            return
        }

        val diagnostics = currentView.diagnostics()
        val statusName = renderStatusName(diagnostics.renderStatusCode)
        title = "Nucleus Smoke: $statusName"
        Log.i(TAG, "$marker renderStatus=$statusName $diagnostics")
    }

    companion object {
        private const val TAG = "NucleusSmoke"

        private fun renderStatusName(status: Int): String = when (status) {
            Nucleus.RENDER_STATUS_NONE -> "none"
            Nucleus.RENDER_STATUS_POSTED -> "posted"
            Nucleus.RENDER_STATUS_NO_SURFACE -> "no-surface"
            Nucleus.RENDER_STATUS_INVALID_SURFACE -> "invalid-surface"
            Nucleus.RENDER_STATUS_LOCK_FAILED -> "lock-failed"
            Nucleus.RENDER_STATUS_POST_FAILED -> "post-failed"
            Nucleus.RENDER_STATUS_UNSUPPORTED_FORMAT -> "unsupported-format"
            else -> "unknown-$status"
        }
    }
}
