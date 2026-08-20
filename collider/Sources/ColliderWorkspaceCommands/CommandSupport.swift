import ColliderCore
import ColliderEngine
import ColliderPersistence
import ColliderRuntime
import ColliderSwiftPM
import Foundation
import NativeBuilderColliderRecipe
import SwiftTargetSDKColliderRecipe
import SystemPackage

extension WorkspaceContext {
    func nativeSDKRoot(for target: NativeLinuxTarget) -> FilePath {
        nativeSDKRoot(named: target.identifier)
    }

    func nativeSDKRoot(named target: String) -> FilePath {
        nativeSDKRoot
            .removingLastComponent()
            .appending(target)
    }

    package func swiftPMInvocation(
        packageRoot explicitPackageRoot: FilePath? = nil,
        buildSystem: SwiftPMBuildSystem = .swiftbuild,
        configuration: SwiftBuildConfiguration = .debug,
        debugInformationFormat: SwiftDebugInformationFormat? = nil,
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
        toolchainIdentity: String? = nil,
        scratchRoot: FilePath? = nil,
        swiftExecutable: CommandSpec.Executable = .named("swift")
    ) throws -> SwiftPMInvocation {
        let packageRoot = explicitPackageRoot ?? layout.root
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
            // The selected compiler path chooses the reusable scratch context.
            // Its contents remain a semantic tool input resolved only when a
            // selected host SwiftPM task is planned.
            let compilerSelection = ArtifactHasher.digest(
                bytes: Array(compiler.string.utf8))
            resolvedToolchainIdentity =
                "host-swift-\(hostSwiftTarget)-\(compilerSelection)"
        }
        let maximumParallelism =
            switch execution {
            case .host: SwiftBuildContext.defaultMaximumParallelism
            case .oci: SwiftBuildContext.concurrentOCIMaximumParallelism
            }
        // A compilation records where it read its sources, and a container is
        // already given the canonical location, so only host execution needs
        // the recorded paths mapped. Adding the mapping to a container build
        // would map a prefix that never appears and would put the host's own
        // directory into the identity through the flag itself.
        let prefixMaps =
            switch execution {
            case .host: filePrefixMapFlags
            case .oci: (swift: [String](), clang: [String]())
            }
        let context = SwiftBuildContext(
            packageRoot: packageRoot,
            buildSystem: buildSystem,
            configuration: configuration,
            debugInformationFormat: debugInformationFormat,
            target: target ?? .host(identity: hostSwiftTarget),
            toolchainIdentity: resolvedToolchainIdentity,
            sanitizer: sanitizer,
            traits: traits,
            swiftFlags: swiftFlags + prefixMaps.swift,
            cFlags: cFlags + prefixMaps.clang,
            cxxFlags: cxxFlags + prefixMaps.clang,
            linkerFlags: linkerFlags,
            toolsets: toolsets,
            staticSwiftStandardLibrary: staticSwiftStandardLibrary,
            maximumParallelism: maximumParallelism,
            execution: execution,
            identityPathMap: identityPathMap)
        let invocation = SwiftPMInvocation(
            context: context,
            scratchPath: layout.swiftScratch(
                for: context,
                under: scratchRoot ?? hostBuildRoot.appending("swiftpm")),
            swiftExecutable: swiftExecutable,
            dependencyLock: {
                let lock = packageRoot.appending("Package.resolved")
                return FileManager.default.fileExists(atPath: lock.string)
                    ? lock : nil
            }(),
            dependencyConfigurationFiles: [
                packageRoot.appending(".swiftpm/configuration/mirrors.json")
            ].filter {
                FileManager.default.fileExists(atPath: $0.string)
            },
            sourceGraph: try swiftPackageGraphs.graph(
                packageRoot: packageRoot,
                swiftExecutable: graphSwiftPath()))
        let isDefaultContext =
            packageRoot == layout.root
            && configuration == .debug
            && debugInformationFormat == nil
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

    /// Build the task graph and execute the selected tasks against the
    /// repository task-state root. Dry runs render their plan immediately;
    /// executed runs are summarized once after the run record is finalized.
    @discardableResult
    package func execute(
        catalog: ComponentCatalog,
        requests: [ComponentEntrypointRequest],
        controls: TaskControls
    ) async throws -> TaskExecutionReport {
        let stateRoot = taskStateRoot
        let sdkRebuildLock = TaskLock.shared(
            SwiftTargetSDKStoragePaths(
                cacheRoot: cacheRoot,
                hostBuildRoot: hostBuildRoot
            ).rebuildLock)
        let report = try await ColliderEngine(runtime: runtime).execute(
            catalog: catalog,
            requests: requests,
            stateRoot: stateRoot,
            identityPathMap: identityPathMap,
            workflowLocks: [sdkRebuildLock],
            lowerings: [SwiftPMLowering()],
            hostPhases: hostPhases,
            options: controls.executionOptions)
        if controls.dryRun {
            try controls.renderDryRun(report, console: console)
        }
        return report
    }
}

extension WorkspaceContext {
    fileprivate func graphSwiftPath() throws -> FilePath {
        let hostEnvironment = taskEnvironment
        if let toolchain = hostEnvironment["SWIFT_TOOLCHAIN"], !toolchain.isEmpty {
            let candidate = FilePath(toolchain).appending("bin/swift")
            if FileManager.default.isExecutableFile(atPath: candidate.string) {
                return candidate
            }
        }
        let searchPath = hostEnvironment["PATH"] ?? ""
        for directory in searchPath.split(separator: ":") {
            let candidate = FilePath(String(directory)).appending("swift")
            if FileManager.default.isExecutableFile(atPath: candidate.string) {
                return candidate
            }
        }
        throw WorkspaceFailure.message(
            "unable to resolve host swift for SwiftPM graph materialization")
    }

    fileprivate func swiftCompilerPath() throws -> FilePath {
        let hostEnvironment = taskEnvironment
        if let value = environment["SWIFTC"], !value.isEmpty {
            return FilePath(
                URL(fileURLWithPath: value).resolvingSymlinksInPath())
        }
        if let toolchain = hostEnvironment["SWIFT_TOOLCHAIN"], !toolchain.isEmpty {
            return FilePath(
                URL(fileURLWithPath: toolchain)
                    .appendingPathComponent("bin/swiftc")
                    .resolvingSymlinksInPath())
        }
        let searchPath = hostEnvironment["PATH"] ?? ""
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
