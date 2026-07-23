import ArgumentParser
import ColliderCore
import ColliderRuntime
import FoundationEssentials
import SystemPackage

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
        do {
            var command = try parseAsRoot()
            let environment = ProcessInfo.processInfo.environment
            let workspace = try resolveWorkspaceRoot(environment: environment)
            let registry = RunRegistry(
                root: FilePath(workspace).appending(".nucleus"))
            let arguments = Array(CommandLine.arguments)
            let requestedRunID = selectedRunID(in: arguments)
            if requestedRunID != nil, !isResumableTaskCommand(arguments) {
                throw WorkspaceFailure.message(
                    "--run-id is supported only by task-graph build and test commands")
            }
            let run = try waitForAsyncResult {
                if let requestedRunID {
                    return try await registry.resume(RunID(rawValue: requestedRunID))
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

struct GlobalOptions: ParsableArguments {
    @Flag(help: "Print the resolved task graph without executing it.")
    var dryRun = false

    @Flag(help: "Explain why each selected task is clean or dirty.")
    var explain = false

    @Flag(help: "Stream leaf commands and complete stage output.")
    var verbose = false

    @Flag(help: "Emit stable machine-readable records.")
    var json = false

    @Option(name: .customLong("run-id"), help: "Resume an interrupted run.")
    var runID: String?

    var controls: TaskControls {
        TaskControls(dryRun: dryRun, explain: explain, verbose: verbose, json: json)
    }
}

private func context() throws -> WorkspaceContext { try WorkspaceContext.load() }

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Report missing tools and repository prerequisites.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Prerequisite group: all, runtime, toolchain, android, or browser.")
    var scope = "all"

    mutating func validate() throws {
        guard ["all", "runtime", "toolchain", "android", "browser"].contains(scope) else {
            throw ValidationError("unknown doctor scope '\(scope)'")
        }
    }

    mutating func run() throws {
        try WorkspaceDoctor(context: context()).run(
            scope: scope,
            dryRun: global.dryRun,
            json: global.json)
    }
}

struct Bootstrap: ParsableCommand {
    @OptionGroup var global: GlobalOptions
    @Argument(help: "all, runtime, browser, or a component name.") var component: String?

    mutating func run() throws {
        let workspace = try context()
        if component == "browser" {
            try ChromiumCommand(context: workspace).run(
                ["bootstrap"][...], controls: global.controls)
        } else {
            try ComponentRegistry(context: workspace).bootstrap(
                selection: component, controls: global.controls)
        }
    }
}

struct Build: ParsableCommand {
    @OptionGroup var global: GlobalOptions
    @Argument(help: "all, runtime, toolchain, android, browser, or a component name.")
    var component: String?

    mutating func run() throws {
        let workspace = try context()
        switch component {
        case "toolchain":
            try ToolchainCommand(context: workspace).run(
                (["rebuild"] + taskControlArguments(global))[...])
        case "android":
            try AndroidCommand(context: workspace).run(
                ["build"][...], controls: global.controls)
        case "browser":
            try ChromiumCommand(context: workspace).run(
                ["build"][...], controls: global.controls)
        default:
            try ComponentRegistry(context: workspace).build(
                selection: component, controls: global.controls)
        }
    }
}

private func selectedRunID(in arguments: [String]) -> String? {
    for (index, argument) in arguments.enumerated() {
        if argument == "--run-id", index + 1 < arguments.count {
            return arguments[index + 1]
        }
        if argument.hasPrefix("--run-id=") {
            return String(argument.dropFirst("--run-id=".count))
        }
    }
    return nil
}

private func isResumableTaskCommand(_ arguments: [String]) -> Bool {
    guard let command = arguments.dropFirst().first else { return false }
    if ["bootstrap", "build", "test", "generate"].contains(command) {
        return true
    }
    let subcommand = arguments.dropFirst(2).first
    return (command == "toolchain" && subcommand == "rebuild")
        || (command == "android"
            && ["build", "native", "verify"].contains(subcommand ?? ""))
        || (command == "android-runtime"
            && ["source-lock", "source", "image"].contains(
                subcommand ?? ""))
        || (command == "browser"
            && ["bootstrap", "build", "test"].contains(subcommand ?? ""))
}

struct Test: ParsableCommand {
    @OptionGroup var global: GlobalOptions
    @Argument(help: "all, runtime, android, browser, or a component name.")
    var component: String?

    mutating func run() throws {
        let workspace = try context()
        if component == "android" {
            try workspace.withExclusiveVerification {
                try AndroidCommand(context: workspace).run(
                    ["build"][...], controls: global.controls)
            }
            return
        }
        if component == "browser" {
            try workspace.withExclusiveVerification {
                try ChromiumCommand(context: workspace).run(
                    ["test"][...], controls: global.controls)
            }
            return
        }
        try workspace.withExclusiveVerification {
            try ComponentRegistry(context: workspace).test(
                selection: component, controls: global.controls)
            if component == nil || component == "all", !global.dryRun {
                try Orchestrator(context: workspace).runRepositoryWideTestGates()
            }
        }
    }
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Build, install, and launch a compositor session.")
    @OptionGroup var global: GlobalOptions
    @Flag var tracy = false
    @Option var output: String?
    @Option var name: String?
    @Option var host: String?
    @Option var port: Int?
    @Option var seconds: Int?
    @Option var scale: Double?
    @Option(name: .customLong("present-mode")) var presentMode: String?
    @Option(name: .customLong("drm-device")) var drmDevice: String?
    @Option var wallpaper: String?
    @Option(name: .customLong("optimize")) var optimization: String?
    @Option var sanitize: String?
    @Flag(name: .customLong("no-build")) var noBuild = false
    @Flag(name: .customLong("vk-validation")) var validation = false
    @Flag(name: .customLong("trace-diagnostics")) var diagnostics = false
    @Flag var valgrind = false
    @Argument(parsing: .captureForPassthrough)
    var compositorArguments: [String] = []

    mutating func run() throws {
        try rejectUnsupportedControls(global)
        var arguments: [String] = []
        if tracy { arguments.append("--tracy") }
        append("--output", output, to: &arguments)
        append("--name", name, to: &arguments)
        append("--host", host, to: &arguments)
        append("--port", port, to: &arguments)
        append("--seconds", seconds, to: &arguments)
        append("--scale", scale, to: &arguments)
        append("--present-mode", presentMode, to: &arguments)
        append("--drm-device", drmDevice, to: &arguments)
        append("--wallpaper", wallpaper, to: &arguments)
        append("--optimize", optimization, to: &arguments)
        append("--sanitize", sanitize, to: &arguments)
        if noBuild { arguments.append("--no-build") }
        if validation { arguments.append("--vk-validation") }
        if diagnostics { arguments.append("--trace-diagnostics") }
        if valgrind { arguments.append("--valgrind") }
        if !compositorArguments.isEmpty {
            arguments.append("--")
            arguments += compositorArguments
        }
        try RunCommand(context: context()).run(arguments[...])
    }
}

struct Install: ParsableCommand {
    @OptionGroup var global: GlobalOptions
    @Argument(help: "session or browser.") var component: String
    @Option var prefix: String?

    mutating func run() throws {
        if component == "browser" {
            try ChromiumCommand(context: context()).run(
                ["install"][...],
                controls: global.controls,
                installPrefix: prefix)
            return
        }
        try rejectUnsupportedControls(global)
        var arguments = [component]
        append("--prefix", prefix, to: &arguments)
        try InstallCommand(context: context()).run(arguments[...])
    }
}

struct Toolchain: ParsableCommand {
    static let configuration = CommandConfiguration(
        subcommands: [Rebuild.self, Status.self, Install.self, Uninstall.self])

    struct Rebuild: ParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Flag var reconfigure = false
        @Option var arch: [String] = []

        mutating func run() throws {
            var arguments = ["rebuild"] + taskControlArguments(global)
            if reconfigure { arguments.append("--reconfigure") }
            for value in arch { arguments += ["--arch", value] }
            try ToolchainCommand(context: context()).run(arguments[...])
        }
    }

    struct Status: ParsableCommand {
        @OptionGroup var global: GlobalOptions
        mutating func run() throws {
            try rejectUnsupportedControls(global, allowingJSON: true)
            try ToolchainStatus(context: context()).run(json: global.json)
        }
    }
    struct Install: ParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Option var version: String?
        @Option var prefix: String?
        @Option var tarball: String?

        mutating func run() throws {
            try rejectUnsupportedControls(global, allowingDryRun: true)
            let workspace = try context()
            try ToolchainInstallation(context: workspace).install(
                version: version,
                prefix: prefix,
                tarball: tarball,
                dryRun: global.dryRun)
        }
    }
    struct Uninstall: ParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Option var version: String?
        @Option var prefix: String?

        mutating func run() throws {
            try rejectUnsupportedControls(global, allowingDryRun: true)
            let workspace = try context()
            try ToolchainInstallation(context: workspace).uninstall(
                version: version,
                prefix: prefix,
                dryRun: global.dryRun)
        }
    }
}

