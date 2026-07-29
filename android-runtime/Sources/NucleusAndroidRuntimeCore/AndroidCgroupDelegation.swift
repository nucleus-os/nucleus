import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct AndroidCgroupDelegation: Equatable, Sendable {
    public let containerName: String
    public let mappedSystemUser: UInt32
    public let mappedSystemGroup: UInt32

    public init(
        containerName: String,
        mappedSystemUser: UInt32,
        mappedSystemGroup: UInt32
    ) throws {
        guard isValidAndroidContainerName(containerName) else {
            throw AndroidCgroupDelegationFailure.invalidContainerName(
                containerName)
        }
        guard mappedSystemUser > 1_000, mappedSystemGroup > 1_000 else {
            throw AndroidCgroupDelegationFailure.invalidMappedSystemIdentity(
                userID: mappedSystemUser,
                groupID: mappedSystemGroup)
        }
        self.containerName = containerName
        self.mappedSystemUser = mappedSystemUser
        self.mappedSystemGroup = mappedSystemGroup
    }

    public var cgroupPath: String {
        "/sys/fs/cgroup/system.slice/\(containerName).scope/payload/android"
    }

    public func run(environment: [String: String]) throws {
        #if os(Linux)
        guard geteuid() == 0 else {
            throw AndroidCgroupDelegationFailure.requiresHostRoot
        }
        guard environment["LXC_HOOK_TYPE"] == "start-host",
            environment["LXC_NAME"] == containerName
        else {
            throw AndroidCgroupDelegationFailure.invalidHookEnvironment
        }
        try prepareLinuxCgroup()
        #else
        throw AndroidCgroupDelegationFailure.unsupportedPlatform
        #endif
    }

    #if os(Linux)
    private func prepareLinuxCgroup() throws {
        let payload = URL(fileURLWithPath: cgroupPath)
            .deletingLastPathComponent().path
        let rootProcessesPath = cgroupPath + "/cgroup.procs"
        let processes = try validatePreconditions(
            payloadProcesses: try read(payload + "/cgroup.procs"),
            rootProcesses: try read(rootProcessesPath),
            controllers: try read(cgroupPath + "/cgroup.controllers"))

        let initCgroup = cgroupPath + "/init"
        guard unsafe mkdir(initCgroup, 0o755) == 0 else {
            throw systemFailure("create the Android init cgroup")
        }
        let mappedRootUser = mappedSystemUser - 1_000
        let mappedRootGroup = mappedSystemGroup - 1_000
        guard
            unsafe chown(
                initCgroup,
                mappedRootUser,
                mappedRootGroup
            ) == 0
        else {
            throw systemFailure("assign the Android init cgroup")
        }
        for process in processes {
            try write(
                "\(process)\n",
                to: initCgroup + "/cgroup.procs",
                operation: "move Android init into its leaf cgroup")
        }
        try requireEmptyProcesses(
            at: rootProcessesPath,
            description: "Android-visible root")

        guard
            unsafe chown(
                cgroupPath,
                mappedSystemUser,
                mappedSystemGroup
            ) == 0
        else {
            throw systemFailure("delegate the Android-visible cgroup root")
        }
        guard unsafe chmod(cgroupPath, 0o775) == 0 else {
            throw systemFailure("set the Android-visible cgroup root mode")
        }
        try verifyDelegatedRoot()
    }

    private func verifyDelegatedRoot() throws {
        var metadata = stat()
        guard unsafe lstat(cgroupPath, &metadata) == 0 else {
            throw systemFailure("inspect the Android-visible cgroup root")
        }
        let permissions = UInt16(metadata.st_mode & 0o777)
        try validateDelegatedRoot(
            owner: metadata.st_uid,
            group: metadata.st_gid,
            permissions: permissions)
    }

    private func requireEmptyProcesses(
        at path: String,
        description: String
    ) throws {
        guard try processIdentifiers(at: path).isEmpty else {
            throw AndroidCgroupDelegationFailure.cgroupContainsProcesses(
                description)
        }
    }

    private func processIdentifiers(at path: String) throws -> [Int32] {
        let contents = try read(path)
        return try processIdentifiers(contents: contents, path: path)
    }

    private func processIdentifiers(
        contents: String,
        path: String
    ) throws -> [Int32] {
        try contents.split(whereSeparator: \.isWhitespace).map {
            guard let identifier = Int32($0), identifier > 0 else {
                throw AndroidCgroupDelegationFailure.invalidProcessList(
                    path: path,
                    contents: contents)
            }
            return identifier
        }
    }

    private func read(_ path: String) throws -> String {
        do {
            return try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw AndroidCgroupDelegationFailure.readFailed(
                path: path,
                error: String(describing: error))
        }
    }

    private func write(
        _ value: String,
        to path: String,
        operation: String
    ) throws {
        let descriptor = unsafe open(path, O_WRONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw systemFailure(operation)
        }
        defer { _ = close(descriptor) }
        let bytes = Array(value.utf8)
        let result = bytes.withUnsafeBytes {
            unsafe Glibc.write(descriptor, $0.baseAddress, $0.count)
        }
        guard result == bytes.count else {
            throw systemFailure(operation)
        }
    }

    private func systemFailure(
        _ operation: String
    ) -> AndroidCgroupDelegationFailure {
        .system(operation: operation, code: errno)
    }
    #endif

    func validatePreconditions(
        payloadProcesses: String,
        rootProcesses: String,
        controllers: String
    ) throws -> [Int32] {
        let payload = try parseProcessIdentifiers(
            payloadProcesses,
            path: "payload/cgroup.procs")
        guard payload.isEmpty else {
            throw AndroidCgroupDelegationFailure.cgroupContainsProcesses(
                "payload parent")
        }
        let requiredControllers = Set(["cpuset", "cpu", "io", "memory", "pids"])
        let availableControllers = Set(
            controllers.split(whereSeparator: \.isWhitespace).map(String.init))
        let missingControllers =
            requiredControllers.subtracting(availableControllers)
        guard missingControllers.isEmpty else {
            throw AndroidCgroupDelegationFailure.missingControllers(
                missingControllers.sorted())
        }
        let processes = try parseProcessIdentifiers(
            rootProcesses,
            path: "android/cgroup.procs")
        guard !processes.isEmpty else {
            throw AndroidCgroupDelegationFailure.missingContainerProcess
        }
        return processes
    }

    func validateDelegatedRoot(
        owner: UInt32,
        group: UInt32,
        permissions: UInt16
    ) throws {
        guard owner == mappedSystemUser,
            group == mappedSystemGroup,
            permissions == 0o775
        else {
            throw AndroidCgroupDelegationFailure.invalidDelegatedRoot(
                path: cgroupPath,
                owner: owner,
                group: group,
                permissions: permissions)
        }
    }

    private func parseProcessIdentifiers(
        _ contents: String,
        path: String
    ) throws -> [Int32] {
        try contents.split(whereSeparator: \.isWhitespace).map {
            guard let identifier = Int32($0), identifier > 0 else {
                throw AndroidCgroupDelegationFailure.invalidProcessList(
                    path: path,
                    contents: contents)
            }
            return identifier
        }
    }
}
public enum AndroidCgroupDelegationFailure:
    Error,
    CustomStringConvertible,
    Equatable,
    Sendable
{
    case invalidContainerName(String)
    case invalidMappedSystemIdentity(userID: UInt32, groupID: UInt32)
    case requiresHostRoot
    case invalidHookEnvironment
    case missingControllers([String])
    case missingContainerProcess
    case cgroupContainsProcesses(String)
    case invalidProcessList(path: String, contents: String)
    case invalidDelegatedRoot(
        path: String,
        owner: UInt32,
        group: UInt32,
        permissions: UInt16)
    case readFailed(path: String, error: String)
    case system(operation: String, code: Int32)
    case unsupportedPlatform

    public var description: String {
        switch self {
        case .invalidContainerName(let name):
            "invalid Android container name: \(name)"
        case .invalidMappedSystemIdentity(let userID, let groupID):
            "invalid mapped Android system identity: \(userID):\(groupID)"
        case .requiresHostRoot:
            "the Android cgroup delegation hook requires host root"
        case .invalidHookEnvironment:
            "the Android cgroup delegation operation requires its matching "
                + "LXC start-host hook"
        case .missingControllers(let controllers):
            "the Android cgroup is missing delegated controllers: "
                + controllers.joined(separator: ", ")
        case .missingContainerProcess:
            "the Android payload cgroup contains no process to move into "
                + "the init leaf"
        case .cgroupContainsProcesses(let description):
            "the \(description) cgroup is not process-free"
        case .invalidProcessList(let path, let contents):
            "invalid process list in \(path): \(contents)"
        case .invalidDelegatedRoot(
            let path,
            let owner,
            let group,
            let permissions
        ):
            "delegated Android cgroup root \(path) has uid \(owner), gid "
                + "\(group), mode \(String(permissions, radix: 8))"
        case .readFailed(let path, let error):
            "could not read \(path): \(error)"
        case .system(let operation, let code):
            "\(operation) failed with errno \(code)"
        case .unsupportedPlatform:
            "Android cgroup delegation requires Linux"
        }
    }
}

private func isValidAndroidContainerName(_ value: String) -> Bool {
    let prefix = "nucleus-framework-"
    guard value.hasPrefix(prefix) else { return false }
    let identifier = value.dropFirst(prefix.count)
    return !identifier.isEmpty && identifier.allSatisfy(\.isNumber)
}
