// Runtime-owned holder for the live Wayland router and its services. Every object
// that needs graph access receives this context explicitly from `WaylandRuntime`.

import Glibc
package import NucleusCompositorServer
package import NucleusCompositorWindowManager
import NucleusDiagnostics
import WaylandServer

@MainActor
package final class RouterHost {
    private static let xwaylandOnlyGlobal = "xwayland_shell_v1"
    unowned let server: NucleusCompositorServer
    unowned let windowManager: WindowManager
    let diagnostics: WaylandRuntimeDiagnostics

    /// The live router, nil before compositor bring-up constructs it.
    var router: NucleusWaylandRouter?

    /// The per-frame scene feeder (drives `WindowSceneAuthor` from the Swift
    /// window model). nil before router activation constructs it; the compositor
    /// loop's per-output `WaylandRuntime.authorSceneFrame` call forwards here.
    var feeder: SceneFeeder?

    /// The constructed router graph (every protocol impl + driver), held here for
    /// the compositor's lifetime. nil before compositor bring-up.
    var runtime: WaylandRouterRuntime?

    /// The Xwayland integration manager (display sockets + subprocess + in-process
    /// XWM). nil until the reactor loop brings it up; reached by the router's reverse
    /// xwayland crossings (configure, set_serial) to drive the live XWM.
    var xwaylandHost: XwaylandHost?

    /// The Swift input backend (libseat session + libinput + udev + xkb + dispatch).
    /// nil before input bring-up constructs it; the loop's seat/libinput FD
    /// handlers drive it and the DRM bring-up borrows its seat for device opens.
    var inputHost: InputHost?
    var xwaylandClientID: WaylandClientID?

    lazy var sessionLockGate = SessionLockGate(host: self)
    lazy var pointerCursorSurface = PointerCursorSurface(server: server)

    private var presentationSequence: UInt64 = 0

    package init(
        server: NucleusCompositorServer,
        windowManager: WindowManager,
        diagnostics: WaylandRuntimeDiagnostics = WaylandRuntimeDiagnostics()
    ) {
        self.server = server
        self.windowManager = windowManager
        self.diagnostics = diagnostics
    }

    func traceProtocol(_ message: String) {
        guard diagnostics.traceProtocolEffects else { return }
        NucleusLogger(subsystem: "wayland-protocol").debug(message)
    }

    package func install(_ runtime: WaylandRouterRuntime) {
        self.runtime = runtime
        router = runtime.router
        feeder = runtime.feeder
    }

    func nextPresentationSequence() -> UInt64 {
        presentationSequence &+= 1
        return presentationSequence
    }

    func allowsGlobal(
        client: WaylandClientID,
        interfaceName: String
    ) -> Bool {
        // Two rules, and this is the only place either is enforced. Xwayland's
        // protocol is scoped to one client; everything else is visible unless
        // the client connected through a security context.
        guard interfaceName == Self.xwaylandOnlyGlobal else {
            return runtime?.securityContext.allows(
                client: client, interface: interfaceName) ?? true
        }
        return client == xwaylandClientID
    }
}

// The public verbs the composition root drives against this holder — activation, per-frame authoring,
// event-loop dispatch, presentation, and the session-lock gate — live on the `WaylandRuntime` facade
// (WaylandRuntime.swift), the module's only public entry point.
