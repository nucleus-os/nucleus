import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SwiftTargetSDKColliderRecipe
import SystemPackage

#if canImport(Darwin)
import Darwin
#endif

struct RebuildOptions {
    var controls: TaskControls

    init(controls: TaskControls = TaskControls()) {
        self.controls = controls
    }
}

struct SwiftTargetSDKStoragePaths: Equatable {
    let cacheRoot: URL
    let artifactRoot: URL
    let downloadRoot: URL
    let generatorScratch: URL
    let runtimeBuilderImageID: URL
    let runtimeCompilerCache: URL
    let runtimeBuildRoot: URL
    let rebuildLock: URL

    init(cacheRoot: URL) {
        self.cacheRoot = cacheRoot.standardizedFileURL
        artifactRoot = self.cacheRoot.appendingPathComponent(
            "nucleus/swift-target-sdks", isDirectory: true)
        downloadRoot = self.cacheRoot.appendingPathComponent(
            "nucleus/downloads/swift-target-sdks", isDirectory: true)
        generatorScratch = self.cacheRoot.appendingPathComponent(
            "nucleus/build/swift-sdk-generator", isDirectory: true)
        runtimeBuilderImageID = self.cacheRoot.appendingPathComponent(
            "nucleus/build-containers/swift-runtime/image-id")
        runtimeCompilerCache = self.cacheRoot.appendingPathComponent(
            "nucleus/ccache/swift-runtime", isDirectory: true)
        runtimeBuildRoot = self.cacheRoot.appendingPathComponent(
            "nucleus/build/swift-target-runtime", isDirectory: true)
        rebuildLock = artifactRoot.appendingPathComponent("rebuild.lock")
    }
}

func swiftTargetSDKArtifactID(
    lockFile: FilePath,
    generatorSource: FilePath,
    validationFixture: FilePath,
    validator: FilePath,
    ndkProperties: FilePath,
    xcodeIdentity: String,
    sourceID: String,
    runtimeBuilderContext: FilePath,
    runtimePreset: FilePath,
    sysrootPreparer: FilePath
) throws -> String {
    var encoder = CanonicalDigestEncoder()
    encoder.append(tag: 1, bytes: try ArtifactHasher.digest(file: lockFile).bytes)
    encoder.append(
        tag: 2,
        bytes: try ArtifactHasher.digest(tree: generatorSource).bytes)
    encoder.append(
        tag: 3,
        bytes: try ArtifactHasher.digest(tree: validationFixture).bytes)
    encoder.append(tag: 4, bytes: try ArtifactHasher.digest(file: validator).bytes)
    encoder.append(
        tag: 5,
        bytes: try ArtifactHasher.digest(file: ndkProperties).bytes)
    encoder.append(tag: 6, string: xcodeIdentity)
    encoder.append(tag: 7, string: sourceID)
    encoder.append(
        tag: 8,
        bytes: try ArtifactHasher.digest(tree: runtimeBuilderContext).bytes)
    encoder.append(tag: 9, bytes: try ArtifactHasher.digest(file: runtimePreset).bytes)
    encoder.append(tag: 10, bytes: try ArtifactHasher.digest(file: sysrootPreparer).bytes)
    let digest = ArtifactHasher.digest(bytes: encoder.bytes).description
    let hexadecimal =
        digest.hasPrefix("sha256:")
        ? String(digest.dropFirst("sha256:".count))
        : digest
    return String(hexadecimal.prefix(24))
}

func swiftTargetRuntimeBuildID(
    lock: SwiftTargetSDKLock,
    sourceID: String,
    runtimeBuilderContext: FilePath,
    runtimePreset: FilePath,
    sysrootPreparer: FilePath
) throws -> String {
    var encoder = CanonicalDigestEncoder()
    encoder.append(tag: 1, string: lock.snapshot)
    for package in lock.ubuntuPackages {
        encoder.append(tag: 2, string: package.url)
        encoder.append(tag: 3, string: package.sha256)
    }
    encoder.append(tag: 4, string: sourceID)
    encoder.append(
        tag: 5,
        bytes: try ArtifactHasher.digest(tree: runtimeBuilderContext).bytes)
    encoder.append(tag: 6, bytes: try ArtifactHasher.digest(file: runtimePreset).bytes)
    encoder.append(tag: 7, bytes: try ArtifactHasher.digest(file: sysrootPreparer).bytes)
    let digest = ArtifactHasher.digest(bytes: encoder.bytes).description
    let hexadecimal =
        digest.hasPrefix("sha256:")
        ? String(digest.dropFirst("sha256:".count))
        : digest
    return String(hexadecimal.prefix(24))
}

