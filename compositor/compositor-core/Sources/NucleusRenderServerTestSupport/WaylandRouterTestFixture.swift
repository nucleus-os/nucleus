import NucleusCompositorServer
package import NucleusCompositorWaylandRuntime
import NucleusCompositorWindowManager
import NucleusCompositorWindowScene
import NucleusLayers

/// Owns the complete server-side graph used by cross-package Wayland wire
/// tests. Keeping this fixture alive keeps every unowned production edge valid;
/// the exposed runtime is the same graph production activation constructs.
@MainActor
package final class WaylandRouterTestFixture {
    private let server: NucleusCompositorServer
    private let windowManager: WindowManager
    private let host: RouterHost
    package let runtime: WaylandRouterRuntime

    package init?() {
        let server = NucleusCompositorServer()
        let windowManager = WindowManager(server: server)
        let host = RouterHost(
            server: server,
            windowManager: windowManager)
        let sink = InMemoryCommitSink()
        let author = WindowSceneAuthor(
            commitSinkFactory: { sink })
        guard
            let runtime = WaylandRouterRuntime(
                author: author,
                host: host)
        else { return nil }

        self.server = server
        self.windowManager = windowManager
        self.host = host
        self.runtime = runtime
        host.install(runtime)
    }
}
