import NucleusDesktop
import Testing

@MainActor
private struct DesktopUmbrellaFixtureApp: App {
    var body: some Scene {
        EmptyScene()
    }
}

@MainActor
@Test func desktopUmbrellaExposesPortableAndClientContracts() {
    let configuration = NucleusDesktopWindowConfiguration(
        title: "Fixture",
        applicationID: "org.nucleus.fixture")
    #expect(configuration.title == "Fixture")
    #expect(NucleusDesktopCapabilityKind.windowManagement.rawValue
        == "xdg_wm_base")
    _ = DesktopUmbrellaFixtureApp().body
    let frame = Rect(x: 1, y: 2, width: 3, height: 4)
    #expect(frame.size.width == 3)

    func createWindow(
        host: NucleusDesktopHost
    ) throws(NucleusDesktopWindowError) {
        let window = try host.createWindow(
            configuration: configuration)
        window.close()
    }
    _ = createWindow
}
