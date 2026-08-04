import ColliderCore
import Foundation
import SystemPackage

package struct AssembleBrowserArtifactAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        let assembly: BrowserArtifactAssembly

        package func encode(into encoder: inout ActionIdentityEncoder) {
            encodeBrowserArtifactIdentity(assembly, into: &encoder)
        }
    }

    package static let kind: ActionKind = "browser.assemble-artifact"

    let assembly: BrowserArtifactAssembly

    package init(assembly: BrowserArtifactAssembly) {
        self.assembly = assembly
    }

    package var identity: Identity { Identity(assembly: assembly) }
    package var environment: [String: String] { assembly.environment }
    package var requirements: ActionRequirements {
        browserArtifactRequirements(assembly, access: .readWrite)
    }

    package func execute(in context: ActionContext) async throws {
        let builtManifest = assembly.buildOutput.appending(
            ".nucleus-built-build.json")
        let buildID = try chromiumBuildID(
            manifest: builtManifest,
            files: context.files)
        let generations = assembly.distributionRoot.appending("generations")
        try context.files.createDirectory(generations)
        let candidate = generations.appending(".\(buildID).prepared")
        try context.files.remove(candidate)
        try context.files.createDirectory(candidate)
        var succeeded = false
        defer {
            if !succeeded { try? context.files.remove(candidate) }
        }

        let runtime = candidate.appending("runtime")
        try context.files.createDirectory(runtime)
        let required: [(String, String, UInt16?)] = [
            ("chrome", "nucleus-browser-bin", 0o755),
            ("chrome_crashpad_handler", "chrome_crashpad_handler", 0o755),
            ("chrome_sandbox", "chrome_sandbox", 0o755),
            ("icudtl.dat", "icudtl.dat", nil),
            ("resources.pak", "resources.pak", nil),
            ("chrome_100_percent.pak", "chrome_100_percent.pak", nil),
            ("chrome_200_percent.pak", "chrome_200_percent.pak", nil),
            ("libEGL.so", "libEGL.so", 0o755),
            ("libGLESv2.so", "libGLESv2.so", 0o755),
            ("libvulkan.so.1", "libvulkan.so.1", 0o755),
        ]
        for (source, destination, permissions) in required {
            try copyItem(
                from: assembly.buildOutput.appending(source),
                to: runtime.appending(destination),
                permissions: permissions,
                files: context.files)
        }
        let snapshot = assembly.buildOutput.appending(
            "v8_context_snapshot.bin")
        if try exists(snapshot, files: context.files) {
            try copyItem(
                from: snapshot,
                to: runtime.appending("v8_context_snapshot.bin"),
                files: context.files)
        } else {
            try copyItem(
                from: assembly.buildOutput.appending("snapshot_blob.bin"),
                to: runtime.appending("snapshot_blob.bin"),
                files: context.files)
        }
        for (name, permissions) in [
            ("chrome_management_service", UInt16(0o755))
        ] {
            let source = assembly.buildOutput.appending(name)
            if try exists(source, files: context.files) {
                try copyItem(
                    from: source,
                    to: runtime.appending(name),
                    permissions: permissions,
                    files: context.files)
            }
        }
        for name in [
            "locales", "default_apps", "MEIPreload",
            "PrivacySandboxAttestationsPreloaded",
        ] {
            let source = assembly.buildOutput.appending(name)
            if try exists(source, files: context.files) {
                try copyItem(
                    from: source,
                    to: runtime.appending(name),
                    files: context.files)
            }
        }
        try copyItem(
            from: assembly.launcher,
            to: candidate.appending("bin/nucleus-browser"),
            permissions: 0o755,
            files: context.files)
        try copyItem(
            from: assembly.desktopTemplate,
            to: candidate.appending(
                "share/applications/dev.nucleus.Browser.desktop.in"),
            files: context.files)
        for size in [16, 22, 24, 32, 48, 64, 128, 256] {
            if let icon = try browserIcon(
                size: size,
                output: assembly.buildOutput,
                source: assembly.chromiumSource,
                files: context.files)
            {
                try copyItem(
                    from: icon,
                    to: candidate.appending(
                        "share/icons/hicolor/\(size)x\(size)/apps/"
                            + "dev.nucleus.Browser.png"),
                    files: context.files)
            }
        }
        try copyItem(
            from: builtManifest,
            to: candidate.appending("nucleus-build-manifest.json"),
            files: context.files)
        try await validateBrowserGeneration(
            candidate,
            environment: assembly.environment,
            context: context)
        try context.files.publishGeneration(
            candidate: candidate,
            generation: generations.appending(buildID),
            active: assembly.distributionRoot.appending("current"))
        succeeded = true
    }

    package func validateOutputs(using files: ActionFileSystem) throws {
        try validateBrowserPublicationStructure(assembly, files: files)
    }
}

package struct ValidateBrowserArtifactAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        let assembly: BrowserArtifactAssembly

        package func encode(into encoder: inout ActionIdentityEncoder) {
            encodeBrowserArtifactIdentity(assembly, into: &encoder)
        }
    }

    package static let kind: ActionKind = "browser.validate-artifact"

    let assembly: BrowserArtifactAssembly

    package init(assembly: BrowserArtifactAssembly) {
        self.assembly = assembly
    }

    package var identity: Identity { Identity(assembly: assembly) }
    package var environment: [String: String] { assembly.environment }
    package var requirements: ActionRequirements {
        browserArtifactRequirements(assembly, access: .read)
    }

    package func execute(in context: ActionContext) async throws {
        let current = try validateBrowserPublicationStructure(
            assembly,
            files: context.files)
        try await validateBrowserGeneration(
            current,
            environment: assembly.environment,
            context: context)
    }

    package func validateOutputs(using files: ActionFileSystem) throws {
        try validateBrowserPublicationStructure(assembly, files: files)
    }
}

private func encodeBrowserArtifactIdentity(
    _ assembly: BrowserArtifactAssembly,
    into encoder: inout ActionIdentityEncoder
) {
    encoder.append(tag: 1, string: assembly.chromiumSource.string)
    encoder.append(tag: 2, string: assembly.buildOutput.string)
    encoder.append(tag: 3, string: assembly.distributionRoot.string)
    encoder.append(tag: 4, string: assembly.launcher.string)
    encoder.append(tag: 5, string: assembly.desktopTemplate.string)
}

private func browserArtifactRequirements(
    _ assembly: BrowserArtifactAssembly,
    access: ActionEffectAccess
) -> ActionRequirements {
    ActionRequirements(
        tools: [
            ActionToolRequirement(
                "ldd",
                executable: .named("ldd"),
                role: .semantic),
            ActionToolRequirement(
                "bash",
                executable: .named("bash"),
                role: .semantic),
        ],
        effects: [
            ActionEffect(.read, scope: .input(assembly.chromiumSource)),
            ActionEffect(.read, scope: .input(assembly.buildOutput)),
            ActionEffect(.read, scope: .input(assembly.launcher)),
            ActionEffect(.read, scope: .input(assembly.desktopTemplate)),
            ActionEffect(
                access,
                scope: access == .read
                    ? .input(assembly.distributionRoot)
                    : .publication(assembly.distributionRoot)),
        ])
}

@discardableResult
private func validateBrowserPublicationStructure(
    _ assembly: BrowserArtifactAssembly,
    files: ActionFileSystem
) throws -> FilePath {
    let builtManifest = assembly.buildOutput.appending(
        ".nucleus-built-build.json")
    let buildID = try chromiumBuildID(manifest: builtManifest, files: files)
    let current = assembly.distributionRoot.appending("current")
    guard
        try files.metadataWithoutFollowingSymlinks(for: current)?.type
            == .symbolicLink,
        try files.readSymbolicLink(current) == "generations/\(buildID)"
    else {
        throw BrowserArtifactActionFailure.invalidOutput(
            "published browser generation does not match \(buildID)")
    }
    let publishedManifest = current.appending(
        "nucleus-build-manifest.json")
    guard try files.contentsEqual(at: builtManifest, and: publishedManifest)
    else {
        throw BrowserArtifactActionFailure.invalidOutput(
            "published browser build manifest does not match \(buildID)")
    }
    try validateBrowserGenerationStructure(current, files: files)
    return current
}

