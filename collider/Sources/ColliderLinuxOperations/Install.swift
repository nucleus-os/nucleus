import ColliderWorkspaceCommands
import Foundation
import SystemPackage

struct DevelopmentRuntimeGeneration {
    let prefix: URL

    var session: URL { prefix.appendingPathComponent("bin/nucleus-session") }
    var sessionSupervisor: URL {
        prefix.appendingPathComponent("libexec/NucleusSessionSupervisor")
    }
    var configService: URL {
        prefix.appendingPathComponent("libexec/NucleusConfigService")
    }
    var controlService: URL {
        prefix.appendingPathComponent("libexec/NucleusControlService")
    }
    var compositor: URL { prefix.appendingPathComponent("bin/NucleusCompositor") }
    var shell: URL { prefix.appendingPathComponent("bin/NucleusShell") }
    var controlCLI: URL { prefix.appendingPathComponent("bin/nucleus") }
    var pamHelper: URL {
        prefix.appendingPathComponent("libexec/NucleusShellPamHelper")
    }
}

struct DevelopmentRuntimeStore {
    func existingGeneration(
        prefix: URL,
        options: RuntimeBuildSelection
    ) throws -> DevelopmentRuntimeGeneration {
        let generation = DevelopmentRuntimeGeneration(prefix: prefix)
        for executable in [
            generation.session,
            generation.sessionSupervisor,
            generation.configService,
            generation.controlService,
            generation.compositor,
            generation.shell,
            generation.controlCLI,
            generation.pamHelper,
        ] where !FileManager.default.isExecutableFile(atPath: executable.path) {
            throw WorkspaceFailure.message(
                "development runtime is not published at \(prefix.path); rerun without --no-build")
        }

        let metadata = prefix.appendingPathComponent("share/nucleus/runtime-build.txt")
        guard let installed = try? String(contentsOf: metadata, encoding: .utf8),
            installed == options.metadata
        else {
            throw WorkspaceFailure.message(
                "published development runtime does not match the requested build; rerun without --no-build"
            )
        }
        return generation
    }
}

struct InstallCommand {
    let context: WorkspaceContext

    func run(
        prefix explicitPrefix: String?,
        controls: TaskControls
    ) async throws {
        let prefix = resolvedPrefix(explicit: explicitPrefix)
        try await ComponentRegistry(context: context).publishDevelopmentRuntime(
            prefix: FilePath(prefix),
            selection: RuntimeBuildSelection(),
            controls: controls)
        if !controls.dryRun {
            try context.console.diagnostic(
                "published development runtime → \(CommandConsole.render(path: prefix.path))")
        }
    }

    func resolvedPrefix(
        explicit value: String?
    ) -> URL {
        if let value {
            return URL(resolveWorkspacePath(value, relativeTo: context.root))
        }
        return URL(context.layout.developmentRuntimeCurrent)
    }
}
