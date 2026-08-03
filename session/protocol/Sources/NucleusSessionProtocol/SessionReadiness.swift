import Glibc
internal import NucleusIPCTransport

public enum SessionProcessRole: UInt8, Sendable, Equatable {
    case compositor = 1
    case shell = 2
    case supervisor = 3
    case configService = 4
    case controlService = 5
    case capability = 6

    public static let argument = "--nucleus-session-role"

    public static func inherited(
        arguments: [String] = CommandLine.arguments
    ) throws -> SessionProcessRole {
        let indices = arguments.indices.filter { arguments[$0] == argument }
        guard indices.count == 1,
            let index = indices.first,
            arguments.indices.contains(index + 1),
            let rawValue = UInt8(arguments[index + 1]),
            let role = SessionProcessRole(rawValue: rawValue),
            role != .supervisor
        else {
            throw SessionReadinessFailure.invalidRole
        }
        return role
    }
}

public enum SessionMilestone: UInt8, Sendable, Equatable {
    case compositorReady = 1
    case shellReady = 2
    case terminating = 3
    case failed = 4
    case configServiceReady = 5
    case controlServiceReady = 6
}

public enum SessionFailureReason:
    Int32, Sendable, Equatable, CustomStringConvertible
{
    case internalFailure = 1
    case compositorExitedBeforeReady = 2
    case shellExitedBeforeReady = 3
    case compositorReadinessClosed = 4
    case shellReadinessClosed = 5
    case compositorReadinessInvalid = 6
    case shellReadinessInvalid = 7
    case compositorStartupTimedOut = 8
    case shellStartupTimedOut = 9
    case compositorExitedAfterReady = 10
    case shellExitedAfterReady = 11
    case configServiceExitedBeforeReady = 12
    case configServiceReadinessClosed = 13
    case configServiceReadinessInvalid = 14
    case configServiceStartupTimedOut = 15
    case configServiceExitedAfterReady = 16
    case controlServiceExitedBeforeReady = 17
    case controlServiceReadinessClosed = 18
    case controlServiceReadinessInvalid = 19
    case controlServiceStartupTimedOut = 20
    case controlServiceExitedAfterReady = 21

    public var description: String {
        switch self {
        case .internalFailure: "internal supervisor failure"
        case .compositorExitedBeforeReady:
            "compositor exited before readiness"
        case .shellExitedBeforeReady: "shell exited before readiness"
        case .compositorReadinessClosed:
            "compositor closed its readiness channel"
        case .shellReadinessClosed: "shell closed its readiness channel"
        case .compositorReadinessInvalid:
            "compositor sent invalid readiness"
        case .shellReadinessInvalid: "shell sent invalid readiness"
        case .compositorStartupTimedOut:
            "compositor startup timed out"
        case .shellStartupTimedOut: "shell startup timed out"
        case .compositorExitedAfterReady:
            "compositor exited after session readiness"
        case .shellExitedAfterReady:
            "shell exited after session readiness"
        case .configServiceExitedBeforeReady:
            "configuration service exited before readiness"
        case .configServiceReadinessClosed:
            "configuration service closed its readiness channel"
        case .configServiceReadinessInvalid:
            "configuration service sent invalid readiness"
        case .configServiceStartupTimedOut:
            "configuration service startup timed out"
        case .configServiceExitedAfterReady:
            "configuration service exited after readiness"
        case .controlServiceExitedBeforeReady:
            "control service exited before readiness"
        case .controlServiceReadinessClosed:
            "control service closed its readiness channel"
        case .controlServiceReadinessInvalid:
            "control service sent invalid readiness"
        case .controlServiceStartupTimedOut:
            "control service startup timed out"
        case .controlServiceExitedAfterReady:
            "control service exited after readiness"
        }
    }
}

public struct SessionReadinessMessage: Sendable, Equatable {
    public static let encodedSize = 12
    private static let magic: UInt32 = 0x4E_55_43_52
    private static let version: UInt16 = 1

    public let role: SessionProcessRole
    public let milestone: SessionMilestone
    public let detail: Int32

    public init(
        role: SessionProcessRole,
        milestone: SessionMilestone,
        detail: Int32 = 0
    ) {
        self.role = role
        self.milestone = milestone
        self.detail = detail
    }

