import ArgumentParser

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

    mutating func run(in context: WorkspaceContext) async throws {
        try await ComponentRegistry(context: context).packageLinuxRuntime(
            controls: taskOptions.controls)
    }
}