private struct ToolchainStatusRecord: Codable {
    let cacheRoot: String
    let artifactRoot: String
    let xcodeIdentity: String
    let activeGeneration: String?
    let activeGenerationPath: String?
    let hostSwiftExecutable: String?
    let hostSwiftVersion: String?
    let swiftSDKs: [String]
    let generations: [String]
}

struct ToolchainStatus {
    let context: WorkspaceContext

    func run(json: Bool) throws {
        let paths = SwiftTargetSDKStoragePaths(cacheRoot: context.cacheRoot)
        let activeLink = paths.artifactRoot.appendingPathComponent("current")
        let active = resolvedSymlink(activeLink)
        let hostSwift = active?.appendingPathComponent("toolchain/usr/bin/swift")
        let sdkRoot = active?.appendingPathComponent("swift-sdks")
        let sdkNames: [String] =
            try sdkRoot.map { root in
                guard FileManager.default.fileExists(atPath: root.path) else {
                    return [String]()
                }
                return try FileManager.default.contentsOfDirectory(atPath: root.path)
                    .filter { $0.hasSuffix(".artifactbundle") }
                    .sorted()
            } ?? []
        let generationsRoot = paths.artifactRoot.appendingPathComponent(
            "generations", isDirectory: true)
        let generations =
            try FileManager.default.fileExists(atPath: generationsRoot.path)
            ? FileManager.default.contentsOfDirectory(atPath: generationsRoot.path)
                .filter { !$0.hasPrefix(".candidate-") }
                .sorted()
            : []
        let executable =
            hostSwift.flatMap {
                FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil
            }
        let record = ToolchainStatusRecord(
            cacheRoot: paths.cacheRoot.path,
            artifactRoot: paths.artifactRoot.path,
            xcodeIdentity: try selectedXcodeIdentity(environment: context.environment),
            activeGeneration: active?.lastPathComponent,
            activeGenerationPath: active?.path,
            hostSwiftExecutable: executable?.path,
            hostSwiftVersion: executable.flatMap {
                try? commandOutput(
                    executable: $0,
                    arguments: ["--version"],
                    environment: context.environment)
            },
            swiftSDKs: sdkNames,
            generations: generations)
        if json {
            print(
                String(
                    decoding: try JSONEncoder.sorted.encode(record),
                    as: UTF8.self))
            return
        }
        print("cache root: \(record.cacheRoot)")
        print("artifact root: \(record.artifactRoot)")
        print("Xcode: \(record.xcodeIdentity)")
        print("active: \(record.activeGeneration ?? "none")")
        print("host Swift: \(record.hostSwiftExecutable ?? "missing")")
        if let version = record.hostSwiftVersion {
            print(version)
        }
        print(
            "Swift SDKs: \(record.swiftSDKs.isEmpty ? "none" : record.swiftSDKs.joined(separator: ", "))"
        )
        print("generations: \(record.generations.count)")
    }
}

struct ToolchainCommand {
    let context: WorkspaceContext

