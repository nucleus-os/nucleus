import ArgumentParser

struct InstallBrowser: TaskControlledCommand {
    static let configuration = CommandConfiguration(commandName: "browser")

    @OptionGroup var taskOptions: TaskControlOptions
    @Option var prefix: String?

    mutating func run(in context: WorkspaceContext) async throws {
        try await BrowserInstallCommand(context: context).run(
            controls: taskOptions.controls,
            installPrefix: prefix)
    }
}
