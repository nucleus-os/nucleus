import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

private func colliderCommandSubcommands() -> [ParsableCommand.Type] {
    var commands: [ParsableCommand.Type] = [
        Doctor.self, Bootstrap.self, Build.self, Test.self,
        Install.self, SwiftSDK.self, Android.self, AndroidRuntime.self,
        Browser.self,
        Generate.self, Sanitize.self, Benchmark.self,
        Validate.self, Cache.self, Logs.self, Status.self,
    ]
    #if os(Linux)
    commands.insert(Run.self, at: 4)
    #endif
    return commands
}

public struct ColliderCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "collider",
        abstract: "Build, validate, and operate the Nucleus repository.",
        version: "0.1.0",
        subcommands: colliderCommandSubcommands())

    public init() {}

    public static func execute(arguments: [String]) async throws {
        var command = try parseAsRoot(arguments)
        let environment = ProcessInfo.processInfo.environment
        let workspace = try resolveWorkspaceRoot(environment: environment)
        let layout = WorkspaceLayout(
            root: URL(fileURLWithPath: workspace, isDirectory: true))
        let registry = RunRegistry(
            root: FilePath(layout.state.path))
        let requestedRunID = requestedRunID(for: command)
        let run =
            if let requestedRunID {
                try await registry.resume(requestedRunID)
            } else {
                try await registry.begin(
                    command: [CommandLine.arguments[0]] + arguments)
            }
        let cancellation = RuntimeCancellation()
        let logging = CommandLogging(registry: registry, run: run)
        let runtime = ColliderRuntime(
            logging: logging,
            cancellation: cancellation)
        let signals = RuntimeSignalHandlers(cancellation: cancellation)
        setActiveCommandRuntime(
            logging: logging,
            cancellation: cancellation,
            runtime: runtime)
        defer {
            signals.cancel()
            setActiveCommandRuntime(
                logging: nil,
                cancellation: nil,
                runtime: nil)
        }
        do {
            if var asyncCommand = command as? any AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
            await runtime.shutdown()
            try await registry.finish(run, status: .succeeded)
        } catch let cleanExit as CleanExit {
            await runtime.shutdown()
            try? await registry.finish(run, status: .succeeded)
            throw cleanExit
        } catch {
            await runtime.shutdown()
            let wasInterrupted = await cancellation.wasInterrupted()
            try? await registry.appendLog(
                Array("Error: \(error)\n".utf8),
                in: run)
            let status = commandFailureStatus(
                error,
                wasInterrupted: wasInterrupted)
            try? await registry.finish(run, status: status)
            throw error
        }
    }
}

func commandFailureStatus(
    _ error: any Error,
    wasInterrupted: Bool
) -> RunStatus {
    if wasInterrupted {
        return .interrupted
    }
    if error is CancellationError {
        return .interrupted
    }
    if case .resumptionIdentityChanged = error as? RunRegistryFailure {
        return .interrupted
    }
    return .failed
}

struct RunIDArgument: ExpressibleByArgument, Equatable, Sendable {
    let value: RunID

    init?(argument: String) {
        guard !argument.isEmpty else { return nil }
        value = RunID(rawValue: argument)
    }
}

struct TaskControlOptions: ParsableArguments {
    @Flag(help: "Print the resolved task graph without executing it.")
    var dryRun = false

    @Flag(help: "Explain why each selected task is clean or dirty.")
    var explain = false

    @Flag(help: "Print each leaf command before executing it.")
    var verbose = false

    @Flag(help: "Keep task output in the durable run log without streaming it.")
    var quiet = false

    @Flag(help: "Emit stable machine-readable records.")
    var json = false

    @Option(name: .customLong("run-id"), help: "Resume an interrupted run.")
    var runID: RunIDArgument?

    mutating func validate() throws {
        guard !quiet || !verbose else {
            throw ValidationError("--quiet and --verbose are mutually exclusive")
        }
    }

    var controls: TaskControls {
        TaskControls(
            dryRun: dryRun,
            explain: explain,
            verbose: verbose,
            quiet: quiet,
            json: json)
    }
}

protocol ResumableRun {
    var requestedRunID: RunID? { get }
}

protocol TaskControlledCommand: AsyncParsableCommand, ResumableRun {
    var taskOptions: TaskControlOptions { get set }
}

extension TaskControlledCommand {
    var requestedRunID: RunID? { taskOptions.runID?.value }
}

func requestedRunID(for command: any ParsableCommand) -> RunID? {
    (command as? any ResumableRun)?.requestedRunID
}

