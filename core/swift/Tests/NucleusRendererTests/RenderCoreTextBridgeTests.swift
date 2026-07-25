import NucleusRenderModel
import NucleusSkiaGraphiteBridge
import Testing
@testable import NucleusRenderer

private struct TextBridgeTestWakeSink:
    AsyncRenderWakeSink
{
    nonisolated func signalRenderWork() {}
}

@MainActor
@Test
func rendererBringupFailsBeforeVulkanWithoutTextBorrowProvider() {
    #expect(!nucleus.skia.hasTextLayoutBorrow())
    let resourceHost = SwiftResourceHost()
    let store = RetainedTreeStore(
        resourceHost: resourceHost)
    let core = RenderCore.create(
        applicationName: "Missing Text Bridge Test",
        presentation: .headless,
        store: store,
        resourceHost: resourceHost,
        asyncRenderWakeSink: TextBridgeTestWakeSink())
    #expect(core == nil)
}
