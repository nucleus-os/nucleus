import Foundation
import Synchronization
import Testing

@testable import NucleusSessionProtocol

#if os(Linux)
import Glibc
#else
import Darwin
#endif

@Suite("Platform service channel")
struct PlatformServiceChannelTests {
    @Test func clipboardUpdatesEnforceIdentityGenerationAndBounds() throws {
        let update = try PlatformClipboardUpdate(
            sourceID: "android",
            generation: 1,
            text: "hello")
        #expect(update.mimeType == PlatformClipboardUpdate.plainTextMIMEType)

        #expect(throws: PlatformServiceChannelFailure.invalidClipboardUpdate) {
            try PlatformClipboardUpdate(
                sourceID: "android",
                generation: 0,
                text: "hello")
        }
        #expect(throws: PlatformServiceChannelFailure.invalidClipboardUpdate) {
            try PlatformClipboardUpdate(
                sourceID: "android",
                generation: 1,
                mimeType: "text/html",
                text: "hello")
        }
        #expect(throws: PlatformServiceChannelFailure.invalidClipboardUpdate) {
            try PlatformClipboardUpdate(
                sourceID: "android",
                generation: 1,
                text: String(
                    repeating: "x",
                    count: PlatformClipboardUpdate.maximumTextBytes + 1))
        }
    }

    @Test func serverReplaysClipboardAndReceivesCommands() async throws {
        let root = try makeTestRuntimeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let server = try PlatformServicePublicationServer(
            providerID: "android",
            sessionRuntimeDirectory: root,
            expectedUserID: getuid())
        let initial = try PlatformClipboardUpdate(
            sourceID: "android",
            generation: 4,
            text: "from Android")
        try server.publish(.clipboard(initial))
        let commands = Mutex<[PlatformServiceCommand]>([])
        let serverTask = Task {
            try await server.run { command in
                commands.withLock { $0.append(command) }
            }
        }

        let client = try PlatformServiceClientChannel(
            connecting: server.socket,
            expectedProviderID: "android",
            expectedUserID: getuid())
        #expect(try client.receive() == nil)
        #expect(try client.receive() == .clipboard(initial))
        #expect(try client.receive() == .notificationsReplace([]))

        let command = try PlatformClipboardUpdate(
            sourceID: "shell",
            generation: 9,
            text: "from native")
        try client.send(.clipboard(command))
        for _ in 0..<100 {
            guard commands.withLock({ $0.isEmpty }) else { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(commands.withLock { $0 } == [.clipboard(command)])

        serverTask.cancel()
        _ = try? await serverTask.value
    }

    @Test func notificationStateReplaysAndCommandsRoundTrip() async throws {
        let root = try makeTestRuntimeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let server = try PlatformServicePublicationServer(
            providerID: "android",
            sessionRuntimeDirectory: root,
            expectedUserID: getuid())
        let notification = try PlatformNotification(
            sourceID: "android",
            id: "key",
            applicationID: "org.example",
            applicationName: "Example",
            title: "Title",
            body: "Body",
            hasDefaultAction: true,
            actions: [
                try PlatformNotificationAction(id: "reply", title: "Reply")
            ])
        try server.publish(.notificationUpsert(notification))
        let commands = Mutex<[PlatformServiceCommand]>([])
        let serverTask = Task {
            try await server.run { command in
                commands.withLock { $0.append(command) }
            }
        }
        defer { serverTask.cancel() }

        let client = try PlatformServiceClientChannel(
            connecting: server.socket,
            expectedProviderID: "android",
            expectedUserID: getuid())
        #expect(try client.receive() == nil)
        #expect(try client.receive() == .notificationsReplace([notification]))
        let activation = try PlatformNotificationActivation(
            notificationID: "key",
            actionID: "reply",
            activationToken: "token")
        try client.send(.activateNotification(activation))
        for _ in 0..<100 {
            guard commands.withLock({ $0.isEmpty }) else { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(commands.withLock { $0 } == [.activateNotification(activation)])
    }

    @Test func notificationReplayStateCannotExceedOnePacket() throws {
        let root = try makeTestRuntimeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let server = try PlatformServicePublicationServer(
            providerID: "android",
            sessionRuntimeDirectory: root,
            expectedUserID: getuid())
        for index in 0..<3 {
            try server.publish(
                .notificationUpsert(
                    try notification(
                        id: String(index),
                        body: String(repeating: "x", count: 64 * 1_024))))
        }
        #expect(throws: PlatformServiceChannelFailure.oversizedMessage) {
            try server.publish(
                .notificationUpsert(
                    try notification(
                        id: "oversized",
                        body: String(repeating: "x", count: 64 * 1_024))))
        }
    }

    private func notification(
        id: String,
        body: String
    ) throws -> PlatformNotification {
        try PlatformNotification(
            sourceID: "android",
            id: id,
            applicationID: "org.example",
            applicationName: "Example",
            title: "",
            body: body)
    }
}
