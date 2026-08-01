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
    let platformID: String
    let platformRoot: String
    let activeGeneration: String?
    let activeGenerationPath: String?
    let toolchainExecutable: String?
    let androidBundles: [String]
    let generations: [String]
}

struct ToolchainStatus {
    let context: WorkspaceContext

    func run(json: Bool) throws {
        let sourceID = try swiftSourceSelection(context).sourceID
        let platformID = sourceID + "-linux-amd64"
        let root = context.cacheRoot.appendingPathComponent(
            "nucleus/swift-platforms/\(platformID)",
            isDirectory: true)
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
            platformID: platformID,
            platformRoot: root.path,
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
        print("platform: \(record.platformID)")
        print("root: \(record.platformRoot)")
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
        let platformID = sourceID + "-linux-amd64"
        let bundleName = "swift-\(sourceID)_android.artifactbundle"
        let cacheRoot = context.cacheRoot.path
        let platformRoot = URL(fileURLWithPath: cacheRoot)
            .appendingPathComponent("nucleus/swift-platforms/\(platformID)")
        let generationID = currentRunID
        let candidate = platformRoot.appendingPathComponent(
            "generations/.candidate-\(generationID)")
        let generation = platformRoot.appendingPathComponent(
            "generations/\(generationID)")
        let toolchainInstall = candidate.appendingPathComponent("toolchain")
        let toolchainRoot = toolchainInstall.appendingPathComponent("usr")
        let androidInstall = candidate.appendingPathComponent("android")
        let sdkSearchRoot = androidInstall
        let sourceWorkspace = sourceSelection.workspace
        let buildWorkspace = platformRoot.appendingPathComponent(
            "build", isDirectory: true)
        let platformLogs = platformRoot.appendingPathComponent("logs")
        let toolchainRecipe = context.layout.swiftToolchain
        let builderContext = toolchainRecipe.appendingPathComponent(
            "build-container", isDirectory: true)
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
                    URL(fileURLWithPath: cacheRoot, isDirectory: true)
                        .appendingPathComponent("nucleus/ccache/swift").path),
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
                        ".legacy-\(bundleName)-\(generationID)"
                    ).path),
                environment: environment)
        let taskSet = try SwiftPlatformColliderRecipe.generation(
            generationConfiguration)
        if !options.controls.dryRun, !options.controls.explain {
            try reclaimSupersededAndroidBuildRoots(generationConfiguration)
        }
        try await context.execute(
            tasks: taskSet.tasks,
            selected: taskSet.selected,
            controls: options.controls,
            workflowLocks: [
                .shared(
                    FilePath(
                        platformRoot.appendingPathComponent("rebuild.lock").path))
            ])
        guard !options.controls.dryRun, !options.controls.explain else { return }
        try context.reclaimSwiftBuildContexts()
        if !options.controls.json {
            print("==> active Swift platform generation: \(generation.path)")
        }
    }

    /// Remove the cross build roots of retired generations before configuring
    /// this one. They describe host tools that no longer exist, and one left
    /// inconsistent by a failed configure fails every rebuild after it, so a
    /// rebuild that inherits nothing is a rebuild that can repair itself.
    private func reclaimSupersededAndroidBuildRoots(
        _ configuration: SwiftPlatformGenerationConfiguration
    ) throws {
        for root
            in SwiftPlatformColliderRecipe
            .supersededAndroidBuildRoots(configuration)
        where FileManager.default.fileExists(atPath: root.string) {
            print("==> reclaiming superseded cross build root: \(root)")
            try FileManager.default.removeItem(atPath: root.string)
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
