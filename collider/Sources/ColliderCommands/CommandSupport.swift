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
    var rebuild = false
    var explain = false
    var verbose = false
    var quiet = false
    var json = false

    var executionOptions: TaskExecutionOptions {
        TaskExecutionOptions(
            dryRun: dryRun,
            rebuildSelected: rebuild,
            explain: explain,
            verbose: verbose,
            quiet: quiet,
            machineReadable: json)
    }

    /// Emit the machine-readable report or the clean/dirty plan. Callers add
    /// their own success line for the plain (non-plan, non-JSON) case.
    func render(_ report: TaskExecutionReport) throws {
        if json {
            print(
                String(
                    decoding: try JSONEncoder.sorted.encode(report),
                    as: UTF8.self))
        } else if dryRun || explain {
            let planningMicroseconds =
                report.planningDurationNanoseconds / 1_000
            let fractionalMilliseconds = String(planningMicroseconds % 1_000)
            let paddedFraction =
                String(
                    repeating: "0",
                    count: 3 - fractionalMilliseconds.count)
                + fractionalMilliseconds
            print(
                "planning  \(planningMicroseconds / 1_000)."
                    + "\(paddedFraction) ms")
            print(
                "input hashing  "
                    + "\(report.selectedInputHashingDurationNanoseconds / 1_000) us")
            print("SwiftPM invocations  \(report.swiftPMInvocationCount)")
            for entry in report.plan {
                let state =
                    entry.isClean
                    ? "clean"
                    : entry.isSubsumed
                        ? "subsumed"
                        : "dirty"
                print(
                    "\(state)  "
                        + "\(entry.task.rawValue)"
                        + executionCoordinateSummary(entry.coordinates)
                        + "  \(entry.explanation)")
            }
        }
    }
}

private func executionCoordinateSummary(
    _ coordinates: TaskExecutionCoordinates?
) -> String {
    guard let coordinates else { return "" }
    var values = [
        "runner=\(coordinates.runner.operatingSystem.rawValue)/"
            + coordinates.runner.architecture.rawValue,
        "executor=\(coordinates.backend.rawValue):"
            + "\(coordinates.execution.operatingSystem.rawValue)/"
            + coordinates.execution.architecture.rawValue,
    ]
    if let artifact = coordinates.artifact {
        var value =
            "artifact=\(artifact.operatingSystem.rawValue)/"
            + artifact.architecture.rawValue
        if let abi = artifact.abi {
            value += "/\(abi)"
        }
        if let apiLevel = artifact.androidAPILevel {
            value += "@api\(apiLevel)"
        }
        values.append(value)
    }
    return "  [\(values.joined(separator: " "))]"
}

/// The subset of the sourcekit-lsp configuration the package owns. Every other
/// language server setting stays the editor's to choose.
private struct LanguageServerConfiguration: Codable {
    struct SwiftPM: Codable {
        let configuration: String
        let scratchPath: String
    }

    let backgroundPreparationMode: String
    let swiftPM: SwiftPM
}

extension WorkspaceContext {
    func pruneSanitizerBuildContexts() throws {
        let swiftPM = layout.state.appendingPathComponent(
            "swiftpm",
            isDirectory: true)
        try DirectoryLifecycle.prune(
            DirectoryRetentionPlan(
                safetyRoot: FilePath(layout.state.path),
                rules: RuntimeSanitizer.allCases.map {
                    DirectoryRetentionRule(
                        root: FilePath(
                            swiftPM.appendingPathComponent(
                                $0.rawValue,
                                isDirectory: true
                            ).path),
                        retain: 2,
                        naming: .swiftBuildContext)
                }))
    }

