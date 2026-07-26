import NucleusCompositorServer
import NucleusCompositorWindowManager
import NucleusCompositorWindowScene
import WaylandServer
@testable import NucleusCompositorWaylandRuntime

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