    public var encoded: [UInt8] {
        var bytes = [UInt8](repeating: 0, count: Self.encodedSize)
        Self.store(Self.magic, in: &bytes, at: 0)
        Self.store(Self.version, in: &bytes, at: 4)
        bytes[6] = role.rawValue
        bytes[7] = milestone.rawValue
        Self.store(UInt32(bitPattern: detail), in: &bytes, at: 8)
        return bytes
    }

    public init?(encoded bytes: [UInt8]) {
        guard bytes.count == Self.encodedSize,
            Self.loadUInt32(bytes, at: 0) == Self.magic,
            Self.loadUInt16(bytes, at: 4) == Self.version,
            let role = SessionProcessRole(rawValue: bytes[6]),
            let milestone = SessionMilestone(rawValue: bytes[7])
        else { return nil }
        self.init(
            role: role,
            milestone: milestone,
            detail: Int32(bitPattern: Self.loadUInt32(bytes, at: 8)))
    }

    private static func store(
        _ value: UInt16,
        in bytes: inout [UInt8],
        at offset: Int
    ) {
        let littleEndian = value.littleEndian
        withUnsafeBytes(of: littleEndian) {
            unsafe bytes.replaceSubrange(
                offset..<(offset + $0.count), with: $0)
        }
    }

    private static func store(
        _ value: UInt32,
        in bytes: inout [UInt8],
        at offset: Int
    ) {
        let littleEndian = value.littleEndian
        withUnsafeBytes(of: littleEndian) {
            unsafe bytes.replaceSubrange(
                offset..<(offset + $0.count), with: $0)
        }
    }

    private static func loadUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset])
            | UInt16(bytes[offset + 1]) << 8
    }

    private static func loadUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}

public enum SessionReadinessFailure: Error, CustomStringConvertible {
    case invalidDescriptor(String)
    case invalidRole
    case transportFailed(String)
    case alreadyReported

    public var description: String {
        switch self {
        case .invalidDescriptor(let value):
            "invalid session readiness descriptor '\(value)'"
        case .invalidRole:
            "invalid or missing inherited session process role"
        case .transportFailed(let error):
            "session readiness transport failed: \(error)"
        case .alreadyReported:
            "session readiness was reported more than once"
        }
    }
}

/// The one-shot child side of the supervisor readiness pipe.
public final class SessionReadinessReporter {
    public static let descriptorArgument = "--nucleus-session-readiness-fd"

    private let role: SessionProcessRole
    private var descriptor: Int32

    public static func inherited(
        role: SessionProcessRole,
        arguments: [String] = CommandLine.arguments
    ) throws -> SessionReadinessReporter? {
        let indices = arguments.indices.filter {
            arguments[$0] == descriptorArgument
        }
        guard !indices.isEmpty else {
            return nil
        }
        guard try SessionProcessRole.inherited(arguments: arguments) == role
        else { throw SessionReadinessFailure.invalidRole }
        guard indices.count == 1, let index = indices.first else {
            throw SessionReadinessFailure.invalidDescriptor("<duplicate>")
        }
        guard
            arguments.indices.contains(index + 1),
            let descriptor = Int32(arguments[index + 1]),
            descriptor >= 3
        else {
            let value =
                arguments.indices.contains(index + 1)
                ? arguments[index + 1]
                : "<missing>"
            throw SessionReadinessFailure.invalidDescriptor(value)
        }
        return SessionReadinessReporter(role: role, descriptor: descriptor)
    }

    public init(role: SessionProcessRole, descriptor: Int32) {
        precondition(descriptor >= 0)
        self.role = role
        self.descriptor = descriptor
    }

    public func report(_ milestone: SessionMilestone) throws {
        guard descriptor >= 0 else {
            throw SessionReadinessFailure.alreadyReported
        }
        let message = SessionReadinessMessage(
            role: role,
            milestone: milestone)
        do {
            try SessionChannel.send(message.encoded, to: descriptor)
        } catch let error as IPCTransportError {
            _ = close(descriptor)
            descriptor = -1
            throw SessionReadinessFailure.transportFailed(
                String(describing: error))
        }
        _ = close(descriptor)
        descriptor = -1
    }

    deinit {
        if descriptor >= 0 { _ = close(descriptor) }
    }
}
