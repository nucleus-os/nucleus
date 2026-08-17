import ArgumentParser
import ColliderCore
import SystemPackage

package struct PackageArtifacts: AsyncParsableCommand {
    package static let configuration = CommandConfiguration(
        commandName: "package",
        abstract: "Assemble native Nucleus distribution packages.",
        subcommands: [PackageLinuxRuntime.self])

    package init() {}
}

private struct PackageLinuxRuntime: TaskControlledCommand {
    static let configuration = CommandConfiguration(
        commandName: "linux-runtime",
        abstract: "Assemble the complete Linux runtime package cohort.")

    @OptionGroup var taskOptions: TaskControlOptions
    @Option(name: .customLong("android-arm64")) var androidARM64: String?
    @Option(name: .customLong("android-x86-64")) var androidX8664: String?

    mutating func run(in context: WorkspaceContext) async throws {
        var androidPackageInputs: [PlatformArchitecture: FilePath] = [:]
        if let androidARM64 {
            androidPackageInputs[.arm64] = resolveWorkspacePath(
                androidARM64, relativeTo: context.root)
        }
        if let androidX8664 {
            androidPackageInputs[.x86_64] = resolveWorkspacePath(
                androidX8664, relativeTo: context.root)
        }
        try await ComponentRegistry(context: context).packageLinuxRuntime(
            androidPackageInputs: androidPackageInputs,
            controls: taskOptions.controls)
    }
}
