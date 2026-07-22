import Foundation

enum RuntimeSanitizer: String, CaseIterable, Equatable {
    case address
    case undefined
    case thread
}

struct RuntimeBuildOptions: Equatable {
    var configuration = "debug"
    var tracy = false
    var sanitizer: RuntimeSanitizer?

    var identity: String {
        [
            configuration,
            tracy ? "tracy" : "plain",
            sanitizer?.rawValue ?? "unsanitized",
        ].joined(separator: "-")
    }

    var metadata: String {
        """
        runtime_schema=1
        configuration=\(configuration)
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
    enum Component: String {
        case compositor
        case shell
        case session
    }

    let context: WorkspaceContext

    func install(
        _ component: Component,
        prefix: URL,
        options: RuntimeBuildOptions = RuntimeBuildOptions()
    ) throws -> RuntimeInstallation {
        let installation = RuntimeInstallation(prefix: prefix)
        try FileManager.default.createDirectory(
            at: prefix.appendingPathComponent("bin"),
            withIntermediateDirectories: true)

        switch component {
        case .compositor:
            try installCompositor(into: installation, options: options)
        case .shell:
            try installShell(into: installation, options: options)
        case .session:
            try installCompositor(into: installation, options: options)
            // Tracy has one capture endpoint. Instrument the compositor, which
            // owns the frame and presentation timeline, while keeping the
            // independently supervised shell on the same sanitizer policy.
            var shellOptions = options
            shellOptions.tracy = false
            try installShell(into: installation, options: shellOptions)
            try writeMetadata(options, into: installation)
        }
        return installation
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
        options: RuntimeBuildOptions
    ) throws {
        let executable = try buildProduct(
            "NucleusCompositor",
            packagePath: "compositor/compositor",
            component: "compositor",
            options: options)
        try copyExecutable(executable, to: installation.compositor)

        let supervisor = try buildProduct(
            "NucleusSessionSupervisor",
            packagePath: "platform-linux",
            component: "session-supervisor",
            options: options)
        try copyExecutable(supervisor, to: installation.sessionSupervisor)

        let sessionPackage = context.root.appendingPathComponent(
            "compositor/packages/session")
        for name in ["nucleus-session", "nucleus-session-validate"] {
            let source = sessionPackage.appendingPathComponent(name)
            try context.run("bash", ["-n", source.path])
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
        let binDirectory = installation.prefix.appendingPathComponent("bin").path
        let unit = template.replacingOccurrences(
            of: "@bindir@", with: binDirectory)
        let unitPath = unitDirectory.appendingPathComponent("nucleus@.service")
        try Data(unit.utf8).write(to: unitPath, options: .atomic)
        try context.run(
            "systemd-analyze",
            ["--user", "--recursive-errors=no", "verify", unitPath.path])
    }

    private func installShell(
        into installation: RuntimeInstallation,
        options: RuntimeBuildOptions
    ) throws {
        let shell = try buildProduct(
            "NucleusShell",
            packagePath: "shell",
            component: "shell",
            options: options)
        let helper = try buildProduct(
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
    ) throws -> URL {
        var arguments = [
            "build",
            "--package-path", packagePath,
            "--configuration", options.configuration,
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
        try context.run("swift", arguments)
        let binPath = try context.run(
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
}

struct InstallCommand {
    let context: WorkspaceContext

    func run(_ arguments: ArraySlice<String>) throws {
        let arguments = Array(arguments)
        guard let name = arguments.first,
              let component = RuntimeInstaller.Component(rawValue: name)
        else {
            throw WorkspaceFailure.message(Self.usage)
        }
        let explicitPrefix = try parsePrefix(Array(arguments.dropFirst()))
        let prefix = explicitPrefix ?? defaultPrefix(for: component)
        _ = try RuntimeInstaller(context: context).install(
            component,
            prefix: prefix)
        print("installed \(component.rawValue) runtime → \(prefix.path)")
    }

    private func parsePrefix(_ arguments: [String]) throws -> URL? {
        guard !arguments.isEmpty else { return nil }
        guard arguments.count == 2, arguments[0] == "--prefix" else {
            throw WorkspaceFailure.message(Self.usage)
        }
        return URL(
            fileURLWithPath: arguments[1],
            relativeTo: context.root
        ).standardizedFileURL
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

    private static let usage = """
    Usage: tools/nucleus install compositor|shell|session [--prefix DIR]

    `session` installs the compositor, session launchers, native shell, and PAM
    helper into one prefix (default: <workspace>/.install).
    """
}