struct ReportOptions: ParsableArguments {
    @Flag(help: "Emit stable machine-readable records.")
    var json = false
}

private func context() throws -> WorkspaceContext { try WorkspaceContext.load() }

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Report missing tools and repository prerequisites.")
    @Flag(help: "Print the resolved checks without executing them.")
    var dryRun = false
    @Flag(help: "Emit stable machine-readable records.")
    var json = false
    @Argument(
        help:
            "Prerequisite group: all, runtime, swift-sdk, android, browser, or ci-macos-builder.")
    var scope: DoctorScope = .all

    mutating func run() async throws {
        try await WorkspaceDoctor(context: context()).run(
            scope: scope,
            dryRun: dryRun,
            json: json)
    }
}

struct Bootstrap: TaskControlledCommand {
    @OptionGroup var taskOptions: TaskControlOptions
    @Argument(help: "all, runtime, browser, or a component name.")
    var component: ComponentSelection?

    mutating func run() async throws {
        let workspace = try context()
        if component == .browser {
            try await ChromiumCommand(context: workspace).run(
                .bootstrap,
                controls: taskOptions.controls)
        } else {
            try await ComponentRegistry(context: workspace).bootstrap(
                selection: component, controls: taskOptions.controls)
        }
    }
}

struct Build: TaskControlledCommand {
    @OptionGroup var taskOptions: TaskControlOptions
    @Argument(help: "all, runtime, swift-sdk, android, browser, or a component name.")
    var component: ComponentSelection?

    mutating func run() async throws {
        let workspace = try context()
        switch component {
        case .swiftSDK:
            try await SwiftSDKCommand(context: workspace).rebuild(
                RebuildOptions(controls: taskOptions.controls))
        case .android:
            try await AndroidCommand(context: workspace).run(
                .build(gradleArguments: []),
                controls: taskOptions.controls)
        case .browser:
            try await ChromiumCommand(context: workspace).run(
                .build,
                controls: taskOptions.controls)
        default:
            try await ComponentRegistry(context: workspace).build(
                selection: component, controls: taskOptions.controls)
        }
    }
}

struct Test: TaskControlledCommand {
    @OptionGroup var taskOptions: TaskControlOptions
    @Argument(
        help: """
            all, runtime, android, browser, loader, gpu-headless, gpu-drm, \
            or a component name.
            """)
    var component: ComponentSelection?

    mutating func run() async throws {
        let workspace = try context()
        if component == .android {
            try await workspace.withExclusiveVerification {
                try await AndroidCommand(context: workspace).run(
                    .build(gradleArguments: []),
                    controls: taskOptions.controls)
            }
            return
        }
        if component == .browser {
            try await workspace.withExclusiveVerification {
                try await ChromiumCommand(context: workspace).run(
                    .test,
                    controls: taskOptions.controls)
            }
            return
        }
        try await workspace.withExclusiveVerification {
            try await ComponentRegistry(context: workspace).test(
                selection: component, controls: taskOptions.controls)
            if component == nil || component == .all, !taskOptions.dryRun {
                try await Orchestrator(
                    context: workspace
                ).runRepositoryWideTestGates()
            }
        }
    }
}

#if os(Linux)
struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Build, install, and launch a compositor session.")
    @Flag var tracy = false
    @Option var output: String?
    @Option var name: String?
    @Option var host: String?
    @Option var port: Int?
    @Option var seconds: Int?
    @Option var scale: Double?
    @Option(name: .customLong("present-mode"))
    var presentMode: PresentMode?
    @Option(name: .customLong("drm-device")) var drmDevice: String?
    @Option var wallpaper: String?
    @Option(name: .customLong("optimize"))
    var optimization: OptimizationMode?
    @Option var sanitize: RuntimeSanitizer?
    @Flag(name: .customLong("no-build")) var noBuild = false
    @Flag(
        help:
            "Start the contained Android runtime as an optional session capability.")
    var android = false
    @Flag(name: .customLong("vk-validation")) var validation = false
    @Flag(name: .customLong("trace-diagnostics")) var diagnostics = false
    @Flag var valgrind = false
    @Argument(parsing: .postTerminator)
    var compositorArguments: [String] = []

    mutating func validate() throws {
        do {
            _ = try resolvedOptions().validated()
        } catch {
            throw ValidationError(String(describing: error))
        }
    }

    mutating func run() async throws {
        try await RunCommand(context: context()).run(
            try resolvedOptions().validated())
    }

    func resolvedOptions() -> RunOptions {
        var options = RunOptions()
        options.tracy = tracy
        if let output {
            options.output = output
            options.outputOptionWasSpecified = true
        }
        if let name {
            options.name = name
            options.outputOptionWasSpecified = true
        }
        if let host {
            options.host = host
            options.tracyOnlyOptionWasSpecified = true
        }
        if let port {
            options.port = port
            options.tracyOnlyOptionWasSpecified = true
        }
        options.seconds = seconds
        options.scale = scale
        options.presentMode = presentMode
        options.drmDevice = drmDevice
        options.wallpaper = wallpaper
        options.optimization = optimization
        options.sanitizer = sanitize
        options.build = !noBuild
        options.android = android
        options.validation = validation
        options.diagnostics = diagnostics
        options.valgrind = valgrind
        options.compositorArguments = compositorArguments
        return options
    }
}
#endif

