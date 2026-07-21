// Drives the authoritative Swift window model for router-attached Xwayland windows.
// The Xwayland analog of RouterWindowDriver: where that adapts xdg-shell events,
// this turns the in-process Swift XWM's lifecycle pushes (XwaylandXWM calls these
// methods directly) into NucleusCompositorServer / WindowManager operations on a Swift
// `Window` with source `.xwayland`.
//
// A paired X window is created bound to its router `WlSurface` (by surface object
// id, resolved XWM-side from the xwayland_shell_v1 serial), and the SceneFeeder
// authors it exactly like an xdg toplevel — the shared SurfaceSceneDelegate content
// path (RouterWindowDriver.surfaceCommitted) authors any window bound by
// surfaceObjectId, so an xwayland surface's buffer commits flow through with no
// xwayland-specific handling. Metadata (title / class / EWMH state) is applied
// through the existing window-id-keyed model APIs from the XWM sink directly; this
// driver owns creation, geometry, map/unmap, and teardown — the parts that bind the
// surface and author the scene.
//
// Isolation: the XWM calls the crossings from the compositor loop (the main actor);
// reactor callbacks assume isolation and call these @MainActor methods. Only
// Sendable scalars cross.

import WaylandServerC
import NucleusCompositorXcbC
@_spi(NucleusCompositor) import NucleusLayers
import NucleusCompositorServer
import NucleusCompositorWindowManager

@MainActor
final class RouterXwaylandDriver {
    private let seatDriver: RouterSeatDriver
    private let compositor: WlCompositor
    private let feeder: SceneFeeder?

    /// model window id → X11 window id, for the reverse configure crossing.
    private var x11ByWindow: [UInt64: UInt64] = [:]

    init(seatDriver: RouterSeatDriver, compositor: WlCompositor, feeder: SceneFeeder? = nil) {
        self.seatDriver = seatDriver
        self.compositor = compositor
        self.feeder = feeder
    }

    /// Create the model window for a freshly-paired X11 window, bound to its router
    /// surface (`surfaceObjectId`). Returns the model window id (0 on failure). The
    /// window starts unmapped at the X-requested geometry; `setMapped` authors the
    /// scene and takes focus once the XWM maps it.
    func createWindow(
        surfaceObjectId: UInt32, x11WindowID: UInt64, overrideRedirect: Bool,
        x: Int32, y: Int32, w: UInt32, h: UInt32
    ) -> UInt64 {
        guard surfaceObjectId != 0 else { return 0 }
        let wm = WindowManager.shared
        let windowID = wm.xwaylandCreated(
            x11WindowID: x11WindowID, overrideRedirect: overrideRedirect, wantsKeyboardFocus: true)
        guard let window = wm.server.window(id: windowID) else { return 0 }
        window.surfaceObjectId = surfaceObjectId
        // Override-redirect windows (menus, tooltips, DnD) keep client-owned placement
        // and carry no compositor chrome; managed toplevels are server-side decorated.
        window.styleMask = overrideRedirect ? .borderless : .titledResizable
        let cw = UInt32(max(1, w))
        let ch = UInt32(max(1, h))
        window.committedLogicalSize = RenderSize(w: Double(cw), h: Double(ch))
        let insets = window.chromeInsets
        let fw = UInt32(max(1, Double(cw) + insets.horizontal))
        let fh = UInt32(max(1, Double(ch) + insets.vertical))
        window.setGeometry(WindowRect(x: Double(x), y: Double(y), width: fw, height: fh))
        window.seedPresentationActorToRect(
            PresentationRect(x: Double(x), y: Double(y), w: Double(fw), h: Double(fh)),
            slotGeneration: window.presentationActor.currentSlotGeneration)
        assignOutput(
            window,
            centerX: Double(x) + Double(fw) * 0.5,
            centerY: Double(y) + Double(fh) * 0.5)
        x11ByWindow[windowID] = x11WindowID
        return windowID
    }

