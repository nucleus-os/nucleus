import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SwiftPlatformColliderRecipe
import SystemPackage

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

enum ToolchainArchitecture: String, CaseIterable, ExpressibleByArgument {
    case aarch64
    case x86_64
}

private struct SwiftSourceSelection {
    let workspace: URL
    let repositories: [FilePath]
    let sourceID: String
}

struct SwiftToolchainStoragePaths: Equatable {
    let cacheRoot: URL
    let platformID: String
    let artifactRoot: URL
    let buildLaneRoot: URL
    let buildWorkspace: URL
    let compilerCache: URL
    let rebuildLock: URL

    init(cacheRoot: URL, sourceID: String) {
        self.cacheRoot = cacheRoot.standardizedFileURL
        platformID = sourceID + "-linux-arm64-host"
        artifactRoot = self.cacheRoot.appendingPathComponent(
            "nucleus/swift-platforms/\(platformID)", isDirectory: true)
        buildLaneRoot = self.cacheRoot.appendingPathComponent(
            "nucleus/swift-build-workspaces/linux-arm64-host", isDirectory: true)
        buildWorkspace = buildLaneRoot.appendingPathComponent(
            "workspace", isDirectory: true)
        compilerCache = self.cacheRoot.appendingPathComponent(
            "nucleus/ccache/swift", isDirectory: true)
        rebuildLock = buildLaneRoot.appendingPathComponent("rebuild.lock")
    }
}

func swiftToolchainArtifactID(
    sourceID: String,
    builderContext: FilePath,
    preset: FilePath,
    cmakeOverrides: FilePath,
    ndkProperties: FilePath,
    recipeSource: FilePath,
    hostWorkflowSource: FilePath,
    architectures: [String],
    apiLevel: UInt32
) throws -> String {
    var encoder = CanonicalDigestEncoder()
    encoder.append(tag: 1, string: sourceID)
    encoder.append(
        tag: 2,
        bytes: try ArtifactHasher.digest(tree: builderContext).bytes)
    encoder.append(tag: 3, bytes: try ArtifactHasher.digest(file: preset).bytes)
    encoder.append(
        tag: 4,
        bytes: try ArtifactHasher.digest(file: cmakeOverrides).bytes)
    encoder.append(
        tag: 5,
        bytes: try ArtifactHasher.digest(file: ndkProperties).bytes)
    encoder.append(
        tag: 8,
        bytes: try ArtifactHasher.digest(tree: recipeSource).bytes)
    encoder.append(
        tag: 9,
        bytes: try ArtifactHasher.digest(file: hostWorkflowSource).bytes)
    for architecture in architectures.sorted() {
        encoder.append(tag: 6, string: architecture)
    }
    encoder.append(tag: 7, integer: UInt64(apiLevel))
    let digest = ArtifactHasher.digest(bytes: encoder.bytes).description
    let hex =
        digest.hasPrefix("sha256:")
        ? String(digest.dropFirst("sha256:".count)) : digest
    return String(hex.prefix(24))
}

private func swiftSourceSelection(
    _ context: WorkspaceContext
) throws -> SwiftSourceSelection {
    let root = context.root
    let workspace = context.layout.swiftToolchain.appendingPathComponent(
        "source", isDirectory: true)
    let modules = try gitOutput(
        ["config", "-f", ".gitmodules", "--get-regexp", "^submodule\\..*\\.path$"],
        in: root)
    let prefix = "swift-toolchain/source/"
    let paths = modules.split(separator: "\n").compactMap { line -> String? in
        guard let separator = line.firstIndex(where: { $0 == " " || $0 == "\t" })
        else { return nil }
        let path = line[line.index(after: separator)...]
            .trimmingCharacters(in: .whitespaces)
        return path.hasPrefix(prefix) ? path : nil
    }.sorted()
    guard !paths.isEmpty else {
        throw WorkspaceFailure.message("Swift source submodules are not declared")
    }
    let index = try gitOutput(["ls-files", "--stage", "--"] + paths, in: root)
    let gitlinks = index.split(separator: "\n").filter { $0.hasPrefix("160000 ") }
    guard gitlinks.count == paths.count else {
        throw WorkspaceFailure.message("Swift source graph contains missing gitlinks")
    }
    let digest = ArtifactHasher.digest(bytes: Array(index.utf8)).description
    let hex =
        digest.hasPrefix("sha256:")
        ? String(digest.dropFirst("sha256:".count))
        : digest
    guard hex.count == 64 else {
        throw WorkspaceFailure.message(
            "invalid Swift source gitlink digest: \(digest)")
    }
    return SwiftSourceSelection(
        workspace: workspace,
        repositories: paths.map {
            FilePath(String($0.dropFirst(prefix.count)))
        },
        sourceID: String(hex.prefix(24)))
}

