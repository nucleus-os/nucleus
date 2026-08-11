import Foundation
import NucleusSessionProtocol
import Testing

@testable import NucleusShellServices

#if os(Linux)
import Glibc
#else
import Darwin
#endif

@MainActor
@Suite("Remote application providers")
struct RemoteApplicationProviderServiceTests {
    @Test("provider snapshots and deltas update the live shell catalog")
    func catalogLifecycle() async throws {
        let runtime = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "nucleus-remote-provider-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtime) }

        let server = try ApplicationProviderPublicationServer(
            providerID: "android",
            sessionRuntimeDirectory: runtime,
            expectedUserID: getuid())
        let first = try record(id: "android:0:org.example/.Main", name: "Example")
        try server.publish(.replace([first]))
        let publication = Task.detached {
            try await server.run { request in
                request.launchID.hasSuffix("/.Settings")
                    ? .activatedExistingPresentation
                    : .created
            }
        }
        defer { publication.cancel() }

        let launcher = LauncherService(desktopProvider: nil)
        let service = RemoteApplicationProviderService(
            launcher: launcher,
            sessionRuntimeDirectory: runtime)
        service.scan(nowNanoseconds: 1)
        let token = try #require(service.pollDescriptors.first?.token)
        #expect(!service.process(token: token))
        #expect(service.process(token: token))
        #expect(launcher.applications().map(\.name) == ["Example"])

        let second = try record(id: "android:0:org.example/.Settings", name: "Settings")
        try server.publish(.upsert(second))
        #expect(service.process(token: token))
        #expect(launcher.applications().map(\.name) == ["Example", "Settings"])
        let settingsID = try #require(ApplicationID(rawValue: second.id))
        #expect(
            launcher.launch(applicationID: settingsID)
                == .activatedExistingPresentation)

        try server.publish(.remove(first.id))
        #expect(service.process(token: token))
        #expect(launcher.applications().map(\.name) == ["Settings"])

        service.disconnect(token: token)
        #expect(launcher.applications().isEmpty)
    }

    private func record(
        id: String,
        name: String
    ) throws -> ApplicationProviderRecord {
        try ApplicationProviderRecord(
            id: id,
            name: name,
            categories: ["productivity"],
            launchID: String(id.dropFirst("android:".count)))
    }
}
