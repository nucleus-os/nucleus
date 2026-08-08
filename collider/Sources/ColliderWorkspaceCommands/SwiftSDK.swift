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

    func run() async throws {
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
        let hostSwiftVersion: String?
        if let executable {
            hostSwiftVersion = try? await commandOutput(
                executable: executable,
                arguments: ["--version"],
                context: context)
        } else {
            hostSwiftVersion = nil
        }
        let record = SwiftSDKStatusRecord(
            cacheRoot: paths.cacheRoot.string,
            artifactRoot: paths.artifactRoot.string,
            xcodeIdentity: try await selectedXcodeIdentity(context: context),
            activeGeneration: active?.lastComponent?.string,
            activeGenerationPath: active?.string,
            hostSwiftExecutable: executable?.string,
            hostSwiftVersion: hostSwiftVersion,
            swiftSDKs: sdkNames,
            generations: generations)
        var lines = [
            "cache root: \(CommandConsole.render(path: record.cacheRoot))",
            "artifact root: \(CommandConsole.render(path: record.artifactRoot))",
            "Xcode: \(record.xcodeIdentity)",
            "active: \(record.activeGeneration ?? "none")",
            "host Swift: \(record.hostSwiftExecutable.map(CommandConsole.render(path:)) ?? "missing")",
        ]
        if let version = record.hostSwiftVersion {
            lines.append(version)
        }
        lines.append(
            "Swift SDKs: \(record.swiftSDKs.isEmpty ? "none" : record.swiftSDKs.joined(separator: ", "))"
        )
        lines.append("generations: \(record.generations.count)")
        try context.console.report(record, text: lines.joined(separator: "\n"))
    }
}

private func selectedXcodeIdentity(
    context: WorkspaceContext
) async throws -> String {
    try await commandOutput(
        executable: FilePath("/usr/bin/xcodebuild"),
        arguments: ["-version"],
        context: context
    ).replacing("\n", with: " ")
}

private func commandOutput(
    executable: FilePath,
    arguments: [String],
    context: WorkspaceContext
) async throws -> String {
    let result = try await context.runtime.execute(
        CommandSpec(
            executable: .path(executable),
            arguments: arguments,
            workingDirectory: context.root,
            environment: context.environment,
            output: .combined(limit: 64 * 1_024)))
    let text = result.standardOutput
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard result.succeeded else {
        throw result.executionFailure(
            reason: "\(executable.lastComponent?.string ?? executable.string) failed: \(text)")
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
