import NucleusCompositorServer
import NucleusCompositorWindowManager
import NucleusCompositorWindowScene
@testable import NucleusCompositorWaylandRuntime

@MainActor
final class WaylandTestGraph {
    let server: NucleusCompositorServer
    let windowManager: WindowManager
    let host: RouterHost

    init() {
        let server = NucleusCompositorServer()
        let windowManager = WindowManager(server: server)
        self.server = server
        self.windowManager = windowManager
        self.host = RouterHost(server: server, windowManager: windowManager)
    }

    func compositor() -> WlCompositor {
        WlCompositor(host: host)
    }

    func seat() -> WlSeat {
        WlSeat(host: host)
    }

    func surface(
        compositor: WlCompositor,
        version: Int32 = 7,
        stableObjectId: UInt32 = 0
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
