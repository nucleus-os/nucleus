import ArgumentParser
import ColliderCore
import ColliderPersistence
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

func swiftTargetSDKArtifactID(
    inputsFile: FilePath,
    validationFixture: FilePath,
    validator: FilePath,
    ndkIdentity: String,
    xcodeIdentity: String,
    sourceID: String,
    runtimeBuilderContext: FilePath,
    runtimePreset: FilePath,
    sysrootPreparer: FilePath,
    pkgConfigDirectory: FilePath,
    generatorSourceID: String
) throws -> String {
    var encoder = CanonicalDigestEncoder()
    encoder.append(tag: 1, bytes: try ArtifactHasher.digest(file: inputsFile).bytes)
    encoder.append(
        tag: 2,
        bytes: try ArtifactHasher.digest(tree: validationFixture).bytes)
    encoder.append(tag: 3, bytes: try ArtifactHasher.digest(file: validator).bytes)
    encoder.append(tag: 4, string: ndkIdentity)
    encoder.append(tag: 5, string: xcodeIdentity)
    encoder.append(tag: 6, string: sourceID)
    encoder.append(
        tag: 7,
        bytes: try ArtifactHasher.digest(tree: runtimeBuilderContext).bytes)
    encoder.append(tag: 8, bytes: try ArtifactHasher.digest(file: runtimePreset).bytes)
    encoder.append(tag: 9, bytes: try ArtifactHasher.digest(file: sysrootPreparer).bytes)
    encoder.append(tag: 10, bytes: try ArtifactHasher.digest(tree: pkgConfigDirectory).bytes)
    encoder.append(tag: 11, string: generatorSourceID)
    return shortenedDigest(ArtifactHasher.digest(bytes: encoder.bytes))
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
    return shortenedDigest(ArtifactHasher.digest(bytes: encoder.bytes))
}

func shortenedDigest(_ digest: ArtifactDigest) -> String {
    let description = digest.description
    let hexadecimal =
        description.hasPrefix("sha256:")
        ? String(description.dropFirst("sha256:".count))
        : description
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
        let registry = ComponentRegistry(context: context)
        let catalog = try registry.componentCatalog(
            forceSwiftSDKGeneration: true)
        try await context.execute(
            catalog: catalog,
            requests: [
                ComponentEntrypointRequest(
                    entrypoint: .build,
                    selection: SwiftTargetSDKColliderRecipe.descriptor.canonicalName)
            ],
            controls: options.controls)
        #endif
    }
}

private func selectedXcodeIdentity(
    environment: [String: String]
) throws -> String {
    try commandOutput(
        executable: FilePath("/usr/bin/xcodebuild"),
        arguments: ["-version"],
        environment: environment
    ).replacing("\n", with: " ")
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
