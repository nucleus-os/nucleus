import Testing

@testable import NucleusAndroidDisplayHostCore

@Test
func applicationPresentationsHaveIndependentIdentityConfigurationAndLifetime() throws {
    var registry = AndroidPresentationRegistry()
    let first = try registry.createApplication(
        appID: "org.example.first",
        title: "First",
        initialMode: AndroidPresentationMode(width: 800, height: 600))
    let second = try registry.createApplication(
        appID: "org.example.second",
        title: "Second",
        initialMode: AndroidPresentationMode(width: 1_024, height: 768))

    #expect(registry.desktop.id == .desktop)
    #expect(registry.desktop.appID == "nucleus.android.desktop")
    #expect(first.id != second.id)
    #expect(first.role == .application)
    #expect(second.role == .application)

    try registry.updateConfiguration(
        id: first.id,
        generation: 2,
        mode: AndroidPresentationMode(width: 1_280, height: 720))

    #expect(registry.presentation(id: first.id)?.configurationGeneration == 2)
    #expect(
        registry.presentation(id: first.id)?.mode
            == AndroidPresentationMode(width: 1_280, height: 720))
    #expect(registry.presentation(id: second.id) == second)

    let removed = registry.removeApplication(id: first.id)
    #expect(removed?.id == first.id)
    #expect(registry.presentation(id: first.id) == nil)
    #expect(registry.presentation(id: second.id) == second)
    #expect(registry.removeApplication(id: .desktop) == nil)
    #expect(registry.desktop.id == .desktop)
}

@Test
func removedPresentationIdentitiesAreNotReused() throws {
    var registry = AndroidPresentationRegistry()
    let removed = try registry.createApplication(
        appID: "org.example.removed",
        title: "Removed",
        initialMode: AndroidPresentationMode(width: 640, height: 480))
    registry.removeApplication(id: removed.id)
    let replacement = try registry.createApplication(
        appID: "org.example.replacement",
        title: "Replacement",
        initialMode: AndroidPresentationMode(width: 640, height: 480))

    #expect(replacement.id.rawValue > removed.id.rawValue)
}
