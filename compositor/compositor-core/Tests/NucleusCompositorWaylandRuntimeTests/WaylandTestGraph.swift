import NucleusCompositorServer
import NucleusCompositorWindowManager
import NucleusCompositorWindowScene
import WaylandServer

@testable import NucleusCompositorWaylandRuntime

/// The server-side graph a Wayland runtime test drives.
///
/// This is the only strong reference to the `RouterHost`, and the router's
/// drivers and scene feeder hold it `unowned` -- correctly, since in production
/// the host owns them and outlives the session. A test therefore has to keep
/// this alive for as long as anything it built is still in use, which is not
/// the same as keeping it in scope: an optimized build may release it after its
/// last read, and every later call through a driver then reads a destroyed
/// object. Each test pairs construction with
/// `defer { withExtendedLifetime(graph) {} }` for that reason.
@MainActor
final class WaylandTestGraph {
    let server: NucleusCompositorServer
    let windowManager: WindowManager
    let host: RouterHost
    let display: WaylandDisplay

    init() {
        let server = NucleusCompositorServer()
        let windowManager = WindowManager(server: server)
        self.server = server
        self.windowManager = windowManager
        self.host = RouterHost(server: server, windowManager: windowManager)
        self.display = WaylandDisplay()!
    }

    func compositor() -> WlCompositor {
        WlCompositor(host: host)
    }

    func seat(display: WaylandDisplay) -> WlSeat {
        WlSeat(host: host, display: display)
    }

    func surface(
        compositor: WlCompositor,
        version: Int32 = 7,
        stableObjectId: UInt32 = 1
    ) -> WlSurface {
        WlSurface(
            compositor: compositor,
            pointerCursorSurface: host.pointerCursorSurface,
            version: version,
            stableObjectId: stableObjectId)
    }

    func routerRuntime(author: WindowSceneAuthor) -> WaylandRouterRuntime? {
        WaylandRouterRuntime(author: author, host: host)
    }
}
