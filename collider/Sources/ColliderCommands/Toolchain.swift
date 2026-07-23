import ColliderCore
import ColliderRuntime
import FoundationEssentials
import SwiftPlatformColliderRecipe
import SystemPackage
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

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
        let sourceID = context.environment["NUCLEUS_SWIFT_SOURCE_ID"]
            ?? "release-6.4.x"
        #if os(macOS)
        let platformID = sourceID + "-macos"
        #else
        let platformID = sourceID
        #endif
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
        let bundles: [String] = try android.map {
            guard FileManager.default.fileExists(atPath: $0.path) else {
                return [String]()
            }
            return try FileManager.default.contentsOfDirectory(atPath: $0.path)
                .filter { $0.hasSuffix(".artifactbundle") }
                .sorted()
        } ?? []
        let generationsURL = root.appendingPathComponent("generations")
        let generations = try FileManager.default.fileExists(atPath: generationsURL.path)
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
            print(String(
                decoding: try JSONEncoder.sorted.encode(record), as: UTF8.self))
            return
        }
        print("platform: \(record.platformID)")
        print("root: \(record.platformRoot)")
        print("active: \(record.activeGeneration ?? "none")")
        print("toolchain: \(record.toolchainExecutable ?? "missing")")
        print("android SDKs: \(record.androidBundles.isEmpty ? "none" : record.androidBundles.joined(separator: ", "))")
        print("generations: \(record.generations.count)")
    }
}

struct ToolchainCommand {
    let context: WorkspaceContext

    private static let usage = """
    Usage: collider toolchain rebuild [options]

      Rebuilds the host Swift toolchain and Android Swift SDK into one inactive
      user-level generation, wires and verifies that generation, then atomically
      activates both artifacts together.

      --dry-run          Print the complete workflow without running it
      --explain          Explain task invalidation
      --verbose          Stream leaf commands
      --json             Emit the task report as JSON
      --reconfigure      Force host-toolchain reconfiguration
      --arch ARCH        Build and test aarch64 or x86_64; repeat for both
    """

    func run(_ arguments: ArraySlice<String>) throws {
        guard let command = arguments.first else {
            throw WorkspaceFailure.message(Self.usage)
        }
        switch command {
        case "rebuild": try rebuild(Array(arguments.dropFirst()))
        case "help", "--help", "-h": print(Self.usage)
        default:
            throw WorkspaceFailure.message(
                "unknown toolchain command '\(command)'\n\n\(Self.usage)")
        }
    }

    private struct RebuildOptions {
        var dryRun = false
        var explain = false
        var verbose = false
        var json = false
        var reconfigure = false
        var arches: [String] = []

        var controls: TaskControls {
            TaskControls(dryRun: dryRun, explain: explain, verbose: verbose, json: json)
        }

        init(_ arguments: [String]) throws {
            var index = arguments.startIndex
            while index < arguments.endIndex {
                switch arguments[index] {
                case "--dry-run": dryRun = true
                case "--explain": explain = true
                case "--verbose": verbose = true
                case "--json": json = true
                case "--reconfigure": reconfigure = true
                case "--arch":
                    index += 1
                    guard index < arguments.endIndex else {
                        throw WorkspaceFailure.message("--arch needs a value")
                    }
                    let arch = arguments[index]
                    guard ["aarch64", "x86_64"].contains(arch) else {
                        throw WorkspaceFailure.message(
                            "unsupported Android SDK architecture '\(arch)'")
                    }
                    if !arches.contains(arch) { arches.append(arch) }
                default:
                    throw WorkspaceFailure.message(
                        "unknown toolchain rebuild option '\(arguments[index])'\n\n\(ToolchainCommand.usage)")
                }
                index += 1
            }
            if arches.isEmpty { arches = ["aarch64"] }
        }
    }

