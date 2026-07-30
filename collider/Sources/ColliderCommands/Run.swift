import ArgumentParser
import Foundation
import NucleusSessionProtocol
import SystemPackage

#if os(Linux)
import Glibc
#endif

enum OptimizationMode: String, Equatable, ExpressibleByArgument {
    case debug
    case release
}

enum PresentMode: String, Equatable, ExpressibleByArgument {
    case vsync
    case mailboxLatestWins = "mailbox_latest_wins"

    var sessionValue: SessionPresentMode {
        switch self {
        case .vsync: .vsync
        case .mailboxLatestWins: .mailboxLatestWins
        }
    }
}

struct RunOptions: Equatable {
    var output = "profiles"
    var name = runtimeTimestamp()
    var host = "127.0.0.1"
    var port = 8086
    var seconds: Int?
    var scale: Double?
    var presentMode: PresentMode?
    var drmDevice: String?
    var wallpaper: String?
    var build = true
    var android = false
    var validation = false
    var diagnostics = false
    var optimization: OptimizationMode?
    var tracy = false
    var valgrind = false
    var sanitizer: RuntimeSanitizer?
    var compositorArguments: [String] = []
    var xwaylandExecutablePath: String?
    var outputOptionWasSpecified = false
    var tracyOnlyOptionWasSpecified = false

    var buildOptions: RuntimeBuildOptions {
        RuntimeBuildOptions(
            optimization: effectiveOptimization,
            tracy: tracy,
            sanitizer: sanitizer)
    }

    var effectiveOptimization: OptimizationMode {
        optimization ?? (tracy ? .release : .debug)
    }

    var sessionConfiguration: SessionConfiguration {
        get throws {
            try SessionConfiguration(
                outputScale: scale ?? 1,
                presentMode: (presentMode ?? .vsync).sessionValue,
                enableVulkanValidation: validation,
                traceProtocol: diagnostics,
                traceDrmDemand: diagnostics,
                drmDevicePath: drmDevice,
                wallpaperPath: wallpaper,
                xwaylandExecutablePath: xwaylandExecutablePath)
        }
    }

    func validated() throws -> RunOptions {
        if !(1...65_535).contains(port) {
            throw WorkspaceFailure.message("invalid Tracy port")
        }
        if let seconds, seconds <= 0 {
            throw WorkspaceFailure.message("--seconds must be positive")
        }
        if let scale, !scale.isFinite || scale <= 0 {
            throw WorkspaceFailure.message(
                "--scale must be a positive finite number")
        }
        if outputOptionWasSpecified && !tracy && !valgrind {
            throw WorkspaceFailure.message(
                "capture options require --tracy (or --valgrind for --output/--name)")
        }
        if tracyOnlyOptionWasSpecified && !tracy {
            throw WorkspaceFailure.message(
                "Tracy capture options require --tracy")
        }
        if valgrind && tracy {
            throw WorkspaceFailure.message("--valgrind and --tracy cannot be combined")
        }
        if valgrind && sanitizer != nil {
            throw WorkspaceFailure.message("--valgrind and --sanitize cannot be combined")
        }
        do {
            _ = try sessionConfiguration
        } catch {
            throw WorkspaceFailure.message("invalid session configuration: \(error)")
        }
        return self
    }
}

struct RunCommand {
    let context: WorkspaceContext

    func run(_ options: RunOptions) async throws {
        var options = options
        options.xwaylandExecutablePath = try resolveXwaylandExecutable(
            environment: context.environment)
        try requireLaunchableSeatEnvironment()

        let prefix = context.layout.installPrefix
        let installer = RuntimeInstaller(context: context)
        let installation =
            if options.build {
                try await installer.install(
                    prefix: prefix,
                    options: options.buildOptions)
            } else {
                try installer.existingSession(
                prefix: prefix,
                options: options.buildOptions)
            }

        var environment = context.environment
        try configureRuntimeEnvironment(options, environment: &environment)
        if options.android {
            try requireInstalledAndroidCapability(installation)
        }

        if options.tracy {
            if options.build {
                try await TracyTools(context: context).buildReceivers()
            }
            try await authenticateAndroidRuntimeIfNeeded(options)
            try await ProfileCapture(context: context).run(
                options: options,
                installation: installation,
                environment: environment,
                sessionLog: environment["NUCLEUS_RUN_LOG"].map {
                    URL(fileURLWithPath: $0)
                })
            return
        }

        let compositorCommand: [String]
        if options.valgrind {
            let directory = try createOutputDirectory(options)
            let log = directory.appendingPathComponent("valgrind.log")
            compositorCommand = [
                "valgrind",
                "--tool=memcheck",
                "--error-exitcode=70",
                "--log-file=\(log.path)",
                "--num-callers=40",
                "--track-origins=yes",
                "--leak-check=no",
                installation.compositor.path,
            ] + options.compositorArguments
            print("valgrind log: \(log.path)")
        } else {
            compositorCommand = [installation.compositor.path]
                + options.compositorArguments
        }
        try await authenticateAndroidRuntimeIfNeeded(options)
        var sessionArguments = [
            "--configuration", try options.sessionConfiguration.hexEncoded,
        ]
        if options.android {
            sessionArguments += ["--capability", "android"]
        }
        sessionArguments += ["--"] + compositorCommand
        try await runSession(
            options: options,
            installation: installation,
            arguments: sessionArguments,
            environment: environment)
    }

