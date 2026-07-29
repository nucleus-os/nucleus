import ArgumentParser
import ColliderCore
import ColliderRuntime
import FoundationEssentials
import SystemPackage

enum RuntimeSanitizer: String, CaseIterable, Equatable,
    ExpressibleByArgument
{
    case address
    case undefined
    case thread
}

struct RuntimeBuildOptions: Equatable {
    var optimization: OptimizationMode = .debug
    var tracy = false
    var sanitizer: RuntimeSanitizer?

    var identity: String {
        [
            optimization.rawValue,
            tracy ? "tracy" : "plain",
            sanitizer?.rawValue ?? "unsanitized",
        ].joined(separator: "-")
    }

    var metadata: String {
        """
        configuration=\(optimization.rawValue)
        tracy=\(tracy)
        sanitizer=\(sanitizer?.rawValue ?? "none")
        """ + "\n"
    }
}

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
    let context: WorkspaceContext

    func install(
        prefix: URL,
        options: RuntimeBuildOptions = RuntimeBuildOptions()
    ) async throws -> RuntimeInstallation {
        guard
            !FileManager.default.fileExists(atPath: prefix.path)
                || (try? FileManager.default.destinationOfSymbolicLink(
                    atPath: prefix.path)) != nil
        else {
            throw WorkspaceFailure.message(
                "runtime installation path must be absent or an active-generation symlink: \(prefix.path)"
            )
        }
        // Generation and candidate directories live under the repository's
        // already-ignored `.nucleus/` tree, keyed per active prefix, rather than
        // as bare siblings of the prefix. They must share a parent so their
        // publication rename is atomic; the active symlink can point anywhere.
        let generationsRoot = generationsRoot(for: prefix)
        try FileManager.default.createDirectory(
            at: generationsRoot,
            withIntermediateDirectories: true)
        let candidate = generationsRoot.appendingPathComponent(
            ".candidate-\(UUID().uuidString)",
            isDirectory: true)
        let installation = RuntimeInstallation(prefix: candidate)
        try? FileManager.default.removeItem(at: candidate)
        for directory in ["bin", "lib", "libexec", "share/nucleus"] {
            try FileManager.default.createDirectory(
                at: candidate.appendingPathComponent(directory),
                withIntermediateDirectories: true)
        }
        var published = false
        defer {
            if !published { try? FileManager.default.removeItem(at: candidate) }
        }

        _ = try await installRuntime(
            into: installation,
            publishedPrefix: prefix,
            options: options)
        try writeMetadata(options, into: installation)
        try validateStructure(installation)
        try await validateELF(installation)
        try await validateRelocation(installation)
        let identity = try ArtifactHasher.digest(tree: FilePath(candidate.path))
        let generation = generationsRoot.appendingPathComponent(
            hex(identity.bytes.prefix(12)), isDirectory: true)
        try GenerationPublisher.publish(
            candidate: FilePath(candidate.path),
            generation: FilePath(generation.path),
            active: FilePath(prefix.path))
        published = true
        try DirectoryLifecycle.prune(
            DirectoryRetentionPlan(
                safetyRoot: FilePath(context.layout.runtimeState.path),
                rules: [
                    DirectoryRetentionRule(
                        root: FilePath(generationsRoot.path),
                        current: FilePath(prefix.path),
                        retain: 3,
                        naming: .contentIdentity)
                ]))
        print("runtime generation: \(identity) \(generation.path)")
        return RuntimeInstallation(prefix: prefix)
    }

    /// Per-prefix generations root under the repository's ignored `.nucleus/`
    /// tree, e.g. `.nucleus/runtime/install/generations` for `<root>/.install`.
    private func generationsRoot(for prefix: URL) -> URL {
        context.layout.runtimeState
            .appendingPathComponent(
                generationKey(for: prefix),
                isDirectory: true
            )
            .appendingPathComponent("generations", isDirectory: true)
    }

    private func generationKey(for prefix: URL) -> String {
        let standardized = prefix.standardizedFileURL.path
        let rootPath = context.root.standardizedFileURL.path
        if standardized == rootPath { return "root" }
        if standardized.hasPrefix(rootPath + "/") {
            let sanitized = sanitizedKey(
                String(standardized.dropFirst(rootPath.count + 1)))
            if !sanitized.isEmpty { return sanitized }
        }
        return "external-"
            + hex(
                ArtifactHasher.digest(bytes: Array(standardized.utf8)).bytes.prefix(8))
    }

    private func sanitizedKey(_ value: String) -> String {
        var result = ""
        for character in value {
            if character.isLetter || character.isNumber {
                result.append(character)
            } else if character == "/" || character == "-" || character == "_" {
                result.append("-")
            }
        }
        while result.hasPrefix("-") { result.removeFirst() }
        while result.hasSuffix("-") { result.removeLast() }
        return result
    }

    private func hex(_ bytes: some Sequence<UInt8>) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var encoded: [UInt8] = []
        for byte in bytes {
            encoded.append(digits[Int(byte >> 4)])
            encoded.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }

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

    private func installRuntime(
        into installation: RuntimeInstallation,
        publishedPrefix: URL,
        options: RuntimeBuildOptions
    ) async throws -> URL {
        let swiftPM = try context.swiftPMInvocation(
            configuration: options.optimization == .debug ? .debug : .release,
            sanitizer: options.sanitizer?.rawValue,
            cFlags: options.tracy ? ["-DTRACY_ENABLE"] : [],
            linkerFlags: options.sanitizer == .undefined ? ["-lubsan"] : [])
        print("==> build complete runtime graph variant=\(options.identity)")
        try await context.run(
            "swift",
            swiftPM.commandArguments(["build"]),
            environmentOverrides: swiftPM.commandEnvironment(
                context.taskEnvironment))
        let products = URL(
            fileURLWithPath: swiftPM.configurationProducts.string,
            isDirectory: true)
        for product in [
            "NucleusCompositor",
            "NucleusSessionSupervisor",
            "NucleusConfigService",
            "NucleusControlService",
            "NucleusShell",
            "NucleusShellPamHelper",
            "nucleus",
        ] {
            let executable = products.appendingPathComponent(product)
            guard FileManager.default.isExecutableFile(atPath: executable.path)
            else {
                throw WorkspaceFailure.message(
                    "runtime product is missing after build: \(executable.path)")
            }
        }

        try await context.run(
            context.layout.tools.appendingPathComponent(
                "stage-runtime-elf.sh"
            ).path,
            [products.path, installation.prefix.path])

        let sessionPackage = context.layout.compositorSessionPackage
        for name in ["nucleus-session", "nucleus-session-validate"] {
            let source = sessionPackage.appendingPathComponent(name)
            try await context.run("bash", ["-n", source.path])
            try copyExecutable(
                source,
                to: installation.prefix.appendingPathComponent("bin/\(name)"))
        }

        let unitDirectory = installation.prefix.appendingPathComponent(
            "share/systemd/user")
        try FileManager.default.createDirectory(
            at: unitDirectory,
            withIntermediateDirectories: true)
        let template = try String(
            contentsOf: sessionPackage.appendingPathComponent("nucleus@.service"),
            encoding: .utf8)
        let unitPath = unitDirectory.appendingPathComponent("nucleus@.service")

        // Validate the complete candidate before publication. The active prefix
        // intentionally does not exist on a first install, so systemd must inspect
        // the candidate executables rather than the future active-generation link.
        let candidateBinDirectory = installation.prefix
            .appendingPathComponent("bin").path
        let validationUnit = template.replacing(
            "@bindir@",
            with: candidateBinDirectory)
        try Data(validationUnit.utf8).write(to: unitPath, options: .atomic)
        try await context.run(
            "systemd-analyze",
            ["--user", "--recursive-errors=no", "verify", unitPath.path])

        let publishedBinDirectory =
            publishedPrefix
            .appendingPathComponent("bin").path
        let publishedUnit = template.replacing(
            "@bindir@",
            with: publishedBinDirectory)
        try Data(publishedUnit.utf8).write(to: unitPath, options: .atomic)
        return products
    }

    private func copyExecutable(_ source: URL, to destination: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.copyItem(at: source, to: destination)
        try manager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: destination.path)
    }

    private func writeMetadata(
        _ options: RuntimeBuildOptions,
        into installation: RuntimeInstallation
    ) throws {
        let directory = installation.prefix.appendingPathComponent("share/nucleus")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        try Data(options.metadata.utf8).write(
            to: directory.appendingPathComponent("runtime-build.txt"),
            options: .atomic)
    }

    private func validateStructure(
        _ installation: RuntimeInstallation
    ) throws {
        let executables = [
            installation.session,
            installation.sessionSupervisor,
            installation.configService,
            installation.controlService,
            installation.compositor,
            installation.shell,
            installation.controlCLI,
            installation.pamHelper,
        ]
        for executable in executables
        where
            !FileManager.default.isExecutableFile(atPath: executable.path)
        {
            throw WorkspaceFailure.message(
                "runtime candidate is missing executable \(executable.path)")
        }
        let metadata = installation.prefix.appendingPathComponent(
            "share/nucleus/runtime-build.txt")
        guard FileManager.default.fileExists(atPath: metadata.path) else {
            throw WorkspaceFailure.message(
                "runtime candidate is missing build metadata")
        }
    }

    private func validateELF(
        _ installation: RuntimeInstallation
    ) async throws {
        let validator = context.layout.tools.appendingPathComponent(
            "validate-runtime-elf.sh")
        let stagedManifest = installation.prefix.appendingPathComponent(
            "share/nucleus/runtime-elf-ownership.tsv")
        try await context.run(
            validator.path,
            [installation.prefix.path, stagedManifest.path])
    }

    private func validateRelocation(
        _ installation: RuntimeInstallation
    ) async throws {
        let original = installation.prefix
        let relocated = original.deletingLastPathComponent()
            .appendingPathComponent(
                ".relocation-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.moveItem(at: original, to: relocated)
        do {
            let validator = context.layout.tools.appendingPathComponent(
                "validate-runtime-elf.sh")
            let manifest = relocated.appendingPathComponent(
                "share/nucleus/runtime-elf-ownership.tsv")
            try await context.run(
                validator.path,
                [relocated.path, manifest.path])
            try FileManager.default.moveItem(at: relocated, to: original)
        } catch {
            try? FileManager.default.moveItem(at: relocated, to: original)
            throw error
        }
    }
}

struct InstallCommand {
    let context: WorkspaceContext

    func run(
        prefix explicitPrefix: String?
    ) async throws {
        let prefix = resolvedPrefix(explicit: explicitPrefix)
        _ = try await RuntimeInstaller(context: context).install(
            prefix: prefix)
        print("installed session runtime → \(prefix.path)")
    }

    func resolvedPrefix(
        explicit value: String?
    ) -> URL {
        if let value {
            return URL(
                fileURLWithPath: value,
                relativeTo: context.root
            ).standardizedFileURL
        }
        return context.layout.installPrefix
    }
}
