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
    inputsFile: FilePath,
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
    for package in target.ubuntuPackages {
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
        let record = SwiftSDKStatusRecord(
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
        let recipeRoot = context.layout.swiftToolchain
        let inputsFile = recipeRoot.appendingPathComponent("target-sdk-inputs.json")
        let inputs = try SwiftTargetSDKInputs.load(from: FilePath(inputsFile.path))
        let sourceID = try swiftTargetRuntimeSourceIdentity(
            root: context.root,
            environment: context.environment)
        let generatorSource = recipeRoot.appendingPathComponent(
            "source/swift-sdk-generator", isDirectory: true)

        let android = try AndroidToolchainVersions.load(workspaceRoot: context.root)
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
                "the Swift target-runtime source closure is not initialized")
        }
        let artifactID = try swiftTargetSDKArtifactID(
            inputsFile: FilePath(inputsFile.path),
            validationFixture: FilePath(fixture.path),
            validator: FilePath(validator.path),
            ndkProperties: FilePath(
                ndkRoot.appendingPathComponent("source.properties").path),
            xcodeIdentity: xcodeIdentity,
            sourceID: sourceID,
            runtimeBuilderContext: FilePath(runtimeBuilderContext.path),
            runtimePreset: FilePath(runtimePreset.path),
            sysrootPreparer: FilePath(sysrootPreparer.path))
        let linuxTargets = try inputs.linuxTargets.map { target in
            let buildID = try swiftTargetRuntimeBuildID(
                inputs: inputs,
                target: target,
                sourceID: sourceID,
                runtimeBuilderContext: FilePath(runtimeBuilderContext.path),
                runtimePreset: FilePath(runtimePreset.path),
                sysrootPreparer: FilePath(sysrootPreparer.path))
            let root = paths.runtimeBuildRoot.appendingPathComponent(
                "\(target.architecture.rawValue)/\(buildID)",
                isDirectory: true)
            return SwiftLinuxTargetBuildConfiguration(
                target: target,
                runtimeBuildWorkspace: FilePath(
                    root.appendingPathComponent("build", isDirectory: true).path),
                runtimeCompilerCache: FilePath(
                    paths.runtimeCompilerCache.appendingPathComponent(
                        target.architecture.rawValue,
                        isDirectory: true
                    ).path),
                runtimeInstall: FilePath(
                    root.appendingPathComponent("install", isDirectory: true).path),
                sysroot: FilePath(
                    root.appendingPathComponent("sysroot", isDirectory: true).path))
        }
        let generation = paths.artifactRoot.appendingPathComponent(
            "generations/\(artifactID)", isDirectory: true)
        let active = paths.artifactRoot.appendingPathComponent("current")
        let discoveryRoot = homeDirectory.appendingPathComponent(
            ".swiftpm/swift-sdks", isDirectory: true)
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
                    "generation": generation.path,
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
                print("==> Swift target SDK generation is clean: \(generation.path)")
            }
            return
        }

        let runID = currentRunID
        let candidate = paths.artifactRoot.appendingPathComponent(
            "generations/.candidate-\(artifactID)-\(runID)",
            isDirectory: true)
        let configuration = SwiftTargetSDKGenerationConfiguration(
            inputs: inputs,
            inputsFile: FilePath(inputsFile.path),
            androidAPILevel: android.minimumSDK,
            downloadRoot: FilePath(paths.downloadRoot.path),
            generatorSource: FilePath(generatorSource.path),
            generatorScratch: FilePath(paths.generatorScratch.path),
            sourceWorkspace: FilePath(sourceWorkspace.path),
            sourceID: sourceID,
            runtimeBuilderContext: FilePath(runtimeBuilderContext.path),
            runtimeBuilderImageID: FilePath(paths.runtimeBuilderImageID.path),
            linuxTargets: linuxTargets,
            sysrootPreparer: FilePath(sysrootPreparer.path),
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
    inputs: SwiftTargetSDKInputs,
    artifactID: String
) -> Bool {
    let marker = generation.appendingPathComponent(
        ".nucleus-target-sdk-generation")
    guard
        (try? String(contentsOf: marker, encoding: .utf8))
            == inputs.snapshot,
        FileManager.default.isExecutableFile(
            atPath: generation.appendingPathComponent(
                "toolchain/usr/bin/swift"
            ).path),
        resolvedSymlink(active)
            == generation.standardizedFileURL.resolvingSymlinksInPath()
    else {
        return false
    }
    for bundleID in [inputs.linuxBundleID, inputs.androidBundleID] {
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

private func swiftTargetRuntimeSourceIdentity(
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
        throw WorkspaceFailure.message(
            "Swift target-runtime source graph has no pinned repositories")
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
