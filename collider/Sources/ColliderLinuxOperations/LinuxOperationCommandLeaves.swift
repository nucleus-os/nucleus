import ArgumentParser
import ColliderWorkspaceCommands
import Foundation
import SystemPackage

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

struct AndroidRuntimePackageInput: TaskControlledCommand {
    static let configuration = CommandConfiguration(
        commandName: "package-input",
        abstract: "Assemble a validated Android native-package input.")

    @OptionGroup var taskOptions: TaskControlOptions
    @Option(name: .customLong("runtime-root")) var runtimeRoot: String?
    @Option(name: .customLong("aosp-generation")) var aospGeneration: String?
    @Option(name: .customLong("aosp-signing-key")) var aospSigningKey: String
    @Option var output: String

    mutating func run(in context: WorkspaceContext) async throws {
        let workspace = context
        let android = workspace.layout.androidRuntime
        let managedAOSPGeneration = android.appending(".aosp-build/current")
        try await ComponentRegistry(context: workspace).materializeAndroidPackageInput(
            runtimeRoot: runtimeRoot.map {
                resolveWorkspacePath($0, relativeTo: workspace.root)
            },
            aospGeneration: aospGeneration.map {
                resolveWorkspacePath($0, relativeTo: workspace.root)
            } ?? managedAOSPGeneration,
            usesManagedAOSPGeneration: aospGeneration == nil,
            aospSigningKey: resolveWorkspacePath(
                aospSigningKey,
                relativeTo: workspace.root),
            output: resolveWorkspacePath(output, relativeTo: workspace.root),
            controls: taskOptions.controls)
    }
}