struct Android: ParsableCommand {
    static let configuration = CommandConfiguration(
        subcommands: [Build.self, Native.self, Verify.self])

    struct Build: ParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Argument(parsing: .captureForPassthrough) var arguments: [String] = []
        mutating func run() throws {
            try AndroidCommand(context: context()).run(
                (["build"] + arguments)[...], controls: global.controls)
        }
    }
    struct Native: ParsableCommand {
        @OptionGroup var global: GlobalOptions
        mutating func run() throws {
            try AndroidCommand(context: context()).run(
                ["native"][...], controls: global.controls)
        }
    }
    struct Verify: ParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Argument var library: String?
        mutating func run() throws {
            try AndroidCommand(context: context()).run(
                (["verify"] + [library].compactMap { $0 })[...],
                controls: global.controls)
        }
    }
}

struct AndroidRuntime: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "android-runtime",
        abstract: "Build and operate the contained Android runtime.",
        subcommands: [SourceLock.self, Source.self, Image.self])

    struct SourceLock: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "source-lock",
            abstract: "Verify the pinned AOSP and Repo identities.")
        @OptionGroup var global: GlobalOptions

        mutating func run() throws {
            try ComponentRegistry(context: context())
                .verifyAndroidRuntimeSourceLock(controls: global.controls)
        }
    }

    struct Source: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Materialize the exact AOSP source checkout.")
        @OptionGroup var global: GlobalOptions

        mutating func run() throws {
            try ComponentRegistry(context: context())
                .prepareAndroidRuntimeSource(controls: global.controls)
        }
    }

    struct Image: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Build and release-sign the Nucleus Android images.")
        @OptionGroup var global: GlobalOptions

        mutating func run() throws {
            try ComponentRegistry(context: context())
                .buildAndroidRuntimeImage(controls: global.controls)
        }
    }
}

