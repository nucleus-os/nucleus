import Foundation
internal import NucleusIPCTransport
import Synchronization

#if os(Linux)
import Glibc
#else
import Darwin
#endif

public enum ApplicationProviderEndpoint {
    public static let directoryName = "application-providers"

    public static func directory(in sessionRuntimeDirectory: URL) -> URL {
        sessionRuntimeDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    public static func socket(
        providerID: String,
        in sessionRuntimeDirectory: URL
    ) throws -> URL {
        guard validProviderID(providerID) else {
            throw ApplicationProviderChannelFailure.invalidProviderID(providerID)
        }
        return directory(in: sessionRuntimeDirectory)
            .appendingPathComponent("\(providerID).sock")
    }

    public static func validProviderID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && value.utf8.allSatisfy { byte in
                byte >= Character("a").asciiValue!
                    && byte <= Character("z").asciiValue!
                    || byte >= Character("0").asciiValue!
                        && byte <= Character("9").asciiValue!
                    || byte == Character(".").asciiValue!
                    || byte == Character("-").asciiValue!
            }
    }
}

public enum ApplicationProviderIcon: Codable, Equatable, Sendable {
    case theme(name: String)
    case rasterAsset(digest: String, path: String)
}

public struct ApplicationProviderRecord: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var icon: ApplicationProviderIcon?
    public var categories: [String]
    public var launchID: String

    public init(
        id: String,
        name: String,
        icon: ApplicationProviderIcon? = nil,
        categories: [String] = [],
        launchID: String
    ) throws {
        self.id = id
        self.name = name
        self.icon = icon
        self.categories = categories
        self.launchID = launchID
        try validate()
    }

    public func validate() throws {
        guard validField(id, maximumBytes: 4_096),
            validField(name, maximumBytes: 4_096),
            validField(launchID, maximumBytes: 4_096),
            categories.count <= 64,
            categories.allSatisfy({ validField($0, maximumBytes: 256) })
        else {
            throw ApplicationProviderChannelFailure.invalidRecord
        }
        switch icon {
        case .none:
            break
        case .theme(let name):
            guard validField(name, maximumBytes: 4_096) else {
                throw ApplicationProviderChannelFailure.invalidRecord
            }
        case .rasterAsset(let digest, let path):
            guard digest.count == 64,
                digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                path.hasPrefix("/"),
                validField(path, maximumBytes: 4_096)
            else {
                throw ApplicationProviderChannelFailure.invalidRecord
            }
        }
    }
}

public enum ApplicationProviderCatalogChange: Codable, Equatable, Sendable {
    case replace([ApplicationProviderRecord])
    case upsert(ApplicationProviderRecord)
    case remove(String)
}

public enum ApplicationProviderChannelFailure: Error, Equatable, Sendable {
    case invalidProviderID(String)
    case invalidRecord
    case invalidMessage
    case oversizedCatalog
    case unexpectedProvider(expected: String, actual: String)
}

private enum ApplicationProviderMessageKind: String, Codable, Sendable {
    case hello
    case replace
    case upsert
    case remove
}

private struct ApplicationProviderMessage: Codable, Sendable {
    var kind: ApplicationProviderMessageKind
    var providerID: String
    var records: [ApplicationProviderRecord]?
    var record: ApplicationProviderRecord?
    var applicationID: String?

    init(
        kind: ApplicationProviderMessageKind,
        providerID: String,
        records: [ApplicationProviderRecord]? = nil,
        record: ApplicationProviderRecord? = nil,
        applicationID: String? = nil
    ) {
        self.kind = kind
        self.providerID = providerID
        self.records = records
        self.record = record
        self.applicationID = applicationID
    }

    func validatedChange() throws -> ApplicationProviderCatalogChange? {
        guard ApplicationProviderEndpoint.validProviderID(providerID) else {
            throw ApplicationProviderChannelFailure.invalidProviderID(providerID)
        }
        switch kind {
        case .hello:
            guard records == nil, record == nil, applicationID == nil else {
                throw ApplicationProviderChannelFailure.invalidMessage
            }
            return nil
        case .replace:
            guard let records, record == nil, applicationID == nil,
                records.count <= 16_384
            else {
                throw ApplicationProviderChannelFailure.invalidMessage
            }
            try records.forEach { try $0.validate() }
            guard Set(records.map(\.id)).count == records.count else {
                throw ApplicationProviderChannelFailure.invalidRecord
            }
            return .replace(records)
        case .upsert:
            guard records == nil, let record, applicationID == nil else {
                throw ApplicationProviderChannelFailure.invalidMessage
            }
            try record.validate()
            return .upsert(record)
        case .remove:
            guard records == nil, record == nil, let applicationID,
                validField(applicationID, maximumBytes: 4_096)
            else {
                throw ApplicationProviderChannelFailure.invalidMessage
            }
            return .remove(applicationID)
        }
    }
}

