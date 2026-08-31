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
    pkgConfigDirectory: FilePath,
    generatorSourceID: String
) throws -> String {
    var encoder = IdentityEncoder()
    encoder.append(bytes: try ArtifactHasher.digest(file: inputsFile).bytes)
    encoder.append(bytes: try ArtifactHasher.digest(tree: validationFixture).bytes)
    encoder.append(bytes: try ArtifactHasher.digest(file: validator).bytes)
    encoder.append(ndkIdentity)
    encoder.append(xcodeIdentity)
    encoder.append(sourceID)
    encoder.append(bytes: try ArtifactHasher.digest(tree: runtimeBuilderContext).bytes)
    encoder.append(bytes: try ArtifactHasher.digest(file: runtimePreset).bytes)
    encoder.append(bytes: try ArtifactHasher.digest(tree: pkgConfigDirectory).bytes)
    encoder.append(generatorSourceID)
    return shortenedDigest(ArtifactHasher.digest(bytes: encoder.bytes))
}

/// Names what determines the native half of the target sysroot.
///
/// Every C and C++ consumer of the Swift SDK reads the sysroot and nothing else
/// from it: the compiler and linker resolve inside the builder image, and the
/// bundle supplies `--sysroot`, the libc++ include root, and the libc++ library
/// directory. `usr/lib/swift` and `usr/lib/swift_static` share that directory
/// with the native content but are read by no such build.
///
/// So this digest covers the Ubuntu packages every target unpacks, the
/// first-party pkg-config files staged beside them, and the generator revision
/// that lays the bundle out. It deliberately omits what determines only the
/// Swift half -- the snapshot, the source closure, the host Xcode, the runtime
/// builder context and preset -- and the validation inputs, which determine
/// neither half. A change to any of those leaves the native sysroot identical,
/// which is the claim `docs/task-identity-precision-plan.md` requires a snapshot
/// rebase to verify by diffing the two generations with the Swift directories
/// excluded.
func swiftTargetSDKNativeSysrootID(
    inputs: SwiftTargetSDKInputs,
    pkgConfigDirectory: FilePath,
    generatorSourceID: String
) throws -> String {
    var encoder = IdentityEncoder()
    for target in inputs.linuxTargets.sorted(by: {
        $0.architecture.rawValue < $1.architecture.rawValue
    }) {
        encoder.append(target.architecture.rawValue)
        for package in target.allUbuntuPackages {
            // The resolved URL rather than the pool path, so an identity still
            // moves when the snapshot the packages are fetched from moves.
            encoder.append(inputs.url(for: package))
            encoder.append(package.sha256)
        }
    }
    encoder.append(bytes: try ArtifactHasher.digest(tree: pkgConfigDirectory).bytes)
    encoder.append(generatorSourceID)
    return shortenedDigest(ArtifactHasher.digest(bytes: encoder.bytes))
}

func swiftTargetRuntimeBuildID(
    inputs: SwiftTargetSDKInputs,
    target: SwiftTargetSDKInputs.LinuxTarget,
    sourceID: String,
    runtimeBuilderContext: FilePath,
    runtimePreset: FilePath,
) throws -> String {
    var encoder = IdentityEncoder()
    encoder.append(inputs.snapshot)
    encoder.append(target.architecture.rawValue)
    for package in target.runtimeUbuntuPackages {
        encoder.append(inputs.url(for: package))
        encoder.append(package.sha256)
    }
    encoder.append(sourceID)
    encoder.append(bytes: try ArtifactHasher.digest(tree: runtimeBuilderContext).bytes)
    encoder.append(bytes: try ArtifactHasher.digest(file: runtimePreset).bytes)
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
        let paths = SwiftTargetSDKStoragePaths(
            cacheRoot: context.cacheRoot,
            hostBuildRoot: context.hostBuildRoot)
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
