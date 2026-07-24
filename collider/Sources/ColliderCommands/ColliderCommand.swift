import ArgumentParser
import ColliderCore
import ColliderRuntime
import FoundationEssentials
import SystemPackage

enum ColliderPrivilegedMode: Equatable {
    case androidApexMount
    case androidBPFBroker
    case androidBPFMount
}

func colliderPrivilegedMode(for arguments: [String]) -> ColliderPrivilegedMode? {
    switch arguments.first {
    case androidApexMountCommandName:
        .androidApexMount
    case androidBPFBrokerCommandName:
        .androidBPFBroker
    case androidBPFMountCommandName:
        .androidBPFMount
    default:
        nil
    }
}

public struct ColliderCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "collider",
        abstract: "Build, validate, and operate the Nucleus repository.",
        version: "0.1.0",
        subcommands: [
            Doctor.self, Bootstrap.self, Build.self, Test.self, Run.self,
            Install.self, Toolchain.self, Android.self, AndroidRuntime.self,
            Browser.self,
            Generate.self, Sanitize.self, Benchmark.self,
            Validate.self, Qualify.self, Cache.self, Logs.self, Status.self,
        ])

    public init() {}

    public static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch colliderPrivilegedMode(for: arguments) {
        case .androidApexMount:
            AndroidApexMountPrivilegedCommand.main(
                Array(arguments.dropFirst()))
            return
        case .androidBPFBroker:
            AndroidBPFBrokerPrivilegedCommand.main(
                Array(arguments.dropFirst()))
            return
        case .androidBPFMount:
            AndroidBPFMountPrivilegedCommand.main(
                Array(arguments.dropFirst()))
            return
        case nil:
            break
        }
        do {
            var command = try parseAsRoot()
            let environment = ProcessInfo.processInfo.environment
            let workspace = try resolveWorkspaceRoot(environment: environment)
            let registry = RunRegistry(
                root: FilePath(workspace).appending(".nucleus"))
            let arguments = Array(CommandLine.arguments)
            let requestedRunID = requestedRunID(for: command)
            let run = try waitForAsyncResult {
                if let requestedRunID {
                    return try await registry.resume(requestedRunID)
                }
                return try await registry.begin(command: arguments)
            }
            let cancellation = RuntimeCancellation()
            let signals = RuntimeSignalHandlers(cancellation: cancellation)
            setActiveCommandRuntime(
                logging: CommandLogging(registry: registry, run: run),
                cancellation: cancellation)
            defer {
                signals.cancel()
                setActiveCommandRuntime(logging: nil, cancellation: nil)
            }
            do {
                try command.run()
                try waitForAsyncResult {
                    try await registry.finish(run, status: .succeeded)
                }
            } catch let cleanExit as CleanExit {
                try? waitForAsyncResult {
                    try await registry.finish(run, status: .succeeded)
                }
                throw cleanExit
            } catch {
                let wasInterrupted = try waitForAsyncResult {
                    await cancellation.wasInterrupted()
                }
                try? waitForAsyncResult {
                    try await registry.appendLog(
                        Array("Error: \(error)\n".utf8),
                        in: run)
                }
                let identityChanged: Bool
                if case .resumptionIdentityChanged = error as? RunRegistryFailure {
                    identityChanged = true
                } else {
                    identityChanged = false
                }
                let status: RunStatus = wasInterrupted || identityChanged
                    ? .interrupted : .failed
                try? waitForAsyncResult {
                    try await registry.finish(run, status: status)
                }
                throw error
            }
        } catch {
            exit(withError: error)
        }
    }
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

    @Flag(help: "Stream leaf commands and complete stage output.")
    var verbose = false

    @Flag(help: "Emit stable machine-readable records.")
    var json = false

    @Option(name: .customLong("run-id"), help: "Resume an interrupted run.")
    var runID: RunIDArgument?

    var controls: TaskControls {
        TaskControls(dryRun: dryRun, explain: explain, verbose: verbose, json: json)
    }
}

protocol ResumableRun {
    var requestedRunID: RunID? { get }
}

protocol TaskControlledCommand: ParsableCommand, ResumableRun {
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

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Report missing tools and repository prerequisites.")
    @Flag(help: "Print the resolved checks without executing them.")
    var dryRun = false
    @Flag(help: "Emit stable machine-readable records.")
    var json = false
    @Argument(help: "Prerequisite group: all, runtime, toolchain, android, or browser.")
    var scope: DoctorScope = .all

    mutating func run() throws {
        try WorkspaceDoctor(context: context()).run(
            scope: scope,
            dryRun: dryRun,
            json: json)
    }
}

struct Bootstrap: TaskControlledCommand {
    @OptionGroup var taskOptions: TaskControlOptions
    @Argument(help: "all, runtime, browser, or a component name.")
    var component: ComponentSelection?

