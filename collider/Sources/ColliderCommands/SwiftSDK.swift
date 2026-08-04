import ArgumentParser
import ColliderCore
import ColliderRuntime
import CoreColliderRecipe
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
    let cacheRoot: FilePath
    let artifactRoot: FilePath
    let downloadRoot: FilePath
    let generatorScratch: FilePath
    let runtimeBuilderImageID: FilePath
    let runtimeCompilerCache: FilePath
    let runtimeBuildRoot: FilePath
    let rebuildLock: FilePath

    init(cacheRoot: FilePath) {
        self.cacheRoot = cacheRoot
        artifactRoot = cacheRoot.appending("nucleus/swift-target-sdks")
        downloadRoot = cacheRoot.appending("nucleus/downloads/swift-target-sdks")
        generatorScratch = cacheRoot.appending("nucleus/build/swift-sdk-generator")
        runtimeBuilderImageID = cacheRoot.appending(
            "nucleus/build-containers/swift-runtime/image-id")
        runtimeCompilerCache = cacheRoot.appending("nucleus/ccache/swift-runtime")
        runtimeBuildRoot = cacheRoot.appending("nucleus/build/swift-target-runtime")
        rebuildLock = artifactRoot.appending("rebuild.lock")
    }
}

func swiftTargetSDKArtifactID(
    inputsFile: FilePath,
    validationFixture: FilePath,
    validator: FilePath,
    ndkProperties: FilePath,
    xcodeIdentity: String,
    sourceID: String,
    runtimeBuilderContext: FilePath,
    runtimePreset: FilePath,
    sysrootPreparer: FilePath,
    generatorSourceID: String
) throws -> String {
    var encoder = CanonicalDigestEncoder()
    encoder.append(tag: 1, bytes: try ArtifactHasher.digest(file: inputsFile).bytes)
    encoder.append(
        tag: 2,
        bytes: try ArtifactHasher.digest(tree: validationFixture).bytes)
    encoder.append(tag: 3, bytes: try ArtifactHasher.digest(file: validator).bytes)
    encoder.append(
        tag: 4,
        bytes: try ArtifactHasher.digest(file: ndkProperties).bytes)
    encoder.append(tag: 5, string: xcodeIdentity)
    encoder.append(tag: 6, string: sourceID)
    encoder.append(
        tag: 7,
        bytes: try ArtifactHasher.digest(tree: runtimeBuilderContext).bytes)
    encoder.append(tag: 8, bytes: try ArtifactHasher.digest(file: runtimePreset).bytes)
    encoder.append(tag: 9, bytes: try ArtifactHasher.digest(file: sysrootPreparer).bytes)
    encoder.append(tag: 10, string: generatorSourceID)
    let digest = ArtifactHasher.digest(bytes: encoder.bytes).description
    let hexadecimal =
        digest.hasPrefix("sha256:")
        ? String(digest.dropFirst("sha256:".count))
        : digest
    return String(hexadecimal.prefix(24))
}

func swiftTargetRuntimeBuildID(
    inputs: SwiftTargetSDKInputs,
    target: SwiftTargetSDKInputs.LinuxTarget,
    sourceID: String,
    runtimeBuilderContext: FilePath,
    runtimePreset: FilePath,
    sysrootPreparer: FilePath
) throws -> String {
    var encoder = CanonicalDigestEncoder()
    encoder.append(tag: 1, string: inputs.snapshot)
    encoder.append(tag: 2, string: target.architecture.rawValue)
    for package in target.runtimeUbuntuPackages {
        encoder.append(tag: 3, string: package.url)
        encoder.append(tag: 4, string: package.sha256)
    }
    encoder.append(tag: 5, string: sourceID)
    encoder.append(
        tag: 6,
        bytes: try ArtifactHasher.digest(tree: runtimeBuilderContext).bytes)
    encoder.append(tag: 7, bytes: try ArtifactHasher.digest(file: runtimePreset).bytes)
    encoder.append(tag: 8, bytes: try ArtifactHasher.digest(file: sysrootPreparer).bytes)
    let digest = ArtifactHasher.digest(bytes: encoder.bytes).description
    let hexadecimal =
        digest.hasPrefix("sha256:")
        ? String(digest.dropFirst("sha256:".count))
        : digest
    return String(hexadecimal.prefix(24))
}

func swiftTargetSDKTaskEnvironment(
    _ environment: [String: String],
    runtimeSourceID: String
) -> [String: String] {
    var environment = environment
    environment["NUCLEUS_SWIFT_SOURCE_ID"] = runtimeSourceID
    return environment
}

private struct SwiftSDKStatusRecord: Codable {
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

struct SwiftSDKStatus {
    let context: WorkspaceContext

