@testable import NucleusApp
import NucleusUI
import Testing

@MainActor
@Suite struct NucleusAppLifecycleTests {
    private struct TwoSceneApp: App {
        var body: some Scene {
            WindowGroup("Primary") {
                View()
            }
            WindowGroup(
                "Notice",
                role: .notification,
                activationPolicy: .nonactivating
            ) {
                View()
            }
        }
    }

    @Test func appMaterializesMultipleScenesOnceIntoIndependentContexts() {
        let host = InMemoryAppHost()
        NucleusAppRuntime.installHost(host)

        TwoSceneApp.main()

        #expect(host.presentedScenes.count == 2)
        let primary = host.presentedScenes[0]
        let notice = host.presentedScenes[1]
        #expect(primary.request.id == SceneID(rawValue: 1))
        #expect(notice.request.id == SceneID(rawValue: 2))
        #expect(primary.request.role == .application)
        #expect(notice.request.role == .notification)
        #expect(notice.request.activationPolicy == .nonactivating)
        #expect(primary.scene.uiContext !== notice.scene.uiContext)
        #expect(primary.scene.windows[0].id != notice.scene.windows[0].id)
    }

    @Test func hostLifecycleTransitionsAreDeterministicAndDisconnectIsTerminal()
        throws
    {
        let host = InMemoryAppHost()
        NucleusAppRuntime.installHost(host)
        TwoSceneApp.main()
        let scene = host.presentedScenes[0].scene
        var observed: [SceneActivationState] = []
        scene.onActivationChange = { observed.append($0) }

        scene.transition(to: .active)
        scene.transition(to: .inactive)
        try scene.disconnect()
        try scene.disconnect()
        scene.transition(to: .active)

        #expect(observed == [.active, .inactive, .disconnected])
        #expect(scene.activationState == .disconnected)
        #expect(scene.windows.isEmpty)
        #expect(throws: UIError.self) {
            _ = try scene.publish()
        }
    }
}