    mutating func run() throws {
        let workspace = try context()
        if component == .browser {
            try ChromiumCommand(context: workspace).run(
                .bootstrap,
                controls: taskOptions.controls)
        } else {
            try ComponentRegistry(context: workspace).bootstrap(
                selection: component, controls: taskOptions.controls)
        }
    }
}

struct Build: TaskControlledCommand {
    @OptionGroup var taskOptions: TaskControlOptions
    @Argument(help: "all, runtime, toolchain, android, browser, or a component name.")
    var component: ComponentSelection?

    mutating func run() throws {
        let workspace = try context()
        switch component {
        case .toolchain:
            try ToolchainCommand(context: workspace).rebuild(
                RebuildOptions(controls: taskOptions.controls))
        case .android:
            try AndroidCommand(context: workspace).run(
                .build(gradleArguments: []),
                controls: taskOptions.controls)
        case .browser:
            try ChromiumCommand(context: workspace).run(
                .build,
                controls: taskOptions.controls)
        default:
            try ComponentRegistry(context: workspace).build(
                selection: component, controls: taskOptions.controls)
        }
    }
}

struct Test: TaskControlledCommand {
    @OptionGroup var taskOptions: TaskControlOptions
    @Argument(help: "all, runtime, android, browser, or a component name.")
    var component: ComponentSelection?

    mutating func run() throws {
        let workspace = try context()
        if component == .android {
            try workspace.withExclusiveVerification {
                try AndroidCommand(context: workspace).run(
                    .build(gradleArguments: []),
                    controls: taskOptions.controls)
            }
            return
        }
        if component == .browser {
            try workspace.withExclusiveVerification {
                try ChromiumCommand(context: workspace).run(
                    .test,
                    controls: taskOptions.controls)
            }
            return
        }
        try workspace.withExclusiveVerification {
            try ComponentRegistry(context: workspace).test(
                selection: component, controls: taskOptions.controls)
            if component == nil || component == .all, !taskOptions.dryRun {
                try Orchestrator(context: workspace).runRepositoryWideTestGates()
            }
        }
    }
}

struct Run: ParsableCommand {
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

    mutating func run() throws {
        try RunCommand(context: context()).run(
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
        options.validation = validation
        options.diagnostics = diagnostics
        options.valgrind = valgrind
        options.compositorArguments = compositorArguments
        return options
    }
}

struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install Nucleus runtime and browser products.",
        subcommands: [
            Session.self,
            Compositor.self,
            Shell.self,
            Browser.self,
        ])

    struct Session: RuntimeInstallLeaf {
        static let component = RuntimeInstaller.Component.session
        @Option var prefix: String?
    }

    struct Compositor: RuntimeInstallLeaf {
        static let component = RuntimeInstaller.Component.compositor
        @Option var prefix: String?
    }

    struct Shell: RuntimeInstallLeaf {
        static let component = RuntimeInstaller.Component.shell
        @Option var prefix: String?
    }

    struct Browser: TaskControlledCommand {
        @OptionGroup var taskOptions: TaskControlOptions
        @Option var prefix: String?

        mutating func run() throws {
            try ChromiumCommand(context: context()).run(
                .install,
                controls: taskOptions.controls,
                installPrefix: prefix)
        }
    }
}

protocol RuntimeInstallLeaf: ParsableCommand {
    static var component: RuntimeInstaller.Component { get }
    var prefix: String? { get set }
}

extension RuntimeInstallLeaf {
    mutating func run() throws {
        try InstallCommand(context: context()).run(
            Self.component,
            prefix: prefix)
    }
}

struct Toolchain: ParsableCommand {
    static let configuration = CommandConfiguration(
        subcommands: [Rebuild.self, Status.self, Install.self, Uninstall.self])

    struct Rebuild: TaskControlledCommand {
        @OptionGroup var taskOptions: TaskControlOptions
        @Flag var reconfigure = false
        @Option var arch: [ToolchainArchitecture] = []

        var rebuildOptions: RebuildOptions {
            RebuildOptions(
                controls: taskOptions.controls,
                reconfigure: reconfigure,
                architectures: arch)
        }

        mutating func run() throws {
            try ToolchainCommand(context: context()).rebuild(
                rebuildOptions)
        }
    }

    struct Status: ParsableCommand {
        @OptionGroup var reportOptions: ReportOptions
        mutating func run() throws {
            try ToolchainStatus(context: context()).run(
                json: reportOptions.json)
        }
    }
    struct Install: ParsableCommand {
        @Flag(help: "Print the installation actions without executing them.")
        var dryRun = false
        @Option var version: String?
        @Option var prefix: String?
        @Option var tarball: String?

