import ArgumentParser
import ColliderRuntime
import Foundation

let androidBPFBrokerCommandName = "__android-bpf-broker"
let androidBPFMountCommandName = "__android-bpf-mount"

struct AndroidBPFBrokerPrivilegedCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: androidBPFBrokerCommandName,
        abstract: "Authorize one instance-private Android BPF filesystem.",
        shouldDisplay: false)

    @Option
    var socket: String

    @Option(name: .customLong("root-uid"))
    var rootUID: UInt32

    @Option(name: .customLong("root-gid"))
    var rootGID: UInt32

    mutating func validate() throws {
        do {
            _ = try broker()
        } catch {
            throw ValidationError(String(describing: error))
        }
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

struct AndroidBPFMountPrivilegedCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: androidBPFMountCommandName,
        abstract: "Mount one instance-private Android BPF filesystem.",
        shouldDisplay: false)

    @Option
    var socket: String

    @Option(name: .customLong("root-file-system"))
    var rootFileSystem: String

    @Option
    var container: String

    mutating func validate() throws {
        do {
            _ = try mount()
        } catch {
            throw ValidationError(String(describing: error))
        }
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

struct AndroidBPFBrokerInvocation: Equatable {
    let executable: String
    let arguments: [String]

    init(
        colliderExecutable: String,
        socket: String,
        rootUID: UInt32,
        rootGID: UInt32
    ) {
        executable = "sudo"
        arguments = [
            "--non-interactive",
            colliderExecutable,
            androidBPFBrokerCommandName,
            "--socket",
            socket,
            "--root-uid",
            String(rootUID),
            "--root-gid",
            String(rootGID),
        ]
    }
}
