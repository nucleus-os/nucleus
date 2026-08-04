import ArgumentParser
import Foundation
import QualificationColliderRecipe
import SystemPackage

#if os(Linux)
import Glibc
import NucleusSessionProtocol
#endif

enum OptimizationMode: String, Equatable, ExpressibleByArgument {
    case debug
    case release
}

enum PresentMode: String, Equatable, ExpressibleByArgument {
    case vsync
    case mailboxLatestWins = "mailbox_latest_wins"
}

struct RunOptions: ParsableArguments {
    @Option var output: String?
    @Option var name: String?
    @Option var host: String?
    @Option var port: Int?
    @Option var seconds: Int?
    @Option var scale: Double?
    @Option(name: .customLong("present-mode")) var presentMode: PresentMode?
    @Option(name: .customLong("drm-device")) var drmDevice: String?
    @Option var wallpaper: String?
    @Flag(name: .customLong("no-build")) var noBuild = false
    @Flag var android = false
    @Flag(name: .customLong("vk-validation")) var validation = false
    @Flag(name: .customLong("trace-diagnostics")) var diagnostics = false
    @Option(name: .customLong("optimize")) var optimization: OptimizationMode?
    @Flag var tracy = false
    @Flag var valgrind = false
    @Option(name: .customLong("sanitize")) var sanitizer: SanitizerKind?
    @Argument(parsing: .postTerminator) var compositorArguments: [String] = []
    var xwaylandExecutablePath: String?

    var captureOutput: String { output ?? "profiles" }
    var captureName: String { name ?? runtimeTimestamp() }
    var captureHost: String { host ?? "127.0.0.1" }
    var capturePort: Int { port ?? 8086 }
    var build: Bool { !noBuild }

    var buildOptions: RuntimeBuildOptions {
        RuntimeBuildOptions(
            optimization: effectiveOptimization,
            tracy: tracy,
            sanitizer: sanitizer)
    }

    var effectiveOptimization: OptimizationMode {
        optimization ?? (tracy ? .release : .debug)
    }

    func validated() throws -> RunOptions {
        if !(1...65_535).contains(capturePort) {
            throw WorkspaceFailure.message("invalid Tracy port")
        }
        if let seconds, seconds <= 0 {
            throw WorkspaceFailure.message("--seconds must be positive")
        }
        if let scale, !scale.isFinite || scale <= 0 {
            throw WorkspaceFailure.message(
                "--scale must be a positive finite number")
        }
        if (output != nil || name != nil) && !tracy && !valgrind {
            throw WorkspaceFailure.message(
                "capture options require --tracy (or --valgrind for --output/--name)")
        }
        if (host != nil || port != nil) && !tracy {
            throw WorkspaceFailure.message(
                "Tracy capture options require --tracy")
        }
        if valgrind && tracy {
            throw WorkspaceFailure.message("--valgrind and --tracy cannot be combined")
        }
        if valgrind && sanitizer != nil {
            throw WorkspaceFailure.message("--valgrind and --sanitize cannot be combined")
        }
        #if os(Linux)
        try validateSessionConfiguration()
        #endif
        return self
    }
}

func runtimeTimestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
    return formatter.string(from: Date())
}

#if os(Linux)
extension PresentMode {
    var sessionValue: SessionPresentMode {
        switch self {
        case .vsync: .vsync
        case .mailboxLatestWins: .mailboxLatestWins
        }
    }
}

extension RunOptions {
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

    private func validateSessionConfiguration() throws {
        do {
            _ = try sessionConfiguration
        } catch {
            throw WorkspaceFailure.message("invalid session configuration: \(error)")
        }
    }
}

struct RunCommand {
    let context: WorkspaceContext

    func run(_ options: RunOptions) async throws {
        var options = options
        options.xwaylandExecutablePath = try resolveXwaylandExecutable(
            environment: context.environment)
        try requireLaunchableSeatEnvironment()

        let prefix = URL(context.layout.installPrefix)
        let installer = RuntimeInstaller()
        let installation: RuntimeInstallation
        if options.build {
            try await ComponentRegistry(context: context).installSession(
                prefix: FilePath(prefix),
                options: options.buildOptions)
            installation = RuntimeInstallation(prefix: prefix)
        } else {
            installation = try installer.existingSession(
                prefix: prefix,
                options: options.buildOptions)
        }

        var environment = context.environment
        try configureRuntimeEnvironment(options, environment: &environment)
        if options.android {
            try requireInstalledAndroidCapability()
            environment["NUCLEUS_SESSION_CAPABILITY_ROOT"] =
                context.layout.androidAddonStore
                .appending("session-capabilities").string
        }

        if options.tracy {
            if options.build {
                try await ComponentRegistry(context: context).buildTracyReceivers()
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
            compositorCommand =
                [
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
            compositorCommand =
                [installation.compositor.path]
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
            || context.environment["DISPLAY"] != nil
        {
            throw WorkspaceFailure.message(
                "cannot launch the DRM compositor inside an existing Wayland/X11 "
                    + "desktop session; switch to a free virtual terminal or a "
                    + "display-manager session")
        }
    }

    private func requireInstalledAndroidCapability() throws {
        let store = context.layout.androidAddonStore
        let manifest = store.appending(
            "session-capabilities/android.json")
        let executable = store.appending(
            "current/libexec/nucleus-android-runtime")
        let values = try? URL(manifest).resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isRegularFile == true,
            values?.isSymbolicLink != true,
            FileManager.default.isExecutableFile(
                atPath: executable.string)
        else {
            throw WorkspaceFailure.message(
                "the Android add-on is not installed; install a signed "
                    + "add-on generation before requesting --android")
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
            fileURLWithPath: options.captureOutput,
            relativeTo: URL(compositor, isDirectory: true)
        ).standardizedFileURL
        let directory = root.appendingPathComponent(options.captureName)
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
        guard
            let runDirectory = environment["NUCLEUS_RUN_DIR"].map({
                URL(fileURLWithPath: $0, isDirectory: true)
            })
        else {
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
                output: .file(FilePath(kittyLog))
            ) { kitty in
                try await kitty.waitUntilReady()
                let result = try await session.wait()
                guard
                    result.status == 0
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
#endif
