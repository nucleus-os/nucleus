import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

extension JSONEncoder {
    /// The single stable machine-readable encoding used by every `--json` path.
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

/// The task-graph presentation controls shared by every workflow that drives
/// the Collider task runtime.
struct TaskControls: Sendable {
    var dryRun = false
    var explain = false
    var verbose = false
    var quiet = false
    var json = false

    var executionOptions: TaskExecutionOptions {
        TaskExecutionOptions(
            dryRun: dryRun,
            explain: explain,
            verbose: verbose,
            quiet: quiet,
            machineReadable: json)
    }

    /// Emit the machine-readable report or the clean/dirty plan. Callers add
    /// their own success line for the plain (non-plan, non-JSON) case.
    func render(_ report: TaskExecutionReport) throws {
        if json {
            print(String(
                decoding: try JSONEncoder.sorted.encode(report),
                as: UTF8.self))
        } else if dryRun || explain {
            for entry in report.plan {
                print(
                    "\(entry.isClean ? "clean" : "dirty")  "
                        + "\(entry.task.rawValue)  \(entry.explanation)")
            }
        }
    }
}

extension WorkspaceContext {
    func pruneSanitizerBuildContexts() throws {
        let swiftPM = layout.state.appendingPathComponent(
            "swiftpm",
            isDirectory: true)
        try DirectoryLifecycle.prune(DirectoryRetentionPlan(
            safetyRoot: FilePath(layout.state.path),
            rules: RuntimeSanitizer.allCases.map {
                DirectoryRetentionRule(
                    root: FilePath(swiftPM.appendingPathComponent(
                        $0.rawValue,
                        isDirectory: true).path),
                    retain: 2,
                    naming: .swiftBuildContext)
            }))
    }

    /// The user cache root: `$XDG_CACHE_HOME`, else `$HOME/.cache`, else the
    /// process home directory's `.cache`.
    var cacheRoot: URL {
        if let value = environment["XDG_CACHE_HOME"], !value.isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        if let home = environment["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(".cache", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache", isDirectory: true)
    }

    /// The single native SDK location passed to every build and publication
    /// task. Workspace initialization always establishes this environment
    /// contract before SwiftPM evaluates a first-party manifest.
    var nativeSDKRoot: URL {
        URL(
            fileURLWithPath: environment["NUCLEUS_NATIVE_SDK_ROOT"]!,
            isDirectory: true)
    }

    func swiftPMInvocation(
        configuration: SwiftBuildConfiguration = .debug,
        sanitizer: String? = nil,
        traits: [String] = [],
        swiftFlags: [String] = [],
        cFlags: [String] = [],
        cxxFlags: [String] = [],
        linkerFlags: [String] = [],
        staticSwiftStandardLibrary: Bool = false,
        target: SwiftBuildTarget? = nil
    ) throws -> SwiftPMInvocation {
        let compiler = try swiftCompilerPath()
        let compilerIdentity = try ArtifactHasher.digest(file: compiler)
            .description
        let context = SwiftBuildContext(
            configuration: configuration,
            target: target ?? .host(identity: hostSwiftTarget),
            toolchainIdentity: "\(compiler.string)@\(compilerIdentity)",
            sanitizer: sanitizer,
            traits: traits,
            swiftFlags: swiftFlags,
            cFlags: cFlags,
            cxxFlags: cxxFlags,
            linkerFlags: linkerFlags,
            staticSwiftStandardLibrary: staticSwiftStandardLibrary)
        return SwiftPMInvocation(
            context: context,
            scratchPath: FilePath(layout.swiftScratch(for: context).path))
    }

    /// Build the task graph, execute the selected tasks against the repository
    /// task-state root, render the report, and return it.
    @discardableResult
    func execute(
        tasks: [TaskDeclaration],
        selected: [TaskID],
        controls: TaskControls,
        workflowLocks: [TaskLock] = []
    ) async throws -> TaskExecutionReport {
        let graph = try TaskGraph(tasks)
        let stateRoot = FilePath(layout.tasks.path)
        let report = try await runtime.execute(
            graph: graph,
            selected: selected,
            stateRoot: stateRoot,
            workflowLocks: workflowLocks,
            options: controls.executionOptions)
        try controls.render(report)
        return report
    }
}

private extension WorkspaceContext {
    func swiftCompilerPath() throws -> FilePath {
        if let value = environment["SWIFTC"], !value.isEmpty {
            return FilePath(
                URL(fileURLWithPath: value).resolvingSymlinksInPath().path)
        }
        if let toolchain = environment["SWIFT_TOOLCHAIN"], !toolchain.isEmpty {
            return FilePath(
                URL(fileURLWithPath: toolchain)
                    .appendingPathComponent("bin/swiftc")
                    .resolvingSymlinksInPath()
                    .path)
        }
        let searchPath = environment["PATH"]
            ?? ProcessInfo.processInfo.environment["PATH"]
            ?? ""
        for directory in searchPath.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent("swiftc")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return FilePath(candidate.resolvingSymlinksInPath().path)
            }
        }
        throw WorkspaceFailure.message(
            "unable to resolve swiftc for the shared SwiftPM build context")
    }
}

private let hostSwiftTarget: String = {
    #if os(macOS)
    let operatingSystem = "macos"
    #elseif os(Linux)
    let operatingSystem = "linux"
    #else
    let operatingSystem = "unknown"
    #endif

    #if arch(x86_64)
    let architecture = "x86_64"
    #elseif arch(arm64)
    let architecture = "aarch64"
    #else
    let architecture = "unknown"
    #endif

    return "\(architecture)-\(operatingSystem)"
}()
