import Testing
import NucleusCompositorServer
import NucleusRenderModel
@_spi(NucleusPlatform) import NucleusRenderer
@testable import NucleusCompositorRenderRuntime

private struct LifecycleTestWakeSink: AsyncRenderWakeSink {
    nonisolated func signalRenderWork() {}
}

@MainActor
@Test func failedRendererBringupDoesNotInstallRenderService() {
    RenderRuntime.shutdown()
    let server = NucleusCompositorServer.shared
    let resourceHost = SwiftResourceHost()
    let store = RetainedTreeStore(resourceHost: resourceHost)
    #expect(server.renderService == nil)

    #expect(!RenderRuntime.bringUp(
        drmDeviceFd: -1,
        dmabufMainDevice: 0,
        store: store,
        resourceHost: resourceHost,
        asyncRenderWakeSink: LifecycleTestWakeSink()))
    #expect(server.renderService == nil)
}