struct Browser: ParsableCommand {
    static let configuration = CommandConfiguration(
        subcommands: [Doctor.self, Bootstrap.self, Build.self, Test.self, Install.self])

    struct Doctor: BrowserLeaf {
        static let operation = "doctor"
        @OptionGroup var global: GlobalOptions
    }
    struct Bootstrap: BrowserLeaf {
        static let operation = "bootstrap"
        @OptionGroup var global: GlobalOptions
    }
    struct Build: BrowserLeaf {
        static let operation = "build"
        @OptionGroup var global: GlobalOptions
    }
    struct Test: BrowserLeaf {
        static let operation = "test"
        @OptionGroup var global: GlobalOptions
    }
    struct Install: BrowserLeaf {
        static let operation = "install"
        @OptionGroup var global: GlobalOptions
    }
}

protocol BrowserLeaf: ParsableCommand {
    static var operation: String { get }
    var global: GlobalOptions { get set }
}

extension BrowserLeaf {
    mutating func run() throws {
        try ChromiumCommand(context: context()).run(
            [Self.operation][...], controls: global.controls)
    }
}

struct Sanitize: ParsableCommand {
    @Argument var kind: String?
    mutating func run() throws {
        let workspace = try context()
        try workspace.withExclusiveVerification {
            try SanitizerCommand(context: workspace).run([kind].compactMap { $0 }[...])
        }
    }
}

struct Benchmark: ParsableCommand {
    @Argument var suite: String?
    mutating func run() throws {
        guard suite == nil || suite == "all" else { throw unavailable("selected benchmark suites") }
        let workspace = try context()
        try workspace.withExclusiveVerification { try BenchmarkCommand(context: workspace).run([]) }
    }
}