    func rebuild(_ options: RebuildOptions) async throws {
        #if !os(macOS)
        throw WorkspaceFailure.message(
            "Swift target SDK generation requires the macOS arm64 builder")
        #else
        #if !arch(arm64)
        throw WorkspaceFailure.message(
            "Swift target SDK generation requires native macOS arm64")
        #endif
        let recipeRoot = context.layout.swiftToolchain
        let lockFile = recipeRoot.appendingPathComponent("target-sdk.lock.json")
        let lock = try SwiftTargetSDKLock.load(from: FilePath(lockFile.path))
        let sourceID = try swiftSourceGraphIdentity(
            root: context.root,
            environment: context.environment)
        let generatorSource = recipeRoot.appendingPathComponent(
            "source/swift-sdk-generator", isDirectory: true)
        try validateGeneratorSource(
            generatorSource,
            expectedCommit: lock.swiftSDKGeneratorCommit,
            environment: context.environment)

        let android = try AndroidToolchainVersions.load(workspaceRoot: context.root)
        guard android.minimumSDK == lock.androidAPILevel else {
            throw WorkspaceFailure.message(
                "Android minSdk \(android.minimumSDK) does not match Swift SDK lock API "
                    + "\(lock.androidAPILevel)")
        }
        let ndkRoot = try android.ndkRoot(environment: context.environment)
        let paths = SwiftTargetSDKStoragePaths(cacheRoot: context.cacheRoot)
        let xcodeIdentity = try selectedXcodeIdentity(
            environment: context.environment)
        let xcodeSwift = try xcrunTool(
            "swift", environment: context.environment)
        let fixture = context.root.appendingPathComponent(
            "collider/engine/Sources/ColliderRuntime/Resources/"
                + "ToolchainValidationFixtures/AndroidSDKConsumer",
            isDirectory: true)
        let validator = recipeRoot.appendingPathComponent(
            "validate-target-sdk-artifacts.sh")
        let runtimeBuilderContext = recipeRoot.appendingPathComponent(
            "runtime-build-container", isDirectory: true)
        let runtimePreset = recipeRoot.appendingPathComponent(
            "nucleus-target-runtime-presets.ini")
        let sysrootPreparer = recipeRoot.appendingPathComponent(
            "prepare-linux-sysroot.sh")
        let sourceWorkspace = recipeRoot.appendingPathComponent(
            "source", isDirectory: true)
        guard
            FileManager.default.isExecutableFile(
                atPath: sourceWorkspace.appendingPathComponent(
                    "swift/utils/build-script"
                ).path)
        else {
            throw WorkspaceFailure.message(
                "the complete Swift source graph is not initialized")
        }
        let artifactID = try swiftTargetSDKArtifactID(
            lockFile: FilePath(lockFile.path),
            generatorSource: FilePath(generatorSource.path),
            validationFixture: FilePath(fixture.path),
            validator: FilePath(validator.path),
            ndkProperties: FilePath(
                ndkRoot.appendingPathComponent("source.properties").path),
            xcodeIdentity: xcodeIdentity,
            sourceID: sourceID,
            runtimeBuilderContext: FilePath(runtimeBuilderContext.path),
            runtimePreset: FilePath(runtimePreset.path),
            sysrootPreparer: FilePath(sysrootPreparer.path))
        let runtimeBuildID = try swiftTargetRuntimeBuildID(
            lock: lock,
            sourceID: sourceID,
            runtimeBuilderContext: FilePath(runtimeBuilderContext.path),
            runtimePreset: FilePath(runtimePreset.path),
            sysrootPreparer: FilePath(sysrootPreparer.path))
        let generation = paths.artifactRoot.appendingPathComponent(
            "generations/\(artifactID)", isDirectory: true)
        let active = paths.artifactRoot.appendingPathComponent("current")
        let discoveryRoot = homeDirectory.appendingPathComponent(
            ".swiftpm/swift-sdks", isDirectory: true)
        let runtimeRoot = paths.runtimeBuildRoot.appendingPathComponent(
            runtimeBuildID, isDirectory: true)

        if reusableGeneration(
            generation: generation,
            active: active,
            discoveryRoot: discoveryRoot,
            lock: lock,
            artifactID: artifactID)
        {
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
                    "clean  toolchain.target-sdks  immutable generation "
                        + "\(artifactID) is active and validated")
            } else if !options.controls.quiet {
                print("==> Swift target SDK generation is clean: \(generation.path)")
            }
            return
        }

        let runID = currentRunID
        let candidate = paths.artifactRoot.appendingPathComponent(
            "generations/.candidate-\(artifactID)-\(runID)",
            isDirectory: true)
        let configuration = SwiftTargetSDKGenerationConfiguration(
            lock: lock,
            lockFile: FilePath(lockFile.path),
            downloadRoot: FilePath(paths.downloadRoot.path),
            generatorSource: FilePath(generatorSource.path),
            generatorScratch: FilePath(paths.generatorScratch.path),
            sourceWorkspace: FilePath(sourceWorkspace.path),
            sourceID: sourceID,
            runtimeBuilderContext: FilePath(runtimeBuilderContext.path),
            runtimeBuilderImageID: FilePath(paths.runtimeBuilderImageID.path),
            runtimeBuildWorkspace: FilePath(
                runtimeRoot.appendingPathComponent("build", isDirectory: true).path),
            runtimeCompilerCache: FilePath(paths.runtimeCompilerCache.path),
            runtimeInstall: FilePath(
                runtimeRoot.appendingPathComponent("install", isDirectory: true).path),
            sysrootPreparer: FilePath(sysrootPreparer.path),
            linuxSysroot: FilePath(
                runtimeRoot.appendingPathComponent("sysroot", isDirectory: true).path),
            candidate: FilePath(candidate.path),
            generation: FilePath(generation.path),
            active: FilePath(active.path),
            ndkRoot: FilePath(ndkRoot.path),
            validationFixture: FilePath(fixture.path),
            validator: FilePath(validator.path),
            swiftExecutable: FilePath(xcodeSwift.path),
            sdkDiscoveryRoot: FilePath(discoveryRoot.path),
            displacedRoot: FilePath(
                paths.artifactRoot.appendingPathComponent(
                    "displaced/\(runID)", isDirectory: true
                ).path),
            environment: context.taskEnvironment)
        let taskSet = try SwiftTargetSDKColliderRecipe.generation(configuration)
        if !options.controls.json {
            print("==> Swift target SDK root: \(paths.artifactRoot.path)")
            print("==> Swift target runtime build root: \(runtimeRoot.path)")
            print("==> host compiler input: \(lock.snapshot)-osx.pkg")
            print("==> Linux target: x86_64-unknown-linux-gnu")
            print(
                "==> Android targets: aarch64 and x86_64, API "
                    + "\(lock.androidAPILevel)")
        }
        try await context.execute(
            tasks: taskSet.tasks,
            selected: taskSet.selected,
            controls: options.controls,
            workflowLocks: [.shared(FilePath(paths.rebuildLock.path))])
        guard !options.controls.dryRun, !options.controls.explain else { return }
        if !options.controls.json {
            print("==> active Swift target SDK generation: \(generation.path)")
        }
        #endif
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

    private var homeDirectory: URL {
        if let home = context.environment["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

private func reusableGeneration(
    generation: URL,
    active: URL,
    discoveryRoot: URL,
    lock: SwiftTargetSDKLock,
    artifactID: String
) -> Bool {
    let marker = generation.appendingPathComponent(
        ".nucleus-target-sdk-generation")
    guard
        (try? String(contentsOf: marker, encoding: .utf8))
            == lock.snapshot,
        FileManager.default.isExecutableFile(
            atPath: generation.appendingPathComponent(
                "toolchain/usr/bin/swift"
            ).path),
        resolvedSymlink(active)
            == generation.standardizedFileURL.resolvingSymlinksInPath()
    else {
        return false
    }
    for bundleID in [lock.linuxBundleID, lock.androidBundleID] {
        let name = "\(bundleID).artifactbundle"
        let bundle = generation.appendingPathComponent("swift-sdks/\(name)")
        let discovery = discoveryRoot.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: bundle.path),
            resolvedSymlink(discovery)
                == bundle.standardizedFileURL.resolvingSymlinksInPath()
        else {
            return false
        }
    }
    return generation.lastPathComponent == artifactID
}

private func validateGeneratorSource(
    _ source: URL,
    expectedCommit: String,
    environment: [String: String]
) throws {
    let commit = try commandOutput(
        executable: URL(fileURLWithPath: "/usr/bin/git"),
        arguments: ["-C", source.path, "rev-parse", "HEAD"],
        environment: environment)
    guard commit == expectedCommit else {
        throw WorkspaceFailure.message(
            "swift-sdk-generator is \(commit); lock requires \(expectedCommit)")
    }
}

private func swiftSourceGraphIdentity(
    root: URL,
    environment: [String: String]
) throws -> String {
    let prefix = "swift-toolchain/source/"
    let declarations = try commandOutput(
        executable: URL(fileURLWithPath: "/usr/bin/git"),
        arguments: [
            "-C", root.path,
            "config", "-f", ".gitmodules", "--get-regexp",
            #"^submodule\..*\.path$"#,
        ],
        environment: environment)
    let paths = declarations.split(separator: "\n").compactMap { line -> String? in
        guard let separator = line.firstIndex(where: { $0 == " " || $0 == "\t" })
        else { return nil }
        let path = line[line.index(after: separator)...]
            .trimmingCharacters(in: .whitespaces)
        return path.hasPrefix(prefix) ? path : nil
    }.sorted()
    guard !paths.isEmpty else {
        throw WorkspaceFailure.message("Swift source submodules are not declared")
    }

    var encoder = CanonicalDigestEncoder()
    for path in paths {
        let entry = try commandOutput(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", root.path, "ls-files", "--stage", "--", path],
            environment: environment)
        let fields = entry.split(
            maxSplits: 3,
            whereSeparator: {
                $0 == " " || $0 == "\t"
            })
        guard fields.count == 4, fields[0] == "160000", fields[1].count == 40 else {
            throw WorkspaceFailure.message(
                "Swift source path is not a pinned gitlink: \(path)")
        }
        let expectedCommit = String(fields[1])
        let repository = root.appendingPathComponent(path, isDirectory: true)
        let actualCommit = try commandOutput(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", repository.path, "rev-parse", "HEAD"],
            environment: environment)
        guard actualCommit == expectedCommit else {
            throw WorkspaceFailure.message(
                "Swift source gitlink mismatch at \(path): expected \(expectedCommit), found \(actualCommit)"
            )
        }
        let status = try commandOutput(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: [
                "-C", repository.path, "status", "--porcelain",
                "--untracked-files=all",
            ],
            environment: environment)
        guard status.isEmpty else {
            throw WorkspaceFailure.message(
                "Swift source repository has uncommitted changes: \(path)")
        }
        encoder.append(tag: 1, string: path)
        encoder.append(tag: 2, string: actualCommit)
    }
    let digest = ArtifactHasher.digest(bytes: encoder.bytes).description
    let hexadecimal =
        digest.hasPrefix("sha256:")
        ? String(digest.dropFirst("sha256:".count))
        : digest
    guard hexadecimal.count == 64 else {
        throw WorkspaceFailure.message(
            "invalid Swift source graph digest: \(digest)")
    }
    return String(hexadecimal.prefix(24))
}

private func selectedXcodeIdentity(
    environment: [String: String]
) throws -> String {
    try commandOutput(
        executable: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
        arguments: ["-version"],
        environment: environment
    )
    .replacing("\n", with: " ")
}

private func xcrunTool(
    _ name: String,
    environment: [String: String]
) throws -> URL {
    let output = try commandOutput(
        executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
        arguments: ["--find", name],
        environment: environment)
    let tool = URL(fileURLWithPath: output).standardizedFileURL
    guard FileManager.default.isExecutableFile(atPath: tool.path) else {
        throw WorkspaceFailure.message(
            "Xcode tool is not executable: \(tool.path)")
    }
    return tool
}

private func commandOutput(
    executable: URL,
    arguments: [String],
    environment: [String: String]
) throws -> String {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let text = String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0 else {
        throw WorkspaceFailure.message(
            "\(executable.lastPathComponent) failed: \(text)")
    }
    return text
}

private func resolvedSymlink(_ link: URL) -> URL? {
    guard
        let target = try? FileManager.default.destinationOfSymbolicLink(
            atPath: link.path)
    else {
        return nil
    }
    return URL(
        fileURLWithPath: target,
        relativeTo: link.deletingLastPathComponent()
    ).standardizedFileURL.resolvingSymlinksInPath()
}
