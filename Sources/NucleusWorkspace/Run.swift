import Foundation // Process is required for detached session lifecycle management.
import NucleusLinuxSession
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

struct RunOptions: Equatable {
    var output = "profiles"
    var name = runtimeTimestamp()
    var host = "127.0.0.1"
    var port = 8086
    var seconds: Int?
    var scale: Double?
    var presentMode: String?
    var drmDevice: String?
    var wallpaper: String?
    var build = true
    var validation = false
    var diagnostics = false
    var configuration = "debug"
    var tracy = false
    var valgrind = false
    var sanitizer: RuntimeSanitizer?
    var compositorArguments: [String] = []

    var buildOptions: RuntimeBuildOptions {
        RuntimeBuildOptions(
            configuration: configuration,
            tracy: tracy,
            sanitizer: sanitizer)
    }

    var sessionConfiguration: SessionConfiguration {
        get throws {
            try SessionConfiguration(
                outputScale: scale ?? 1,
                presentMode: presentMode == "mailbox_latest_wins"
                    ? .mailboxLatestWins
                    : .vsync,
                enableVulkanValidation: validation,
                traceProtocol: diagnostics,
                traceDrmDemand: diagnostics,
                drmDevicePath: drmDevice,
                wallpaperPath: wallpaper)
        }
    }

    static func parse(_ input: [String]) throws -> RunOptions? {
        var value = RunOptions()
        var outputOption = false
        var tracyOnlyOption = false
        var optimizationOption = false
        var index = 0

        func argument(_ option: String) throws -> String {
            guard index + 1 < input.count else {
                throw WorkspaceFailure.message("missing value for \(option)")
            }
            index += 1
            return input[index]
        }

        while index < input.count {
            switch input[index] {
            case "--tracy":
                value.tracy = true
            case "--output":
                value.output = try argument("--output")
                outputOption = true
            case "--name":
                value.name = try argument("--name")
                outputOption = true
            case "--host":
                value.host = try argument("--host")
                tracyOnlyOption = true
            case "--port":
                guard let port = Int(try argument("--port")),
                      (1...65535).contains(port)
                else {
                    throw WorkspaceFailure.message("invalid Tracy port")
                }
                value.port = port
                tracyOnlyOption = true
            case "--seconds":
                guard let seconds = Int(try argument("--seconds")), seconds > 0 else {
                    throw WorkspaceFailure.message("--seconds must be positive")
                }
                value.seconds = seconds
            case "--scale":
                guard let scale = Double(try argument("--scale")),
                      scale.isFinite,
                      scale > 0
                else {
                    throw WorkspaceFailure.message("--scale must be a positive finite number")
                }
                value.scale = scale
            case "--present-mode":
                value.presentMode = try argument("--present-mode")
            case "--drm-device":
                value.drmDevice = try argument("--drm-device")
            case "--wallpaper":
                value.wallpaper = try argument("--wallpaper")
            case "--optimize":
                value.configuration = try argument("--optimize")
                optimizationOption = true
            case "--sanitize":
                let rawValue = try argument("--sanitize")
                guard let sanitizer = RuntimeSanitizer(rawValue: rawValue) else {
                    throw WorkspaceFailure.message(
                        "--sanitize must be address, undefined, or thread")
                }
                value.sanitizer = sanitizer
            case "--no-build":
                value.build = false
            case "--vk-validation":
                value.validation = true
            case "--trace-diagnostics":
                value.diagnostics = true
            case "--valgrind":
                value.valgrind = true
            case "--":
                value.compositorArguments = Array(input.dropFirst(index + 1))
                return try value.validated(
                    outputOption: outputOption,
                    tracyOnlyOption: tracyOnlyOption,
                    optimizationOption: optimizationOption)
            case "-h", "--help":
                return nil
            default:
                throw WorkspaceFailure.message(
                    "unknown run option '\(input[index])'\n\n\(RunCommand.usage)")
            }
            index += 1
        }
        return try value.validated(
            outputOption: outputOption,
            tracyOnlyOption: tracyOnlyOption,
            optimizationOption: optimizationOption)
    }

