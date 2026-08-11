import Foundation
internal import NucleusIPCTransport
import Synchronization

#if os(Linux)
import Glibc
#else
import Darwin
#endif

public enum PlatformServiceEndpoint {
    public static let directoryName = "platform-services"

    public static func directory(in sessionRuntimeDirectory: URL) -> URL {
        sessionRuntimeDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    public static func socket(
        providerID: String,
        in sessionRuntimeDirectory: URL
    ) throws -> URL {
        guard ApplicationProviderEndpoint.validProviderID(providerID) else {
            throw PlatformServiceChannelFailure.invalidProviderID(providerID)
        }
        return directory(in: sessionRuntimeDirectory)
            .appendingPathComponent("\(providerID).sock")
    }
}

public struct PlatformClipboardUpdate: Codable, Equatable, Sendable {
    public static let maximumTextBytes = 128 * 1_024
    public static let plainTextMIMEType = "text/plain;charset=utf-8"

    public var sourceID: String
    public var generation: UInt64
    public var mimeType: String
    public var text: String?

    public init(
        sourceID: String,
        generation: UInt64,
        mimeType: String = Self.plainTextMIMEType,
        text: String?
    ) throws {
        self.sourceID = sourceID
        self.generation = generation
        self.mimeType = mimeType
        self.text = text
        try validate()
    }

    public func validate() throws {
        guard ApplicationProviderEndpoint.validProviderID(sourceID),
            generation > 0,
            mimeType == Self.plainTextMIMEType,
            text?.utf8.count ?? 0 <= Self.maximumTextBytes,
            !(text?.contains("\0") ?? false)
        else {
            throw PlatformServiceChannelFailure.invalidClipboardUpdate
        }
    }
}

public enum PlatformNotificationUrgency: String, Codable, Equatable, Sendable {
    case low
    case normal
    case critical
}

public struct PlatformNotificationProgress: Codable, Equatable, Sendable {
    public var value: UInt64
    public var total: UInt64

    public init(value: UInt64, total: UInt64) throws {
        self.value = value
        self.total = total
        try validate()
    }

    public func validate() throws {
        guard total > 0, value <= total else {
            throw PlatformServiceChannelFailure.invalidNotification
        }
    }
}

public struct PlatformNotificationAction: Codable, Equatable, Sendable {
    public var id: String
    public var title: String

    public init(id: String, title: String) throws {
        self.id = id
        self.title = title
        try validate()
    }

    public func validate() throws {
        guard validPlatformServiceField(id, maximumBytes: 1_024),
            validPlatformServiceField(title, maximumBytes: 4_096)
        else {
            throw PlatformServiceChannelFailure.invalidNotification
        }
    }
}

public struct PlatformNotification: Codable, Equatable, Sendable {
    public var sourceID: String
    public var id: String
    public var applicationID: String
    public var applicationName: String
    public var title: String
    public var body: String
    public var iconDigest: String?
    public var urgency: PlatformNotificationUrgency
    public var progress: PlatformNotificationProgress?
    public var hasDefaultAction: Bool
    public var actions: [PlatformNotificationAction]

    public init(
        sourceID: String,
        id: String,
        applicationID: String,
        applicationName: String,
        title: String,
        body: String,
        iconDigest: String? = nil,
        urgency: PlatformNotificationUrgency = .normal,
        progress: PlatformNotificationProgress? = nil,
        hasDefaultAction: Bool = false,
        actions: [PlatformNotificationAction] = []
    ) throws {
        self.sourceID = sourceID
        self.id = id
        self.applicationID = applicationID
        self.applicationName = applicationName
        self.title = title
        self.body = body
        self.iconDigest = iconDigest
        self.urgency = urgency
        self.progress = progress
        self.hasDefaultAction = hasDefaultAction
        self.actions = actions
        try validate()
    }

