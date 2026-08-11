import Foundation
import NucleusSessionProtocol
import Testing

#if os(Linux)
import Glibc
#else
import Darwin
#endif

@Suite("Application provider channel")
struct ApplicationProviderChannelTests {
    @Test("server publishes its current snapshot and incremental changes")
    func publicationLifecycle() async throws {
        let runtime = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "nucleus-application-provider-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtime) }

        let initial = try record(id: "android:0:org.example/.Main", name: "Example")
        let server = try ApplicationProviderPublicationServer(
            providerID: "android",
            sessionRuntimeDirectory: runtime,
            expectedUserID: getuid())
        try server.publish(.replace([initial]))
        let service = Task {
            try await server.run { request in
                .failed("unexpected launch for \(request.launchID)")
            }
        }
        defer { service.cancel() }

        let socket = try ApplicationProviderEndpoint.socket(
            providerID: "android",
            in: runtime)
        let client = try ApplicationProviderClientChannel(
            connecting: socket,
            expectedProviderID: "android",
            expectedUserID: getuid())
        #expect(try client.receive() == nil)
        #expect(try client.receive() == .replace([initial]))

        let updated = try record(
            id: initial.id,
            name: "Renamed",
            icon: .rasterAsset(
                digest: String(repeating: "a", count: 64),
                path: "/run/nucleus/example.png"))
        try server.publish(.upsert(updated))
        #expect(try client.receive() == .upsert(updated))
        try server.publish(.remove(updated.id))
        #expect(try client.receive() == .remove(updated.id))
    }

    @Test("provider launch uses an independent request-reply channel")
    func launchTransaction() async throws {
        let runtime = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "nucleus-application-provider-launch-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtime) }

        let server = try ApplicationProviderPublicationServer(
            providerID: "android",
            sessionRuntimeDirectory: runtime,
            expectedUserID: getuid())
        let service = Task {
            try await server.run { request in
                #expect(request.launchID == "10:org.example/.Main")
                #expect(request.activationToken == "activation-token")
                return .created
            }
        }
        defer { service.cancel() }

        let request = try ApplicationProviderLaunchRequest(
            providerID: "android",
            launchID: "10:org.example/.Main",
            activationToken: "activation-token")
        let result = try await Task.detached {
            try ApplicationProviderLaunchClient.launch(
                request,
                sessionRuntimeDirectory: runtime,
                expectedUserID: getuid())
        }.value

        #expect(result == .created)
    }

    @Test("provider and record identities are bounded")
    func identityValidation() throws {
        #expect(!ApplicationProviderEndpoint.validProviderID("android:runtime"))
        #expect(!ApplicationProviderEndpoint.validProviderID("Android"))
        #expect(throws: ApplicationProviderChannelFailure.self) {
            try ApplicationProviderRecord(
                id: "android:app",
                name: "Example",
                icon: .rasterAsset(digest: "not-a-digest", path: "/tmp/icon.png"),
                launchID: "app")
        }
    }

    private func record(
        id: String,
        name: String,
        icon: ApplicationProviderIcon? = nil
    ) throws -> ApplicationProviderRecord {
        try ApplicationProviderRecord(
            id: id,
            name: name,
            icon: icon,
            categories: ["productivity"],
            launchID: String(id.dropFirst("android:".count)))
    }
}
