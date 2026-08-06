import ArgumentParser

struct InstallBrowser: TaskControlledCommand {
    static let configuration = CommandConfiguration(commandName: "browser")

    @OptionGroup var taskOptions: TaskControlOptions
    @Option var prefix: String?

    mutating func run() async throws {
        try await ChromiumCommand(context: context()).run(
            .install,
            controls: taskOptions.controls,
            installPrefix: prefix)
    }
}
