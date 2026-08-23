import ArgumentParser
import ColliderWorkspaceCommands

struct InstallSession: TaskControlledCommand {
    static let configuration = CommandConfiguration(commandName: "session")

    @OptionGroup var taskOptions: TaskControlOptions
    @Option var prefix: String?

    mutating func run(in context: WorkspaceContext) async throws {
        try await InstallCommand(context: context).run(
            prefix: prefix,
            controls: taskOptions.controls)
    }
}