private func gitOutput(_ arguments: [String], in root: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root.path] + arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let bytes = output.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
        throw WorkspaceFailure.message(String(decoding: bytes, as: UTF8.self))
    }
    return String(decoding: bytes, as: UTF8.self)
}

private func contractStatus(_ stamp: URL) -> String {
    FileManager.default.isReadableFile(atPath: stamp.path)
        ? "established" : "missing; next rebuild resets this lane"
}

private func ninjaWorkspaceStatus(_ workspace: URL) -> String {
    let root = workspace.appendingPathComponent(
        "build/buildbot_linux", isDirectory: true)
    guard FileManager.default.fileExists(atPath: root.path) else {
        return "missing"
    }
    let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles])
    while let file = enumerator?.nextObject() as? URL {
        if file.lastPathComponent == "build.ninja" {
            return "reusable"
        }
    }
    return "present without Ninja graph"
}

private func compilerCacheStatistics(
    at cache: URL,
    environment: [String: String]
) -> CompilerCacheStatistics? {
    guard let executable = executable(named: "ccache", environment: environment)
    else { return nil }
    let process = Process()
    process.executableURL = executable
    process.arguments = ["--dir", cache.path, "--print-stats"]
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    do {
        try process.run()
    } catch {
        return nil
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let text = String(
        decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let values = Dictionary(
        uniqueKeysWithValues: text.split(separator: "\n").compactMap {
            line -> (String, Int)? in
            let fields = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard fields.count == 2, let value = Int(fields[1]) else { return nil }
            return (String(fields[0]), value)
        })
    let hits =
        (values["direct_cache_hit"] ?? 0)
        + (values["preprocessed_cache_hit"] ?? 0)
    guard let misses = values["cache_miss"],
        let size = values["cache_size_kibibyte"]
    else { return nil }
    return CompilerCacheStatistics(
        hits: hits,
        misses: misses,
        cacheSizeKiB: size)
}

private func executable(
    named name: String,
    environment: [String: String]
) -> URL? {
    for directory in (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":") {
        let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
            .appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
    }
    return nil
}

private func reportCompilerCacheDelta(
    from initial: CompilerCacheStatistics?,
    at cache: URL,
    environment: [String: String],
    json: Bool
) {
    guard !json, let initial,
        let final = compilerCacheStatistics(at: cache, environment: environment)
    else { return }
    let delta = final.delta(from: initial)
    print(
        "==> ccache rebuild delta: \(delta.hits) hits, \(delta.misses) misses "
            + "(\(delta.requests) cacheable compilations)")
}

private func alternateNucleusCacheRoots(
    resolved: URL,
    environment: [String: String]
) -> [URL] {
    var candidates: [URL] = []
    if let home = environment["HOME"], !home.isEmpty {
        candidates.append(
            URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(".cache", isDirectory: true))
    }
    if let nativeSDK = environment["NUCLEUS_NATIVE_SDK_ROOT"],
        nativeSDK.hasSuffix("/nucleus/nucleus-native-sdk")
    {
        candidates.append(
            URL(fileURLWithPath: nativeSDK)
                .deletingLastPathComponent()
                .deletingLastPathComponent())
    }
    let volumes = URL(fileURLWithPath: "/Volumes", isDirectory: true)
    let mounted =
        (try? FileManager.default.contentsOfDirectory(
            at: volumes,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
    candidates += mounted
    let canonical = resolved.standardizedFileURL
    return Array(Set(candidates.map(\.standardizedFileURL)))
        .filter {
            $0 != canonical
                && FileManager.default.fileExists(
                    atPath: $0.appendingPathComponent(
                        "nucleus/swift-platforms", isDirectory: true
                    ).path)
        }
        .sorted { $0.path < $1.path }
}

func isReusableSwiftToolchainGeneration(
    generation: URL,
    active: URL,
    sdkDiscoveryLink: URL,
    bundleName: String,
    artifactID: String
) -> Bool {
    let marker = generation.appendingPathComponent(
        ".nucleus-toolchain-artifact")
    guard
        (try? String(contentsOf: marker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) == artifactID,
        FileManager.default.isExecutableFile(
            atPath: generation.appendingPathComponent(
                "toolchain/usr/bin/swift-driver"
            ).path),
        FileManager.default.fileExists(
            atPath: generation.appendingPathComponent(
                "android/\(bundleName)", isDirectory: true
            ).path),
        resolvedSymlink(active)
            == generation.standardizedFileURL.resolvingSymlinksInPath(),
        resolvedSymlink(sdkDiscoveryLink)
            == generation.appendingPathComponent(
                "android/\(bundleName)", isDirectory: true
            ).standardizedFileURL.resolvingSymlinksInPath()
    else { return false }
    return true
}

private func resolvedSymlink(_ link: URL) -> URL? {
    guard
        let target = try? FileManager.default.destinationOfSymbolicLink(
            atPath: link.path)
    else { return nil }
    return URL(
        fileURLWithPath: target,
        relativeTo: link.deletingLastPathComponent()
    ).standardizedFileURL.resolvingSymlinksInPath()
}

struct RebuildOptions {
    var controls: TaskControls
    var architectures: [ToolchainArchitecture]

    init(
        controls: TaskControls = TaskControls(),
        architectures: [ToolchainArchitecture] = []
    ) {
        self.controls = controls
        var seen: Set<ToolchainArchitecture> = []
        let selected = architectures.filter {
            seen.insert($0).inserted
        }
        self.architectures = selected.isEmpty ? [.aarch64] : selected
    }
}

private struct ToolchainStatusRecord: Codable {
    let cacheRoot: String
    let platformID: String
    let platformRoot: String
    let buildLaneRoot: String
    let buildWorkspace: String
    let compilerCache: String
    let hostBuildContract: String
    let androidBuildContract: String
    let ninjaWorkspace: String
    let compilerCacheStatistics: CompilerCacheStatistics?
    let alternateCacheRoots: [String]
    let activeGeneration: String?
    let activeGenerationPath: String?
    let toolchainExecutable: String?
    let androidBundles: [String]
    let generations: [String]
}

struct CompilerCacheStatistics: Codable, Equatable {
    let hits: Int
    let misses: Int
    let cacheSizeKiB: Int

    var requests: Int { hits + misses }

    func delta(from previous: Self) -> Self {
        Self(
            hits: max(0, hits - previous.hits),
            misses: max(0, misses - previous.misses),
            cacheSizeKiB: cacheSizeKiB)
    }
}

struct ToolchainStatus {
    let context: WorkspaceContext

    func run(json: Bool) throws {
        let sourceID = try swiftSourceSelection(context).sourceID
        let paths = SwiftToolchainStoragePaths(
            cacheRoot: context.cacheRoot, sourceID: sourceID)
        let root = paths.artifactRoot
        let current = root.appendingPathComponent("current")
        let destination = try? FileManager.default.destinationOfSymbolicLink(
            atPath: current.path)
        let active = destination.map {
            URL(fileURLWithPath: $0, relativeTo: root).standardizedFileURL
        }
        let toolchain = active?.appendingPathComponent("toolchain/usr/bin/swift")
        let android = active?.appendingPathComponent("android")
        let bundles: [String] =
            try android.map {
                guard FileManager.default.fileExists(atPath: $0.path) else {
                    return [String]()
                }
                return try FileManager.default.contentsOfDirectory(atPath: $0.path)
                    .filter { $0.hasSuffix(".artifactbundle") }
                    .sorted()
            } ?? []
        let generationsURL = root.appendingPathComponent("generations")
        let generations =
            try FileManager.default.fileExists(atPath: generationsURL.path)
            ? FileManager.default.contentsOfDirectory(atPath: generationsURL.path).sorted()
            : []
        let record = ToolchainStatusRecord(
            cacheRoot: paths.cacheRoot.path,
            platformID: paths.platformID,
            platformRoot: root.path,
            buildLaneRoot: paths.buildLaneRoot.path,
            buildWorkspace: paths.buildWorkspace.path,
            compilerCache: paths.compilerCache.path,
            hostBuildContract: contractStatus(
                paths.buildWorkspace.appendingPathComponent(
                    ".nucleus-build-contracts/host.json")),
            androidBuildContract: contractStatus(
                paths.buildWorkspace.appendingPathComponent(
                    ".nucleus-build-contracts/android.json")),
            ninjaWorkspace: ninjaWorkspaceStatus(paths.buildWorkspace),
            compilerCacheStatistics: compilerCacheStatistics(
                at: paths.compilerCache,
                environment: context.environment),
            alternateCacheRoots: alternateNucleusCacheRoots(
                resolved: paths.cacheRoot,
                environment: context.environment
            ).map(\.path),
            activeGeneration: active?.lastPathComponent,
            activeGenerationPath: active?.path,
            toolchainExecutable: toolchain.flatMap {
                FileManager.default.isExecutableFile(atPath: $0.path) ? $0.path : nil
            },
            androidBundles: bundles,
            generations: generations)
        if json {
            print(
                String(
                    decoding: try JSONEncoder.sorted.encode(record), as: UTF8.self))
            return
        }
        print("cache root: \(record.cacheRoot)")
        print("platform: \(record.platformID)")
        print("root: \(record.platformRoot)")
        print("build lane: \(record.buildLaneRoot)")
        print("build workspace: \(record.buildWorkspace)")
        print("compiler cache: \(record.compilerCache)")
        print("host build contract: \(record.hostBuildContract)")
        print("Android build contract: \(record.androidBuildContract)")
        print("Ninja workspace: \(record.ninjaWorkspace)")
        if let statistics = record.compilerCacheStatistics {
            print(
                "ccache: \(statistics.hits) hits, \(statistics.misses) misses, "
                    + "\(statistics.cacheSizeKiB) KiB")
        } else {
            print("ccache: statistics unavailable")
        }
        for alternate in record.alternateCacheRoots {
            print(
                "warning: another Nucleus toolchain cache exists at \(alternate); "
                    + "set one canonical XDG_CACHE_HOME before rebuilding")
        }
        print("active: \(record.activeGeneration ?? "none")")
        print("toolchain: \(record.toolchainExecutable ?? "missing")")
        print(
            "android SDKs: \(record.androidBundles.isEmpty ? "none" : record.androidBundles.joined(separator: ", "))"
        )
        print("generations: \(record.generations.count)")
    }
}

struct ToolchainCommand {
    let context: WorkspaceContext

    func rebuild(_ options: RebuildOptions) async throws {
        let androidToolchain = try AndroidToolchainVersions.load(
            workspaceRoot: context.root)
        let androidNDKHome = try androidToolchain.ndkRoot(
            environment: context.environment)
        let sourceSelection = try swiftSourceSelection(context)
        let sourceID = sourceSelection.sourceID
        let paths = SwiftToolchainStoragePaths(
            cacheRoot: context.cacheRoot, sourceID: sourceID)
        let bundleName = "swift-\(sourceID)_android.artifactbundle"
        let cacheRoot = paths.cacheRoot.path
        let platformRoot = paths.artifactRoot
        let sourceWorkspace = sourceSelection.workspace
        let buildWorkspace = paths.buildWorkspace
        let toolchainRecipe = context.layout.swiftToolchain
        let builderContext = toolchainRecipe.appendingPathComponent(
            "build-container", isDirectory: true)
        let artifactID = try swiftToolchainArtifactID(
            sourceID: sourceID,
            builderContext: FilePath(builderContext.path),
            preset: FilePath(
                toolchainRecipe.appendingPathComponent(
                    "nucleus-build-presets.ini"
                ).path),
            cmakeOverrides: FilePath(
                toolchainRecipe.appendingPathComponent(
                    "nucleus-swift-cmake-overrides.cmake"
                ).path),
            ndkProperties: FilePath(
                androidNDKHome.appendingPathComponent("source.properties").path),
            recipeSource: FilePath(
                context.root.appendingPathComponent(
                    "collider/Sources/SwiftPlatformColliderRecipe"
                ).path),
            hostWorkflowSource: FilePath(
                context.root.appendingPathComponent(
                    "collider/engine/Sources/ColliderRuntime/HostToolchainWorkflow.swift"
                ).path),
            architectures: options.architectures.map(\.rawValue),
            apiLevel: androidToolchain.minimumSDK)
        let runID = currentRunID
        let candidate = platformRoot.appendingPathComponent(
            "generations/.candidate-\(artifactID)-\(runID)")
        let generation = platformRoot.appendingPathComponent(
            "generations/\(artifactID)")
        let toolchainInstall = candidate.appendingPathComponent("toolchain")
        let toolchainRoot = toolchainInstall.appendingPathComponent("usr")
        let androidInstall = candidate.appendingPathComponent("android")
        let sdkSearchRoot = androidInstall
        let platformLogs = platformRoot.appendingPathComponent("logs")
        let builderImageID = URL(fileURLWithPath: cacheRoot, isDirectory: true)
            .appendingPathComponent(
                "nucleus/build-containers/swift/image-reference")
        var environment = context.taskEnvironment
        environment.merge([
            "NUCLEUS_SWIFT_SOURCE_INSTALL": toolchainInstall.path,
            "NUCLEUS_SWIFT_ANDROID_INSTALL": androidInstall.path,
            "NUCLEUS_SWIFT_TOOLCHAIN": toolchainRoot.path,
            "NUCLEUS_SWIFT_SDKS_PATH": sdkSearchRoot.path,
            "NUCLEUS_SWIFT_SOURCE_WORKSPACE": sourceWorkspace.path,
            "NUCLEUS_SWIFT_ANDROID_BUNDLE_NAME": bundleName,
            "NUCLEUS_ANDROID_NDK_HOME": androidNDKHome.path,
            "NUCLEUS_SWIFT_PLATFORM_ORCHESTRATED": "1",
            "NUCLEUS_SWIFT_SOURCE_LOG_DIR":
                platformLogs
                .appendingPathComponent("toolchain").path,
            "NUCLEUS_SWIFT_ANDROID_LOG_DIR":
                platformLogs
                .appendingPathComponent("android").path,
        ]) { _, selected in selected }
        let foundation = SwiftAndroidFoundationConfiguration(
            downloadCache: FilePath(
                URL(fileURLWithPath: cacheRoot, isDirectory: true)
                    .appendingPathComponent(
                        "nucleus/downloads/swift-android-foundation"
                    ).path),
            androidInstallRoot: FilePath(androidInstall.path),
            ndkRoot: FilePath(androidNDKHome.path),
            architectures: options.architectures.map(\.rawValue),
            apiLevel: androidToolchain.minimumSDK,
            jobs: UInt32(
                min(
                    ProcessInfo.processInfo.activeProcessorCount, 16)),
            builder: SwiftOCIConfiguration(
                imageID: FilePath(builderImageID.path),
                sourceWorkspace: FilePath(sourceWorkspace.path),
                recipeRoot: FilePath(toolchainRecipe.path),
                buildWorkspace: FilePath(buildWorkspace.path),
                compilerCache: FilePath(
                    paths.compilerCache.path),
                candidate: FilePath(candidate.path)),
            environment: environment)
        let discoveryDirectory = homeDirectory.appendingPathComponent(
            ".swiftpm/swift-sdks", isDirectory: true)
        let discoveryLink = discoveryDirectory.appendingPathComponent(bundleName)
        let generationConfiguration =
            SwiftPlatformGenerationConfiguration(
                foundation: foundation,
                candidate: FilePath(candidate.path),
                generation: FilePath(generation.path),
                active: FilePath(
                    platformRoot.appendingPathComponent("current").path),
                recipeRoot: FilePath(toolchainRecipe.path),
                builderContext: FilePath(builderContext.path),
                builderImageID: FilePath(builderImageID.path),
                sourceWorkspace: FilePath(sourceWorkspace.path),
                buildWorkspace: FilePath(buildWorkspace.path),
                sourceRepositories: sourceSelection.repositories,
                sourceID: sourceID,
                artifactID: artifactID,
                hostCC: FilePath(
                    try hostCompiler(
                        environmentName: "NUCLEUS_HOST_CC",
                        executable: "clang"
                    ).path),
                hostCXX: FilePath(
                    try hostCompiler(
                        environmentName: "NUCLEUS_HOST_CXX",
                        executable: "clang++"
                    ).path),
                bundleName: bundleName,
                sdkDiscoveryLink: FilePath(discoveryLink.path),
                sdkDiscoveryDisplacedItem: FilePath(
                    discoveryDirectory.appendingPathComponent(
                        ".legacy-\(bundleName)-\(runID)"
                    ).path),
                environment: environment)
        if isReusableSwiftToolchainGeneration(
            generation: generation,
            active: platformRoot.appendingPathComponent("current"),
            sdkDiscoveryLink: discoveryLink,
            bundleName: bundleName,
            artifactID: artifactID)
        {
            try await ColliderRuntime().validateSwiftSourceWorkspace(
                SwiftSourceWorkspaceValidation(
                    workspaceRoot: FilePath(sourceWorkspace.path),
                    repositories: sourceSelection.repositories,
                    environment: environment))
            if options.controls.json {
                let result = [
                    "artifactID": artifactID,
                    "generation": generation.path,
                    "status": "clean",
                ]
                print(
                    String(
                        decoding: try JSONEncoder.sorted.encode(result),
                        as: UTF8.self))
            } else if options.controls.dryRun || options.controls.explain {
                print(
                    "clean  toolchain.generation  immutable generation "
                        + "\(artifactID) is active and validated")
            } else if !options.controls.quiet {
                print("==> Swift toolchain generation is clean: \(generation.path)")
            }
            return
        }
        let taskSet = try SwiftPlatformColliderRecipe.generation(
            generationConfiguration)
        if !options.controls.json {
            print("==> Swift artifact root: \(paths.artifactRoot.path)")
            print("==> Swift incremental build lane: \(paths.buildWorkspace.path)")
            print("==> Swift compiler cache: \(paths.compilerCache.path)")
            for alternate in alternateNucleusCacheRoots(
                resolved: paths.cacheRoot,
                environment: context.environment)
            {
                print(
                    "warning: another Nucleus toolchain cache exists at "
                        + "\(alternate.path); set one canonical XDG_CACHE_HOME "
                        + "before rebuilding")
            }
        }
        let initialCompilerCache = compilerCacheStatistics(
            at: paths.compilerCache,
            environment: context.environment)
        do {
            try await context.execute(
                tasks: taskSet.tasks,
                selected: taskSet.selected,
                controls: options.controls,
                workflowLocks: [
                    .shared(FilePath(paths.rebuildLock.path))
                ])
        } catch {
            reportCompilerCacheDelta(
                from: initialCompilerCache,
                at: paths.compilerCache,
                environment: context.environment,
                json: options.controls.json)
            throw error
        }
        reportCompilerCacheDelta(
            from: initialCompilerCache,
            at: paths.compilerCache,
            environment: context.environment,
            json: options.controls.json)
        guard !options.controls.dryRun, !options.controls.explain else { return }
        try context.reclaimSwiftBuildContexts()
        if !options.controls.json {
            print("==> active Swift platform generation: \(generation.path)")
        }
    }

    private var currentRunID: String {
        if let runDirectory = context.environment["NUCLEUS_RUN_DIR"],
            !runDirectory.isEmpty
        {
            return URL(fileURLWithPath: runDirectory).lastPathComponent
        }
        return Date().formatted(.iso8601)
            .replacing(":", with: "-") + "-\(getpid())"
    }

    private func hostCompiler(
        environmentName: String,
        executable: String
    ) throws -> URL {
        let requested = context.environment[environmentName] ?? executable
        if requested.hasPrefix("/") {
            let path = URL(fileURLWithPath: requested).standardizedFileURL
            guard FileManager.default.isExecutableFile(atPath: path.path) else {
                throw WorkspaceFailure.message(
                    "host compiler is not executable: \(path.path)")
            }
            return path
        }
        for directory in (context.environment["PATH"] ?? "/usr/bin:/bin")
            .split(separator: ":", omittingEmptySubsequences: false)
        {
            let root = directory.isEmpty ? "." : String(directory)
            let candidate = URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent(requested)
                .standardizedFileURL
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw WorkspaceFailure.message(
            "host compiler '\(requested)' was not found on PATH")
    }

    private var homeDirectory: URL {
        if let home = context.environment["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

}

struct ToolchainInstallation {
    let context: WorkspaceContext

    func install(
        version: String?,
        prefix: String?,
        tarball: String?,
        dryRun: Bool
    ) async throws {
        let resolvedVersion = try validatedVersion(version)
        let resolvedPrefix = try validatedPrefix(prefix)
        let resolvedTarball = URL(
            fileURLWithPath: tarball
                ?? defaultTarball(
                    version: resolvedVersion
                ).path
        ).standardizedFileURL
        guard FileManager.default.fileExists(atPath: resolvedTarball.path) else {
            throw WorkspaceFailure.message(
                "Swift toolchain archive not found: \(resolvedTarball.path)")
        }
        let identity = try ArtifactHasher.digest(file: FilePath(resolvedTarball.path))
        try await invokeHelper(
            operation: .install,
            version: resolvedVersion,
            prefix: resolvedPrefix,
            tarball: resolvedTarball,
            identity: identity,
            dryRun: dryRun)
    }

    func uninstall(
        version: String?,
        prefix: String?,
        dryRun: Bool
    ) async throws {
        try await invokeHelper(
            operation: .uninstall,
            version: try validatedVersion(version),
            prefix: try validatedPrefix(prefix),
            tarball: nil,
            identity: nil,
            dryRun: dryRun)
    }

    private func invokeHelper(
        operation: ToolchainSystemOperation,
        version: String,
        prefix: URL,
        tarball: URL?,
        identity: ArtifactDigest?,
        dryRun: Bool
    ) async throws {
        let executable: URL
        #if os(Linux)
        executable = URL(fileURLWithPath: "/proc/self/exe")
            .resolvingSymlinksInPath()
        #else
        guard let bundledExecutable = Bundle.main.executableURL else {
            throw WorkspaceFailure.message("could not resolve the Collider executable")
        }
        executable = bundledExecutable.standardizedFileURL
        #endif
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw WorkspaceFailure.message("could not resolve the Collider executable")
        }
        var helperArguments = [
            operation.entryPoint,
            version,
            prefix.path,
        ]
        switch operation {
        case .install:
            guard let tarball, let identity else {
                throw WorkspaceFailure.message("toolchain installation input is incomplete")
            }
            helperArguments += [tarball.path, identity.description]
        case .uninstall:
            break
        }
        let commandArguments = ["--", executable.path] + helperArguments
        if dryRun {
            print((["sudo"] + commandArguments).joined(separator: " "))
            return
        }
        try await context.run(
            "sudo",
            commandArguments,
            directory: context.root,
            terminal: true)
    }

    private func validatedVersion(_ supplied: String?) throws -> String {
        guard let value = supplied ?? context.environment["NUCLEUS_SWIFT_SOURCE_ID"]
        else {
            throw WorkspaceFailure.message(
                "Swift source identity is missing; source tools/host-env.sh")
        }
        return try ToolchainSystemRequest.validateVersion(value)
    }

    private func validatedPrefix(_ supplied: String?) throws -> URL {
        let value = supplied ?? "/opt/nucleus-swift"
        return try ToolchainSystemRequest.validatePrefix(value)
    }

    private func defaultTarball(version: String) -> URL {
        return context.cacheRoot.appendingPathComponent(
            "nucleus/swift-platforms/\(version)/current/toolchain/"
                + "swift-\(version)-linux.tar.gz")
    }
}