struct Generate: ParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [RNSpec.self, Vulkan.self, Wayland.self])
    struct RNSpec: ParsableCommand {
        @OptionGroup var global: GlobalOptions
        mutating func run() throws {
            try runGenerator("rn", global: global)
        }
    }
    struct Vulkan: ParsableCommand {
        @OptionGroup var global: GlobalOptions
        mutating func run() throws {
            try runGenerator("vulkan", global: global)
        }
    }
    struct Wayland: ParsableCommand {
        @OptionGroup var global: GlobalOptions
        mutating func run() throws {
            try runGenerator("wayland", global: global)
        }
    }
}

private func runGenerator(_ component: String, global: GlobalOptions) throws {
    try ComponentRegistry(context: context()).generate(
        component, controls: global.controls)
}

struct Validate: ParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [Vulkan.self])
    struct Vulkan: ParsableCommand {
        @OptionGroup var global: GlobalOptions

        mutating func run() throws {
            try VulkanValidation(context: context()).run(
                dryRun: global.dryRun,
                json: global.json)
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
        var presentMode = "vsync"

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
            guard ["vsync", "mailbox_latest_wins"].contains(presentMode) else {
                throw ValidationError(
                    "--present-mode must be vsync or mailbox_latest_wins")
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
        @OptionGroup var global: GlobalOptions
        mutating func run() throws {
            try rejectUnsupportedControls(global, allowingJSON: true)
            try RepositoryCache(context: context()).status(json: global.json)
        }
    }
    struct Prune: ParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Option(name: .customLong("keep-runs"), help: "Number of recent completed runs to retain.")
        var keepRuns = 20

        mutating func validate() throws {
            guard keepRuns >= 0 else { throw ValidationError("--keep-runs must be nonnegative") }
        }

        mutating func run() throws {
            try rejectUnsupportedControls(
                global,
                allowingDryRun: true,
                allowingJSON: true)
            try RepositoryCache(context: context()).prune(
                keepingRuns: keepRuns,
                dryRun: global.dryRun,
                json: global.json)
        }
    }
}

struct Logs: ParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [List.self, Show.self, Tail.self])
    struct List: ParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Option var kind: String?
        mutating func run() throws {
            try rejectUnsupportedControls(global, allowingJSON: true)
            let workspace = try context()
            try RepositoryState(context: workspace).list(kind: kind, json: global.json)
        }
    }
    struct Show: ParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Argument var runID: String?
        @Option var kind: String?
        mutating func run() throws {
            try rejectUnsupportedControls(global)
            let workspace = try context()
            try RepositoryState(context: workspace).show(runID, kind: kind)
        }
    }
    struct Tail: ParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Argument var runID: String?
        @Option var kind: String?
        mutating func run() throws {
            try rejectUnsupportedControls(global)
            let workspace = try context()
            try RepositoryState(context: workspace).tail(runID, kind: kind)
        }
    }
}

struct Status: ParsableCommand {
    @OptionGroup var global: GlobalOptions
    mutating func run() throws {
        try rejectUnsupportedControls(global, allowingJSON: true)
        let workspace = try context()
        try RepositoryState(context: workspace).printStatus(json: global.json)
    }
}

private func append<T>(_ option: String, _ value: T?, to arguments: inout [String]) {
    if let value { arguments += [option, String(describing: value)] }
}

private func taskControlArguments(_ options: GlobalOptions) -> [String] {
    var arguments: [String] = []
    if options.dryRun { arguments.append("--dry-run") }
    if options.explain { arguments.append("--explain") }
    if options.verbose { arguments.append("--verbose") }
    if options.json { arguments.append("--json") }
    return arguments
}

private func rejectUnsupportedControls(
    _ options: GlobalOptions,
    allowingDryRun: Bool = false,
    allowingJSON: Bool = false
) throws {
    if (!allowingDryRun && options.dryRun) || options.explain || options.verbose
        || (!allowingJSON && options.json) || options.runID != nil
    {
        throw unavailable("global task controls for this migrated workflow")
    }
}

private func unavailable(_ feature: String) -> ValidationError {
    ValidationError("\(feature) has not migrated to the Collider task runtime")
}
