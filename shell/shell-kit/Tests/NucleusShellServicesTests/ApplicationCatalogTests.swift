import Testing

@testable import NucleusShellServices

@MainActor
@Suite("Application catalog")
struct ApplicationCatalogTests {
    @Test("providers merge and detach without disturbing other namespaces")
    func providerLifecycle() {
        let catalog = ApplicationCatalog()
        let desktop = FakeApplicationProvider(
            id: .desktop,
            applications: [record(provider: .desktop, localID: "terminal", name: "Terminal")])
        let androidID = ApplicationProviderID(rawValue: "android")
        let android = FakeApplicationProvider(
            id: androidID,
            applications: [record(provider: androidID, localID: "maps", name: "Maps")])
        var publishedNames: [[String]] = []
        catalog.onApplicationsChanged = { applications in
            publishedNames.append(applications.map(\.name))
        }

        catalog.attach(desktop)
        catalog.attach(android)
        #expect(catalog.applications.map(\.name) == ["Maps", "Terminal"])

        android.publish(
            .upsert(record(provider: androidID, localID: "camera", name: "Camera")))
        #expect(catalog.applications.map(\.name) == ["Camera", "Maps", "Terminal"])

        android.publish(.remove(ApplicationID(provider: androidID, localID: "maps")))
        #expect(catalog.applications.map(\.name) == ["Camera", "Terminal"])

        catalog.detach(providerID: androidID)
        #expect(catalog.applications.map(\.name) == ["Terminal"])
        #expect(publishedNames.last == ["Terminal"])
        #expect(desktop.handlerIsInstalled)
        #expect(!android.handlerIsInstalled)
    }

    @Test("launches route to the owning provider with activation identity")
    func launchRouting() {
        let providerID = ApplicationProviderID(rawValue: "remote")
        let application = record(provider: providerID, localID: "editor", name: "Editor")
        let provider = FakeApplicationProvider(
            id: providerID,
            applications: [application],
            result: .activatedExistingPresentation)
        let catalog = ApplicationCatalog()
        catalog.attach(provider)

        let request = ApplicationLaunchRequest(
            applicationID: application.id,
            activationToken: "activation-token")
        #expect(catalog.launch(request) == .activatedExistingPresentation)
        #expect(provider.requests == [request])
    }

    private func record(
        provider: ApplicationProviderID,
        localID: String,
        name: String
    ) -> ApplicationRecord {
        ApplicationRecord(
            id: ApplicationID(provider: provider, localID: localID),
            name: name,
            providerID: provider,
            providerLaunchID: localID)
    }
}

@MainActor
private final class FakeApplicationProvider: ApplicationProvider {
    let id: ApplicationProviderID
    var applications: [ApplicationRecord]
    var requests: [ApplicationLaunchRequest] = []
    var handlerIsInstalled: Bool { handler != nil }

    private let result: ApplicationLaunchResult
    private var handler: (@MainActor @Sendable (ApplicationCatalogChange) -> Void)?

    init(
        id: ApplicationProviderID,
        applications: [ApplicationRecord],
        result: ApplicationLaunchResult = .created
    ) {
        self.id = id
        self.applications = applications
        self.result = result
    }

    func setCatalogChangeHandler(
        _ handler: (@MainActor @Sendable (ApplicationCatalogChange) -> Void)?
    ) {
        self.handler = handler
    }

    func launch(_ request: ApplicationLaunchRequest) -> ApplicationLaunchResult {
        requests.append(request)
        return result
    }

    func publish(_ change: ApplicationCatalogChange) {
        handler?(change)
    }
}