        mutating func run() throws {
            let workspace = try context()
            try ToolchainInstallation(context: workspace).install(
                version: version,
                prefix: prefix,
                tarball: tarball,
                dryRun: dryRun)
        }
    }
    struct Uninstall: ParsableCommand {
        @Flag(help: "Print the removal actions without executing them.")
        var dryRun = false
        @Option var version: String?
        @Option var prefix: String?

        mutating func run() throws {
            let workspace = try context()
            try ToolchainInstallation(context: workspace).uninstall(
                version: version,
                prefix: prefix,
                dryRun: dryRun)
        }
    }
}

struct Android: ParsableCommand {
    static let configuration = CommandConfiguration(
        subcommands: [Build.self, Native.self, Verify.self])

    struct Build: TaskControlledCommand {
        @OptionGroup var taskOptions: TaskControlOptions
        @Argument(parsing: .postTerminator) var arguments: [String] = []

        var operation: AndroidOperation {
            .build(gradleArguments: arguments)
        }

        mutating func run() throws {
            try AndroidCommand(context: context()).run(
                operation,
                controls: taskOptions.controls)
        }
    }
    struct Native: TaskControlledCommand {
        @OptionGroup var taskOptions: TaskControlOptions

        var operation: AndroidOperation { .native }

        mutating func run() throws {
            try AndroidCommand(context: context()).run(
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

        mutating func run() throws {
            try AndroidCommand(context: context()).run(
                operation,
                controls: taskOptions.controls)
        }
    }
}

struct AndroidRuntime: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "android-runtime",
        abstract: "Build and operate the contained Android runtime.",
        subcommands: [
            SourceLock.self,
            Source.self,
            Image.self,
            FrameworkBoot.self,
        ])

    struct SourceLock: TaskControlledCommand {
        static let configuration = CommandConfiguration(
            commandName: "source-lock",
            abstract: "Verify the pinned AOSP and Repo identities.")
        @OptionGroup var taskOptions: TaskControlOptions

        mutating func run() throws {
            try ComponentRegistry(context: context())
                .verifyAndroidRuntimeSourceLock(
                    controls: taskOptions.controls)
        }
    }

    struct Source: TaskControlledCommand {
        static let configuration = CommandConfiguration(
            abstract: "Materialize the exact AOSP source checkout.")
        @OptionGroup var taskOptions: TaskControlOptions

        mutating func run() throws {
            try ComponentRegistry(context: context())
                .prepareAndroidRuntimeSource(
                    controls: taskOptions.controls)
        }
    }

    struct Image: TaskControlledCommand {
        static let configuration = CommandConfiguration(
            abstract: "Build and release-sign the Nucleus Android images.")
        @OptionGroup var taskOptions: TaskControlOptions

        mutating func run() throws {
            try ComponentRegistry(context: context())
                .buildAndroidRuntimeImage(
                    controls: taskOptions.controls)
        }
    }

    struct FrameworkBoot: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "framework-boot",
            abstract:
                "Boot the signed Android framework in its production container.")

        @Option(
            name: .customLong("timeout-seconds"),
            help: "Maximum framework readiness wait.")
        var timeoutSeconds: UInt32 = 180

        mutating func validate() throws {
            guard timeoutSeconds > 0 else {
                throw ValidationError(
                    "--timeout-seconds must be positive")
            }
        }

        mutating func run() throws {
            try AndroidFrameworkBootCommand(
                context: context(),
                timeoutSeconds: timeoutSeconds
            ).run()
        }
    }
}

struct Browser: ParsableCommand {
    static let configuration = CommandConfiguration(
        subcommands: [Doctor.self, Bootstrap.self, Build.self, Test.self])

    struct Doctor: ParsableCommand {
        @Flag(help: "Print the resolved browser checks without executing them.")
        var dryRun = false
        @Flag(help: "Emit stable machine-readable records.")
        var json = false

