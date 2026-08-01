import Foundation
import Glibc
package import NucleusControlProtocol
import NucleusIPCTransport

package enum ControlSocket {
    package static let environmentVariable = "NUCLEUS_CONTROL_SOCKET"
    package static let elevatedCapabilityDescriptorArgument =
        "--nucleus-shell-control-capability-fd"

    package static func defaultPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let explicit = environment[environmentVariable], !explicit.isEmpty {
            return explicit
        }
        guard let runtimeDirectory = environment["XDG_RUNTIME_DIR"],
            !runtimeDirectory.isEmpty
        else { return nil }
        let sessionID =
            environment["NUCLEUS_SESSION_ID"]
            ?? environment["WAYLAND_DISPLAY"]
            ?? "wayland-0"
        return "\(runtimeDirectory)/nucleus/\(sessionID)/control.sock"
    }
}

package enum ControlClientError: Error, Equatable, Sendable {
    case noSocketPath
    case socketPathTooLong(String)
    case cannotConnect(path: String, errno: Int32)
    case transportFailed(String)
    case malformedResponse(String)
    case protocolFailure(ControlProtocolError)

    package var message: String {
        switch self {
        case .noSocketPath:
            "no control socket path; set \(ControlSocket.environmentVariable) "
                + "or XDG_RUNTIME_DIR"
        case .socketPathTooLong(let path):
            "control socket path is too long for a unix socket: \(path)"
        case .cannotConnect(let path, let code):
            "cannot connect to \(path): \(systemMessage(code))"
        case .transportFailed(let detail):
            "control transport failed: \(detail)"
        case .malformedResponse(let detail):
            "malformed response: \(detail)"
        case .protocolFailure(let failure):
            "control protocol failure: \(failure)"
        }
    }
}

/// A blocking one-shot client. Each exchange is exactly one request packet and
/// one correlated response packet over a fresh SOCK_SEQPACKET connection.
package struct ControlClient: Sendable {
    package static let maximumPacketBytes = 64 * 1024

    private let path: String
    private let requestID: ControlRequestID

    package init(
        path: String,
        requestID: ControlRequestID = ControlRequestID(rawValue: 1)
    ) {
        self.path = path
        self.requestID = requestID
    }

    package init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        requestID: ControlRequestID = ControlRequestID(rawValue: 1)
    ) throws(ControlClientError) {
        guard let path = ControlSocket.defaultPath(environment: environment)
        else { throw .noSocketPath }
        self.init(path: path, requestID: requestID)
    }

    package func send(
        _ request: ControlRequest,
        capabilityDescriptor: Int32? = nil
    ) throws(ControlClientError) -> ControlResponse {
        let connection: PacketConnection
        do {
            connection = try PacketConnection.connect(path: path)
        } catch let error as IPCTransportError {
            switch error {
            case .systemCall(_, let code) where code == ENAMETOOLONG:
                throw .socketPathTooLong(path)
            case .systemCall(_, let code):
                throw .cannotConnect(path: path, errno: code)
            default:
                throw .transportFailed("\(error)")
            }
        } catch {
            throw .transportFailed("\(error)")
        }

        let requestEnvelope = ControlRequestEnvelope(
            requestID: requestID,
            request: request)
        do {
            try connection.send(
                ControlCoding.packet(requestEnvelope),
                descriptors: capabilityDescriptor.map { [$0] } ?? [])
            let packet = try connection.receive(
                maximumBytes: Self.maximumPacketBytes,
                maximumDescriptors: 0)
            let responseEnvelope = try ControlCoding.decoder().decode(
                ControlResponseEnvelope.self,
                from: Data(packet.bytes))
            guard
                responseEnvelope.protocolVersion
                    == ControlProtocolVersion.current
            else {
                throw ControlProtocolError.unsupportedVersion(
                    expected: ControlProtocolVersion.current,
                    actual: responseEnvelope.protocolVersion)
            }
            guard responseEnvelope.requestID == requestID else {
                throw ControlProtocolError.mismatchedRequestID(
                    expected: requestID,
                    actual: responseEnvelope.requestID)
            }
            return responseEnvelope.response
        } catch let error as ControlProtocolError {
            throw .protocolFailure(error)
        } catch let error as IPCTransportError {
            throw .transportFailed("\(error)")
        } catch {
            throw .malformedResponse("\(error)")
        }
    }
}

private func systemMessage(_ code: Int32) -> String {
    unsafe String(cString: strerror(code))
}
