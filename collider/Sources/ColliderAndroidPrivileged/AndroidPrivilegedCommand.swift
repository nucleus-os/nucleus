import ArgumentParser
import ColliderRuntime
import Foundation

public enum AndroidPrivilegedOperation {
    public static let apexMountCommandName = "__android-apex-mount"
    public static let bpfBrokerCommandName = "__android-bpf-broker"
    public static let bpfMountCommandName = "__android-bpf-mount"
    public static let cgroupDelegateCommandName = "__android-cgroup-delegate"
}

public struct AndroidPrivilegedCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "collider-android-privileged",
        abstract: "Perform privileged Android container setup operations.",
        subcommands: [
            AndroidApexMountPrivilegedCommand.self,
            AndroidBPFBrokerPrivilegedCommand.self,
            AndroidBPFMountPrivilegedCommand.self,
            AndroidCgroupDelegatePrivilegedCommand.self,
        ])

    public init() {}
}

private struct AndroidApexMountPrivilegedCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: AndroidPrivilegedOperation.apexMountCommandName,
        abstract: "Perform one validated pre-APEX payload mount.",
        shouldDisplay: false)

    @Option(name: .customLong("root-file-system"))
    var rootFileSystem: String

    @Option
    var source: String

    @Option
    var target: String

    @Option
    var payloadFileSystem: String

    @Option
    var payloadOffset: UInt64

    mutating func validate() throws {
        _ = try request()
    }

    mutating func run() throws {
        try request().mount()
    }

    private func request() throws -> AndroidApexMountRequest {
        guard let payloadFileSystem = AndroidApexPayloadFileSystem(
            rawValue: payloadFileSystem)
        else {
            throw ValidationError(
                "unsupported APEX payload filesystem: \(payloadFileSystem)")
        }
        return try AndroidApexMountRequest(
            rootFileSystem: rootFileSystem,
            source: source,
            target: target,
            payloadFileSystem: payloadFileSystem,
            payloadOffset: payloadOffset)
    }
}

private struct AndroidBPFBrokerPrivilegedCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: AndroidPrivilegedOperation.bpfBrokerCommandName,
        abstract: "Authorize one instance-private Android BPF filesystem.",
        shouldDisplay: false)

    @Option
    var socket: String

    @Option(name: .customLong("root-uid"))
    var rootUID: UInt32

    @Option(name: .customLong("root-gid"))
    var rootGID: UInt32

    mutating func validate() throws {
        _ = try broker()
    }

    mutating func run() throws {
        try broker().run()
    }

    private func broker() throws -> AndroidBPFDelegationBroker {
        try AndroidBPFDelegationBroker(
            socketPath: socket,
            containerRootUID: rootUID,
            containerRootGID: rootGID)
    }
}

private struct AndroidBPFMountPrivilegedCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: AndroidPrivilegedOperation.bpfMountCommandName,
        abstract: "Mount one instance-private Android BPF filesystem.",
        shouldDisplay: false)

    @Option
    var socket: String

    @Option(name: .customLong("root-file-system"))
    var rootFileSystem: String

    @Option
    var container: String

    mutating func validate() throws {
        _ = try mount()
    }

    mutating func run() throws {
        try mount().run(environment: ProcessInfo.processInfo.environment)
    }

    private func mount() throws -> AndroidBPFDelegationMount {
        try AndroidBPFDelegationMount(
            socketPath: socket,
            rootFileSystem: rootFileSystem,
            containerName: container)
    }
}

private struct AndroidCgroupDelegatePrivilegedCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: AndroidPrivilegedOperation.cgroupDelegateCommandName,
        abstract: "Delegate one Android payload cgroup.",
        shouldDisplay: false)

    @Option
    var container: String

    @Option(name: .customLong("system-uid"))
    var systemUID: UInt32

    @Option(name: .customLong("system-gid"))
    var systemGID: UInt32

    mutating func validate() throws {
        _ = try delegation()
    }

    mutating func run() throws {
        try delegation().run(
            environment: ProcessInfo.processInfo.environment)
    }

    private func delegation() throws -> AndroidCgroupDelegation {
        try AndroidCgroupDelegation(
            containerName: container,
            mappedSystemUser: systemUID,
            mappedSystemGroup: systemGID)
    }
}
