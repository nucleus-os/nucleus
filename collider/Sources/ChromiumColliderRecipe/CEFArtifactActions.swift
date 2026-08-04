import ColliderCore
import Foundation
import SystemPackage

package struct AssembleCEFArtifactAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        let assembly: CEFArtifactAssembly

        package func encode(into encoder: inout ActionIdentityEncoder) {
            encodeCEFArtifactIdentity(assembly, into: &encoder)
        }
    }

    package static let kind: ActionKind = "browser.assemble-cef"

    let assembly: CEFArtifactAssembly

    package init(assembly: CEFArtifactAssembly) {
        self.assembly = assembly
    }

    package var identity: Identity { Identity(assembly: assembly) }
    package var environment: [String: String] { assembly.environment }
    package var requirements: ActionRequirements {
        cefArtifactRequirements(assembly, publicationAccess: .readWrite)
    }

    package func execute(in context: ActionContext) async throws {
        let builtManifest = assembly.buildOutput.appending(
            ".nucleus-built-build.json")
        let buildID = try chromiumBuildID(
            manifest: builtManifest,
            files: context.files)
        let commandEnvironment = cefEnvironment(assembly)
        try context.files.createDirectory(assembly.distributionRoot)
        let distributionCandidate = assembly.distributionRoot.appending(
            ".\(buildID).distribution")
        try context.files.remove(distributionCandidate)
        try context.files.createDirectory(distributionCandidate)
        defer { try? context.files.remove(distributionCandidate) }

        try await requireCEFSuccess(
            .named("python3"),
            [
                "cef/tools/make_distrib.py",
                "--output-dir=\(distributionCandidate)",
                "--allow-partial",
                "--ninja-build",
                "--release-build-dir=\(assembly.buildOutput)",
                "--x64-build",
                "--minimal",
                "--no-archive",
            ],
            directory: assembly.chromiumSource,
            environment: commandEnvironment,
            context: context)
        let checkout = String(assembly.cefCheckout.prefix(7))
        let suffix =
            "+g\(checkout)+chromium-\(assembly.chromiumVersion)"
            + "_linux64_minimal"
        let matches = try context.files.listRecursively(distributionCandidate)
            .filter {
                !$0.relativePath.contains("/")
                    && $0.metadata.type == .directory
                    && $0.relativePath.hasPrefix("cef_binary_")
                    && $0.relativePath.hasSuffix(suffix)
            }
        guard matches.count == 1, let produced = matches.first else {
            throw CEFArtifactActionFailure.invalidOutput(
                "expected one current CEF minimal distribution; found "
                    + "\(matches.count)")
        }

        let releases = assembly.distributionRoot.appending("releases")
        try context.files.createDirectory(releases)
        let candidate = releases.appending(".\(buildID).prepared")
        try context.files.remove(candidate)
        try context.files.createDirectory(candidate)
        var succeeded = false
        defer {
            if !succeeded { try? context.files.remove(candidate) }
        }
        let sdk = candidate.appending("sdk")
        let artifacts = candidate.appending("artifacts")
        try context.files.copyTree(from: produced.path, to: sdk)
        try context.files.createDirectory(artifacts)
        try context.files.copy(
            from: builtManifest,
            to: sdk.appending("nucleus-build-manifest.json"))
        for relative in [
            "Release/libvk_swiftshader.so",
            "Release/vk_swiftshader_icd.json",
        ] {
            try context.files.remove(sdk.appending(relative))
        }
        let resources = sdk.appending("Resources")
        if try context.files.metadata(for: resources)?.type == .directory {
            let names = try context.files.listRecursively(resources)
                .filter { !$0.relativePath.contains("/") }
                .map(\.relativePath)
            for name in names {
                try context.files.replaceSymlink(
                    at: sdk.appending("Release/\(name)"),
                    target: "../Resources/\(name)")
            }
        }
        try await validateCEFSDK(
            sdk,
            environment: commandEnvironment,
            smoke: candidate.appending(".consumer-smoke"),
            context: context)
        try await requireCEFSuccess(
            .named("python3"),
            ["tools/version_manager.py", "-c"],
            directory: assembly.chromiumSource.appending("cef"),
            environment: commandEnvironment,
            context: context)

        let producedName = produced.relativePath
        let version = String(
            producedName
                .dropFirst("cef_binary_".count)
                .dropLast("_linux64_minimal".count))
        let tarball = "cef-\(version)-linux64-codecs.tar.gz"
        let archive = artifacts.appending(tarball)
        try await requireCEFSuccess(
            .named("tar"),
            [
                "-C", candidate.string,
                "--sort=name",
                "--mtime=@0",
                "--owner=0",
                "--group=0",
                "--numeric-owner",
                "--use-compress-program=gzip -n",
                "-cf", archive.string,
                "--transform=s,^sdk,\(buildID),",
                "sdk",
            ],
            directory: candidate,
            environment: commandEnvironment,
            context: context)
        let checksum = try context.files.digest(file: archive)
            .description.replacingOccurrences(of: "sha256:", with: "")
        try context.files.write(
            Array("\(checksum)  \(tarball)\n".utf8),
            to: artifacts.appending("\(tarball).sha256"))
        try context.files.copy(
            from: builtManifest,
            to: artifacts.appending("nucleus-build-manifest.json"))

        try context.files.publishGeneration(
            candidate: candidate,
            generation: releases.appending(buildID),
            active: assembly.distributionRoot.appending("current-release"))
        try context.files.replaceSymlink(
            at: assembly.distributionRoot.appending("current"),
            target: "current-release/sdk")
        try context.files.replaceSymlink(
            at: assembly.distributionRoot.appending("artifacts-current"),
            target: "current-release/artifacts")
        succeeded = true
    }

    package func validateOutputs(using files: ActionFileSystem) throws {
        try validateCEFPublicationStructure(assembly, files: files)
    }
}

