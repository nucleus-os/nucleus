import Foundation

public struct AndroidRuntimePrivilegedCommandFailure:
    Error, CustomStringConvertible, Equatable, Sendable
{
    public let description: String

    init(_ description: String) {
        self.description = description
    }
}

public enum AndroidRuntimePrivilegedCommand {
    public static func run(
        arguments: [String],
        environment: [String: String]
    ) throws {
        guard let operation = arguments.first else {
            throw AndroidRuntimePrivilegedCommandFailure(
                "missing privileged operation")
        }
        let options = try parseOptions(Array(arguments.dropFirst()))
        switch operation {
        case AndroidRuntimePrivilegedOperation.apexMountCommandName:
            try requireExactly(
                options,
                [
                    "root-file-system", "source", "target",
                    "payload-file-system", "payload-offset",
                ])
            guard let fileSystem = AndroidRuntimeApexPayloadFileSystem(
                rawValue: options["payload-file-system"]!),
                let offset = UInt64(options["payload-offset"]!)
            else {
                throw AndroidRuntimePrivilegedCommandFailure(
                    "invalid APEX payload metadata")
            }
            try AndroidApexMountRequest(
                rootFileSystem: options["root-file-system"]!,
                source: options["source"]!,
                target: options["target"]!,
                payloadFileSystem: fileSystem,
                payloadOffset: offset
            ).mount()
        case AndroidRuntimePrivilegedOperation.bpfBrokerCommandName:
            try requireExactly(
                options,
                ["socket", "root-uid", "root-gid"])
            guard let userID = UInt32(options["root-uid"]!),
                let groupID = UInt32(options["root-gid"]!)
            else {
                throw AndroidRuntimePrivilegedCommandFailure(
                    "invalid BPF broker identity")
            }
            try AndroidBPFDelegationBroker(
                socketPath: options["socket"]!,
                containerRootUID: userID,
                containerRootGID: groupID
            ).run()
        case AndroidRuntimePrivilegedOperation.bpfMountCommandName:
            try requireExactly(
                options,
                ["socket", "root-file-system", "container"])
            try AndroidBPFDelegationMount(
                socketPath: options["socket"]!,
                rootFileSystem: options["root-file-system"]!,
                containerName: options["container"]!
            ).run(environment: environment)
        case AndroidRuntimePrivilegedOperation.cgroupDelegateCommandName:
            try requireExactly(
                options,
                ["container", "system-uid", "system-gid"])
            guard let userID = UInt32(options["system-uid"]!),
                let groupID = UInt32(options["system-gid"]!)
            else {
                throw AndroidRuntimePrivilegedCommandFailure(
                    "invalid cgroup delegation identity")
            }
            try AndroidCgroupDelegation(
                containerName: options["container"]!,
                mappedSystemUser: userID,
                mappedSystemGroup: groupID
            ).run(environment: environment)
        default:
            throw AndroidRuntimePrivilegedCommandFailure(
                "unknown privileged operation: \(operation)")
        }
    }

    private static func parseOptions(
        _ arguments: [String]
    ) throws -> [String: String] {
        guard arguments.count.isMultiple(of: 2) else {
            throw AndroidRuntimePrivilegedCommandFailure(
                "privileged options require one value each")
        }
        var options: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--"),
                argument.count > 2,
                !argument.contains("=")
            else {
                throw AndroidRuntimePrivilegedCommandFailure(
                    "invalid privileged option: \(argument)")
            }
            let key = String(argument.dropFirst(2))
            guard options.updateValue(
                arguments[index + 1],
                forKey: key
            ) == nil else {
                throw AndroidRuntimePrivilegedCommandFailure(
                    "duplicate privileged option: \(argument)")
            }
            index += 2
        }
        return options
    }

    private static func requireExactly(
        _ options: [String: String],
        _ keys: Set<String>
    ) throws {
        guard Set(options.keys) == keys else {
            throw AndroidRuntimePrivilegedCommandFailure(
                "privileged operation options do not match its contract")
        }
    }
}
