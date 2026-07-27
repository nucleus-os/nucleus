import ArgumentParser
import ColliderRuntime
import Foundation

let androidCgroupDelegateCommandName = "__android-cgroup-delegate"

struct AndroidCgroupDelegatePrivilegedCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: androidCgroupDelegateCommandName,
        abstract: "Delegate one Android payload cgroup.",
        shouldDisplay: false)

    @Option
    var container: String

    @Option(name: .customLong("system-uid"))
    var systemUID: UInt32

    @Option(name: .customLong("system-gid"))
    var systemGID: UInt32

    mutating func validate() throws {
        do {
            _ = try delegation()
        } catch {
            throw ValidationError(String(describing: error))
        }
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