    func run(json: Bool) throws {
        let paths = SwiftTargetSDKStoragePaths(cacheRoot: context.cacheRoot)
        let activeLink = paths.artifactRoot.appending("current")
        let active = resolvedSymlink(activeLink)
        let hostSwift = active?.appending("toolchain/usr/bin/swift")
        let sdkRoot = active?.appending("swift-sdks")
        let sdkNames: [String] =
            try sdkRoot.map { root in
                guard FileManager.default.fileExists(atPath: root.string) else {
                    return [String]()
                }
                return try FileManager.default.contentsOfDirectory(atPath: root.string)
                    .filter { $0.hasSuffix(".artifactbundle") }
                    .sorted()
            } ?? []
        let generationsRoot = paths.artifactRoot.appending("generations")
        let generations =
            try FileManager.default.fileExists(atPath: generationsRoot.string)
            ? FileManager.default.contentsOfDirectory(atPath: generationsRoot.string)
                .filter { !$0.hasPrefix(".candidate-") }
                .sorted()
            : []
        let executable =
            hostSwift.flatMap {
                FileManager.default.isExecutableFile(atPath: $0.string) ? $0 : nil
            }
        let record = SwiftSDKStatusRecord(
            cacheRoot: paths.cacheRoot.string,
            artifactRoot: paths.artifactRoot.string,
            xcodeIdentity: try selectedXcodeIdentity(environment: context.environment),
            activeGeneration: active?.lastComponent?.string,
            activeGenerationPath: active?.string,
            hostSwiftExecutable: executable?.string,
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

struct SwiftSDKCommand {
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
        let recipeRoot = context.layout.swiftSDK
        let inputsFile = recipeRoot.appending("target-sdk-inputs.json")
        let inputs = try SwiftTargetSDKInputs.load(from: inputsFile)
        let sourceID = try swiftTargetRuntimeSourceIdentity(
            root: context.root,
            environment: context.environment)
        let generatorSourceID = try validatedSwiftGitlinkCommit(
            root: context.root,
            path: "swift-sdk/source/swift-sdk-generator",
            environment: context.environment)
        let generatorSource = recipeRoot.appending("source/swift-sdk-generator")

        let android = try AndroidToolchainVersions.load(workspaceRoot: context.root)
        let ndkRoot = try android.ndkRoot(environment: context.environment)
        let paths = SwiftTargetSDKStoragePaths(cacheRoot: context.cacheRoot)
        let xcodeIdentity = try selectedXcodeIdentity(
            environment: context.environment)
        let xcodeSwift = try xcrunTool(
            "swift", environment: context.environment)
        let fixture = context.root.appending(
            "collider/engine/Sources/ColliderRuntime/Resources/"
                + "ToolchainValidationFixtures/AndroidSDKConsumer")
        let validator = recipeRoot.appending(
            "validate-target-sdk-artifacts.sh")
        let runtimeBuilderContext = recipeRoot.appending("runtime-build-container")
        let runtimePreset = recipeRoot.appending(
            "nucleus-target-runtime-presets.ini")
        let sysrootPreparer = recipeRoot.appending(
            "prepare-linux-sysroot.sh")
        let sourceWorkspace = recipeRoot.appending("source")
        guard
            FileManager.default.isExecutableFile(
                atPath: sourceWorkspace.appending("swift/utils/build-script").string)
        else {
            throw WorkspaceFailure.message(
                "the Swift target-runtime source closure is not initialized")
        }
        let artifactID = try swiftTargetSDKArtifactID(
            inputsFile: inputsFile,
            validationFixture: fixture,
            validator: validator,
            ndkProperties: ndkRoot.appending("source.properties"),
            xcodeIdentity: xcodeIdentity,
            sourceID: sourceID,
            runtimeBuilderContext: runtimeBuilderContext,
            runtimePreset: runtimePreset,
            sysrootPreparer: sysrootPreparer,
            generatorSourceID: generatorSourceID)
        let linuxTargets = try inputs.linuxTargets.map { target in
            let buildID = try swiftTargetRuntimeBuildID(
                inputs: inputs,
                target: target,
                sourceID: sourceID,
                runtimeBuilderContext: runtimeBuilderContext,
                runtimePreset: runtimePreset,
                sysrootPreparer: sysrootPreparer)
            let root = paths.runtimeBuildRoot.appending(
                "\(target.architecture.rawValue)/\(buildID)")
            return SwiftLinuxTargetBuildConfiguration(
                target: target,
                runtimeBuildWorkspace: root.appending("build"),
                runtimeCompilerCache: paths.runtimeCompilerCache.appending(
                    target.architecture.rawValue),
                runtimeInstall: root.appending("install"),
                sysroot: root.appending("sysroot"))
        }
        let generation = paths.artifactRoot.appending("generations/\(artifactID)")
        let active = paths.artifactRoot.appending("current")
        let discoveryRoot = homeDirectory.appending(".swiftpm/swift-sdks")
        if reusableGeneration(
            generation: generation,
            active: active,
            discoveryRoot: discoveryRoot,
            inputs: inputs,
            artifactID: artifactID)
        {
            if options.controls.json {
                let result = [
                    "artifactID": artifactID,
                    "generation": generation.string,
                    "status": "clean",
                ]
                print(
                    String(
                        decoding: try JSONEncoder.sorted.encode(result),
                        as: UTF8.self))
            } else if options.controls.dryRun || options.controls.explain {
                print(
                    "clean  swift-sdk.target-sdks  immutable generation "
                        + "\(artifactID) is active and validated")
            } else if !options.controls.quiet {
                print("==> Swift target SDK generation is clean: \(generation.string)")
            }
            return
        }

        let runID = currentRunID
        let candidate = paths.artifactRoot.appending(
            "generations/.candidate-\(artifactID)-\(runID)")
        let taskEnvironment = swiftTargetSDKTaskEnvironment(
            context.taskEnvironment,
            runtimeSourceID: sourceID)
        let configuration = SwiftTargetSDKGenerationConfiguration(
            inputs: inputs,
            inputsFile: inputsFile,
            androidAPILevel: android.minimumSDK,
            downloadRoot: paths.downloadRoot,
            generatorSource: generatorSource,
            generatorScratch: paths.generatorScratch,
            sourceWorkspace: sourceWorkspace,
            sourceID: sourceID,
            runtimeBuilderContext: runtimeBuilderContext,
            runtimeBuilderImageID: paths.runtimeBuilderImageID,
            linuxTargets: linuxTargets,
            sysrootPreparer: sysrootPreparer,
            candidate: candidate,
            generation: generation,
            active: active,
            ndkRoot: ndkRoot,
            validationFixture: fixture,
            validator: validator,
            swiftExecutable: xcodeSwift,
            sdkDiscoveryRoot: discoveryRoot,
            displacedRoot: paths.artifactRoot.appending("displaced/\(runID)"),
            environment: taskEnvironment)
        let taskSet = try SwiftTargetSDKColliderRecipe.generation(configuration)
        if !options.controls.json {
            print("==> Swift target SDK root: \(paths.artifactRoot.string)")
            for target in linuxTargets {
                print(
                    "==> \(target.target.architecture.rawValue) Linux runtime: "
                        + target.runtimeInstall.removingLastComponent().string)
            }
            print("==> host compiler input: \(inputs.snapshot)-osx.pkg")
            print("==> Linux targets: aarch64 and x86_64")
            print(
                "==> Android targets: aarch64 and x86_64, API "
                    + "\(android.minimumSDK)")
        }
        try await context.execute(
            tasks: taskSet.tasks,
            selected: taskSet.selected,
            controls: options.controls,
            workflowLocks: [.shared(paths.rebuildLock)])
        guard !options.controls.dryRun, !options.controls.explain else { return }
        if !options.controls.json {
            print("==> active Swift target SDK generation: \(generation.string)")
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

    private var homeDirectory: FilePath {
        if let home = context.environment["HOME"], !home.isEmpty {
            return FilePath(home)
        }
        return FilePath(FileManager.default.homeDirectoryForCurrentUser)
    }
}

private func reusableGeneration(
    generation: FilePath,
    active: FilePath,
    discoveryRoot: FilePath,
    inputs: SwiftTargetSDKInputs,
    artifactID: String
) -> Bool {
    let marker = URL(
        fileURLWithPath: generation.appending(
            ".nucleus-target-sdk-generation"
        ).string)
    guard
        (try? String(contentsOf: marker, encoding: .utf8))
            == inputs.snapshot,
        FileManager.default.isExecutableFile(
            atPath: generation.appending("toolchain/usr/bin/swift").string),
        resolvedSymlink(active)
            == resolvedPath(generation)
    else {
        return false
    }
    for bundleID in [inputs.linuxBundleID, inputs.androidBundleID] {
        let name = "\(bundleID).artifactbundle"
        let bundle = generation.appending("swift-sdks/\(name)")
        let discovery = discoveryRoot.appending(name)
        guard FileManager.default.fileExists(atPath: bundle.string),
            resolvedSymlink(discovery)
                == resolvedPath(bundle)
        else {
            return false
        }
    }
    return generation.lastComponent?.string == artifactID
}

private func swiftTargetRuntimeSourceIdentity(
    root: FilePath,
    environment: [String: String]
) throws -> String {
    let prefix = "swift-sdk/source/"
    let declarations = try commandOutput(
        executable: FilePath("/usr/bin/git"),
        arguments: [
            "-C", root.string,
            "config", "-f", ".gitmodules", "--get-regexp",
            #"^submodule\..*\.path$"#,
        ],
        environment: environment)
    let paths = declarations.split(separator: "\n").compactMap { line -> String? in
        guard let separator = line.firstIndex(where: { $0 == " " || $0 == "\t" })
        else { return nil }
        let path = line[line.index(after: separator)...]
            .trimmingCharacters(in: .whitespaces)
        return path.hasPrefix(prefix)
            && path != "swift-sdk/source/swift-sdk-generator"
            ? path : nil
    }.sorted()
    guard !paths.isEmpty else {
        throw WorkspaceFailure.message(
            "Swift target-runtime source graph has no pinned repositories")
    }

    var encoder = CanonicalDigestEncoder()
    for path in paths {
        let expectedCommit = try validatedSwiftGitlinkCommit(
            root: root,
            path: path,
            environment: environment)
        encoder.append(tag: 1, string: String(path.dropFirst(prefix.count)))
        encoder.append(tag: 2, string: expectedCommit)
    }
    let digest = ArtifactHasher.digest(bytes: encoder.bytes).description
    let hexadecimal =
        digest.hasPrefix("sha256:")
        ? String(digest.dropFirst("sha256:".count))
        : digest
    guard hexadecimal.count == 64 else {
        throw WorkspaceFailure.message(
            "invalid Swift target-runtime source digest: \(digest)")
    }
    return String(hexadecimal.prefix(24))
}

private func validatedSwiftGitlinkCommit(
    root: FilePath,
    path: String,
    environment: [String: String]
) throws -> String {
    let entry = try commandOutput(
        executable: FilePath("/usr/bin/git"),
        arguments: ["-C", root.string, "ls-files", "--stage", "--", path],
        environment: environment)
    let fields = entry.split(
        maxSplits: 3,
        whereSeparator: { $0 == " " || $0 == "\t" })
    guard fields.count == 4, fields[0] == "160000", fields[1].count == 40 else {
        throw WorkspaceFailure.message(
            "Swift source path is not a pinned gitlink: \(path)")
    }
    let expectedCommit = String(fields[1])
    let repository = root.appending(path)
    let actualCommit = try commandOutput(
        executable: FilePath("/usr/bin/git"),
        arguments: ["-C", repository.string, "rev-parse", "HEAD"],
        environment: environment)
    guard actualCommit == expectedCommit else {
        throw WorkspaceFailure.message(
            "Swift source gitlink mismatch at \(path): expected \(expectedCommit), found \(actualCommit)"
        )
    }
    let status = try commandOutput(
        executable: FilePath("/usr/bin/git"),
        arguments: [
            "-C", repository.string, "status", "--porcelain",
            "--untracked-files=all",
        ],
        environment: environment)
    guard status.isEmpty else {
        throw WorkspaceFailure.message(
            "Swift source repository has uncommitted changes: \(path)")
    }
    return expectedCommit
}

private func selectedXcodeIdentity(
    environment: [String: String]
) throws -> String {
    try commandOutput(
        executable: FilePath("/usr/bin/xcodebuild"),
        arguments: ["-version"],
        environment: environment
    )
    .replacing("\n", with: " ")
}

private func xcrunTool(
    _ name: String,
    environment: [String: String]
) throws -> FilePath {
    let output = try commandOutput(
        executable: FilePath("/usr/bin/xcrun"),
        arguments: ["--find", name],
        environment: environment)
    let tool = URL(fileURLWithPath: output).standardizedFileURL
    guard FileManager.default.isExecutableFile(atPath: tool.path) else {
        throw WorkspaceFailure.message(
            "Xcode tool is not executable: \(tool.path)")
    }
    return FilePath(tool)
}

private func commandOutput(
    executable: FilePath,
    arguments: [String],
    environment: [String: String]
) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable.string)
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
            "\(executable.lastComponent?.string ?? executable.string) failed: \(text)")
    }
    return text
}

private func resolvedSymlink(_ link: FilePath) -> FilePath? {
    guard
        let target = try? FileManager.default.destinationOfSymbolicLink(
            atPath: link.string)
    else {
        return nil
    }
    return FilePath(
        URL(
            fileURLWithPath: target,
            relativeTo: URL(
                fileURLWithPath: link.removingLastComponent().string,
                isDirectory: true)
        ).standardizedFileURL.resolvingSymlinksInPath().path)
}

private func resolvedPath(_ path: FilePath) -> FilePath {
    FilePath(URL(fileURLWithPath: path.string).resolvingSymlinksInPath())
}
