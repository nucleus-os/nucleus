import NucleusCompositorServer
import NucleusCompositorShell
import NucleusCompositorOverlayScene
import NucleusCompositorRenderRuntime
import Tracy
import Glibc

/// Per-output frame-demand orchestration — the Swift owner of frame demand.
///
/// It drives each output's Swift-owned `DisplayLink` directly (no `display_link_*`
/// crossing) and reads "why another frame is needed" from the Swift shell /
/// overlay / render owners and the render active-animations fact.
/// Reached Swift-direct from the compositor loop.
@MainActor
final class DisplayFrameDemand {
    private unowned let server: NucleusCompositorServer
    private unowned let renderRuntime: RenderRuntime
    private unowned let shellServices: ShellServices

    init(
        server: NucleusCompositorServer,
        renderRuntime: RenderRuntime,
        shellServices: ShellServices
    ) {
        self.server = server
        self.renderRuntime = renderRuntime
        self.shellServices = shellServices
    }

    /// Mark a one-shot frame need on every output.
    func requestFrame(reason: RedrawReasons = .surfaceDamage) {
        for display in server.layout.displays {
            display.requestRedraw(reason)
        }
    }

    /// Mark a one-shot frame need on `outputID`; falls back to every output when
    /// the id is not a known output.
    func requestFrame(
        outputID: UInt64,
        reason: RedrawReasons = .surfaceDamage
    ) {
        if let display = server.layout.display(id: outputID) {
            display.requestRedraw(reason)
        } else {
            requestFrame(reason: reason)
        }
    }

    func requestFrameForOverlay() {
        requestFrame(outputID: overlayOutputID(), reason: .shellOverlay)
    }

    /// Collect the current frame-demand policy from the shell/overlay/render
    /// owners and apply it across the outputs' `DisplayLink`s.
    func sync() {
        let layout = server.layout
        guard !layout.displays.isEmpty else { return }
        let overlayID = overlayOutputID()

        // Collect. The `||` short-circuits, so a satisfied
        // bezel latch leaves the notification latch unconsumed (and vice-versa).
        let overlayFrameRequested = shellServices.bezel.takeFrameRequest()
            || shellServices.notifications.takeFrameRequest()
        let notificationDeadlineNs =
            shellServices.overlayScene.notificationDeadlineNs()
        let notificationAnimationActive =
            shellServices.bezel.hasActiveNotifications()
        let overlayRenderAnimationActive = renderRuntime.hasActiveAnimations

        // Apply.
        if overlayFrameRequested { requestFrameForOverlay() }
        if notificationDeadlineNs != 0,
            let display = layout.display(id: overlayID)
        {
            display.displayLink.requestFrameDeadline(notificationDeadlineNs)
            display.requestRedraw(.shellOverlay)
        }
        for display in layout.displays {
            let isOverlay = display.id == overlayID
            display.displayLink.continuous = DisplayLink.ContinuousDemand(
                animation: isOverlay && overlayRenderAnimationActive,
                notification: isOverlay && notificationAnimationActive,
                screenshot: false,
                background: false)
            if isOverlay && (
                overlayRenderAnimationActive || notificationAnimationActive)
            {
                display.requestRedraw(.animation)
            }
            emitTimelinePlots(display)
        }
    }

    func willSubmit(_ display: Display) {
        let range = frameRangeName(display)
        if display.displayLink.submittedFrameOpen {
            Trace.frameMarkEnd(range)
            Trace.message("frame superseded: \(display.displayLink.outputTag)", color: Trace.Color.yellow)
        }
        Trace.frameMarkStart(range)
    }

    func didSubmit(_ display: Display) {
        emitTimelinePlots(display)
    }

    func didPresent(
        _ display: Display, presentationNs: UInt64, predictedPresentNs: UInt64
    ) {
        Trace.frameMarkEnd(frameRangeName(display))
        let errorNs = Int64(bitPattern: presentationNs) - Int64(bitPattern: predictedPresentNs)
        Trace.plot(plotName(display, "predict_err_ms"), Double(errorNs) / 1_000_000.0)
        if errorNs > Int64(clamping: display.displayLink.refreshIntervalNs) {
            Trace.message("missed vblank: \(display.displayLink.outputTag)", color: Trace.Color.red)
        }
        emitTimelinePlots(display)
    }

    private func emitTimelinePlots(_ display: Display) {
        let link = display.displayLink
        let sample = link.sampleTimeline()
        let redraw = display.sampleRedrawMetrics()
        let now = monotonicNowNs()
        let remaining = Int64(bitPattern: sample.deadlineNs) - Int64(bitPattern: now)
        Trace.plot(plotName(display, "budget_remaining_ms"), Double(remaining) / 1_000_000.0)
        Trace.plot(
            plotName(display, "present_id_outstanding"),
            sample.lastPresentID >= link.lastAckedPresentID
                ? sample.lastPresentID - link.lastAckedPresentID : 0)
        Trace.plot(
            plotName(display, "refresh_interval_ms"),
            Double(sample.refreshIntervalNs) / 1_000_000.0)
        Trace.plot(
            plotName(display, "redraw_requests"),
            redraw.redrawRequests)
        Trace.plot(
            plotName(display, "redraw_coalesced"),
            redraw.coalescedRequests)
        Trace.plot(
            plotName(display, "scene_author_passes"),
            redraw.sceneAuthorPasses)
        Trace.plot(
            plotName(display, "render_without_submission"),
            redraw.renderPassesWithoutSubmission)
        for (index, count) in
            redraw.coalescedByReason.enumerated()
        {
            Trace.plot(
                plotName(
                    display,
                    "coalesced_reason_\(index)"),
                count)
        }
        for (index, residenceNs) in
            redraw.stateResidenceNs.enumerated()
        {
            Trace.plot(
                plotName(
                    display,
                    "state_\(index)_seconds"),
                Double(residenceNs)
                    / 1_000_000_000.0)
        }
    }

    private func plotName(_ display: Display, _ metric: String) -> String {
        "swift.frame.\(display.displayLink.outputTag).\(metric)"
    }

    private func frameRangeName(_ display: Display) -> String {
        "swift.frame.\(display.displayLink.outputTag)"
    }

    private func monotonicNowNs() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
    }

    private func overlayOutputID() -> UInt64 {
        server.spaces.overlayDisplayID(layout: server.layout)
    }
}
