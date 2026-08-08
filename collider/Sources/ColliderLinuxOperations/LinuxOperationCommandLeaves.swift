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

struct InstallAndroidAddon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "android-addon",
        abstract: "Install or deactivate an independently signed Android add-on.",
        subcommands: [Activate.self, Deactivate.self, Uninstall.self])

    struct Activate: ColliderWorkspaceCommand {
        @OptionGroup var outputOptions: CommandOutputOptions
        @Argument var artifact: String
        @Option(name: .customLong("trust-key")) var trustKey: String?
        @Option(name: .customLong("base-prefix")) var basePrefix: String?
        @Option(name: .customLong("store-root")) var storeRoot: String?
        @Option(name: .customLong("state-root")) var stateRoot: String?

        mutating func run(in context: WorkspaceContext) async throws {
            let workspace = context
            let resolvedBase =
                basePrefix.map {
                    URL(resolveWorkspacePath($0, relativeTo: workspace.root))
                } ?? URL(workspace.layout.installPrefix)
            try AndroidAddonInstallCommand().install(
                artifact: URL(
                    resolveWorkspacePath(artifact, relativeTo: workspace.root)),
                trustKey: trustKey.map {
                    URL(resolveWorkspacePath($0, relativeTo: workspace.root))
                }
                    ?? resolvedBase.appendingPathComponent(
                        "share/nucleus/trust/android-addon-publisher.pem"),
                basePrefix: resolvedBase,
                storeRoot: storeRoot.map {
                    URL(resolveWorkspacePath($0, relativeTo: workspace.root))
                } ?? URL(workspace.layout.androidAddonStore),
                persistentStateRoot: stateRoot.map {
                    URL(resolveWorkspacePath($0, relativeTo: workspace.root))
                } ?? URL(workspace.layout.androidPersistentState))
        }
    }

    struct Deactivate: ColliderWorkspaceCommand {
        @OptionGroup var outputOptions: CommandOutputOptions
        @Option(name: .customLong("store-root")) var storeRoot: String?
        @Option(name: .customLong("state-root")) var stateRoot: String?

        mutating func run(in context: WorkspaceContext) async throws {
            let workspace = context
            try AndroidAddonInstallCommand().deactivate(
                storeRoot: storeRoot.map {
                    URL(resolveWorkspacePath($0, relativeTo: workspace.root))
                } ?? URL(workspace.layout.androidAddonStore),
                persistentStateRoot: stateRoot.map {
                    URL(resolveWorkspacePath($0, relativeTo: workspace.root))
                } ?? URL(workspace.layout.androidPersistentState))
        }
    }

    struct Uninstall: ColliderWorkspaceCommand {
        @OptionGroup var outputOptions: CommandOutputOptions
        @Option(name: .customLong("store-root")) var storeRoot: String?
        @Option(name: .customLong("state-root")) var stateRoot: String?

        mutating func run(in context: WorkspaceContext) async throws {
            let workspace = context
            try AndroidAddonInstallCommand().uninstall(
                storeRoot: storeRoot.map {
                    URL(resolveWorkspacePath($0, relativeTo: workspace.root))
                } ?? URL(workspace.layout.androidAddonStore),
                persistentStateRoot: stateRoot.map {
                    URL(resolveWorkspacePath($0, relativeTo: workspace.root))
                } ?? URL(workspace.layout.androidPersistentState))
        }
    }
}

struct AndroidRuntimePackageAddon: TaskControlledCommand {
    static let configuration = CommandConfiguration(
        commandName: "package-addon",
        abstract: "Assemble and sign a downloadable Android add-on artifact.")

    @OptionGroup var taskOptions: TaskControlOptions
    @Option(name: .customLong("runtime-root")) var runtimeRoot: String?
    @Option(name: .customLong("aosp-generation")) var aospGeneration: String?
    @Option(name: .customLong("compatibility")) var compatibility: String
    @Option(name: .customLong("aosp-signing-key")) var aospSigningKey: String
    @Option(name: .customLong("addon-signing-key")) var addonSigningKey: String
    @Option var output: String

    mutating func run(in context: WorkspaceContext) async throws {
        let workspace = context
        let android = workspace.layout.androidRuntime
        let managedAOSPGeneration = android.appending(".aosp-build/current")
        try await ComponentRegistry(context: workspace).packageAndroidAddon(
            runtimeRoot: runtimeRoot.map {
                resolveWorkspacePath($0, relativeTo: workspace.root)
            },
            aospGeneration: aospGeneration.map {
                resolveWorkspacePath($0, relativeTo: workspace.root)
            } ?? managedAOSPGeneration,
            usesManagedAOSPGeneration: aospGeneration == nil,
            compatibility: resolveWorkspacePath(
                compatibility,
                relativeTo: workspace.root),
            aospSigningKey: resolveWorkspacePath(
                aospSigningKey,
                relativeTo: workspace.root),
            addonSigningKey: resolveWorkspacePath(
                addonSigningKey,
                relativeTo: workspace.root),
            output: resolveWorkspacePath(output, relativeTo: workspace.root),
            controls: taskOptions.controls)
    }
}
