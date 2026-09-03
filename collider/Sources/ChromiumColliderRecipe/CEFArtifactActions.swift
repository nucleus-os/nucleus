import ColliderCore
import Foundation
import SystemPackage

package struct AssembleCEFArtifactAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        let assembly: CEFArtifactAssembly

        package func encode(into encoder: inout IdentityEncoder) {
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
        let builtManifest = assembly.buildManifest
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

        try await requireCEFContainerSuccess(
            command: ["cef-make-distrib", assembly.target.cefBuildFlag],
            workingDirectory: "/source/chromium/src",
            hostWorkingDirectory: assembly.chromiumSource,
            mounts: [
                OCIMount(
                    boundedExport: distributionCandidate,
                    target: "/distribution")
            ],
            persistentWorkspaceMounts: [
                assembly.readOnlySourceMount,
                assembly.readOnlyOutputMount,
            ],
            environment: commandEnvironment,
            assembly: assembly,
            context: context)
        let checkout = String(assembly.cefCheckout.prefix(7))
        let suffix =
            "+g\(checkout)+chromium-\(assembly.chromiumVersion)"
            + "_\(assembly.target.cefPlatformName)_minimal"
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
            assembly: assembly,
            environment: commandEnvironment,
            smoke: candidate.appending(".consumer-smoke"),
            context: context)
        let producedName = produced.relativePath
        let version = String(
            producedName
                .dropFirst("cef_binary_".count)
                .dropLast("_\(assembly.target.cefPlatformName)_minimal".count))
        let tarball =
            "cef-\(version)-\(assembly.target.cefPlatformName)-codecs.tar.gz"
        let archive = artifacts.appending(tarball)
        try await requireCEFContainerSuccess(
            command: ["cef-archive", tarball, buildID],
            workingDirectory: "/candidate",
            hostWorkingDirectory: candidate,
            mounts: [
                OCIMount(boundedExport: candidate, target: "/candidate")
            ],
            environment: commandEnvironment,
            assembly: assembly,
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
    }

    package func validateOutputs(using files: ActionFileSystem) throws {
        try validateCEFPublicationStructure(assembly, files: files)
    }
}

private func encodeCEFArtifactIdentity(
    _ assembly: CEFArtifactAssembly,
    into encoder: inout IdentityEncoder
) {
    encoder.append(path: assembly.chromiumSource)
    encoder.append(path: assembly.buildManifest)
    encoder.append(path: assembly.distributionRoot)
    encoder.append(assembly.cefCheckout)
    encoder.append(assembly.chromiumVersion)
    encoder.append(
        nested: OCIMountedEntrypointActionIdentity(assembly.entrypoint))
    encoder.append(assembly.target.architecture.rawValue)
    encoder.append(assembly.outputWorkspace.identity.key)
    encoder.append(assembly.sourceWorkspace.identity.key)
}

private func cefArtifactRequirements(
    _ assembly: CEFArtifactAssembly,
    publicationAccess: ActionEffectAccess
) -> ActionRequirements {
    ActionRequirements(
        effects: [
            ActionEffect(.read, scope: .input(assembly.chromiumSource)),
            ActionEffect(.read, scope: .input(assembly.buildManifest)),
            ActionEffect(.read, scope: .input(assembly.entrypoint.image.path)),
            assembly.entrypoint.effect,
            ActionEffect(
                publicationAccess,
                scope: publicationAccess == .read
                    ? .input(assembly.distributionRoot)
                    : .publication(assembly.distributionRoot)),
            ActionEffect(
                .readWrite,
                scope: .scratch(
                    assembly.distributionRoot.appending(".consumer-smoke"))),
        ],
        persistentWorkspaceEffects: [
            ActionPersistentWorkspaceEffect(
                workspace: assembly.sourceWorkspace,
                target: "/source",
                access: .readOnly),
            ActionPersistentWorkspaceEffect(
                workspace: assembly.outputWorkspace,
                target: "/build",
                access: .readOnly),
        ],
        executionPlatform: .linuxARM64OCI,
        artifactTarget: assembly.target.artifactTarget)
}

@discardableResult
private func validateCEFPublicationStructure(
    _ assembly: CEFArtifactAssembly,
    files: ActionFileSystem
) throws -> FilePath {
    let builtManifest = assembly.buildManifest
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
    assembly: CEFArtifactAssembly,
    environment: [String: String],
    smoke: FilePath,
    context: ActionContext
) async throws {
    try validateCEFSDKStructure(sdk, files: context.files)
    try context.files.remove(smoke)
    try context.files.createDirectory(smoke)
    defer { try? context.files.remove(smoke) }
    let validation = try await context.containers.execute(
        chromiumToolExecution(
            target: assembly.target,
            entrypoint: assembly.entrypoint,
            hostname: "chromium-cef-validation",
            workingDirectory: "/sdk",
            hostWorkingDirectory: sdk,
            mounts: [
                OCIMount(source: sdk, target: "/sdk", access: .readOnly),
                OCIMount(boundedExport: smoke, target: "/smoke"),
            ],
            persistentWorkspaceMounts: [assembly.readOnlySourceMount],
            // Unlike every other tool execution, this one compiles: it builds
            // a consumer against the SDK to prove the SDK is consumable. The
            // compiler is Chromium's checked-in x86_64 clang, so this is the
            // one artifact execution that needs translation.
            executableRequirements: chromiumBuildExecutableRequirements,
            command: ["validate-cef", assembly.target.architecture.rawValue],
            environment: environment,
            output: .logged))
    guard validation.succeeded else {
        throw validation.executionFailure(
            reason: "CEF SDK failed Linux linkage or consumer validation")
    }
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

private func requireCEFContainerSuccess(
    command: [String],
    workingDirectory: String,
    hostWorkingDirectory: FilePath,
    mounts: [OCIMount],
    persistentWorkspaceMounts: [OCIPersistentWorkspaceMount] = [],
    environment: [String: String],
    assembly: CEFArtifactAssembly,
    context: ActionContext
) async throws {
    let result = try await context.containers.execute(
        chromiumToolExecution(
            target: assembly.target,
            entrypoint: assembly.entrypoint,
            hostname: "chromium-cef-artifact",
            workingDirectory: workingDirectory,
            hostWorkingDirectory: hostWorkingDirectory,
            mounts: mounts,
            persistentWorkspaceMounts: persistentWorkspaceMounts,
            command: command,
            environment: environment))
    guard result.succeeded else {
        throw result.executionFailure(reason: "CEF artifact command failed")
    }
}

private func cefEnvironment(_ assembly: CEFArtifactAssembly) -> [String: String] {
    assembly.environment
}

private enum CEFArtifactActionFailure: Error, CustomStringConvertible {
    case invalidOutput(String)

    var description: String {
        switch self {
        case .invalidOutput(let message):
            message
        }
    }
}
