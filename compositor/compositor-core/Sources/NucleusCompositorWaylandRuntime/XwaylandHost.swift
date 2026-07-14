// Xwayland integration manager. Owns the X11 display sockets (XwaylandDisplay), the Xwayland
// subprocess (XwaylandProcess), and the in-process window manager (XwaylandXWM).
//
// The compositor reactor loop (CompositorRuntime) drives this through the
// nucleus_xwm_host_* crossings: bring-up binds the display + exports DISPLAY; the
// xwayland_listen token's first-client edge spawns Xwayland; the xwayland_ready token
// hands the WM fd to the XWM; the xwayland_xwm token pumps XCB events. The live XWM is
// reachable for the router's reverse crossings (configure, set_serial) via
// RouterHost.shared.xwaylandHost.

import Glibc
import NucleusCompositorServer

@MainActor
final class XwaylandHost {
    var display: XwaylandDisplay?
    var process: XwaylandProcess?
    var xwm: XwaylandXWM?
    private var processActive = false

    /// Claim a display slot, bind sockets, export DISPLAY, and arm first-client
    /// detection. Returns false if no display could be bound (X11 unavailable).
    func bringUp() -> Bool {
        guard let d = XwaylandDisplay.bind() else { return false }
        display = d
        d.startListening()
        setenv("DISPLAY", ":\(d.number)", 1)  // export for compositor children
        return true
    }

    var abstractFd: Int32 { display?.abstractFd ?? -1 }
    var fsFd: Int32 { display?.fsFd ?? -1 }

    /// First-client edge on a listen socket → spawn Xwayland. Returns true if `fd`
    /// was one of our listen sockets (the loop then stops polling it).
    func handleDisplayReadable(_ fd: Int32) -> Bool {
        guard let d = display, d.isFirstClient(fd) else { return false }
        guard !processActive else { return true }
        let p = XwaylandProcess()
        if p.spawn(displayNum: d.number, abstractFd: d.abstractFd, fsFd: d.fsFd) {
            process = p
            processActive = true
        }
        return true
    }

    /// The readiness pipe fd, polled until Xwayland reports its display number.
    func readyFd() -> Int32? { processActive ? process?.readyFd() : nil }

    /// Xwayland is ready: take the WM fd and bring the XWM up.
    func handleReadyReadable() {
        guard let p = process else { return }
        let wmFd = p.takeWmFdOnReady()
        guard wmFd >= 0 else { return }
        guard let x = XwaylandXWM(wmFd: wmFd) else { return }
        xwm = x
        x.refreshDesktopState()
    }

    /// The XCB connection fd, polled once the XWM is live.
    func xwmFd() -> Int32? { xwm?.pollFd }

    /// Pump XCB events. Returns false on a fatal connection error (drop the token).
    func dispatch() -> Bool { xwm?.dispatchReadable() ?? false }

    /// Re-publish DPI/desktop state after a fractional-scale or layout change.
    func updateScale() { xwm?.refreshDesktopState() }

    func shutdown() {
        xwm?.shutdown()
        xwm = nil
        process?.shutdown()
        process = nil
        processActive = false
        display?.shutdown()
        display = nil
    }
}

// ── bring-up + loop crossings (the composition root drives these directly) ───────

/// Bring up the Xwayland manager. Returns whether X11 support is available.
@MainActor public func nucleus_xwm_host_init() -> Bool {
    let host = XwaylandHost()
    guard host.bringUp() else { return false }
    RouterHost.shared.xwaylandHost = host
    return true
}

@MainActor public func nucleus_xwm_host_abstract_fd() -> Int32 {
    RouterHost.shared.xwaylandHost?.abstractFd ?? -1
}

@MainActor public func nucleus_xwm_host_fs_fd() -> Int32 {
    RouterHost.shared.xwaylandHost?.fsFd ?? -1
}

/// xwayland_listen token: a listen socket became readable. Returns true on the
/// first-client edge (Xwayland spawned; stop polling the socket).
@MainActor public func nucleus_xwm_host_display_readable(_ fd: Int32) -> Bool {
    RouterHost.shared.xwaylandHost?.handleDisplayReadable(fd) ?? false
}

/// The readiness pipe fd, or -1 if not waiting (post-drain registration).
@MainActor public func nucleus_xwm_host_ready_fd() -> Int32 {
    RouterHost.shared.xwaylandHost?.readyFd() ?? -1
}

/// xwayland_ready token: Xwayland reported its display number → bring up the XWM.
@MainActor public func nucleus_xwm_host_ready_readable() {
    RouterHost.shared.xwaylandHost?.handleReadyReadable()
}

/// The XCB connection fd, or -1 if the XWM isn't live (post-drain registration).
@MainActor public func nucleus_xwm_host_xwm_fd() -> Int32 {
    RouterHost.shared.xwaylandHost?.xwmFd() ?? -1
}

/// xwayland_xwm token: XCB fd readable → pump events. Returns false on fatal error.
@MainActor public func nucleus_xwm_host_dispatch() -> Bool {
    RouterHost.shared.xwaylandHost?.dispatch() ?? false
}

/// Pointer focus entered an xwayland surface -> re-assert the last X cursor against
/// the Swift cursor server. Returns whether an XWM cursor source is live. Called
/// intra-module by the input dispatch (same NucleusCompositorWaylandRuntime module).
@MainActor func nucleus_compositor_xwm_reapply_cursor() -> Bool {
    guard let xwm = RouterHost.shared.xwaylandHost?.xwm else { return false }
    return xwm.applyCurrentCursor()
}

@MainActor public func nucleus_xwm_host_shutdown() {
    RouterHost.shared.xwaylandHost?.shutdown()
    RouterHost.shared.xwaylandHost = nil
}