    private func rebuild(_ arguments: [String]) throws {
        let options = try RebuildOptions(arguments)
        let sourceID = context.environment["NUCLEUS_SWIFT_SOURCE_ID"] ?? "release-6.4.x"
        let sourceRef: String
        let sourceScheme: String
        var checkoutMode: SwiftPlatformGenerationConfiguration.CheckoutMode
        if let explicitRef = context.environment["NUCLEUS_SWIFT_SOURCE_REF"],
           !explicitRef.isEmpty
        {
            sourceRef = explicitRef
            sourceScheme = context.environment["NUCLEUS_SWIFT_SOURCE_SCHEME"]
                ?? explicitRef
            checkoutMode = .branch
        } else if let tag = context.environment["NUCLEUS_SWIFT_SOURCE_TAG"],
                  !tag.isEmpty
        {
            sourceRef = tag
            sourceScheme = context.environment["NUCLEUS_SWIFT_SOURCE_SCHEME"]
                ?? "main"
            checkoutMode = .tag
        } else {
            sourceRef = "release/6.4.x"
            sourceScheme = context.environment["NUCLEUS_SWIFT_SOURCE_SCHEME"]
                ?? sourceRef
            checkoutMode = .branch
        }
        if let mode = context.environment[
            "NUCLEUS_SWIFT_SOURCE_CHECKOUT_MODE"]
        {
            guard let explicitMode =
                SwiftPlatformGenerationConfiguration.CheckoutMode(
                    rawValue: mode)
            else {
                throw WorkspaceFailure.message(
                    "unsupported Swift checkout mode '\(mode)'")
            }
            checkoutMode = explicitMode
        }
        #if os(macOS)
        let platformID = sourceID + "-macos"
        let bundleName = "swift-\(sourceID)-macos_android.artifactbundle"
        #else
        let platformID = sourceID
        let bundleName = "swift-\(sourceID)_android.artifactbundle"
        #endif
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
        let sourceWorkspace = context.environment[
            "NUCLEUS_SWIFT_SOURCE_WORKSPACE"
        ].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? URL(fileURLWithPath: cacheRoot, isDirectory: true)
            .appendingPathComponent("nucleus/swift-source/\(platformID)")
        let platformLogs = platformRoot.appendingPathComponent("logs")
        let toolchainRecipe = context.root.appendingPathComponent("swift-toolchain")
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
            "NUCLEUS_SWIFT_SOURCE_LOG_DIR": platformLogs
                .appendingPathComponent("toolchain").path,
            "NUCLEUS_SWIFT_ANDROID_LOG_DIR": platformLogs
                .appendingPathComponent("android").path,
        ]) { _, selected in selected }
        let foundation = SwiftAndroidFoundationConfiguration(
            downloadCache: FilePath(
                URL(fileURLWithPath: cacheRoot, isDirectory: true)
                    .appendingPathComponent(
                        "nucleus/downloads/swift-android-foundation").path),
            androidInstallRoot: FilePath(androidInstall.path),
            ndkRoot: FilePath(androidNDKHome.path),
            architectures: options.arches,
            apiLevel: 36,
            jobs: UInt32(min(
                ProcessInfo.processInfo.activeProcessorCount, 16)),
            environment: environment)
        let discoveryDirectory = homeDirectory.appendingPathComponent(
            ".swiftpm/swift-sdks", isDirectory: true)
        let discoveryLink = discoveryDirectory.appendingPathComponent(bundleName)
        let taskSet = try SwiftPlatformColliderRecipe.generation(
            SwiftPlatformGenerationConfiguration(
                foundation: foundation,
                candidate: FilePath(candidate.path),
                generation: FilePath(generation.path),
                active: FilePath(
                    platformRoot.appendingPathComponent("current").path),
                recipeRoot: FilePath(toolchainRecipe.path),
                sourceWorkspace: FilePath(sourceWorkspace.path),
                sourceID: platformID,
                sourceRef: sourceRef,
                sourceScheme: sourceScheme,
                checkoutMode: checkoutMode,
                hostCC: FilePath(try hostCompiler(
                    environmentName: "NUCLEUS_HOST_CC",
                    executable: "clang").path),
                hostCXX: FilePath(try hostCompiler(
                    environmentName: "NUCLEUS_HOST_CXX",
                    executable: "clang++").path),
                bundleName: bundleName,
                validationWorkRoot: FilePath(validationWorkRoot.path),
                sdkDiscoveryLink: FilePath(discoveryLink.path),
                sdkDiscoveryDisplacedItem: FilePath(
                    discoveryDirectory.appendingPathComponent(
                        ".legacy-\(bundleName)-\(generationID)").path),
                reconfigureHost: options.reconfigure,
                environment: environment))
        try context.execute(
            tasks: taskSet.tasks,
            selected: taskSet.selected,
            controls: options.controls,
            workflowLocks: [
                .shared(FilePath(
                    platformRoot.appendingPathComponent("rebuild.lock").path)),
            ])
        if !options.json, !options.dryRun, !options.explain {
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

    private var androidNDKHome: URL {
        if let explicit = context.environment["NUCLEUS_ANDROID_NDK_HOME"]
            ?? context.environment["ANDROID_NDK_HOME"],
           !explicit.isEmpty
        {
            return URL(fileURLWithPath: explicit, isDirectory: true)
        }
        let version = context.environment["NUCLEUS_ANDROID_NDK_VERSION"]
            ?? "30.0.14904198"
        #if os(macOS)
        return homeDirectory.appendingPathComponent(
            "Library/Android/sdk/ndk/\(version)", isDirectory: true)
        #else
        return homeDirectory.appendingPathComponent(
            "Android/Sdk/ndk/\(version)", isDirectory: true)
        #endif
    }

    private var validationWorkRoot: URL {
        if let runDirectory = context.environment["NUCLEUS_RUN_DIR"],
           !runDirectory.isEmpty
        {
            return URL(fileURLWithPath: runDirectory, isDirectory: true)
                .appendingPathComponent("work/android-sdk", isDirectory: true)
        }
        return context.root.appendingPathComponent(
            ".nucleus/work/android-sdk", isDirectory: true)
    }
}