    /// Every SwiftPM build context is keyed to the compiler that produced it, so
    /// publishing a Swift platform generation strands all of them at once.
    /// Reclaim them with the rebuild that superseded them rather than leaving a
    /// multi-gigabyte build directory behind per retired toolchain.
    func reclaimSwiftBuildContexts() throws {
        let swiftPM = layout.state.appendingPathComponent(
            "swiftpm",
            isDirectory: true)
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: swiftPM,
                includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        try DirectoryLifecycle.prune(
            DirectoryRetentionPlan(
                safetyRoot: FilePath(layout.state.path),
                rules:
                    contents
                    .filter {
                        (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?
                            .isDirectory == true
                    }
                    .map {
                        DirectoryRetentionRule(
                            root: FilePath($0.path),
                            retain: 0,
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

    func nativeSDKRoot(for target: NativeLinuxTarget) -> URL {
        nativeSDKRoot(named: target.identifier)
    }

    func nativeSDKRoot(named target: String) -> URL {
        nativeSDKRoot
            .deletingLastPathComponent()
            .appendingPathComponent(target, isDirectory: true)
    }

    func swiftPMInvocation(
        configuration: SwiftBuildConfiguration = .debug,
        sanitizer: String? = nil,
        traits: [String] = [],
        swiftFlags: [String] = [],
        cFlags: [String] = [],
        cxxFlags: [String] = [],
        linkerFlags: [String] = [],
        toolsets: [FilePath] = [],
        staticSwiftStandardLibrary: Bool = false,
        target: SwiftBuildTarget? = nil,
        execution: SwiftPMExecution = .host,
        toolchainIdentity: String? = nil
    ) throws -> SwiftPMInvocation {
        let packageRoot = layout.rootPath
        let manifest = packageRoot.appending("Package.swift")
        guard FileManager.default.fileExists(atPath: manifest.string) else {
            throw WorkspaceFailure.message(
                "canonical Swift package has no manifest: " + manifest.string)
        }

        let resolvedToolchainIdentity: String
        if let toolchainIdentity {
            resolvedToolchainIdentity = toolchainIdentity
        } else {
            let compiler = try swiftCompilerPath()
            let compilerIdentity = try ArtifactHasher.digest(file: compiler)
                .description
            resolvedToolchainIdentity = "\(compiler.string)@\(compilerIdentity)"
        }
        let context = SwiftBuildContext(
            packageRoot: packageRoot,
            configuration: configuration,
            target: target ?? .host(identity: hostSwiftTarget),
            toolchainIdentity: resolvedToolchainIdentity,
            sanitizer: sanitizer,
            traits: traits,
            swiftFlags: swiftFlags,
            cFlags: cFlags,
            cxxFlags: cxxFlags,
            linkerFlags: linkerFlags,
            toolsets: toolsets,
            staticSwiftStandardLibrary: staticSwiftStandardLibrary,
            execution: execution)
        let invocation = SwiftPMInvocation(
            context: context,
            scratchPath: FilePath(layout.swiftScratch(for: context).path))
        let isDefaultContext =
            configuration == .debug
            && sanitizer == nil
            && target == nil
            && traits.isEmpty
            && swiftFlags.isEmpty
            && cFlags.isEmpty
            && cxxFlags.isEmpty
            && linkerFlags.isEmpty
            && toolsets.isEmpty
            && !staticSwiftStandardLibrary
            && execution == .host
        if isDefaultContext {
            // Publishing the editor's view of the package build directory is
            // part of resolving it. A stale pointer would send the language
            // server off to build its own copy, so this republishes whenever the
            // default context resolves somewhere new.
            try publishLanguageServerConfiguration(invocation)
        }
        return invocation
    }

    /// Point the language server at the build directory the package already
    /// maintains. Without it sourcekit-lsp builds and indexes every package into
    /// a second directory, duplicating the complete package build.
    /// The directory is content addressed, so this configuration is generated
    /// rather than checked in.
    func publishLanguageServerConfiguration(
        _ invocation: SwiftPMInvocation
    ) throws {
        let configuration = LanguageServerConfiguration(
            // Preparing a target the way the package builds it keeps one set
            // of compiled modules. The lazily type-checked default writes
            // modules that the next package build has to replace.
            backgroundPreparationMode: "build",
            swiftPM: LanguageServerConfiguration.SwiftPM(
                configuration: invocation.context.configuration.rawValue,
                // The language server resolves a relative build directory
                // against the package. Name it absolutely.
                scratchPath: invocation.scratchPath.string))
        var bytes = try JSONEncoder.sorted.encode(configuration)
        bytes.append(UInt8(ascii: "\n"))
        try publish(
            bytes,
            to: root.appendingPathComponent(".sourcekit-lsp", isDirectory: true)
                .appendingPathComponent("config.json"))

        // A manifest that needs SwiftPM's generated header directory reads it
        // from the environment, and a language server build has to name the same
        // directory as a package build or the two recompile each other. The
        // host environment carries these to every tool started from a Nucleus
        // shell, the language server included.
        let shell = """
            # Generated by Collider. The package build directory the language
            # server and every other Nucleus entry point share.
            export NUCLEUS_SWIFTPM_SCRATCH_PATH='\(invocation.scratchPath.string)'
            export NUCLEUS_SWIFTPM_GENERATED_MODULE_MAPS_PATH='\(invocation.generatedModuleMaps.string)'
            """
        try publish(
            Data(shell.utf8),
            to: layout.state
                .appendingPathComponent("swiftpm", isDirectory: true)
                .appendingPathComponent("environment.sh"))
    }

    private func publish(_ bytes: Data, to path: URL) throws {
        guard (try? Data(contentsOf: path)) != bytes else { return }
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try bytes.write(to: path, options: .atomic)
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

extension WorkspaceContext {
    fileprivate func swiftCompilerPath() throws -> FilePath {
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
        let searchPath =
            environment["PATH"]
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