public final class ApplicationProviderClientChannel: @unchecked Sendable {
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
            throw ApplicationProviderChannelFailure.invalidProviderID(expectedProviderID)
        }
        let connection = try PacketConnection.connect(path: socket.path)
        try connection.requirePeer(userID: expectedUserID)
        self.connection = connection
        self.expectedProviderID = expectedProviderID
    }

    public func receive() throws -> ApplicationProviderCatalogChange? {
        let packet = try connection.receive(
            maximumBytes: Self.maximumMessageBytes,
            maximumDescriptors: 0)
        guard packet.descriptors.isEmpty else {
            throw ApplicationProviderChannelFailure.invalidMessage
        }
        let message = try JSONDecoder().decode(
            ApplicationProviderMessage.self,
            from: Data(packet.bytes))
        guard message.providerID == expectedProviderID else {
            throw ApplicationProviderChannelFailure.unexpectedProvider(
                expected: expectedProviderID,
                actual: message.providerID)
        }
        return try message.validatedChange()
    }
}

public final class ApplicationProviderPublicationServer: @unchecked Sendable {
    public static let maximumMessageBytes = ApplicationProviderClientChannel.maximumMessageBytes

    private struct State: Sendable {
        var connection: PacketConnection?
        var records: [String: ApplicationProviderRecord] = [:]
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
        self.providerID = providerID
        self.expectedUserID = expectedUserID
        socket = try ApplicationProviderEndpoint.socket(
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

    public func publish(_ change: ApplicationProviderCatalogChange) throws {
        try state.withLock { state in
            switch change {
            case .replace(let records):
                guard records.count <= 16_384 else {
                    throw ApplicationProviderChannelFailure.oversizedCatalog
                }
                try records.forEach { try $0.validate() }
                guard Set(records.map(\.id)).count == records.count else {
                    throw ApplicationProviderChannelFailure.invalidRecord
                }
                state.records = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
            case .upsert(let record):
                try record.validate()
                state.records[record.id] = record
            case .remove(let id):
                state.records.removeValue(forKey: id)
            }
            guard let connection = state.connection else { return }
            do {
                try send(change, over: connection)
            } catch {
                state.connection = nil
                throw error
            }
        }
    }

    public func run() async throws {
        while true {
            try Task.checkCancellation()
            var descriptor = pollfd(
                fd: listener.fileDescriptor,
                events: Int16(POLLIN),
                revents: 0)
            let result = unsafe poll(&descriptor, 1, 250)
            if result < 0 {
                if errno == EINTR { continue }
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            guard result > 0 else { continue }
            let connection: PacketConnection
            do {
                connection = try listener.accept(expectedUserID: expectedUserID)
            } catch let error as IPCTransportError {
                if case .systemCall(_, let code) = error,
                    code == EAGAIN || code == EWOULDBLOCK
                {
                    continue
                }
                throw error
            }
            try state.withLock { state in
                try sendMessage(
                    ApplicationProviderMessage(
                        kind: .hello,
                        providerID: providerID),
                    over: connection)
                let records = state.records.values.sorted { $0.id < $1.id }
                try send(.replace(records), over: connection)
                state.connection = connection
            }
        }
    }

    private func send(
        _ change: ApplicationProviderCatalogChange,
        over connection: PacketConnection
    ) throws {
        let message: ApplicationProviderMessage
        switch change {
        case .replace(let records):
            message = ApplicationProviderMessage(
                kind: .replace,
                providerID: providerID,
                records: records)
        case .upsert(let record):
            message = ApplicationProviderMessage(
                kind: .upsert,
                providerID: providerID,
                record: record)
        case .remove(let id):
            message = ApplicationProviderMessage(
                kind: .remove,
                providerID: providerID,
                applicationID: id)
        }
        try sendMessage(message, over: connection)
    }

    private func sendMessage(
        _ message: ApplicationProviderMessage,
        over connection: PacketConnection
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(message)
        guard bytes.count <= Self.maximumMessageBytes else {
            throw ApplicationProviderChannelFailure.oversizedCatalog
        }
        try connection.send(bytes)
    }
}

private func validField(_ value: String, maximumBytes: Int) -> Bool {
    !value.isEmpty && value.utf8.count <= maximumBytes && !value.contains("\0")
}
