import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

struct Install: AsyncParsableCommand {
    private static func subcommands() -> [ParsableCommand.Type] {
        var commands: [ParsableCommand.Type] = [Browser.self]
        #if os(Linux)
        commands.insert(Session.self, at: 0)
        commands.insert(AndroidAddon.self, at: 1)
        #endif
        return commands
    }

    static let configuration = CommandConfiguration(
        abstract: "Install Nucleus runtime and browser products.",
        subcommands: subcommands())

    #if os(Linux)
    struct Session: AsyncParsableCommand {
        @Option var prefix: String?
        mutating func run() async throws {
            try await InstallCommand(context: context()).run(prefix: prefix)
        }
    }

    struct AndroidAddon: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "android-addon",
            abstract: "Install or deactivate an independently signed Android add-on.",
            subcommands: [Activate.self, Deactivate.self, Uninstall.self])

        struct Activate: AsyncParsableCommand {
            @Argument var artifact: String
            @Option(name: .customLong("trust-key")) var trustKey: String?
            @Option(name: .customLong("base-prefix")) var basePrefix: String?
            @Option(name: .customLong("store-root")) var storeRoot: String?
            @Option(name: .customLong("state-root")) var stateRoot: String?

            mutating func run() async throws {
                let workspace = try context()
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

        struct Deactivate: ParsableCommand {
            @Option(name: .customLong("store-root")) var storeRoot: String?
            @Option(name: .customLong("state-root")) var stateRoot: String?

            mutating func run() throws {
                let workspace = try context()
                try AndroidAddonInstallCommand().deactivate(
                    storeRoot: storeRoot.map {
                        URL(resolveWorkspacePath($0, relativeTo: workspace.root))
                    } ?? URL(workspace.layout.androidAddonStore),
                    persistentStateRoot: stateRoot.map {
                        URL(resolveWorkspacePath($0, relativeTo: workspace.root))
                    } ?? URL(workspace.layout.androidPersistentState))
            }
        }

        struct Uninstall: ParsableCommand {
            @Option(name: .customLong("store-root")) var storeRoot: String?
            @Option(name: .customLong("state-root")) var stateRoot: String?

            mutating func run() throws {
                let workspace = try context()
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
    #endif

    struct Browser: TaskControlledCommand {
        @OptionGroup var taskOptions: TaskControlOptions
        @Option var prefix: String?

        mutating func run() async throws {
            try await ChromiumCommand(context: context()).run(
                .install,
                controls: taskOptions.controls,
                installPrefix: prefix)
        }
    }
}