private func encodeCEFArtifactIdentity(
    _ assembly: CEFArtifactAssembly,
    into encoder: inout ActionIdentityEncoder
) {
    encoder.append(tag: 1, string: assembly.chromiumSource.string)
    encoder.append(tag: 2, string: assembly.buildOutput.string)
    encoder.append(tag: 3, string: assembly.depotTools.string)
    encoder.append(tag: 4, string: assembly.distributionRoot.string)
    encoder.append(tag: 5, string: assembly.cefCheckout)
    encoder.append(tag: 6, string: assembly.chromiumVersion)
}

private func cefArtifactRequirements(
    _ assembly: CEFArtifactAssembly,
    publicationAccess: ActionEffectAccess
) -> ActionRequirements {
    ActionRequirements(
        tools: [
            ActionToolRequirement(
                "python3", executable: .named("python3"), role: .semantic),
            ActionToolRequirement(
                "tar", executable: .named("tar"), role: .semantic),
            ActionToolRequirement(
                "ldd", executable: .named("ldd"), role: .semantic),
            ActionToolRequirement(
                "cc", executable: .named("cc"), role: .semantic),
        ],
        effects: [
            ActionEffect(.read, scope: .input(assembly.chromiumSource)),
            ActionEffect(.read, scope: .input(assembly.buildOutput)),
            ActionEffect(.read, scope: .input(assembly.depotTools)),
            ActionEffect(
                publicationAccess,
                scope: publicationAccess == .read
                    ? .input(assembly.distributionRoot)
                    : .publication(assembly.distributionRoot)),
            ActionEffect(
                .readWrite,
                scope: .scratch(
                    assembly.distributionRoot.appending(".consumer-smoke"))),
        ])
}

