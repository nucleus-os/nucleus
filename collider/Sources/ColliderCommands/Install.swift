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
        prefix.appendingPathComponent("bin/nucleus-session-supervisor")
    }
    var compositor: URL { prefix.appendingPathComponent("bin/nucleus-compositor") }
    var shell: URL { prefix.appendingPathComponent("bin/nucleus-shell") }
    var pamHelper: URL { prefix.appendingPathComponent("bin/nucleus-pam-helper") }
}

struct RuntimeInstaller {
    enum Component: String, ExpressibleByArgument {
        case compositor
        case shell
        case session
    }

    let context: WorkspaceContext

    func install(
        _ component: Component,
        prefix: URL,
        options: RuntimeBuildOptions = RuntimeBuildOptions()
    ) async throws -> RuntimeInstallation {
        guard !FileManager.default.fileExists(atPath: prefix.path)
            || (try? FileManager.default.destinationOfSymbolicLink(
                atPath: prefix.path)) != nil
        else {
            throw WorkspaceFailure.message(
                "runtime installation path must be absent or an active-generation symlink: \(prefix.path)")
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
        try FileManager.default.createDirectory(
            at: candidate.appendingPathComponent("bin"),
            withIntermediateDirectories: true)
        var published = false
        defer {
            if !published { try? FileManager.default.removeItem(at: candidate) }
        }

        switch component {
        case .compositor:
            try await installCompositor(
                into: installation, publishedPrefix: prefix, options: options)
        case .shell:
            try await installShell(
                into: installation,
                options: options)
        case .session:
            try await installCompositor(
                into: installation, publishedPrefix: prefix, options: options)
            // Tracy has one capture endpoint. Instrument the compositor, which
            // owns the frame and presentation timeline, while keeping the
            // independently supervised shell on the same sanitizer policy.
            var shellOptions = options
            shellOptions.tracy = false
            try await installShell(
                into: installation,
                options: shellOptions)
            try writeMetadata(options, into: installation)
        }
        try validate(component, installation: installation)
        let identity = try ArtifactHasher.digest(tree: FilePath(candidate.path))
        let generation = generationsRoot.appendingPathComponent(
            hex(identity.bytes.prefix(12)), isDirectory: true)
        try GenerationPublisher.publish(
            candidate: FilePath(candidate.path),
            generation: FilePath(generation.path),
            active: FilePath(prefix.path))
        published = true
        try DirectoryLifecycle.prune(DirectoryRetentionPlan(
            safetyRoot: FilePath(
                context.root.appendingPathComponent(".nucleus/runtime").path),
            rules: [
                DirectoryRetentionRule(
                    root: FilePath(generationsRoot.path),
                    current: FilePath(prefix.path),
                    retain: 3,
                    naming: .contentIdentity),
            ]))
        print("runtime generation: \(identity) \(generation.path)")
        return RuntimeInstallation(prefix: prefix)
    }

    /// Per-prefix generations root under the repository's ignored `.nucleus/`
    /// tree, e.g. `.nucleus/runtime/install/generations` for `<root>/.install`.
    private func generationsRoot(for prefix: URL) -> URL {
        context.root.appendingPathComponent(
            ".nucleus/runtime/\(generationKey(for: prefix))/generations",
            isDirectory: true)
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
        return "external-" + hex(
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
            installation.compositor,
            installation.shell,
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

    private func installCompositor(
        into installation: RuntimeInstallation,
        publishedPrefix: URL,
        options: RuntimeBuildOptions
    ) async throws {
        let executable = try await buildProduct(
            "NucleusCompositor",
            packagePath: "compositor/compositor",
            component: "compositor",
            options: options)
        try copyExecutable(executable, to: installation.compositor)

        let supervisor = try await buildProduct(
            "NucleusSessionSupervisor",
            packagePath: "platform-linux",
            component: "session-supervisor",
            options: options)
        try copyExecutable(supervisor, to: installation.sessionSupervisor)

        let sessionPackage = context.root.appendingPathComponent(
            "compositor/packages/session")
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

        let publishedBinDirectory = publishedPrefix
            .appendingPathComponent("bin").path
        let publishedUnit = template.replacing(
            "@bindir@",
            with: publishedBinDirectory)
        try Data(publishedUnit.utf8).write(to: unitPath, options: .atomic)
    }

    private func installShell(
        into installation: RuntimeInstallation,
        options: RuntimeBuildOptions
    ) async throws {
        let shell = try await buildProduct(
            "NucleusShell",
            packagePath: "shell",
            component: "shell",
            options: options)
        let helper = try await buildProduct(
            "NucleusShellPamHelper",
            packagePath: "shell",
            component: "shell",
            options: options)
        try copyExecutable(shell, to: installation.shell)
        try copyExecutable(helper, to: installation.pamHelper)
    }

    private func buildProduct(
        _ product: String,
        packagePath: String,
        component: String,
        options: RuntimeBuildOptions
    ) async throws -> URL {
        var arguments = [
            "build",
            "--package-path", packagePath,
            "--configuration", options.optimization.rawValue,
            "--product", product,
        ]
        if options.tracy {
            arguments += ["-Xcc", "-DTRACY_ENABLE"]
        }
        if let sanitizer = options.sanitizer {
            arguments += ["--sanitize", sanitizer.rawValue]
            if sanitizer == .undefined {
                arguments += ["-Xlinker", "-lubsan"]
            }
        }
        if options.tracy || options.sanitizer != nil {
            let scratch = context.root
                .appendingPathComponent(".build/nucleus-runtime")
                .appendingPathComponent(options.identity)
                .appendingPathComponent(component)
            arguments += ["--scratch-path", scratch.path]
        }

        print("==> build runtime product=\(product) variant=\(options.identity)")
        try await context.run("swift", arguments)
        let binPath = try await context.run(
            "swift", arguments + ["--show-bin-path"], capture: true)
        guard let lastLine = binPath.split(separator: "\n").last else {
            throw WorkspaceFailure.message(
                "SwiftPM did not report a binary path for \(product)")
        }
        let executable = URL(fileURLWithPath: String(lastLine))
            .appendingPathComponent(product)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw WorkspaceFailure.message(
                "runtime product is missing after build: \(executable.path)")
        }
        return executable
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

    private func validate(
        _ component: Component,
        installation: RuntimeInstallation
    ) throws {
        let executables: [URL]
        switch component {
        case .compositor:
            executables = [
                installation.session,
                installation.sessionSupervisor,
                installation.compositor,
            ]
        case .shell:
            executables = [installation.shell, installation.pamHelper]
        case .session:
            executables = [
                installation.session,
                installation.sessionSupervisor,
                installation.compositor,
                installation.shell,
                installation.pamHelper,
            ]
        }
        for executable in executables where
            !FileManager.default.isExecutableFile(atPath: executable.path)
        {
            throw WorkspaceFailure.message(
                "runtime candidate is missing executable \(executable.path)")
        }
        if component == .session {
            let metadata = installation.prefix.appendingPathComponent(
                "share/nucleus/runtime-build.txt")
            guard FileManager.default.fileExists(atPath: metadata.path) else {
                throw WorkspaceFailure.message(
                    "runtime candidate is missing build metadata")
            }
        }
    }
}

struct InstallCommand {
    let context: WorkspaceContext

    func run(
        _ component: RuntimeInstaller.Component,
        prefix explicitPrefix: String?
    ) async throws {
        let prefix = resolvedPrefix(
            for: component,
            explicit: explicitPrefix)
        _ = try await RuntimeInstaller(context: context).install(
            component,
            prefix: prefix)
        print("installed \(component.rawValue) runtime → \(prefix.path)")
    }

    func resolvedPrefix(
        for component: RuntimeInstaller.Component,
        explicit value: String?
    ) -> URL {
        if let value {
            return URL(
                fileURLWithPath: value,
                relativeTo: context.root
            ).standardizedFileURL
        }
        return defaultPrefix(for: component)
    }

    private func defaultPrefix(for component: RuntimeInstaller.Component) -> URL {
        switch component {
        case .compositor:
            context.root.appendingPathComponent("compositor/compositor/.install")
        case .shell:
            context.root.appendingPathComponent("shell/.install")
        case .session:
            context.root.appendingPathComponent(".install")
        }
    }
}
