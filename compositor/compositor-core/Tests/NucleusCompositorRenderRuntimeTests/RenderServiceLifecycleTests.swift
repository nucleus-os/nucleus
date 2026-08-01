import NucleusCompositorServer
internal import NucleusAppHostProtocols
import NucleusRenderModel
package import NucleusRenderer
import Testing

@testable import NucleusCompositorRenderRuntime

private struct LifecycleTestWakeSink: AsyncRenderWakeSink {
    nonisolated func signalRenderWork() {}
}

@MainActor
@Test func failedRendererBringupDoesNotInstallRenderService() {
    let server = NucleusCompositorServer()
    let runtime = RenderRuntime(server: server)
    let resourceHost = SwiftResourceHost()
    let store = RetainedTreeStore(resourceHost: resourceHost)
    #expect(server.renderService == nil)

    #expect(
        !runtime.bringUp(
            drmDeviceFd: -1,
            dmabufMainDevice: 0,
            enableValidation: false,
            presentPolicy: .vsync,
            store: store,
            resourceHost: resourceHost,
            asyncRenderWakeSink: LifecycleTestWakeSink()))
    #expect(server.renderService == nil)
    runtime.shutdown()
}