    public func validate() throws {
        guard ApplicationProviderEndpoint.validProviderID(sourceID),
            validPlatformServiceField(id, maximumBytes: 4_096),
            validPlatformServiceField(applicationID, maximumBytes: 4_096),
            validPlatformServiceField(applicationName, maximumBytes: 4_096),
            validPlatformServiceText(title, maximumBytes: 16_384),
            validPlatformServiceText(body, maximumBytes: 64 * 1_024),
            actions.count <= 16,
            Set(actions.map(\.id)).count == actions.count,
            iconDigest.map(validPlatformServiceDigest) ?? true
        else {
            throw PlatformServiceChannelFailure.invalidNotification
        }
        try progress?.validate()
        try actions.forEach { try $0.validate() }
    }
}

public struct PlatformNotificationActivation: Codable, Equatable, Sendable {
    public var notificationID: String
    public var actionID: String?
    public var activationToken: String?

    public init(
        notificationID: String,
        actionID: String? = nil,
        activationToken: String? = nil
    ) throws {
        self.notificationID = notificationID
        self.actionID = actionID
        self.activationToken = activationToken
        try validate()
    }

    public func validate() throws {
        guard validPlatformServiceField(notificationID, maximumBytes: 4_096),
            actionID.map({ validPlatformServiceField($0, maximumBytes: 1_024) })
                ?? true,
            activationToken.map({
                validPlatformServiceField($0, maximumBytes: 4_096)
            }) ?? true
        else {
            throw PlatformServiceChannelFailure.invalidNotificationCommand
        }
    }
}

public enum PlatformServicePublication: Codable, Equatable, Sendable {
    case clipboard(PlatformClipboardUpdate)
    case notificationsReplace([PlatformNotification])
    case notificationUpsert(PlatformNotification)
    case notificationRemove(String)

    public func validate() throws {
        switch self {
        case .clipboard(let update):
            try update.validate()
        case .notificationsReplace(let notifications):
            guard notifications.count <= 4_096,
                Set(notifications.map(\.id)).count == notifications.count
            else {
                throw PlatformServiceChannelFailure.invalidNotification
            }
            try notifications.forEach { try $0.validate() }
        case .notificationUpsert(let notification):
            try notification.validate()
        case .notificationRemove(let id):
            guard validPlatformServiceField(id, maximumBytes: 4_096) else {
                throw PlatformServiceChannelFailure.invalidNotification
            }
        }
    }
}

public enum PlatformServiceCommand: Codable, Equatable, Sendable {
    case clipboard(PlatformClipboardUpdate)
    case dismissNotification(String)
    case activateNotification(PlatformNotificationActivation)

    public func validate() throws {
        switch self {
        case .clipboard(let update):
            try update.validate()
        case .dismissNotification(let id):
            guard validPlatformServiceField(id, maximumBytes: 4_096) else {
                throw PlatformServiceChannelFailure.invalidNotificationCommand
            }
        case .activateNotification(let activation):
            try activation.validate()
        }
    }
}

public enum PlatformServiceChannelFailure: Error, Equatable, Sendable {
    case invalidProviderID(String)
    case invalidClipboardUpdate
    case invalidNotification
    case invalidNotificationCommand
    case invalidMessage
    case oversizedMessage
    case unexpectedProvider(expected: String, actual: String)
}

private enum PlatformServiceMessageKind: String, Codable, Sendable {
    case hello
    case publication
    case command
}

private struct PlatformServiceMessage: Codable, Sendable {
    var kind: PlatformServiceMessageKind
    var providerID: String
    var publication: PlatformServicePublication?
    var command: PlatformServiceCommand?

    func validate(expectedProviderID: String) throws {
        guard providerID == expectedProviderID else {
            throw PlatformServiceChannelFailure.unexpectedProvider(
                expected: expectedProviderID,
                actual: providerID)
        }
        switch kind {
        case .hello:
            guard publication == nil, command == nil else {
                throw PlatformServiceChannelFailure.invalidMessage
            }
        case .publication:
            guard let publication, command == nil else {
                throw PlatformServiceChannelFailure.invalidMessage
            }
            try publication.validate()
            guard publication.belongs(to: providerID) else {
                throw PlatformServiceChannelFailure.invalidMessage
            }
        case .command:
            guard publication == nil, let command else {
                throw PlatformServiceChannelFailure.invalidMessage
            }
            try command.validate()
        }
    }
}

public final class PlatformServiceClientChannel: @unchecked Sendable {
    public static let maximumMessageBytes = 256 * 1_024

    private let connection: PacketConnection
    public let expectedProviderID: String

    public var fileDescriptor: Int32 { connection.fileDescriptor }

