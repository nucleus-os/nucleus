import ArgumentParser
import ColliderCore
import SystemPackage

package struct PackageArtifacts: AsyncParsableCommand {
    package static let configuration = CommandConfiguration(
        commandName: "package",
        abstract: "Assemble native Nucleus distribution packages.",
        subcommands: [PackageLinuxRuntime.self, PackageAndroidInput.self])

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

/// The cohort consumes these as artifacts, so assembling a cohort produces them
/// on the way. They are separately reachable because producing them is its own
/// contract: an architecture's Android input must be materializable without
/// building a browser.
private struct PackageAndroidInput: TaskControlledCommand {
    static let configuration = CommandConfiguration(
        commandName: "android-input",
        abstract: "Materialize every locked architecture's Android package input.")

    @OptionGroup var taskOptions: TaskControlOptions

    mutating func run(in context: WorkspaceContext) async throws {
        try await ComponentRegistry(context: context).packageAndroidInputs(
            controls: taskOptions.controls)
    }
}