    private func validated(
        outputOption: Bool,
        tracyOnlyOption: Bool,
        optimizationOption: Bool
    ) throws -> RunOptions {
        guard ["debug", "release"].contains(configuration) else {
            throw WorkspaceFailure.message("--optimize must be debug or release")
        }
        if let presentMode,
           !["vsync", "mailbox_latest_wins"].contains(presentMode) {
            throw WorkspaceFailure.message(
                "--present-mode must be vsync or mailbox_latest_wins")
        }
        if outputOption && !tracy && !valgrind {
            throw WorkspaceFailure.message(
                "capture options require --tracy (or --valgrind for --output/--name)")
        }
        if tracyOnlyOption && !tracy {
            throw WorkspaceFailure.message(
                "Tracy capture options require --tracy")
        }
        if valgrind && tracy {
            throw WorkspaceFailure.message("--valgrind and --tracy cannot be combined")
        }
        if valgrind && sanitizer != nil {
            throw WorkspaceFailure.message("--valgrind and --sanitize cannot be combined")
        }
        var value = self
        if tracy && !optimizationOption {
            value.configuration = "release"
        }
        do {
            _ = try value.sessionConfiguration
        } catch {
            throw WorkspaceFailure.message("invalid session configuration: \(error)")
        }
        return value
    }
}

struct RunCommand {
    let context: WorkspaceContext

    static let usage = """
    Usage: tools/nucleus run [options] [-- compositor-arguments]

      --optimize debug|release  (default: debug; Tracy: release)
      --no-build
      --seconds N              stop the run after N seconds
      --scale N                output scale (default: 1)
      --present-mode vsync|mailbox_latest_wins
      --drm-device /dev/dri/renderD...
      --wallpaper PATH
      --vk-validation
      --trace-diagnostics
      --sanitize address|undefined|thread
      --valgrind

    Tracy capture:
      --tracy
      --output DIR --name NAME --host HOST --port PORT

    Logs:
      logs/nucleus-<UTC timestamp>-<pid>.log
      logs/latest -> most recent run
    """

    func run(_ arguments: ArraySlice<String>) throws {
        guard let options = try RunOptions.parse(Array(arguments)) else {
            print(Self.usage)
            return
        }
        try requireLaunchableSeatEnvironment()

        let prefix = context.root.appendingPathComponent(".install")
        let installer = RuntimeInstaller(context: context)
        let installation = options.build
            ? try installer.install(
                .session,
                prefix: prefix,
                options: options.buildOptions)
            : try installer.existingSession(
                prefix: prefix,
                options: options.buildOptions)

        var environment = context.environment
        try configureRuntimeEnvironment(options, environment: &environment)

        if options.tracy {
            if options.build {
                try TracyTools(context: context).buildReceivers()
            }
            try ProfileCapture(context: context).run(
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
            try runForDuration(
                seconds,
                executable: installation.session,
                arguments: sessionArguments,
                environment: environment)
        } else {
            try replaceProcess(
                with: installation.session,
                arguments: sessionArguments,
                environment: environment)
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
            let script = context.root.appendingPathComponent(
                "compositor/scripts/run-vk-validation.sh")
            try context.run(script.path, ["--check"])
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

    private func replaceProcess(
        with executable: URL,
        arguments: [String],
        environment: [String: String]
    ) throws {
        for (key, value) in environment {
            guard setenv(key, value, 1) == 0 else {
                throw WorkspaceFailure.message(
                    "could not configure runtime environment variable \(key): errno \(errno)")
            }
        }
        let storage: [UnsafeMutablePointer<CChar>?] =
            ([executable.path] + arguments).map { strdup($0) } + [nil]
        defer { storage.forEach { free($0) } }
        fflush(nil)
        _ = storage.withUnsafeBufferPointer { buffer in
            execv(
                executable.path,
                UnsafeMutablePointer(mutating: buffer.baseAddress!))
        }
        throw WorkspaceFailure.message(
            "could not launch \(executable.path): errno \(errno)")
    }

    private func runForDuration(
        _ seconds: Int,
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        try process.run()

        print("run duration: \(seconds) second\(seconds == 1 ? "" : "s")")
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            print("run duration reached; stopping session")
            process.terminate()
            for _ in 0..<60 where process.isRunning {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            return
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw WorkspaceFailure.process(
                [executable.path] + arguments,
                process.terminationStatus)
        }
    }
}

func runtimeTimestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
    return formatter.string(from: Date())
}
