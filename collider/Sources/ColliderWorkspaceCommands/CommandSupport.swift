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
    ) async throws -> SwiftPMInvocation {
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
        // Source info records each source file's modification time, so a
        // product built from one revision carries when its sources happened to
        // be written or fetched and no second machine reproduces it. It exists
        // for navigating to source in a debugger or an editor, which is what
        // the host builds serve; a product built in a container is not read
        // that way.
        let productFlags =
            switch execution {
            case .host: [String]()
            case .oci: ["-avoid-emit-module-source-info"]
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
            swiftFlags: swiftFlags + prefixMaps.swift + productFlags,
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
            scratchPath: verificationScratch(
                layout.swiftScratch(
                    for: context,
                    under: scratchRoot ?? hostBuildRoot.appending("swiftpm"))),
            swiftExecutable: swiftExecutable,
            dependencyLock: {
                let lock = packageRoot.appending("Package.resolved")
                return FileManager.default.fileExists(atPath: lock.string)
                    ? lock : nil
            }(),
            dependencyConfigurationFiles: [
                swiftPMMirrorConfiguration(under: packageRoot)
            ].filter {
                FileManager.default.fileExists(atPath: $0.string)
            },
            sourceGraph: try await swiftPackageGraphs.graph(
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
        var options = controls.executionOptions
        if let sourceRevalidation {
            options.sourceClosureObserver = { sourceRevalidation.record($0) }
        }
        if !controls.dryRun {
            // Before executing, so a run never trims a directory it is about to
            // write into, and per run rather than per context, because the
            // growth this bounds accumulates across weeks while an eviction
            // racing a live scratch directory would be a far worse failure.
            //
            // This could not be wired while two checkouts sharing the store
            // lowered one revision to two identities: each checkout's contexts
            // were permanently unreachable to the other, so a bound would have
            // had them evict each other on every build. They resolve the same
            // context for the same work now, so a bound computed here reaches
            // only what no checkout claims.
            //
            // A failure here is a declaration that cannot describe its own
            // storage, which is worth stopping for: the same fault would make
            // an explicit prune silently collect nothing.
            try RepositoryCache(
                context: self,
                catalog: catalog
            ).boundIdentityContexts()
        }
        let report = try await ColliderEngine(runtime: runtime).execute(
            catalog: catalog,
            requests: requests,
            stateRoot: stateRoot,
            identityPathMap: identityPathMap,
            workflowLocks: [sdkRebuildLock],
            lowerings: [SwiftPMLowering(testFilter: controls.testFilter)],
            hostPhases: hostPhases,
            options: options)
        if controls.dryRun {
            try controls.renderDryRun(report, console: console)
        }
        return report
    }
}

extension WorkspaceContext {
    /// The sibling this invocation produces into when verifying, which shares
    /// the retained location's name so the pair is obvious on disk.
    fileprivate func verificationScratch(_ scratch: FilePath) -> FilePath {
        guard producesIntoVerificationScratch, let name = scratch.lastComponent
        else { return scratch }
        return scratch.removingLastComponent()
            .appending(name.string + verificationScratchSuffix)
    }

    func graphSwiftPath() throws -> FilePath {
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

/// Where SwiftPM reads dependency mirrors for a package.
///
/// Named once because every consumer has to agree on it. Resolution hands it
/// to SwiftPM, the graph cache keys on whether it exists, and the package-root
/// view copies it into what a container sees. A container that cannot see it
/// resolves a pin's recorded location literally and reaches for the network:
/// `Package.resolved` records `apple/swift-system` while the manifest declares
/// the `nucleus-os` fork, and only this file reconciles them. The view first
/// shipped without it, which is what turned a missing copy into a container
/// attempting a fetch.
func swiftPMMirrorConfiguration(under packageRoot: FilePath) -> FilePath {
    packageRoot.appending(".swiftpm/configuration/mirrors.json")
}