@discardableResult
private func validateCEFPublicationStructure(
    _ assembly: CEFArtifactAssembly,
    files: ActionFileSystem
) throws -> FilePath {
    let builtManifest = assembly.buildOutput.appending(
        ".nucleus-built-build.json")
    let buildID = try chromiumBuildID(manifest: builtManifest, files: files)
    let release = assembly.distributionRoot.appending("current-release")
    guard
        try files.metadataWithoutFollowingSymlinks(for: release)?.type
            == .symbolicLink,
        try files.readSymbolicLink(release) == "releases/\(buildID)"
    else {
        throw CEFArtifactActionFailure.invalidOutput(
            "published CEF generation does not match \(buildID)")
    }
    for manifest in [
        assembly.distributionRoot.appending(
            "current/nucleus-build-manifest.json"),
        assembly.distributionRoot.appending(
            "artifacts-current/nucleus-build-manifest.json"),
    ] {
        guard try files.contentsEqual(at: builtManifest, and: manifest) else {
            throw CEFArtifactActionFailure.invalidOutput(
                "published CEF manifest does not match \(buildID)")
        }
    }
    let sdk = assembly.distributionRoot.appending("current")
    try validateCEFSDKStructure(sdk, files: files)
    return sdk
}

private func validateCEFSDK(
    _ sdk: FilePath,
    environment: [String: String],
    smoke: FilePath,
    context: ActionContext
) async throws {
    try validateCEFSDKStructure(sdk, files: context.files)
    let linker = try await context.commands.execute(
        CommandSpec(
            executable: .named("ldd"),
            arguments: [sdk.appending("Release/libcef.so").string],
            workingDirectory: sdk,
            environment: environment,
            output: .captured(limit: 4 * 1_024 * 1_024)))
    guard linker.status == 0,
        !linker.standardOutput.contains("not found")
    else {
        throw CEFArtifactActionFailure.invalidOutput(
            "CEF SDK has unresolved dynamic libraries")
    }
    try context.files.remove(smoke)
    try context.files.createDirectory(smoke)
    defer { try? context.files.remove(smoke) }
    let source = smoke.appending("consumer.c")
    try context.files.write(
        Array(
            """
            #include "include/cef_version_info.h"
            int main(void) { return cef_version_info(0) > 0 ? 0 : 1; }
            """.utf8),
        to: source)
    let consumer = smoke.appending("consumer")
    try await requireCEFSuccess(
        .named("cc"),
        [
            "-I", sdk.string,
            source.string,
            "-L", sdk.appending("Release").string,
            "-Wl,-rpath,\(sdk.appending("Release"))",
            "-lcef",
            "-o", consumer.string,
        ],
        directory: smoke,
        environment: environment,
        context: context)
    try await requireCEFSuccess(
        .taskOutput(consumer),
        [],
        directory: smoke,
        environment: environment,
        context: context)
}

private func validateCEFSDKStructure(
    _ sdk: FilePath,
    files: ActionFileSystem
) throws {
    for relative in [
        "Release/libcef.so", "Release/chrome-sandbox",
        "Release/icudtl.dat", "Resources",
        "include/cef_version_info.h",
        "nucleus-build-manifest.json",
    ] {
        guard try files.metadata(for: sdk.appending(relative)) != nil else {
            throw CEFArtifactActionFailure.invalidOutput(
                "CEF SDK artifact is missing: \(relative)")
        }
    }
}

private func requireCEFSuccess(
    _ executable: CommandSpec.Executable,
    _ arguments: [String],
    directory: FilePath,
    environment: [String: String],
    context: ActionContext
) async throws {
    let result = try await context.commands.execute(
        CommandSpec(
            executable: executable,
            arguments: arguments,
            workingDirectory: directory,
            environment: environment))
    guard result.status == 0 else {
        throw CEFArtifactActionFailure.commandFailed(result.status)
    }
}

private func cefEnvironment(_ assembly: CEFArtifactAssembly) -> [String: String] {
    var value = assembly.environment
    value["PATH"] =
        assembly.depotTools.string + ":"
        + (value["PATH"] ?? "/usr/bin:/bin")
    value["DEPOT_TOOLS_UPDATE"] = "0"
    return value
}

private enum CEFArtifactActionFailure: Error, CustomStringConvertible {
    case commandFailed(Int32)
    case invalidOutput(String)

    var description: String {
        switch self {
        case .commandFailed(let status):
            "CEF artifact command failed with status \(status)"
        case .invalidOutput(let message):
            message
        }
    }
}
