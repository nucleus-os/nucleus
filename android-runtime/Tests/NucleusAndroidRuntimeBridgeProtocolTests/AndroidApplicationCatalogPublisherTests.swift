import Foundation
import Glibc
internal import NucleusAndroidRuntimeBridgeProtocol
import NucleusSessionProtocol
import Testing

@testable import NucleusAndroidRuntimeBrokerCore

@Suite("Android application catalog publisher")
struct AndroidApplicationCatalogPublisherTests {
    @Test("package replacements atomically update records and collect icons")
    func replacementAndIconLifecycle() async throws {
        let runtime = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "nucleus-android-catalog-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtime) }

        let server = try ApplicationProviderPublicationServer(
            providerID: "android",
            sessionRuntimeDirectory: runtime,
            expectedUserID: getuid())
        let publisher = try AndroidApplicationCatalogPublisher(
            server: server,
            sessionRuntimeDirectory: runtime)
        let service = Task { try await server.run() }
        defer { service.cancel() }
        let client = try ApplicationProviderClientChannel(
            connecting: server.socket,
            expectedProviderID: "android",
            expectedUserID: getuid())
        #expect(try client.receive() == nil)
        #expect(try client.receive() == .replace([]))

        let oldDigest = String(repeating: "a", count: 64)
        try await publisher.handle(
            .iconAsset(
                generation: "generation",
                userSerial: 0,
                asset: icon(digest: oldDigest)))
        let initial = activity(label: "Example", digest: oldDigest)
        try await publisher.handle(
            .activitiesReplaced(
                generation: "generation",
                userSerial: 0,
                activities: [initial]))
        let initialChange = try #require(try client.receive())
        let initialRecords = try #require(replacement(from: initialChange))
        let initialRecord = try #require(initialRecords.first)
        guard case .rasterAsset(let publishedOldDigest, let oldPath) = initialRecord.icon else {
            Issue.record("initial Android application omitted its icon")
            return
        }
        #expect(publishedOldDigest == oldDigest)
        #expect(FileManager.default.fileExists(atPath: oldPath))

        let newDigest = String(repeating: "b", count: 64)
        try await publisher.handle(
            .iconAsset(
                generation: "generation",
                userSerial: 0,
                asset: icon(digest: newDigest)))
        let renamed = activity(label: "Renamed", digest: newDigest)
        try await publisher.handle(
            .packageActivitiesReplaced(
                generation: "generation",
                userSerial: 0,
                packageName: renamed.packageName,
                activities: [renamed]))
        let update = try #require(try client.receive())
        guard case .upsert(let updated) = update,
            case .rasterAsset(let publishedNewDigest, let newPath) = updated.icon
        else {
            Issue.record("package replacement did not upsert the new icon")
            return
        }
        #expect(publishedNewDigest == newDigest)
        #expect(updated.name == "Renamed")
        #expect(FileManager.default.fileExists(atPath: newPath))
        #expect(!FileManager.default.fileExists(atPath: oldPath))

        try await publisher.handle(
            .packageActivitiesReplaced(
                generation: "generation",
                userSerial: 0,
                packageName: renamed.packageName,
                activities: []))
        #expect(try client.receive() == .remove(updated.id))
        #expect(!FileManager.default.fileExists(atPath: newPath))
    }

    private func activity(
        label: String,
        digest: String
    ) -> AndroidRuntimeBridgeActivity {
        AndroidRuntimeBridgeActivity(
            packageName: "org.example",
            activityName: "org.example.MainActivity",
            label: label,
            categories: ["productivity"],
            iconDigest: digest)
    }

    private func icon(digest: String) -> AndroidRuntimeBridgeIconAsset {
        AndroidRuntimeBridgeIconAsset(
            digest: digest,
            bytes: Data([
                0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
                0x00,
            ]))
    }

    private func replacement(
        from change: ApplicationProviderCatalogChange
    ) -> [ApplicationProviderRecord]? {
        guard case .replace(let records) = change else { return nil }
        return records
    }
}
