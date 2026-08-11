import Foundation
import NucleusAndroidRuntimeCore
import NucleusIPCTransport

package enum AndroidPresentationControlOperation: String, Codable, Sendable {
    case create
    case close
    case activate
    case observe
}

package struct AndroidPresentationControlRequest:
    Codable, Equatable, Sendable
{
    package let operation: AndroidPresentationControlOperation
    package let presentationID: UInt64?
    package let appID: String?
    package let title: String?
    package let width: UInt32?
    package let height: UInt32?
    package let activationToken: String?

    package static func create(
        appID: String,
        title: String,
        width: UInt32,
        height: UInt32,
        activationToken: String? = nil
    ) -> Self {
        Self(
            operation: .create,
            presentationID: nil,
            appID: appID,
            title: title,
            width: width,
            height: height,
            activationToken: activationToken)
    }

    package static func close(presentationID: UInt64) -> Self {
        Self(
            operation: .close,
            presentationID: presentationID,
            appID: nil,
            title: nil,
            width: nil,
            height: nil,
            activationToken: nil)
    }

    package static func activate(
        presentationID: UInt64,
        token: String
    ) -> Self {
        Self(
            operation: .activate,
            presentationID: presentationID,
            appID: nil,
            title: nil,
            width: nil,
            height: nil,
            activationToken: token)
    }

    package static var observe: Self {
        Self(
            operation: .observe,
            presentationID: nil,
            appID: nil,
            title: nil,
            width: nil,
            height: nil,
            activationToken: nil)
    }

    package func validate() throws {
        switch operation {
        case .create:
            guard presentationID == nil,
                let appID,
                let title,
                !appID.isEmpty,
                !title.isEmpty,
                appID.utf8.count <= 512,
                title.utf8.count <= 1_024,
                !appID.contains("\0"),
                !title.contains("\0"),
                let width,
                let height,
                width > 0,
                height > 0,
                width <= 16_384,
                height <= 16_384,
                validActivationToken
            else {
                throw AndroidRuntimeFailure(
                    "invalid Android presentation create request")
            }
        case .close:
            guard let presentationID,
                presentationID > 0,
                appID == nil,
                title == nil,
                width == nil,
                height == nil,
                activationToken == nil
            else {
                throw AndroidRuntimeFailure(
                    "invalid Android presentation close request")
            }
        case .activate:
            guard let presentationID,
                presentationID > 0,
                appID == nil,
                title == nil,
                width == nil,
                height == nil,
                activationToken?.isEmpty == false,
                validActivationToken
            else {
                throw AndroidRuntimeFailure(
                    "invalid Android presentation activation request")
            }
        case .observe:
            guard presentationID == nil,
                appID == nil,
                title == nil,
                width == nil,
                height == nil,
                activationToken == nil
            else {
                throw AndroidRuntimeFailure(
                    "invalid Android presentation observation request")
            }
        }
    }

    private var validActivationToken: Bool {
        activationToken.map {
            !$0.isEmpty && $0.utf8.count <= 4_096 && !$0.contains("\0")
        } ?? true
    }
}

package enum AndroidPresentationEventKind: String, Codable, Sendable {
    case ready
    case closed
}

package struct AndroidPresentationEvent: Codable, Equatable, Sendable {
    package let kind: AndroidPresentationEventKind
    package let presentationID: UInt64?

    package static let ready = Self(kind: .ready, presentationID: nil)

    package static func closed(presentationID: UInt64) -> Self {
        Self(kind: .closed, presentationID: presentationID)
    }

    package func validate() throws {
        switch kind {
        case .ready:
            guard presentationID == nil else {
                throw AndroidRuntimeFailure(
                    "invalid Android presentation observer readiness")
            }
        case .closed:
            guard let presentationID, presentationID > 0 else {
                throw AndroidRuntimeFailure(
                    "invalid Android presentation closure event")
            }
        }
    }
}

package struct AndroidPresentationControlReply:
    Codable, Equatable, Sendable
{
    package let presentationID: UInt64

    package init(presentationID: UInt64) {
        self.presentationID = presentationID
    }
}

package final class AndroidPresentationControlConnection:
    @unchecked Sendable
{
    package static let maximumMessageBytes = 8 * 1_024

    private let connection: PacketConnection

    package var fileDescriptor: Int32 { connection.fileDescriptor }

    fileprivate init(_ connection: PacketConnection) {
        self.connection = connection
    }

    package static func connect(
        socketPath: String
    ) throws -> AndroidPresentationControlConnection {
        AndroidPresentationControlConnection(
            try PacketConnection.connect(path: socketPath))
    }

    package static func socketPair() throws
        -> (
            AndroidPresentationControlConnection,
            AndroidPresentationControlConnection
        )
    {
        let pair = try PacketConnection.socketPair()
        return (
            AndroidPresentationControlConnection(pair.0),
            AndroidPresentationControlConnection(pair.1)
        )
    }

    package func send(
        _ request: AndroidPresentationControlRequest
    ) throws {
        try request.validate()
        try encodeAndSend(request)
    }

    package func receiveRequest() throws
        -> AndroidPresentationControlRequest
    {
        let request: AndroidPresentationControlRequest = try receive()
        try request.validate()
        return request
    }

    package func send(
        _ reply: AndroidPresentationControlReply
    ) throws {
        guard reply.presentationID > 0 else {
            throw AndroidRuntimeFailure(
                "invalid Android presentation control reply")
        }
        try encodeAndSend(reply)
    }

    package func receiveReply() throws
        -> AndroidPresentationControlReply
    {
        let reply: AndroidPresentationControlReply = try receive()
        guard reply.presentationID > 0 else {
            throw AndroidRuntimeFailure(
                "invalid Android presentation control reply")
        }
        return reply
    }

    package func send(_ event: AndroidPresentationEvent) throws {
        try event.validate()
        try encodeAndSend(event)
    }

    package func receiveEvent() throws -> AndroidPresentationEvent {
        let event: AndroidPresentationEvent = try receive()
        try event.validate()
        return event
    }

    private func encodeAndSend<Value: Encodable>(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(value)
        guard bytes.count <= Self.maximumMessageBytes else {
            throw AndroidRuntimeFailure(
                "Android presentation control packet is oversized")
        }
        try connection.send(bytes)
    }

    private func receive<Value: Decodable>() throws -> Value {
        let packet = try connection.receive(
            maximumBytes: Self.maximumMessageBytes,
            maximumDescriptors: 0)
        guard packet.descriptors.isEmpty else {
            throw AndroidRuntimeFailure(
                "Android presentation control packets cannot carry descriptors")
        }
        return try JSONDecoder().decode(Value.self, from: Data(packet.bytes))
    }
}

package final class AndroidPresentationControlListener:
    @unchecked Sendable
{
    private let listener: PacketListener

    package var fileDescriptor: Int32 { listener.fileDescriptor }

    package init(socketPath: String) throws {
        listener = try PacketListener(path: socketPath, mode: 0o600)
    }

    package func accept(
        expectedUserID: UInt32
    ) throws -> AndroidPresentationControlConnection {
        AndroidPresentationControlConnection(
            try listener.accept(expectedUserID: expectedUserID))
    }
}