    public init(
        connecting socket: URL,
        expectedProviderID: String,
        expectedUserID: UInt32
    ) throws {
        guard ApplicationProviderEndpoint.validProviderID(expectedProviderID) else {
            throw PlatformServiceChannelFailure.invalidProviderID(expectedProviderID)
        }
        let connection = try PacketConnection.connect(path: socket.path)
        try connection.requirePeer(userID: expectedUserID)
        self.connection = connection
        self.expectedProviderID = expectedProviderID
    }

    public func receive() throws -> PlatformServicePublication? {
        let message = try receivePlatformServiceMessage(from: connection)
        try message.validate(expectedProviderID: expectedProviderID)
        switch message.kind {
        case .hello:
            return nil
        case .publication:
            return message.publication
        case .command:
            throw PlatformServiceChannelFailure.invalidMessage
        }
    }

    public func send(_ command: PlatformServiceCommand) throws {
        try command.validate()
        guard command.isValidShellCommand else {
            throw PlatformServiceChannelFailure.invalidMessage
        }
        try sendPlatformServiceMessage(
            PlatformServiceMessage(
                kind: .command,
                providerID: expectedProviderID,
                command: command),
            over: connection)
    }
}

public final class PlatformServicePublicationServer: @unchecked Sendable {
    private struct State: Sendable {
        var connection: PacketConnection?
        var clipboard: PlatformClipboardUpdate?
        var notifications: [String: PlatformNotification] = [:]
    }

    public let providerID: String
    public let socket: URL

    private let listener: PacketListener
    private let expectedUserID: UInt32
    private let state = Mutex(State())

    public init(
        providerID: String,
        sessionRuntimeDirectory: URL,
        expectedUserID: UInt32
    ) throws {
        guard ApplicationProviderEndpoint.validProviderID(providerID) else {
            throw PlatformServiceChannelFailure.invalidProviderID(providerID)
        }
        self.providerID = providerID
        self.expectedUserID = expectedUserID
        socket = try PlatformServiceEndpoint.socket(
            providerID: providerID,
            in: sessionRuntimeDirectory)
        let directory = socket.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard unsafe chmod(directory.path, 0o700) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        listener = try PacketListener(
            path: socket.path,
            mode: 0o600,
            nonblocking: true)
    }

    public func publish(_ publication: PlatformServicePublication) throws {
        try publication.validate()
        guard publication.belongs(to: providerID) else {
            throw PlatformServiceChannelFailure.invalidMessage
        }
        let message = PlatformServiceMessage(
            kind: .publication,
            providerID: providerID,
            publication: publication)
        let bytes = try encodePlatformServiceMessage(message)
        try state.withLock { state in
            if case .clipboard(let update) = publication {
                state.clipboard = update
            }
            switch publication {
            case .clipboard:
                break
            case .notificationsReplace(let notifications):
                let replacement = Dictionary(
                    uniqueKeysWithValues: notifications.map { ($0.id, $0) })
                try validateNotificationReplay(replacement)
                state.notifications = replacement
            case .notificationUpsert(let notification):
                var replacement = state.notifications
                replacement[notification.id] = notification
                try validateNotificationReplay(replacement)
                state.notifications = replacement
            case .notificationRemove(let id):
                state.notifications.removeValue(forKey: id)
            }
            guard let connection = state.connection else { return }
            do {
                try connection.send(bytes)
            } catch {
                state.connection = nil
                throw error
            }
        }
    }

    private func validateNotificationReplay(
        _ notifications: [String: PlatformNotification]
    ) throws {
        _ = try encodePlatformServiceMessage(
            PlatformServiceMessage(
                kind: .publication,
                providerID: providerID,
                publication: .notificationsReplace(
                    notifications.values.sorted { $0.id < $1.id })))
    }

