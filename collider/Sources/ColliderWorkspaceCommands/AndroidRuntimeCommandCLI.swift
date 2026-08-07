import ArgumentParser

struct AndroidRuntimeSourceLock: TaskControlledCommand {
    static let configuration = CommandConfiguration(
        commandName: "source-lock",
        abstract: "Verify the pinned AOSP and Repo identities.")
    @OptionGroup var taskOptions: TaskControlOptions

    mutating func run(in context: WorkspaceContext) async throws {
        try await ComponentRegistry(context: context)
            .verifyAndroidRuntimeSourceLock(controls: taskOptions.controls)
    }
}

struct AndroidRuntimeSource: TaskControlledCommand {
    static let configuration = CommandConfiguration(
        commandName: "source",
        abstract: "Materialize the exact AOSP source checkout.")
    @OptionGroup var taskOptions: TaskControlOptions

    mutating func run(in context: WorkspaceContext) async throws {
        try await ComponentRegistry(context: context)
            .prepareAndroidRuntimeSource(controls: taskOptions.controls)
    }
}

struct AndroidRuntimeImage: TaskControlledCommand {
    static let configuration = CommandConfiguration(
        commandName: "image",
        abstract: "Build and release-sign the Nucleus Android images.")
    @OptionGroup var taskOptions: TaskControlOptions

    mutating func run(in context: WorkspaceContext) async throws {
        try await ComponentRegistry(context: context)
            .buildAndroidRuntimeImage(controls: taskOptions.controls)
    }
}