    private func requireLaunchableSeatEnvironment() throws {
        if context.environment["WAYLAND_DISPLAY"] != nil
            || context.environment["DISPLAY"] != nil {
            throw WorkspaceFailure.message(
                "cannot launch the DRM compositor inside an existing Wayland/X11 "
                + "desktop session; switch to a free virtual terminal or a "
                + "display-manager session")
        }
    }

    private func requireInstalledAndroidCapability(
        _ installation: RuntimeInstallation
    ) throws {
        let manifest = installation.prefix.appendingPathComponent(
            "share/nucleus/session-capabilities/android.json")
        let values = try? manifest.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isRegularFile == true,
              values?.isSymbolicLink != true,
              FileManager.default.isExecutableFile(
                atPath: installation.androidRuntime.path)
        else {
            throw WorkspaceFailure.message(
                "the Android runtime is not installed; build the signed "
                    + "Android image and rerun without --no-build")
        }
    }

    private func authenticateAndroidRuntimeIfNeeded(
        _ options: RunOptions
    ) async throws {
        guard options.android else { return }
        try await context.run(
            "sudo",
            ["--validate"],
            terminal: true)
    }

    private func configureRuntimeEnvironment(
        _ options: RunOptions,
        environment: inout [String: String]
    ) throws {
        if options.validation {
            let layer = try VulkanValidationLayer.resolve(
                environment: environment)
            layer.applying(to: &environment)
        }
        switch options.sanitizer {
        case .address:
            environment["ASAN_OPTIONS"] =
                "halt_on_error=1:abort_on_error=1:detect_leaks=0:symbolize=1"
        case .undefined:
            environment["UBSAN_OPTIONS"] =
                "halt_on_error=1:abort_on_error=1:print_stacktrace=1"
        case .thread:
            environment["TSAN_OPTIONS"] =
                "halt_on_error=1:abort_on_error=1:history_size=7:second_deadlock_stack=1"
        case nil:
            break
        }
    }

    private func createOutputDirectory(_ options: RunOptions) throws -> URL {
        let compositor = context.layout.compositor
        let root = URL(
            fileURLWithPath: options.output,
            relativeTo: compositor
        ).standardizedFileURL
        let directory = root.appendingPathComponent(options.name)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        return directory
    }

    private func runSession(
        options: RunOptions,
        installation: RuntimeInstallation,
        arguments: [String],
        environment: [String: String]
    ) async throws {
        if let seconds = options.seconds {
            print(
                "run duration: \(seconds) second"
                    + "\(seconds == 1 ? "" : "s")")
        }
        guard options.android else {
            try await context.run(
                installation.session.path,
                arguments,
                environmentOverrides: environment,
                timeoutSeconds: options.seconds,
                timeoutIsSuccess: options.seconds != nil,
                terminal: true)
            return
        }
        guard let runDirectory = environment["NUCLEUS_RUN_DIR"].map({
            URL(fileURLWithPath: $0, isDirectory: true)
        }) else {
            throw WorkspaceFailure.message(
                "Android runtime logging requires NUCLEUS_RUN_DIR")
        }
        let diagnostics = runDirectory.appendingPathComponent(
            "android-runtime",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: diagnostics,
            withIntermediateDirectories: true)
        let kittyLog = diagnostics.appendingPathComponent("kitty.log")
        try await context.withRunningCommand(
            installation.session.path,
            arguments,
            environmentOverrides: environment,
            terminal: true,
            timeoutSeconds: options.seconds
        ) { session in
            try await session.waitUntilReady()
            let runtimeDirectory = try await waitForSessionWaylandSocket(
                session,
                environment: environment)
            let invocation = AndroidRuntimeLogWindowInvocation(
                diagnosticsDirectory: diagnostics)
            try await context.withRunningCommand(
                invocation.executable,
                invocation.arguments,
                environmentOverrides: [
                    "XDG_RUNTIME_DIR": runtimeDirectory.path,
                    "WAYLAND_DISPLAY": "wayland-0",
                ],
                output: .file(FilePath(kittyLog.path))
            ) { kitty in
                try await kitty.waitUntilReady()
                let result = try await session.wait()
                guard result.status == 0
                    || result.timedOut && options.seconds != nil
                else {
                    throw WorkspaceFailure.process(
                        [installation.session.path] + arguments,
                        result.status)
                }
            }
        }
    }

    private func waitForSessionWaylandSocket(
        _ session: RunningCommand,
        environment: [String: String]
    ) async throws -> URL {
        let parentRuntimeDirectory =
            environment["XDG_RUNTIME_DIR"]
            ?? "/run/user/\(getuid())"
        guard parentRuntimeDirectory.hasPrefix("/") else {
            throw WorkspaceFailure.message(
                "XDG_RUNTIME_DIR must be absolute")
        }
        guard let processIdentifier = await session.processIdentifier else {
            throw WorkspaceFailure.message(
                "session process identifier is unavailable")
        }
        let runtimeDirectory = URL(
            fileURLWithPath: parentRuntimeDirectory,
            isDirectory: true
        ).appendingPathComponent(
            "nucleus-\(processIdentifier)",
            isDirectory: true)
        let socket = runtimeDirectory.appendingPathComponent("wayland-0")
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: socket.path) {
                return runtimeDirectory
            }
            guard await session.isRunning else {
                let result = try await session.wait()
                throw WorkspaceFailure.process(
                    ["nucleus-session"],
                    result.status)
            }
            try await ContinuousClock().sleep(for: .milliseconds(100))
        }
        throw WorkspaceFailure.message(
            "Nucleus Wayland socket was not published before the log-window "
                + "deadline")
    }
}

func runtimeTimestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
    return formatter.string(from: Date())
}
