#if os(Linux)
import Foundation
import SystemPackage

struct RuntimeInstallation {
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

struct RuntimeInstaller {
    func existingSession(
        prefix: URL,
        options: RuntimeBuildOptions
    ) throws -> RuntimeInstallation {
        let installation = RuntimeInstallation(prefix: prefix)
        for executable in [
            installation.session,
            installation.sessionSupervisor,
            installation.configService,
            installation.controlService,
            installation.compositor,
            installation.shell,
            installation.controlCLI,
            installation.pamHelper,
        ] where !FileManager.default.isExecutableFile(atPath: executable.path) {
            throw WorkspaceFailure.message(
                "runtime is not installed at \(prefix.path); rerun without --no-build")
        }

        let metadata = prefix.appendingPathComponent("share/nucleus/runtime-build.txt")
        guard let installed = try? String(contentsOf: metadata, encoding: .utf8),
            installed == options.metadata
        else {
            throw WorkspaceFailure.message(
                "installed runtime does not match the requested build; rerun without --no-build")
        }
        return installation
    }
}

struct InstallCommand {
    let context: WorkspaceContext

    func run(
        prefix explicitPrefix: String?
    ) async throws {
        let prefix = resolvedPrefix(explicit: explicitPrefix)
        try await ComponentRegistry(context: context).installSession(
            prefix: FilePath(prefix),
            options: RuntimeBuildOptions())
        print("installed session runtime → \(prefix.path)")
    }

    func resolvedPrefix(
        explicit value: String?
    ) -> URL {
        if let value {
            return URL(resolveWorkspacePath(value, relativeTo: context.root))
        }
        return URL(context.layout.installPrefix)
    }
}
#endif