        mutating func run() throws {
            try ChromiumCommand(context: context()).run(
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
    mutating func run() throws {
        try ChromiumCommand(context: context()).run(
            Self.operation,
            controls: taskOptions.controls)
    }
}

struct Sanitize: ParsableCommand {
    @Argument var selection: SanitizerSelection = .all
    mutating func run() throws {
        let workspace = try context()
        try workspace.withExclusiveVerification {
            try SanitizerCommand(context: workspace).run(selection)
        }
    }
}

struct Benchmark: ParsableCommand {
    mutating func run() throws {
        let workspace = try context()
        try workspace.withExclusiveVerification {
            try BenchmarkCommand(context: workspace).run()
        }
    }
}

struct Generate: ParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [RNSpec.self, Vulkan.self, Wayland.self])
    struct RNSpec: TaskControlledCommand {
        @OptionGroup var taskOptions: TaskControlOptions
        mutating func run() throws {
            try runGenerator(.reactNative, taskOptions: taskOptions)
        }
    }
    struct Vulkan: TaskControlledCommand {
        @OptionGroup var taskOptions: TaskControlOptions
        mutating func run() throws {
            try runGenerator(.vulkan, taskOptions: taskOptions)
        }
    }
    struct Wayland: TaskControlledCommand {
        @OptionGroup var taskOptions: TaskControlOptions
        mutating func run() throws {
            try runGenerator(.wayland, taskOptions: taskOptions)
        }
    }
}

private func runGenerator(
    _ component: GeneratorComponent,
    taskOptions: TaskControlOptions
) throws {
    try ComponentRegistry(context: context()).generate(
        component, controls: taskOptions.controls)
}

struct Validate: ParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [Vulkan.self])
    struct Vulkan: ParsableCommand {
        @Flag(help: "Print validation actions without executing them.")
        var dryRun = false
        @Flag(help: "Emit stable machine-readable records.")
        var json = false

        mutating func run() throws {
            try VulkanValidation(context: context()).run(
                dryRun: dryRun,
                json: json)
        }
    }
}

struct Qualify: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run live hardware qualification workflows.",
        subcommands: [AndroidPresentation.self])

    struct AndroidPresentation: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "android-presentation",
            abstract:
                "Qualify gfxstream-to-Wayland presentation in a bounded Nucleus session.")

        @Option(
            name: .customLong("drm-device"),
            help: "Connected DRM render node used by every graphics participant.")
        var drmDevice: String

        @Option(help: "Number of paced frames to present.")
        var frames = 600

        @Option(help: "Qualification artifact directory.")
        var output: String?

        @Option(help: "Positive fractional output scale.")
        var scale = 1.0

        @Option(
            name: .customLong("present-mode"),
            help: "vsync or mailbox_latest_wins.")
        var presentMode: PresentMode = .vsync

        @Flag(name: .customLong("no-build"))
        var noBuild = false

        @Flag(name: .customLong("vk-validation"))
        var validation = false

        @Flag(name: .customLong("trace-diagnostics"))
        var diagnostics = false

        mutating func validate() throws {
            guard (1...6_000).contains(frames) else {
                throw ValidationError("--frames must be between 1 and 6000")
            }
            guard scale.isFinite, scale > 0 else {
                throw ValidationError("--scale must be positive and finite")
            }
        }

        mutating func run() throws {
            try AndroidPresentationQualificationCommand(context: context()).run(
                AndroidPresentationQualificationOptions(
                    drmDevice: drmDevice,
                    frames: frames,
                    output: output,
                    scale: scale,
                    presentMode: presentMode,
                    build: !noBuild,
                    validation: validation,
                    diagnostics: diagnostics))
        }
    }
}

struct Cache: ParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [Status.self, Prune.self])
    struct Status: ParsableCommand {
        @OptionGroup var reportOptions: ReportOptions
        mutating func run() throws {
            try RepositoryCache(context: context()).status(
                json: reportOptions.json)
        }
    }
    struct Prune: ParsableCommand {
        @Flag(help: "Print removals without applying them.")
        var dryRun = false
        @Flag(help: "Emit stable machine-readable records.")
        var json = false
        @Option(name: .customLong("keep-runs"), help: "Number of recent completed runs to retain.")
        var keepRuns = 20

        mutating func validate() throws {
            guard keepRuns >= 0 else { throw ValidationError("--keep-runs must be nonnegative") }
        }

        mutating func run() throws {
            try RepositoryCache(context: context()).prune(
                keepingRuns: keepRuns,
                dryRun: dryRun,
                json: json)
        }
    }
}

struct Logs: ParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [List.self, Show.self, Tail.self])
    struct List: ParsableCommand {
        @OptionGroup var reportOptions: ReportOptions
        @Option var kind: String?
        mutating func run() throws {
            let workspace = try context()
            try RepositoryState(context: workspace).list(
                kind: kind,
                json: reportOptions.json)
        }
    }
    struct Show: ParsableCommand {
        @Argument var runID: String?
        @Option var kind: String?
        mutating func run() throws {
            let workspace = try context()
            try RepositoryState(context: workspace).show(runID, kind: kind)
        }
    }
    struct Tail: ParsableCommand {
        @Argument var runID: String?
        @Option var kind: String?
        mutating func run() throws {
            let workspace = try context()
            try RepositoryState(context: workspace).tail(runID, kind: kind)
        }
    }
}

struct Status: ParsableCommand {
    @OptionGroup var reportOptions: ReportOptions
    mutating func run() throws {
        let workspace = try context()
        try RepositoryState(context: workspace).printStatus(
            json: reportOptions.json)
    }
}
