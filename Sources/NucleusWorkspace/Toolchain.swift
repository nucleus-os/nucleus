import FoundationEssentials
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

struct ToolchainCommand {
    let context: WorkspaceContext

    private static let usage = """
    Usage: tools/nucleus toolchain rebuild [options]

      Rebuilds the host Swift toolchain and Android Swift SDK into one inactive
      user-level generation, wires and verifies that generation, then atomically
      activates both artifacts together.

      --dry-run          Print the complete workflow without running it
      --reconfigure      Force host-toolchain reconfiguration
      --skip-ndk         Require the configured Android NDK without downloading it
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
        var reconfigure = false
        var skipNDK = false
        var arches: [String] = []

        init(_ arguments: [String]) throws {
            var index = arguments.startIndex
            while index < arguments.endIndex {
                switch arguments[index] {
                case "--dry-run": dryRun = true
                case "--reconfigure": reconfigure = true
                case "--skip-ndk": skipNDK = true
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
        #if os(macOS)
        let platformID = sourceID + "-macos"
        let toolchainBuildScript = "build-macos.sh"
        let androidBuildScript = "build-macos.sh"
        let bundleName = "swift-\(sourceID)-macos_android.artifactbundle"
        #else
        let platformID = sourceID
        let toolchainBuildScript = "build.sh"
        let androidBuildScript = "build.sh"
        let bundleName = "swift-\(sourceID)_android.artifactbundle"
        #endif
        let cacheRoot = context.environment["XDG_CACHE_HOME"]
            ?? homeDirectory.appendingPathComponent(".cache").path
        let platformRoot = URL(fileURLWithPath: cacheRoot)
            .appendingPathComponent("nucleus/swift-platforms/\(platformID)")
        let generationID = Date().formatted(.iso8601)
            .replacing(":", with: "-") + "-\(getpid())"
        let generations = platformRoot.appendingPathComponent("generations")
        let generation = generations.appendingPathComponent(generationID)
        let toolchainInstall = generation.appendingPathComponent("toolchain")
        let toolchainRoot = toolchainInstall.appendingPathComponent("usr")
        let androidInstall = generation.appendingPathComponent("android")
        let sdkSearchRoot = androidInstall
        let platformLogs = platformRoot.appendingPathComponent("logs")
        let toolchainRecipe = context.root.appendingPathComponent("swift-toolchain")
        let androidRecipe = context.root.appendingPathComponent("swift-android-sdk")

        var toolchainArguments: [String] = []
        if options.reconfigure { toolchainArguments.append("--reconfigure") }
        var sdkArguments = ["--reconfigure"]
        if options.skipNDK { sdkArguments.append("--skip-ndk") }
        for arch in options.arches { sdkArguments += ["--arch", arch] }

        let environment = [
            "NUCLEUS_SWIFT_SOURCE_INSTALL": toolchainInstall.path,
            "NUCLEUS_SWIFT_ANDROID_INSTALL": androidInstall.path,
            "NUCLEUS_SWIFT_TOOLCHAIN": toolchainRoot.path,
            "NUCLEUS_SWIFT_SDKS_PATH": sdkSearchRoot.path,
            "NUCLEUS_SWIFT_ANDROID_BUNDLE_NAME": bundleName,
            "NUCLEUS_SWIFT_PLATFORM_ORCHESTRATED": "1",
            "NUCLEUS_SWIFT_SOURCE_LOG_DIR": platformLogs
                .appendingPathComponent("toolchain").path,
            "NUCLEUS_SWIFT_ANDROID_LOG_DIR": platformLogs
                .appendingPathComponent("android").path,
        ]

        if options.dryRun {
            print("generation: \(generation.path)")
            printCommand("host-toolchain", "./\(toolchainBuildScript)", toolchainArguments, toolchainRecipe, environment)
            printCommand("android-sdk", "./\(androidBuildScript)", sdkArguments, androidRecipe, environment)
            printCommand("wire-android-sdk", "./scripts/prepare-sdk.sh", [], androidRecipe, environment)
            for arch in options.arches {
                printCommand(
                    "test-android-sdk-\(arch)",
                    "./scripts/test-installed-sdk.sh",
                    [],
                    androidRecipe,
                    environment.merging(["NUCLEUS_SWIFT_ANDROID_TEST_ARCH": arch]) { _, new in new })
            }
            print("==> activate-generation\n\(platformRoot.path)/current -> generations/\(generationID)")
            return
        }

        try FileManager.default.createDirectory(
            at: generations, withIntermediateDirectories: true)
        let lock = try WorkspaceFileLock(
            path: platformRoot.appendingPathComponent("rebuild.lock").path,
            purpose: "toolchain rebuild")
        defer { withExtendedLifetime(lock) {} }
        try? FileManager.default.removeItem(at: generation)
        try FileManager.default.createDirectory(at: generation, withIntermediateDirectories: true)
        var published = false
        defer {
            if !published { try? FileManager.default.removeItem(at: generation) }
        }

        print("==> host-toolchain")
        try context.run(
            "./\(toolchainBuildScript)", toolchainArguments, directory: toolchainRecipe,
            environmentOverrides: environment)
        print("==> android-sdk")
        try context.run(
            "./\(androidBuildScript)", sdkArguments, directory: androidRecipe,
            environmentOverrides: environment)
        print("==> wire-android-sdk")
        try context.run(
            "./scripts/prepare-sdk.sh", [], directory: androidRecipe,
            environmentOverrides: environment)
        for arch in options.arches {
            print("==> test-android-sdk-\(arch)")
            try context.run(
                "./scripts/test-installed-sdk.sh", [], directory: androidRecipe,
                environmentOverrides: environment.merging(
                    ["NUCLEUS_SWIFT_ANDROID_TEST_ARCH": arch]) { _, new in new })
        }

        guard FileManager.default.fileExists(
            atPath: sdkSearchRoot.appendingPathComponent(bundleName).path)
        else {
            throw WorkspaceFailure.message("staged Android SDK bundle is missing")
        }
        let discoveryChange = try ensureSDKDiscoveryLink(
            platformRoot: platformRoot, bundleName: bundleName)
        do {
            try activate(generationID: generationID, platformRoot: platformRoot)
        } catch {
            try? rollbackSDKDiscoveryLink(discoveryChange)
            throw error
        }
        published = true
        print("==> active Swift platform generation: \(generation.path)")
    }

    private func printCommand(
        _ phase: String,
        _ executable: String,
        _ arguments: [String],
        _ directory: URL,
        _ environment: [String: String]
    ) {
        print("==> \(phase)")
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
            print("\(key)=\(value)", terminator: " ")
        }
        print(([directory.appendingPathComponent(String(executable.dropFirst(2))).path] + arguments)
            .joined(separator: " "))
    }

    private enum SDKDiscoveryChange {
        case unchanged
        case created(URL)
        case replacedSymlink(URL, String)
        case movedItem(URL, URL)
    }

    private func ensureSDKDiscoveryLink(
        platformRoot: URL, bundleName: String
    ) throws -> SDKDiscoveryChange {
        let directory = homeDirectory.appendingPathComponent(".swiftpm/swift-sdks")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent(bundleName)
        let destination = platformRoot.appendingPathComponent("current/android/\(bundleName)").path
        if let existing = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) {
            if existing == destination { return .unchanged }
            try FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(
                atPath: link.path, withDestinationPath: destination)
            return .replacedSymlink(link, existing)
        } else if FileManager.default.fileExists(atPath: link.path) {
            let backup = directory.appendingPathComponent(".legacy-\(bundleName)-\(getpid())")
            try FileManager.default.moveItem(at: link, to: backup)
            try FileManager.default.createSymbolicLink(
                atPath: link.path, withDestinationPath: destination)
            return .movedItem(link, backup)
        }
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
        return .created(link)
    }

    private func rollbackSDKDiscoveryLink(_ change: SDKDiscoveryChange) throws {
        switch change {
        case .unchanged:
            return
        case .created(let link):
            try FileManager.default.removeItem(at: link)
        case .replacedSymlink(let link, let destination):
            try FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(
                atPath: link.path, withDestinationPath: destination)
        case .movedItem(let link, let backup):
            try FileManager.default.removeItem(at: link)
            try FileManager.default.moveItem(at: backup, to: link)
        }
    }

    private func activate(generationID: String, platformRoot: URL) throws {
        let next = platformRoot.appendingPathComponent(".current-\(getpid())")
        try? FileManager.default.removeItem(at: next)
        try FileManager.default.createSymbolicLink(
            atPath: next.path,
            withDestinationPath: "generations/\(generationID)")
        guard rename(next.path, platformRoot.appendingPathComponent("current").path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: next)
            throw WorkspaceFailure.message(
                "could not activate Swift platform generation: errno \(code)")
        }
    }

    private var homeDirectory: URL {
        if let home = context.environment["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