struct ToolchainInstallation {
    let context: WorkspaceContext

    func install(
        version: String?,
        prefix: String?,
        tarball: String?,
        dryRun: Bool
    ) throws {
        let resolvedVersion = try validatedVersion(version)
        let resolvedPrefix = try validatedPrefix(prefix)
        let resolvedTarball = URL(fileURLWithPath: tarball ?? defaultTarball(
            version: resolvedVersion).path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: resolvedTarball.path) else {
            throw WorkspaceFailure.message(
                "Swift toolchain archive not found: \(resolvedTarball.path)")
        }
        let identity = try ArtifactHasher.digest(file: FilePath(resolvedTarball.path))
        try invokeHelper(
            arguments: [],
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
    ) throws {
        try invokeHelper(
            arguments: ["--uninstall"],
            version: try validatedVersion(version),
            prefix: try validatedPrefix(prefix),
            tarball: nil,
            identity: nil,
            dryRun: dryRun)
    }

    private func invokeHelper(
        arguments: [String],
        version: String,
        prefix: URL,
        tarball: URL?,
        identity: ArtifactDigest?,
        dryRun: Bool
    ) throws {
        let helper = context.root.appendingPathComponent("swift-toolchain/install.sh")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw WorkspaceFailure.message(
                "privileged toolchain helper is not executable: \(helper.path)")
        }
        var environmentArguments = [
            "NUCLEUS_SWIFT_VERSION=\(version)",
            "NUCLEUS_SWIFT_PREFIX=\(prefix.path)",
        ]
        if let tarball {
            environmentArguments.append("NUCLEUS_SWIFT_TARBALL=\(tarball.path)")
        }
        if let identity {
            environmentArguments.append("NUCLEUS_SWIFT_ARTIFACT_ID=\(identity)")
        }
        let commandArguments = ["env"] + environmentArguments + [helper.path] + arguments
        if dryRun {
            print((["sudo"] + commandArguments).joined(separator: " "))
            return
        }
        try context.run(
            "sudo",
            commandArguments,
            directory: context.root,
            terminal: true)
    }

    private func validatedVersion(_ supplied: String?) throws -> String {
        let value = supplied
            ?? context.environment["NUCLEUS_SWIFT_SOURCE_ID"]
            ?? "release-6.4.x"
        guard !value.isEmpty,
              value.first?.isLetter == true || value.first?.isNumber == true,
              !value.contains(".."),
              value.allSatisfy({ $0.isLetter || $0.isNumber || ".-_".contains($0) })
        else {
            throw WorkspaceFailure.message("invalid Swift toolchain version '\(value)'")
        }
        return value
    }

    private func validatedPrefix(_ supplied: String?) throws -> URL {
        let value = supplied ?? "/opt/nucleus-swift"
        let resolved = URL(
            fileURLWithPath: value, isDirectory: true).standardizedFileURL
        guard value.hasPrefix("/"), resolved.path != "/" else {
            throw WorkspaceFailure.message(
                "toolchain install prefix must be an absolute non-root path")
        }
        return resolved
    }

    private func defaultTarball(version: String) -> URL {
        return context.cacheRoot.appendingPathComponent(
            "nucleus/swift-platforms/\(version)/current/toolchain/"
                + "swift-\(version)-linux.tar.gz")
    }
}
