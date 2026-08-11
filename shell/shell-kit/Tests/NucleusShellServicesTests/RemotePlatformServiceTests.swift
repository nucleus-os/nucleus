import Foundation
import NucleusSessionProtocol
import NucleusUI
import Synchronization
import Testing

@testable import NucleusShellServices

#if os(Linux)
import Glibc
#else
import Darwin
#endif

@MainActor
@Suite("Remote platform services")
struct RemotePlatformServiceTests {
    @Test("clipboard state crosses the provider boundary in both directions")
    func clipboardRoundTrip() async throws {
        let runtime = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "nucleus-platform-service-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtime) }

        let server = try PlatformServicePublicationServer(
            providerID: "android",
            sessionRuntimeDirectory: runtime,
            expectedUserID: getuid())
        let commands = Mutex<[PlatformServiceCommand]>([])
        let serverTask = Task.detached {
            try await server.run { command in
                commands.withLock { $0.append(command) }
            }
        }
        defer { serverTask.cancel() }

        let adapter = InMemoryPasteboardAdapter(string: "native")
        let pasteboard = Pasteboard(adapter: adapter)
        let notifications = NotificationService()
        let service = try RemotePlatformService(
            providerID: "android",
            pasteboard: pasteboard,
            notifications: notifications,
            sessionRuntimeDirectory: runtime,
            expectedUserID: getuid())
        service.scan(nowNanoseconds: 1)
        #expect(service.pollDescriptor != nil)
        #expect(!service.process())
        #expect(service.process())
        #expect(notifications.notifications.isEmpty)

        service.nativeSelectionChanged()
        try await waitUntil {
            !commands.withLock { $0.isEmpty }
        }
        let expectedCommand = try PlatformClipboardUpdate(
            sourceID: "shell",
            generation: 1,
            text: "native")
        #expect(
            commands.withLock { $0 } == [
                .clipboard(expectedCommand)
            ])

        let android = try PlatformClipboardUpdate(
            sourceID: "android",
            generation: 7,
            text: "android")
        try server.publish(.clipboard(android))
        #expect(service.process())
        try await waitUntil { adapter.string == "android" }

        service.nativeSelectionChanged()
        try await Task.sleep(for: .milliseconds(20))
        #expect(commands.withLock { $0 }.count == 1)

        service.disconnect()
        try await waitUntil { adapter.string == nil }
    }

    @Test("notification state and actions cross the provider boundary")
    func notificationRoundTrip() async throws {
        let runtime = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "nucleus-platform-notification-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtime) }

        let server = try PlatformServicePublicationServer(
            providerID: "android",
            sessionRuntimeDirectory: runtime,
            expectedUserID: getuid())
        let notification = try PlatformNotification(
            sourceID: "android",
            id: "notification-key",
            applicationID: "org.example",
            applicationName: "Example",
            title: "Ready",
            body: "The operation completed.",
            hasDefaultAction: true,
            actions: [
                try PlatformNotificationAction(
                    id: "action:0",
                    title: "Open")
            ])
        try server.publish(.notificationUpsert(notification))
        let commands = Mutex<[PlatformServiceCommand]>([])
        let serverTask = Task.detached {
            try await server.run { command in
                commands.withLock { $0.append(command) }
            }
        }
        defer { serverTask.cancel() }

        let pasteboard = Pasteboard(adapter: InMemoryPasteboardAdapter())
        let notifications = NotificationService()
        let service = try RemotePlatformService(
            providerID: "android",
            pasteboard: pasteboard,
            notifications: notifications,
            sessionRuntimeDirectory: runtime,
            expectedUserID: getuid())
        service.scan(nowNanoseconds: 1)
        #expect(!service.process())
        #expect(service.process())
        let presented = try #require(notifications.notifications.first)
        #expect(presented.summary == "Ready")
        #expect(presented.actions.first?.title == "Open")

        notifications.activate(
            stableID: presented.id.stableID,
            actionID: "action:0",
            activationToken: "token")
        notifications.dismiss(stableID: presented.id.stableID)
        try await waitUntil {
            commands.withLock {
                $0.filter {
                    if case .clipboard = $0 { return false }
                    return true
                }.count == 2
            }
        }
        let activation = try PlatformNotificationActivation(
            notificationID: "notification-key",
            actionID: "action:0",
            activationToken: "token")
        #expect(
            commands.withLock {
                $0.filter {
                    if case .clipboard = $0 { return false }
                    return true
                }
            } == [
                .activateNotification(activation),
                .dismissNotification("notification-key"),
            ])
        #expect(notifications.notifications.isEmpty)

        try server.publish(.notificationUpsert(notification))
        #expect(service.process())
        #expect(notifications.notifications.count == 1)
        service.disconnect()
        #expect(notifications.notifications.isEmpty)
    }

    private func waitUntil(
        _ predicate: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("condition did not become true")
    }
}