private func validateBrowserGeneration(
    _ generation: FilePath,
    environment: [String: String],
    context: ActionContext
) async throws {
    try validateBrowserGenerationStructure(generation, files: context.files)
    let runtime = generation.appending("runtime")
    let linker = try await context.commands.execute(
        CommandSpec(
            executable: .named("ldd"),
            arguments: [runtime.appending("nucleus-browser-bin").string],
            workingDirectory: generation,
            environment: environment,
            output: .captured(limit: 4 * 1_024 * 1_024)))
    guard linker.status == 0,
        !linker.standardOutput.contains("not found")
    else {
        throw BrowserArtifactActionFailure.invalidOutput(
            "browser generation has unresolved dynamic libraries")
    }
    let launcher = try await context.commands.execute(
        CommandSpec(
            executable: .named("bash"),
            arguments: [
                "-n", generation.appending("bin/nucleus-browser").string,
            ],
            workingDirectory: generation,
            environment: environment))
    guard launcher.status == 0 else {
        throw BrowserArtifactActionFailure.invalidOutput(
            "browser launcher is not valid shell syntax")
    }
}

private func validateBrowserGenerationStructure(
    _ generation: FilePath,
    files: ActionFileSystem
) throws {
    let runtime = generation.appending("runtime")
    for relative in [
        "nucleus-browser-bin", "chrome_crashpad_handler",
        "chrome_sandbox", "icudtl.dat", "resources.pak",
        "chrome_100_percent.pak", "chrome_200_percent.pak",
        "locales", "libEGL.so", "libGLESv2.so", "libvulkan.so.1",
    ] {
        guard try exists(runtime.appending(relative), files: files) else {
            throw BrowserArtifactActionFailure.invalidOutput(
                "browser generation is missing: \(relative)")
        }
    }
    for relative in [
        "share/icons/hicolor/128x128/apps/dev.nucleus.Browser.png",
        "nucleus-build-manifest.json",
        "bin/nucleus-browser",
    ] {
        guard try exists(generation.appending(relative), files: files) else {
            throw BrowserArtifactActionFailure.invalidOutput(
                "browser generation is missing: \(relative)")
        }
    }
}

private func copyItem(
    from source: FilePath,
    to destination: FilePath,
    permissions: UInt16? = nil,
    files: ActionFileSystem
) throws {
    guard let metadata = try files.metadata(for: source) else {
        throw BrowserArtifactActionFailure.invalidOutput(
            "required browser artifact is missing: \(source)")
    }
    try files.createDirectory(destination.removingLastComponent())
    if metadata.type == .directory {
        try files.copyTree(from: source, to: destination)
    } else {
        try files.copy(from: source, to: destination)
    }
    if let permissions {
        try files.setPermissions(permissions, for: destination)
    }
}

private func browserIcon(
    size: Int,
    output: FilePath,
    source: FilePath,
    files: ActionFileSystem
) throws -> FilePath? {
    for candidate in [
        output.appending("product_logo_\(size).png"),
        source.appending(
            "chrome/app/theme/chromium/linux/product_logo_\(size).png"),
        source.appending(
            "chrome/app/theme/default_100_percent/chromium/linux/"
                + "product_logo_\(size).png"),
        source.appending(
            "chrome/app/theme/chromium/product_logo_\(size).png"),
    ] where try exists(candidate, files: files) {
        return candidate
    }
    return nil
}

private func exists(
    _ path: FilePath,
    files: ActionFileSystem
) throws -> Bool {
    try files.metadata(for: path) != nil
}

package func chromiumBuildID(
    manifest: FilePath,
    files: ActionFileSystem
) throws -> String {
    let object = try JSONSerialization.jsonObject(
        with: Data(files.read(manifest)))
    guard let dictionary = object as? [String: Any],
        let value = dictionary["buildID"] as? String
            ?? dictionary["build_id"] as? String,
        value.range(
            of: #"^[0-9a-f]{24}$"#,
            options: .regularExpression) != nil
    else {
        throw BrowserArtifactActionFailure.invalidOutput(
            "Chromium build identity is missing: \(manifest)")
    }
    return value
}

private enum BrowserArtifactActionFailure: Error, CustomStringConvertible {
    case invalidOutput(String)

    var description: String {
        switch self {
        case .invalidOutput(let message): message
        }
    }
}
