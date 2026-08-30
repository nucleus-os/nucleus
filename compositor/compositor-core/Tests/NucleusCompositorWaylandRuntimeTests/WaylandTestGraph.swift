import NucleusCompositorServer
import NucleusCompositorWindowManager
import NucleusCompositorWindowScene
import WaylandServer

@testable import NucleusCompositorWaylandRuntime

/// The server-side graph a Wayland runtime test drives.
///
/// This is the only strong reference to the `RouterHost`, which the router's
/// drivers and scene feeder hold `unowned` -- correctly, since production has
/// the host own them and outlive the session. Tests once had to pin this with
/// `withExtendedLifetime` so an optimized build would not release it after its
/// last read and leave a driver reading a destroyed object. They no longer do:
/// nothing in this graph reaches outward from a `deinit`, so the order ARC
/// happens to release these in cannot matter.
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
