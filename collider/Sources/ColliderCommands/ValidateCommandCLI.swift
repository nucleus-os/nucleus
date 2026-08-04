import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

struct Validate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [Vulkan.self])
    struct Vulkan: AsyncParsableCommand {
        @Flag(help: "Print validation actions without executing them.")
        var dryRun = false
        @Flag(help: "Emit stable machine-readable records.")
        var json = false

        mutating func run() async throws {
            try VulkanValidation(context: context()).run(
                dryRun: dryRun,
                json: json)
        }
    }
}