    public func run(
        onCommand:
            @escaping @Sendable (
                PlatformServiceCommand
            ) async -> Void
    ) async throws {
        while true {
            try Task.checkCancellation()
            let connection = state.withLock(\.connection)
            var descriptors = [
                pollfd(
                    fd: listener.fileDescriptor,
                    events: Int16(POLLIN),
                    revents: 0)
            ]
            if let connection {
                descriptors.append(
                    pollfd(
                        fd: connection.fileDescriptor,
                        events: Int16(POLLIN | POLLERR | POLLHUP),
                        revents: 0))
            }
            let result = unsafe poll(&descriptors, nfds_t(descriptors.count), 250)
            if result < 0 {
                if errno == EINTR { continue }
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            guard result > 0 else { continue }
            if descriptors[0].revents & Int16(POLLIN) != 0 {
                acceptConnection()
            }
            guard descriptors.count == 2 else { continue }
            guard
                state.withLock({ $0.connection === connection })
            else { continue }
            let returned = descriptors[1].revents
            if returned & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                state.withLock { state in
                    if state.connection === connection {
                        state.connection = nil
                    }
                }
                continue
            }
            guard returned & Int16(POLLIN) != 0, let connection else {
                continue
            }
            do {
                let message = try receivePlatformServiceMessage(from: connection)
                try message.validate(expectedProviderID: providerID)
                guard message.kind == .command, let command = message.command else {
                    throw PlatformServiceChannelFailure.invalidMessage
                }
                await onCommand(command)
            } catch {
                state.withLock { state in
                    if state.connection === connection {
                        state.connection = nil
                    }
                }
            }
        }
    }

    private func acceptConnection() {
        let connection: PacketConnection
        do {
            connection = try listener.accept(expectedUserID: expectedUserID)
        } catch {
            return
        }
        do {
            try state.withLock { state in
                try sendPlatformServiceMessage(
                    PlatformServiceMessage(
                        kind: .hello,
                        providerID: providerID),
                    over: connection)
                if let clipboard = state.clipboard {
                    try sendPlatformServiceMessage(
                        PlatformServiceMessage(
                            kind: .publication,
                            providerID: providerID,
                            publication: .clipboard(clipboard)),
                        over: connection)
                }
                let notifications = state.notifications.values.sorted {
                    $0.id < $1.id
                }
                try sendPlatformServiceMessage(
                    PlatformServiceMessage(
                        kind: .publication,
                        providerID: providerID,
                        publication: .notificationsReplace(notifications)),
                    over: connection)
                state.connection = connection
            }
        } catch {
            return
        }
    }
}

private func validPlatformServiceField(
    _ value: String,
    maximumBytes: Int
) -> Bool {
    !value.isEmpty && value.utf8.count <= maximumBytes && !value.contains("\0")
}

private func validPlatformServiceText(
    _ value: String,
    maximumBytes: Int
) -> Bool {
    value.utf8.count <= maximumBytes && !value.contains("\0")
}

private func validPlatformServiceDigest(_ value: String) -> Bool {
    value.utf8.count == 64
        && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
}

extension PlatformServicePublication {
    fileprivate func belongs(to providerID: String) -> Bool {
        switch self {
        case .clipboard(let update):
            return update.sourceID == providerID
        case .notificationsReplace(let notifications):
            return notifications.allSatisfy { $0.sourceID == providerID }
        case .notificationUpsert(let notification):
            return notification.sourceID == providerID
        case .notificationRemove:
            return true
        }
    }
}

extension PlatformServiceCommand {
    fileprivate var isValidShellCommand: Bool {
        switch self {
        case .clipboard(let update):
            return update.sourceID == "shell"
        case .dismissNotification, .activateNotification:
            return true
        }
    }
}

private func sendPlatformServiceMessage(
    _ message: PlatformServiceMessage,
    over connection: PacketConnection
) throws {
    try connection.send(encodePlatformServiceMessage(message))
}

private func encodePlatformServiceMessage(
    _ message: PlatformServiceMessage
) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let bytes = try encoder.encode(message)
    guard bytes.count <= PlatformServiceClientChannel.maximumMessageBytes else {
        throw PlatformServiceChannelFailure.oversizedMessage
    }
    return bytes
}

private func receivePlatformServiceMessage(
    from connection: PacketConnection
) throws -> PlatformServiceMessage {
    let packet = try connection.receive(
        maximumBytes: PlatformServiceClientChannel.maximumMessageBytes,
        maximumDescriptors: 0)
    guard packet.descriptors.isEmpty else {
        throw PlatformServiceChannelFailure.invalidMessage
    }
    return try JSONDecoder().decode(
        PlatformServiceMessage.self,
        from: Data(packet.bytes))
}