struct Install: AsyncParsableCommand {
    private static func subcommands() -> [ParsableCommand.Type] {
        var commands: [ParsableCommand.Type] = [Browser.self]
        #if os(Linux)
        commands.insert(Session.self, at: 0)
        #endif
        return commands
    }

    static let configuration = CommandConfiguration(
        abstract: "Install Nucleus runtime and browser products.",
        subcommands: subcommands())

    #if os(Linux)
    struct Session: AsyncParsableCommand {
        @Option var prefix: String?
        mutating func run() async throws {
            try await InstallCommand(context: context()).run(prefix: prefix)
        }
    }
    #endif

    struct Browser: TaskControlledCommand {
        @OptionGroup var taskOptions: TaskControlOptions
        @Option var prefix: String?

        mutating func run() async throws {
            try await ChromiumCommand(context: context()).run(
                .install,
                controls: taskOptions.controls,
                installPrefix: prefix)
        }
    }
}

struct SwiftSDK: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swift-sdk",
        abstract: "Build and inspect Nucleus Swift SDK artifacts.",
        subcommands: [Rebuild.self, Status.self])

    struct Rebuild: TaskControlledCommand {
        @OptionGroup var taskOptions: TaskControlOptions

        var rebuildOptions: RebuildOptions {
            RebuildOptions(controls: taskOptions.controls)
        }

        mutating func run() async throws {
            try await SwiftSDKCommand(context: context()).rebuild(
                rebuildOptions)
        }
    }

    struct Status: AsyncParsableCommand {
        @OptionGroup var reportOptions: ReportOptions
        mutating func run() async throws {
            try SwiftSDKStatus(context: context()).run(
                json: reportOptions.json)
        }
    }
}

struct Android: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        subcommands: [Build.self, Native.self, Verify.self])

    struct Build: TaskControlledCommand {
        @OptionGroup var taskOptions: TaskControlOptions
        @Argument(parsing: .postTerminator) var arguments: [String] = []

        var operation: AndroidOperation {
            .build(gradleArguments: arguments)
        }

        mutating func run() async throws {
            try await AndroidCommand(context: context()).run(
                operation,
                controls: taskOptions.controls)
        }
    }
    struct Native: TaskControlledCommand {
        @OptionGroup var taskOptions: TaskControlOptions

        var operation: AndroidOperation { .native }

        mutating func run() async throws {
            try await AndroidCommand(context: context()).run(
                operation,
                controls: taskOptions.controls)
        }
    }
    struct Verify: TaskControlledCommand {
        @OptionGroup var taskOptions: TaskControlOptions
        @Argument var library: String?

        var operation: AndroidOperation {
            .verify(library: library)
        }

        mutating func run() async throws {
            try await AndroidCommand(context: context()).run(
                operation,
                controls: taskOptions.controls)
        }
    }
}

struct AndroidRuntime: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "android-runtime",
        abstract: "Build and operate the contained Android runtime.",
        subcommands: [
            SourceLock.self,
            Source.self,
            Image.self,
        ])

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

}

struct Browser: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        subcommands: [Doctor.self, Bootstrap.self, Build.self, Test.self])

    struct Doctor: AsyncParsableCommand {
        @Flag(help: "Print the resolved browser checks without executing them.")
        var dryRun = false
        @Flag(help: "Emit stable machine-readable records.")
        var json = false

        mutating func run() async throws {
            try await ChromiumCommand(context: context()).run(
                .doctor,
                controls: TaskControls(dryRun: dryRun, json: json))
        }
    }
    struct Bootstrap: BrowserTaskLeaf {
        static let operation = ChromiumOperation.bootstrap
        @OptionGroup var taskOptions: TaskControlOptions
    }
    struct Build: BrowserTaskLeaf {
        static let operation = ChromiumOperation.build
        @OptionGroup var taskOptions: TaskControlOptions
    }
    struct Test: BrowserTaskLeaf {
        static let operation = ChromiumOperation.test
        @OptionGroup var taskOptions: TaskControlOptions
    }
}

