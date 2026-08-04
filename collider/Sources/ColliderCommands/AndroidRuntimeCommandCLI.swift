import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

struct AndroidRuntime: AsyncParsableCommand {
    private static func subcommands() -> [ParsableCommand.Type] {
        var commands: [ParsableCommand.Type] = [
            SourceLock.self,
            Source.self,
            Image.self,
        ]
        #if os(Linux)
        commands.append(PackageAddon.self)
        #endif
        return commands
    }

    static let configuration = CommandConfiguration(
        commandName: "android-runtime",
        abstract: "Build and operate the contained Android runtime.",
        subcommands: subcommands())

    struct SourceLock: TaskControlledCommand {
        static let configuration = CommandConfiguration(
            commandName: "source-lock",
            abstract: "Verify the pinned AOSP and Repo identities.")
        @OptionGroup var taskOptions: TaskControlOptions

        mutating func run() async throws {
            try await ComponentRegistry(context: context())
                .verifyAndroidRuntimeSourceLock(
                    controls: taskOptions.controls)
        }
    }

    struct Source: TaskControlledCommand {
        static let configuration = CommandConfiguration(
            abstract: "Materialize the exact AOSP source checkout.")
        @OptionGroup var taskOptions: TaskControlOptions

        mutating func run() async throws {
            try await ComponentRegistry(context: context())
                .prepareAndroidRuntimeSource(
                    controls: taskOptions.controls)
        }
    }

    struct Image: TaskControlledCommand {
        static let configuration = CommandConfiguration(
            abstract: "Build and release-sign the Nucleus Android images.")
        @OptionGroup var taskOptions: TaskControlOptions

        mutating func run() async throws {
            try await ComponentRegistry(context: context())
                .buildAndroidRuntimeImage(
                    controls: taskOptions.controls)
        }
    }

    #if os(Linux)
    struct PackageAddon: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "package-addon",
            abstract: "Assemble and sign a downloadable Android add-on artifact.")
        @Option(name: .customLong("runtime-root")) var runtimeRoot: String?
        @Option(name: .customLong("aosp-generation")) var aospGeneration: String?
        @Option(name: .customLong("compatibility")) var compatibility: String
        @Option(name: .customLong("aosp-signing-key")) var aospSigningKey: String
        @Option(name: .customLong("addon-signing-key")) var addonSigningKey: String
        @Option var output: String

        mutating func run() async throws {
            let workspace = try context()
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
                aospSigningKey:
                    resolveWorkspacePath(aospSigningKey, relativeTo: workspace.root),
                addonSigningKey:
                    resolveWorkspacePath(addonSigningKey, relativeTo: workspace.root),
                output:
                    resolveWorkspacePath(output, relativeTo: workspace.root))
        }
    }
    #endif

}
