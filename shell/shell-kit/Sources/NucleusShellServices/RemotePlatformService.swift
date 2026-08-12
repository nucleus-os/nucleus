package import Foundation
internal import NucleusSessionProtocol
package import NucleusUI

#if os(Linux)
import Glibc
#else
import Darwin
#endif

@MainActor
package final class RemotePlatformService {
    package struct PollDescriptor: Sendable, Equatable {
        package var fileDescriptor: Int32
    }

    private let providerID: String
    private let socket: URL
    private let expectedUserID: UInt32
    private weak var pasteboard: Pasteboard?
    private weak var notifications: NotificationService?
    private var channel: PlatformServiceClientChannel?
    private var receivedHello = false
    private var nextScanNanoseconds: UInt64 = 0
    private var nextShellGeneration: UInt64 = 1
    private var lastAndroidGeneration: UInt64 = 0
    private var selectionReadGeneration: UInt64 = 0
    private var suppressedRemoteGeneration: UInt64?
    private var suppressedRemoteText: String?
    private var androidOwnsNativeSelection = false
    private var clipboardWriteTask: Task<Void, Never>?

    package init(
        providerID: String,
        pasteboard: Pasteboard,
        notifications: NotificationService,
        sessionRuntimeDirectory: URL,
        expectedUserID: UInt32 = getuid()
    ) throws {
        self.providerID = providerID
        self.pasteboard = pasteboard
        self.notifications = notifications
        self.expectedUserID = expectedUserID
        socket = try PlatformServiceEndpoint.socket(
            providerID: providerID,
            in: sessionRuntimeDirectory)
        notifications.attachSource(providerID) { [weak self] command in
            self?.sendNotificationCommand(command)
        }
    }

    package var pollDescriptor: PollDescriptor? {
        channel.map { PollDescriptor(fileDescriptor: $0.fileDescriptor) }
    }

    package func scan(nowNanoseconds: UInt64) {
        guard channel == nil, nowNanoseconds >= nextScanNanoseconds else {
            return
        }
        nextScanNanoseconds = nowNanoseconds &+ 250_000_000
        guard FileManager.default.fileExists(atPath: socket.path),
            let channel = try? PlatformServiceClientChannel(
                connecting: socket,
                expectedProviderID: providerID,
                expectedUserID: expectedUserID)
        else { return }
        self.channel = channel
        receivedHello = false
    }

    package func nanosecondsUntilScan(nowNanoseconds: UInt64) -> UInt64? {
        guard channel == nil else { return nil }
        return nextScanNanoseconds > nowNanoseconds
            ? nextScanNanoseconds - nowNanoseconds
            : 0
    }

    @discardableResult
    package func process() -> Bool {
        guard let channel else { return false }
        do {
            guard let publication = try channel.receive() else {
                guard !receivedHello else {
                    throw RemotePlatformServiceFailure.duplicateHello
                }
                receivedHello = true
                nativeSelectionChanged()
                return false
            }
            guard receivedHello else {
                throw RemotePlatformServiceFailure.publicationBeforeHello
            }
            switch publication {
            case .clipboard(let update):
                receiveClipboard(update)
            case .notificationsReplace(let replacement):
                notifications?.replace(
                    sourceID: providerID,
                    with: replacement.map(mapNotification))
            case .notificationUpsert(let notification):
                notifications?.upsert(mapNotification(notification))
            case .notificationRemove(let id):
                notifications?.remove(
                    ShellNotificationID(
                        sourceID: providerID,
                        notificationID: id))
            }
            return true
        } catch {
            disconnect()
            return true
        }
    }

    package func nativeSelectionChanged() {
        guard receivedHello, channel != nil, pasteboard != nil else { return }
        selectionReadGeneration &+= 1
        precondition(
            selectionReadGeneration != 0,
            "native clipboard read generation exhausted")
        let generation = selectionReadGeneration
        Task { @MainActor [weak self] in
            await self?.publishNativeSelection(readGeneration: generation)
        }
    }

    package func disconnect() {
        let shouldWithdraw = androidOwnsNativeSelection
        channel = nil
        receivedHello = false
        nextScanNanoseconds = 0
        suppressedRemoteGeneration = nil
        suppressedRemoteText = nil
        androidOwnsNativeSelection = false
        lastAndroidGeneration = 0
        notifications?.withdrawSource(providerID)
        clipboardWriteTask?.cancel()
        clipboardWriteTask = nil
        selectionReadGeneration &+= 1
        precondition(
            selectionReadGeneration != 0,
            "native clipboard read generation exhausted")
        if shouldWithdraw, let pasteboard {
            Task { @MainActor in
                try? await pasteboard.clear()
            }
        }
    }

    package func shutdown() {
        channel = nil
        receivedHello = false
        suppressedRemoteGeneration = nil
        suppressedRemoteText = nil
        androidOwnsNativeSelection = false
        notifications?.detachSource(providerID)
        clipboardWriteTask?.cancel()
        clipboardWriteTask = nil
        selectionReadGeneration &+= 1
        precondition(
            selectionReadGeneration != 0,
            "native clipboard read generation exhausted")
    }

    private func receiveClipboard(_ update: PlatformClipboardUpdate) {
        guard update.sourceID == providerID,
            update.generation > lastAndroidGeneration,
            let pasteboard
        else { return }
        lastAndroidGeneration = update.generation
        suppressedRemoteGeneration = update.generation
        suppressedRemoteText = update.text
        androidOwnsNativeSelection = true
        clipboardWriteTask?.cancel()
        clipboardWriteTask = Task { @MainActor [weak self, weak pasteboard] in
            guard let self, let pasteboard else { return }
            guard suppressedRemoteGeneration == update.generation else {
                return
            }
            do {
                if let text = update.text {
                    try await pasteboard.writeString(text)
                } else {
                    try await pasteboard.clear()
                }
            } catch {
                if suppressedRemoteGeneration == update.generation {
                    suppressedRemoteGeneration = nil
                    suppressedRemoteText = nil
                    androidOwnsNativeSelection = false
                }
            }
            if suppressedRemoteGeneration == update.generation {
                clipboardWriteTask = nil
            }
        }
    }

    private func publishNativeSelection(readGeneration: UInt64) async {
        guard readGeneration == selectionReadGeneration,
            let pasteboard,
            let channel,
            receivedHello
        else { return }
        let text: String?
        do {
            text = try await pasteboard.readString()
        } catch {
            return
        }
        guard readGeneration == selectionReadGeneration else { return }
        if suppressedRemoteGeneration != nil,
            suppressedRemoteText == text
        {
            suppressedRemoteGeneration = nil
            suppressedRemoteText = nil
            return
        }
        suppressedRemoteGeneration = nil
        suppressedRemoteText = nil
        androidOwnsNativeSelection = false
        let generation = nextShellGeneration
        nextShellGeneration &+= 1
        precondition(
            nextShellGeneration != 0,
            "shell clipboard generation exhausted")
        do {
            try channel.send(
                .clipboard(
                    PlatformClipboardUpdate(
                        sourceID: "shell",
                        generation: generation,
                        text: text)))
        } catch {
            disconnect()
        }
    }

    private func sendNotificationCommand(
        _ command: ShellNotificationSourceCommand
    ) {
        guard let channel, receivedHello else { return }
        do {
            switch command {
            case .dismiss(let notificationID):
                try channel.send(.dismissNotification(notificationID))
            case .activate(
                let notificationID,
                let actionID,
                let activationToken
            ):
                try channel.send(
                    .activateNotification(
                        PlatformNotificationActivation(
                            notificationID: notificationID,
                            actionID: actionID,
                            activationToken: activationToken)))
            }
        } catch {
            disconnect()
        }
    }

    private func mapNotification(
        _ notification: PlatformNotification
    ) -> ShellNotification {
        let urgency: ShellNotificationUrgency
        switch notification.urgency {
        case .low: urgency = .low
        case .normal: urgency = .normal
        case .critical: urgency = .critical
        }
        return ShellNotification(
            id: ShellNotificationID(
                sourceID: providerID,
                notificationID: notification.id),
            applicationID: notification.applicationID,
            applicationName: notification.applicationName,
            summary: notification.title,
            body: notification.body,
            iconDigest: notification.iconDigest,
            urgency: urgency,
            progress: notification.progress.map {
                ShellNotificationProgress(
                    value: $0.value,
                    total: $0.total)
            },
            hasDefaultAction: notification.hasDefaultAction,
            actions: notification.actions.map {
                ShellNotificationAction(id: $0.id, title: $0.title)
            })
    }
}

private enum RemotePlatformServiceFailure: Error {
    case duplicateHello
    case publicationBeforeHello
}