protocol BrowserTaskLeaf: TaskControlledCommand {
    static var operation: ChromiumOperation { get }
}

extension BrowserTaskLeaf {
    mutating func run() async throws {
        try await ChromiumCommand(context: context()).run(
            Self.operation,
            controls: taskOptions.controls)
    }
}

struct Sanitize: AsyncParsableCommand {
    @Argument var selection: SanitizerSelection = .all
    mutating func run() async throws {
        let workspace = try context()
        try await workspace.withExclusiveVerification {
            try await SanitizerCommand(context: workspace).run(selection)
        }
    }
}

struct Benchmark: AsyncParsableCommand {
    mutating func run() async throws {
        let workspace = try context()
        try await workspace.withExclusiveVerification {
            try await BenchmarkCommand(context: workspace).run()
        }
    }
}

struct Generate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [
        RNSpec.self, Vulkan.self, Wayland.self,
    ])
    struct RNSpec: TaskControlledCommand {
        @OptionGroup var taskOptions: TaskControlOptions
        mutating func run() async throws {
            try await runGenerator(.reactNative, taskOptions: taskOptions)
        }
    }
    struct Vulkan: TaskControlledCommand {
        @OptionGroup var taskOptions: TaskControlOptions
        mutating func run() async throws {
            try await runGenerator(.vulkan, taskOptions: taskOptions)
        }
    }
    struct Wayland: TaskControlledCommand {
        @OptionGroup var taskOptions: TaskControlOptions
        mutating func run() async throws {
            try await runGenerator(.wayland, taskOptions: taskOptions)
        }
    }
}

private func runGenerator(
    _ component: GeneratorComponent,
    taskOptions: TaskControlOptions
) async throws {
    try await ComponentRegistry(context: context()).generate(
        component, controls: taskOptions.controls)
}

struct Validate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [Vulkan.self])
    struct Vulkan: AsyncParsableCommand {
        @Flag(help: "Print validation actions without executing them.")
        var dryRun = false
        @Flag(help: "Emit stable machine-readable records.")
        var json = false

        mutating func run() async throws {
            try VulkanValidation(context: context()).run(
                dryRun: dryRun,
                json: json)
        }
    }
}

struct Cache: AsyncParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [Status.self, Prune.self])
    struct Status: AsyncParsableCommand {
        @OptionGroup var reportOptions: ReportOptions
        mutating func run() async throws {
            try RepositoryCache(context: context()).status(
                json: reportOptions.json)
        }
    }
    struct Prune: AsyncParsableCommand {
        @Flag(help: "Print removals without applying them.")
        var dryRun = false
        @Flag(help: "Emit stable machine-readable records.")
        var json = false
        @Option(name: .customLong("keep-runs"), help: "Number of recent completed runs to retain.")
        var keepRuns = 20

        mutating func validate() throws {
            guard keepRuns >= 0 else { throw ValidationError("--keep-runs must be nonnegative") }
        }

        mutating func run() async throws {
            try await RepositoryCache(context: context()).prune(
                keepingRuns: keepRuns,
                dryRun: dryRun,
                json: json)
        }
    }
}

struct Logs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [List.self, Show.self, Tail.self])
    struct List: AsyncParsableCommand {
        @OptionGroup var reportOptions: ReportOptions
        @Option var kind: String?
        mutating func run() async throws {
            let workspace = try context()
            try RepositoryState(context: workspace).list(
                kind: kind,
                json: reportOptions.json)
        }
    }
    struct Show: AsyncParsableCommand {
        @Argument var runID: String?
        @Option var kind: String?
        mutating func run() async throws {
            let workspace = try context()
            try RepositoryState(context: workspace).show(runID, kind: kind)
        }
    }
    struct Tail: AsyncParsableCommand {
        @Argument var runID: String?
        @Option var kind: String?
        mutating func run() async throws {
            let workspace = try context()
            try await RepositoryState(context: workspace).tail(
                runID,
                kind: kind)
        }
    }
}

struct Status: AsyncParsableCommand {
    @OptionGroup var reportOptions: ReportOptions
    mutating func run() async throws {
        let workspace = try context()
        try RepositoryState(context: workspace).printStatus(
            json: reportOptions.json)
    }
}