    /// Apply an X-imposed geometry (client-requested for override-redirect; the
    /// XWM's authoritative rect for managed windows) to the model window: adopt it
    /// as the layout rect and snap the presented frame to it.
    func applyGeometry(windowID: UInt64, x: Int32, y: Int32, w: UInt32, h: UInt32) {
        guard let window = WindowManager.shared.server.window(id: windowID) else { return }
        let previousRect = window.currentRect()
        let cw = UInt32(max(1, w))
        let ch = UInt32(max(1, h))
        window.committedLogicalSize = RenderSize(w: Double(cw), h: Double(ch))
        let insets = window.chromeInsets
        let fw = UInt32(max(1, Double(cw) + insets.horizontal))
        let fh = UInt32(max(1, Double(ch) + insets.vertical))
        window.setGeometry(WindowRect(x: Double(x), y: Double(y), width: fw, height: fh))
        window.seedPresentationActorToRect(
            PresentationRect(x: Double(x), y: Double(y), w: Double(fw), h: Double(fh)),
            slotGeneration: window.presentationActor.currentSlotGeneration)
        assignOutput(
            window,
            centerX: Double(x) + Double(fw) * 0.5,
            centerY: Double(y) + Double(fh) * 0.5)
        if window.mapped {
            RenderBridge.requestFrame(
                forWindowID: windowID,
                includingPreviousRect: previousRect)
        }
    }

    /// Map or unmap the model window. On map: author the scene at the current frame,
    /// flip `mapped`, and take keyboard focus. On unmap: hide it (`mapped` false) and
    /// tear the scene down. The X-side MapNotify/UnmapNotify drives this.
    func setMapped(windowID: UInt64, mapped: Bool) {
        let wm = WindowManager.shared
        guard let window = wm.server.window(id: windowID), window.surfaceObjectId != 0 else { return }
        let surfaceId = UInt32(window.surfaceObjectId)
        if mapped {
            guard !window.mapped else { return }
            feeder?.cancelClosingForRemap(window: window)
            window.mapped = true
            let rect = window.currentRect()
            feeder?.windowMapped(
                surfaceID: surfaceId, x: rect.x, y: rect.y,
                width: Double(rect.width), height: Double(rect.height))
            if window.wantsKeyboardFocus {
                wm.server.windows.focus(id: windowID)
                seatDriver.setKeyboardFocus(toSurfaceId: surfaceId)
            }
            RenderBridge.requestFrame(
                forWindowID: windowID)
        } else {
            guard window.mapped else { return }
            let closing = feeder?.beginClosing(
                window: window,
                destroyWindowOnCompletion: false) ?? false
            window.mapped = false
            seatDriver.surfaceUnmapped(surfaceId: surfaceId)
            if closing {
                feeder?.surfaceContentDetached(surfaceID: surfaceId)
            } else {
                feeder?.windowUnmapped(surfaceID: surfaceId)
            }
            RenderBridge.requestFrame(
                forWindowID: windowID)
        }
    }

    /// Tear the model window + scene down on X11 DestroyNotify / surface destruction.
    func destroy(windowID: UInt64) {
        let wm = WindowManager.shared
        guard let window = wm.server.window(id: windowID) else { return }
        var closing = false
        if window.surfaceObjectId != 0 {
            let surfaceId = UInt32(window.surfaceObjectId)
            closing = feeder?.beginClosing(
                window: window,
                destroyWindowOnCompletion: true) ?? false
            window.mapped = false
            seatDriver.surfaceUnmapped(surfaceId: surfaceId)
            if closing {
                feeder?.surfaceContentDetached(surfaceID: surfaceId)
            } else {
                feeder?.windowUnmapped(surfaceID: surfaceId)
            }
        }
        x11ByWindow[windowID] = nil
        wm.xwaylandDestroyed(windowID: windowID)
        if !closing {
            wm.server.destroyWindow(id: windowID)
        }
    }

