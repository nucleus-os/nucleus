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
    private unowned let host: RouterHost
    var display: XwaylandDisplay?
    var process: XwaylandProcess?
    var xwm: XwaylandXWM?
    private var processActive = false

    init(host: RouterHost) {
        self.host = host
    }

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
        let p = XwaylandProcess(host: host)
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
        guard let x = XwaylandXWM(wmFd: wmFd, host: host) else { return }
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

// ── composition-root lifecycle ────────────────────────────────────────────────

public extension WaylandRuntime {
    func bringUpXwayland() -> Bool {
        let xwaylandHost = XwaylandHost(host: host)
        guard xwaylandHost.bringUp() else { return false }
        host.xwaylandHost = xwaylandHost
        return true
    }

    var xwaylandAbstractFileDescriptor: Int32 {
        host.xwaylandHost?.abstractFd ?? -1
    }

    var xwaylandFilesystemFileDescriptor: Int32 {
        host.xwaylandHost?.fsFd ?? -1
    }

    func xwaylandDisplayReadable(_ fileDescriptor: Int32) -> Bool {
        host.xwaylandHost?.handleDisplayReadable(fileDescriptor) ?? false
    }

    var xwaylandReadyFileDescriptor: Int32 {
        host.xwaylandHost?.readyFd() ?? -1
    }

    func xwaylandReadyReadable() {
        host.xwaylandHost?.handleReadyReadable()
    }

    var xwaylandWindowManagerFileDescriptor: Int32 {
        host.xwaylandHost?.xwmFd() ?? -1
    }

    func dispatchXwaylandWindowManager() -> Bool {
        host.xwaylandHost?.dispatch() ?? false
    }

    func shutdownXwayland() {
        host.xwaylandHost?.shutdown()
        host.xwaylandHost = nil
    }
}
