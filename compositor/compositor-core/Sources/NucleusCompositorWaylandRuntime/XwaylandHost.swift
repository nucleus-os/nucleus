// Xwayland integration manager. Owns the X11 display sockets (XwaylandDisplay), the Xwayland
// subprocess (XwaylandProcess), and the in-process window manager (XwaylandXWM).
//
// The compositor reactor loop (CompositorRuntime) drives this through the
// nucleus_xwm_host_* crossings: bring-up binds the display + exports DISPLAY; the
// xwayland_listen token's first-client edge spawns Xwayland; the xwayland_ready token
// hands the WM fd to the XWM; the xwayland_xwm token pumps XCB events. The live XWM is
// reachable for the router's reverse crossings (configure, set_serial) via
// the owning RouterHost's `xwaylandHost`.

import Glibc
internal import NucleusCompositorServer

@MainActor
final class XwaylandHost {
    private unowned let host: RouterHost
    private let executablePath: String
    private let traceEnabled: Bool
    private let runtimeDirectory: XwaylandRuntimeDirectory
    var display: XwaylandDisplay?
    var process: XwaylandProcess?
    var xwm: XwaylandXWM?
    private var processActive = false

    init(
        host: RouterHost,
        executablePath: String,
        traceEnabled: Bool,
        runtimeDirectory: XwaylandRuntimeDirectory
    ) {
        self.host = host
        self.executablePath = executablePath
        self.traceEnabled = traceEnabled
        self.runtimeDirectory = runtimeDirectory
    }

    /// Claim a display slot, bind sockets, export DISPLAY, and arm first-client
    /// detection. Returns false if no display could be bound (X11 unavailable).
    func bringUp() -> Bool {
        guard let d = XwaylandDisplay.bind() else { return false }
        display = d
        d.startListening()
        unsafe setenv("DISPLAY", ":\(d.number)", 1)  // export for compositor children
        return true
    }

    var abstractFd: Int32 { display?.abstractFd ?? -1 }
    var fsFd: Int32 { display?.fsFd ?? -1 }

    /// First-client edge on a listen socket → spawn Xwayland. Returns true if `fd`
    /// was one of our listen sockets (the loop then stops polling it).
    func handleDisplayReadable(_ fd: Int32) -> Bool {
        guard let d = display, d.isFirstClient(fd) else { return false }
        guard !processActive else { return true }
        let p = XwaylandProcess(
            host: host,
            executablePath: executablePath,
            runtimeDirectory: runtimeDirectory,
            traceEnabled: traceEnabled)
        if p.spawn(displayNum: d.number, abstractFd: d.abstractFd, fsFd: d.fsFd) {
            process = p
            processActive = true
        }
        return true
    }

    /// The readiness pipe fd, polled until Xwayland reports its display number.
    func readyFd() -> Int32? { processActive ? process?.readyFd() : nil }
    func traceFd() -> Int32? { processActive ? process?.traceFd() : nil }
    func drainTrace() -> Bool { process?.drainTrace() ?? false }
    var traceDroppedBytes: UInt64 {
        process?.traceDroppedBytes ?? 0
    }

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

extension WaylandRuntime {
    package func bringUpXwayland(
        executablePath: String,
        traceEnabled: Bool
    ) -> Bool {
        guard
            let runtimeDirectory =
                try? XwaylandRuntimeDirectory
                .openFromEnvironment()
        else {
            return false
        }
        let xwaylandHost = XwaylandHost(
            host: host,
            executablePath: executablePath,
            traceEnabled: traceEnabled,
            runtimeDirectory: runtimeDirectory)
        guard xwaylandHost.bringUp() else { return false }
        host.xwaylandHost = xwaylandHost
        return true
    }

    package var xwaylandAbstractFileDescriptor: Int32 {
        host.xwaylandHost?.abstractFd ?? -1
    }

    package var xwaylandFilesystemFileDescriptor: Int32 {
        host.xwaylandHost?.fsFd ?? -1
    }

    package func xwaylandDisplayReadable(_ fileDescriptor: Int32) -> Bool {
        host.xwaylandHost?.handleDisplayReadable(fileDescriptor) ?? false
    }

    package var xwaylandReadyFileDescriptor: Int32 {
        host.xwaylandHost?.readyFd() ?? -1
    }

    package var xwaylandTraceFileDescriptor: Int32 {
        host.xwaylandHost?.traceFd() ?? -1
    }

    package func drainXwaylandTrace() -> Bool {
        host.xwaylandHost?.drainTrace() ?? false
    }

    package var xwaylandTraceDroppedBytes: UInt64 {
        host.xwaylandHost?.traceDroppedBytes ?? 0
    }

    package func xwaylandReadyReadable() {
        host.xwaylandHost?.handleReadyReadable()
    }

    package var xwaylandWindowManagerFileDescriptor: Int32 {
        host.xwaylandHost?.xwmFd() ?? -1
    }

    package func dispatchXwaylandWindowManager() -> Bool {
        host.xwaylandHost?.dispatch() ?? false
    }

    package func shutdownXwayland() {
        host.xwaylandHost?.shutdown()
        host.xwaylandHost = nil
    }
}
