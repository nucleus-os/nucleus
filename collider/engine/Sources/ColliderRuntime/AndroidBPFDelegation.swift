import ColliderPlatformC
import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct AndroidBPFDelegationBroker: Equatable, Sendable {
    public let socketPath: String
    public let expectedPeerUID: UInt32

    public init(
        socketPath: String,
        expectedPeerUID: UInt32
    ) throws {
        try validateBPFDelegationPath(
            socketPath,
            suffix: ["bpf-broker", "broker.sock"],
            field: "BPF broker socket")
        guard expectedPeerUID > 0 else {
            throw AndroidBPFDelegationFailure.invalidPeerUID(
                expectedPeerUID)
        }
        self.socketPath = socketPath
        self.expectedPeerUID = expectedPeerUID
    }

    public func run() throws {
        guard geteuid() == 0 else {
            throw AndroidBPFDelegationFailure.brokerRequiresRoot
        }
        let status = socketPath.withCString {
            collider_android_bpf_delegation_broker(
                $0,
                expectedPeerUID)
        }
        guard status == 0 else {
            throw AndroidBPFDelegationFailure.system(
                operation: "authorize the Android BPF filesystem",
                code: errno)
        }
    }
}

public struct AndroidBPFDelegationMount: Equatable, Sendable {
    public let socketPath: String
    public let rootFileSystem: String
    public let containerName: String

    public init(
        socketPath: String,
        rootFileSystem: String,
        containerName: String
    ) throws {
        try validateBPFDelegationPath(
            socketPath,
            suffix: ["bpf-broker", "broker.sock"],
            field: "BPF broker socket")
        try validateBPFDelegationPath(
            rootFileSystem,
            suffix: ["rootfs"],
            field: "container root filesystem")
        let components = try bpfDelegationComponents(
            rootFileSystem,
            field: "container root filesystem")
        guard components[3] == containerName else {
            throw AndroidBPFDelegationFailure.containerMismatch(
                expected: components[3],
                actual: containerName)
        }
        self.socketPath = socketPath
        self.rootFileSystem = rootFileSystem
        self.containerName = containerName
    }

    public func run(environment: [String: String]) throws {
        guard geteuid() == 0 else {
            throw AndroidBPFDelegationFailure.mountRequiresContainerRoot
        }
        guard environment["LXC_HOOK_TYPE"] == "mount",
            environment["LXC_NAME"] == containerName,
            environment["LXC_ROOTFS_PATH"] == rootFileSystem,
            let mountedRoot = environment["LXC_ROOTFS_MOUNT"]
        else {
            throw AndroidBPFDelegationFailure.invalidMountHookEnvironment
        }
        let targetPath = try bpfMountTarget(mountedRoot: mountedRoot)
        let status = socketPath.withCString { socket in
            targetPath.withCString { target in
                collider_android_bpf_delegation_mount(socket, target)
            }
        }
        guard status == 0 else {
            throw AndroidBPFDelegationFailure.system(
                operation: "mount the delegated Android BPF filesystem",
                code: errno)
        }
    }
}

public enum AndroidBPFDelegationFailure:
    Error,
    CustomStringConvertible,
    Equatable,
    Sendable
{
    case invalidPath(field: String, value: String)
    case invalidPeerUID(UInt32)
    case containerMismatch(expected: String, actual: String)
    case brokerRequiresRoot
    case mountRequiresContainerRoot
    case invalidMountHookEnvironment
    case system(operation: String, code: Int32)

    public var description: String {
        switch self {
        case .invalidPath(let field, let value):
            "invalid \(field): \(value)"
        case .invalidPeerUID(let userID):
            "invalid Android BPF broker peer UID: \(userID)"
        case .containerMismatch(let expected, let actual):
            "BPF mount target belongs to \(expected), not \(actual)"
        case .brokerRequiresRoot:
            "the internal Android BPF broker requires host root"
        case .mountRequiresContainerRoot:
            "the Android BPF mount hook requires container root"
        case .invalidMountHookEnvironment:
            "the Android BPF mount operation requires its matching LXC mount hook"
        case .system(let operation, let code):
            "\(operation) failed with errno \(code)"
        }
    }
}

private func validateBPFDelegationPath(
    _ path: String,
    suffix: [String],
    field: String
) throws {
    let components = try bpfDelegationComponents(path, field: field)
    guard components.count == 4 + suffix.count,
        Array(components.suffix(suffix.count)) == suffix
    else {
        throw AndroidBPFDelegationFailure.invalidPath(
            field: field,
            value: path)
    }
}

private func bpfDelegationComponents(
    _ path: String,
    field: String
) throws -> [String] {
    let rawComponents = path.split(
        separator: "/",
        omittingEmptySubsequences: false)
    let components = rawComponents.dropFirst().map(String.init)
    guard rawComponents.first == "",
        components.count >= 4,
        components[0] == "run",
        components[1] == "nucleus",
        components[2] == "android",
        components[3].hasPrefix("nucleus-framework-"),
        !components[3].dropFirst("nucleus-framework-".count).isEmpty,
        components[3].dropFirst("nucleus-framework-".count)
            .allSatisfy(\.isNumber),
        components.allSatisfy({
            !$0.isEmpty
                && $0 != "."
                && $0 != ".."
                && $0.allSatisfy({
                    !$0.isWhitespace && !$0.isNewline && $0 != "#"
                })
        })
    else {
        throw AndroidBPFDelegationFailure.invalidPath(
            field: field,
            value: path)
    }
    return components
}

private func bpfMountTarget(
    mountedRoot: String
) throws -> String {
    let components = mountedRoot.split(
        separator: "/",
        omittingEmptySubsequences: false)
    guard components.first == "",
        components.count > 1,
        components.dropFirst().allSatisfy({
            !$0.isEmpty
                && $0 != "."
                && $0 != ".."
                && $0.allSatisfy({
                    !$0.isWhitespace && !$0.isNewline && $0 != "#"
                })
        })
    else {
        throw AndroidBPFDelegationFailure.invalidMountHookEnvironment
    }
    return mountedRoot + "/sys/fs/bpf"
}