    /// Emit an X11 configure for the model window's current rect (interactive
    /// move/resize of a managed X window). The XWM owns the X-side ConfigureNotify.
    func configureToX(windowID: UInt64) {
        guard let window = WindowManager.shared.server.window(id: windowID),
            let x11WindowID = x11ByWindow[windowID]
        else { return }
        let content = window.contentRect(forFrameRect: window.currentRect())
        // The Swift XWM owns the X-side ConfigureNotify emission, keyed by X11 id.
        RouterHost.shared.xwaylandHost?.xwm?.configureWindowById(
            xcb_window_t(truncatingIfNeeded: x11WindowID),
            Int16(clamping: Int(content.x.rounded())), Int16(clamping: Int(content.y.rounded())),
            UInt16(clamping: Int(max(1, content.width))), UInt16(clamping: Int(max(1, content.height))))
    }

    /// Apply an EWMH fullscreen/maximize transition to the shared window model
    /// and immediately issue the corresponding X ConfigureWindow. X11 has no
    /// xdg-style configure serial/ack; the WM configure is authoritative.
    func applyStateConfigure(windowID: UInt64) {
        let wm = WindowManager.shared
        guard let window = wm.server.window(id: windowID),
              let plan = wm.planConfigure(ConfigureRequest(
                windowID: windowID, reason: .xwaylandStateRequest,
                activated: wm.server.windows.focusedWindow?.id == windowID,
                tileEdges: window.tileEdges))
        else { return }
        window.setGeometry(plan.targetRect)
        window.activeMaximized = plan.activeMaximized
        window.activeFullscreen = plan.activeFullscreen
        window.specialOutputID = plan.specialOutputID
        if let outputID = plan.layoutOutputID {
            window.currentOutputID = outputID
            window.preferredOutputID = outputID
        }
        let finalRect = PresentationRect(
            x: plan.targetRect.x, y: plan.targetRect.y,
            w: Double(plan.targetRect.width), h: Double(plan.targetRect.height))
        if window.mapped, plan.shouldPresent, plan.layoutTransitionID != 0,
           let feeder
        {
            feeder.beginTileTransition(
                window: window,
                finalRect: finalRect,
                slotGeneration: window.presentationActor.currentSlotGeneration)
        } else {
            window.seedPresentationActorToRect(
                finalRect,
                slotGeneration: window.presentationActor.currentSlotGeneration)
        }
        configureToX(windowID: windowID)
        RenderBridge.requestFrame(
            forWindowID: windowID)
    }

    /// EWMH activation uses the same family raise, model focus, and wl_keyboard
    /// focus transition as native click-to-focus.
    func activateWindow(windowID: UInt64) {
        guard let window = WindowManager.shared.server.window(id: windowID),
              window.mapped, window.surfaceObjectId != 0 else { return }
        WindowManager.shared.server.windows.raise(id: windowID)
        WindowManager.shared.server.windows.focus(id: windowID)
        if window.wantsKeyboardFocus {
            seatDriver.setKeyboardFocus(toSurfaceId: UInt32(window.surfaceObjectId))
        }
        RenderBridge.requestFrame(
            forWindowID: windowID)
    }

    func raiseWindow(windowID: UInt64) {
        guard WindowManager.shared.server.windows.raise(id: windowID) else { return }
        RenderBridge.requestFrame(
            forWindowID: windowID)
    }

    /// Replan X11 windows whose geometry is output-relative after a mode, scale,
    /// placement, or membership change. Normal floating windows retain their
    /// client-owned geometry; fullscreen/maximized windows receive a fresh X
    /// ConfigureNotify against the updated work area.
    func outputTopologyChanged() {
        for window in WindowManager.shared.server.windows.windows
        where window.source == .xwayland
            && window.mapped
            && (window.requestedFullscreen
                || window.activeFullscreen
                || window.requestedMaximized
                || window.activeMaximized)
        {
            applyStateConfigure(windowID: window.id)
        }
    }

    private func assignOutput(
        _ window: Window,
        centerX: Double,
        centerY: Double
    ) {
        let server = WindowManager.shared.server
        let outputID = server.displayOutputForPoint(
            x: centerX, y: centerY)
        guard outputID != 0,
            window.currentOutputID != outputID
        else { return }
        window.currentOutputID = outputID
        window.preferredOutputID = outputID
        if WindowManager.shared.xwaylandClientListIncludes(
            windowID: window.id)
        {
            server.spaces.assignToActiveSpace(
                window: window.id, outputID: outputID)
        }
    }
}
