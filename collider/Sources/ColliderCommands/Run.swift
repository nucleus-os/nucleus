import ArgumentParser
import Foundation
import NucleusSessionProtocol

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

        let prefix = context.root.appendingPathComponent(".install")
        let installer = RuntimeInstaller(context: context)
        let installation =
            if options.build {
                try await installer.install(
                .session,
                prefix: prefix,
                options: options.buildOptions)
            } else {
                try installer.existingSession(
                prefix: prefix,
                options: options.buildOptions)
            }

        var environment = context.environment
        try configureRuntimeEnvironment(options, environment: &environment)

        if options.tracy {
            if options.build {
                try await TracyTools(context: context).buildReceivers()
            }
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
        let sessionArguments = [
            "--configuration", try options.sessionConfiguration.hexEncoded,
            "--",
        ] + compositorCommand
        if let seconds = options.seconds {
            try await runForDuration(
                seconds,
                executable: installation.session,
                arguments: sessionArguments,
                environment: environment)
        } else {
            try await context.run(
                installation.session.path,
                sessionArguments,
                environmentOverrides: environment,
                terminal: true)
        }
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
        let compositor = context.root.appendingPathComponent("compositor")
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

    private func runForDuration(
        _ seconds: Int,
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) async throws {
        print("run duration: \(seconds) second\(seconds == 1 ? "" : "s")")
        try await context.run(
            executable.path,
            arguments,
            environmentOverrides: environment,
            timeoutSeconds: seconds,
            timeoutIsSuccess: true,
            terminal: true)
    }
}

func runtimeTimestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
    return formatter.string(from: Date())
}
