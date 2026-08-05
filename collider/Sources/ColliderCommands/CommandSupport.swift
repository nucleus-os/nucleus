import ColliderCore
import ColliderEngine
import ColliderPersistence
import ColliderRuntime
import ColliderSwiftPM
import Foundation
import QualificationColliderRecipe
import SystemPackage

extension DirectoryNamePattern {
    package static let swiftBuildContext = Self(
        rawValue: #"^sha256-[0-9a-f]{64}$"#)
    package static let swiftSDKCandidate = Self(
        rawValue: #"^\.candidate-[0-9a-f]{24}-[0-9TZ-]+-[0-9]+$"#)
}

extension WorkspaceContext {
    func pruneSanitizerBuildContexts() throws {
        let swiftPM = layout.state.appending("swiftpm")
        try DirectoryLifecycle.prune(
            DirectoryRetentionPlan(
                safetyRoot: layout.state,
                rules: SanitizerKind.allCases.map {
                    DirectoryRetentionRule(
                        root: swiftPM.appending($0.rawValue),
                        retain: 2,
                        naming: .swiftBuildContext)
                }))
    }

    /// Every SwiftPM build context is keyed to the compiler that produced it, so
    /// publishing a Swift platform generation strands all of them at once.
    /// Reclaim them with the rebuild that superseded them rather than leaving a
    /// multi-gigabyte build directory behind per retired toolchain.
    func reclaimSwiftBuildContexts() throws {
        let swiftPM = layout.state.appending("swiftpm")
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: swiftPM.string, isDirectory: true),
                includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        try DirectoryLifecycle.prune(
            DirectoryRetentionPlan(
                safetyRoot: layout.state,
                rules:
                    contents
                    .filter {
                        (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?
                            .isDirectory == true
                    }
                    .map {
                        DirectoryRetentionRule(
                            root: FilePath($0),
                            retain: 0,
                            naming: .swiftBuildContext)
                    }))
    }

    func nativeSDKRoot(for target: NativeLinuxTarget) -> FilePath {
        nativeSDKRoot(named: target.identifier)
    }

    func nativeSDKRoot(named target: String) -> FilePath {
        nativeSDKRoot
            .removingLastComponent()
            .appending(target)
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
        let packageRoot = layout.root
        let manifest = packageRoot.appending("Package.swift")
        guard FileManager.default.fileExists(atPath: manifest.string) else {
            throw WorkspaceFailure.message(
                "canonical Swift package has no manifest: " + manifest.string)
        }

        let resolvedToolchainIdentity: String
        if let toolchainIdentity {
            resolvedToolchainIdentity = toolchainIdentity
        } else {
            let sourceID = environment["NUCLEUS_SWIFT_SOURCE_ID"] ?? "xcode"
            resolvedToolchainIdentity =
                "host-swift-\(sourceID)-\(hostSwiftTarget)"
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
            scratchPath: layout.swiftScratch(for: context))
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
            // independent of compiler discovery. The selected synthesized
            // SwiftPM task resolves and hashes the semantic compiler tool.
            try publishLanguageServerConfiguration(invocation)
        }
        return invocation
    }

    /// Build the task graph, execute the selected tasks against the repository
    /// task-state root, render the report, and return it.
    @discardableResult
    func execute(
        catalog: ComponentCatalog,
        requests: [ComponentEntrypointRequest],
        controls: TaskControls,
        workflowLocks: [TaskLock] = []
    ) async throws -> TaskExecutionReport {
        let stateRoot = layout.tasks
        let report = try await ColliderEngine(runtime: runtime).execute(
            catalog: catalog,
            requests: requests,
            stateRoot: stateRoot,
            workflowLocks: workflowLocks,
            lowerings: [SwiftPMLowering()],
            options: controls.executionOptions)
        try controls.render(report)
        return report
    }
}

extension WorkspaceContext {
    fileprivate func swiftCompilerPath() throws -> FilePath {
        if let value = environment["SWIFTC"], !value.isEmpty {
            return FilePath(
                URL(fileURLWithPath: value).resolvingSymlinksInPath())
        }
        if let toolchain = environment["SWIFT_TOOLCHAIN"], !toolchain.isEmpty {
            return FilePath(
                URL(fileURLWithPath: toolchain)
                    .appendingPathComponent("bin/swiftc")
                    .resolvingSymlinksInPath())
        }
        let searchPath =
            environment["PATH"]
            ?? ProcessInfo.processInfo.environment["PATH"]
            ?? ""
        for directory in searchPath.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent("swiftc")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return FilePath(candidate.resolvingSymlinksInPath())
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
