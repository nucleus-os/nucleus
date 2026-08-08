import ColliderCore
import Foundation
import SystemPackage

package struct InstallBrowserAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        let installation: BrowserInstallation

        package func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: installation.distributionRoot.string)
            encoder.append(tag: 2, string: installation.prefix.string)
            encoder.append(
                tag: 3,
                string: installation.systemSandboxDirectory.string)
            var candidates = CanonicalDigestEncoder(
                identityPathMap: encoder.identityPathMap)
            for candidate in installation.widevineCandidates {
                candidates.append(tag: 1, string: candidate.string)
            }
            encoder.append(tag: 4, bytes: candidates.bytes)
        }
    }

    package static let kind: ActionKind = "browser.install"

    let installation: BrowserInstallation

    package init(installation: BrowserInstallation) {
        self.installation = installation
    }

    package var identity: Identity { Identity(installation: installation) }
    package var environment: [String: String] { installation.environment }

    package var requirements: ActionRequirements {
        ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "bash", executable: .named("bash"), role: .semantic),
                ActionToolRequirement(
                    "ldd", executable: .named("ldd"), role: .semantic),
                ActionToolRequirement(
                    "unshare", executable: .named("unshare"), role: .semantic),
                ActionToolRequirement(
                    "sudo", executable: .named("sudo"), role: .semantic),
                ActionToolRequirement(
                    "stat", executable: .named("stat"), role: .semantic),
                ActionToolRequirement(
                    "desktop-file-validate",
                    executable: .named("desktop-file-validate"),
                    role: .semantic),
                ActionToolRequirement(
                    "update-desktop-database",
                    executable: .named("update-desktop-database"),
                    role: .semantic),
            ],
            effects: [
                ActionEffect(
                    .read,
                    scope: .input(installation.distributionRoot)),
                ActionEffect(
                    .readWrite,
                    scope: .publication(normalizedPrefix)),
                ActionEffect(
                    .readWrite,
                    scope: .unrestricted(
                        installation.systemSandboxDirectory)),
            ]
                + installation.widevineCandidates.map {
                    ActionEffect(.read, scope: .input($0))
                },
            executionPlatform: .linuxX86_64Native,
            artifactTarget: .linuxX86_64)
    }

    package func execute(in context: ActionContext) async throws {
        let prefix = normalizedPrefix
        guard prefix.string != "/" else {
            throw failure("browser installation prefix must not be /")
        }
        try context.files.createDirectory(prefix)
        let artifact = try activeArtifact(files: context.files)
        let buildID = try chromiumBuildID(
            manifest: artifact.appending("nucleus-build-manifest.json"),
            files: context.files)
        let widevineCandidates =
            [
                artifact.appending("runtime/WidevineCdm")
            ] + installation.widevineCandidates
        guard
            let widevine = try widevineCandidates.first(where: {
                try completeWidevine($0, files: context.files)
            })
        else {
            throw failure(
                "a complete Linux x64 WidevineCdm installation is required")
        }
        let widevineManifestDigest = try context.files.digest(
            file: widevine.appending("manifest.json")
        ).description
        let widevineLibraryDigest = try context.files.digest(
            file: widevine.appending(
                "_platform_specific/linux_x64/libwidevinecdm.so")
        )
        .description
        let widevineID = ArtifactDigest.sha256(
            Array((widevineManifestDigest + widevineLibraryDigest).utf8)
        )
        .description

        let sandboxSource = artifact.appending("runtime/chrome_sandbox")
        let systemSandbox = installation.systemSandboxDirectory.appending(
            "chrome-sandbox")
        var sandboxID = "user-namespace"
        if try await !userNamespaceAvailable(context: context) {
            guard try context.files.metadata(for: sandboxSource)?.type == .regular
            else {
                throw failure(
                    "setuid sandbox build artifact is missing: "
                        + sandboxSource.string)
            }
            if try await !validSystemSandbox(
                sandbox: systemSandbox,
                source: sandboxSource,
                context: context)
            {
                try await requireSuccess(
                    .named("sudo"),
                    [
                        "install", "-d", "-o", "root", "-g", "root",
                        "-m", "0755",
                        installation.systemSandboxDirectory.string,
                    ],
                    context: context)
                try await requireSuccess(
                    .named("sudo"),
                    [
                        "install", "-o", "root", "-g", "root",
                        "-m", "4755",
                        sandboxSource.string, systemSandbox.string,
                    ],
                    context: context)
            }
            guard
                try await validSystemSandbox(
                    sandbox: systemSandbox,
                    source: sandboxSource,
                    context: context)
            else {
                throw failure(
                    "setuid sandbox installation is invalid: "
                        + systemSandbox.string)
            }
            sandboxID = try context.files.digest(file: systemSandbox)
                .description
        }

        let launcherPath = prefix.appending("bin/nucleus-browser").string
        let forbidden = CharacterSet(charactersIn: "\n\r\\\"$`%")
        guard launcherPath.rangeOfCharacter(from: forbidden) == nil else {
            throw failure(
                "browser install prefix is unsafe in a desktop Exec field: "
                    + prefix.string)
        }
        let launcher = artifact.appending("bin/nucleus-browser")
        let desktopTemplate = artifact.appending(
            "share/applications/dev.nucleus.Browser.desktop.in")
        let identityBytes = [
            buildID, widevineID, sandboxID, prefix.string,
            try context.files.digest(file: launcher).description,
            try context.files.digest(file: desktopTemplate).description,
        ].joined(separator: "\n")
        let installID = String(
            ArtifactDigest.sha256(Array(identityBytes.utf8))
                .hexadecimal.prefix(24))
        let runtimeRoot = prefix.appending("lib/nucleus-browser")
        let generations = runtimeRoot.appending("generations")
        try context.files.createDirectory(generations)
        let candidate = generations.appending(".\(installID).prepared")
        try context.files.remove(candidate)
        try context.files.copyTree(from: artifact, to: candidate)
        var succeeded = false
        defer {
            if !succeeded { try? context.files.remove(candidate) }
        }

        let installedWidevine = candidate.appending("runtime/WidevineCdm")
        try context.files.remove(installedWidevine)
        try context.files.copyTree(from: widevine, to: installedWidevine)
        let desktop = candidate.appending(
            "share/applications/dev.nucleus.Browser.desktop")
        let templatePath = candidate.appending(
            "share/applications/dev.nucleus.Browser.desktop.in")
        let template = try text(at: templatePath, files: context.files)
        try context.files.write(
            Array(
                template.replacingOccurrences(
                    of: "@NUCLEUS_BROWSER_LAUNCHER@",
                    with: launcherPath
                ).utf8),
            to: desktop)
        try context.files.remove(templatePath)
        try await requireSuccess(
            .named("bash"),
            ["-n", candidate.appending("bin/nucleus-browser").string],
            context: context)
        try await requireSuccess(
            .named("desktop-file-validate"),
            [desktop.string],
            context: context)
        let linker = try await context.commands.execute(
            CommandSpec(
                executable: .named("ldd"),
                arguments: [
                    candidate.appending("runtime/nucleus-browser-bin").string
                ],
                workingDirectory: prefix,
                environment: installation.environment,
                output: .captured(limit: 4 * 1_024 * 1_024)))
        guard linker.status == 0,
            !linker.standardOutput.contains("not found")
        else {
            throw failure(
                "installed browser has unresolved dynamic libraries")
        }
        try context.files.write(
            try encodedJSON(
                BrowserInstallManifest(
                    installID: installID,
                    buildID: buildID,
                    widevineSHA256: widevineID,
                    sandbox: sandboxID,
                    prefix: prefix.string)),
            to: candidate.appending("nucleus-install-manifest.json"))
        try context.files.publishGeneration(
            candidate: candidate,
            generation: generations.appending(installID),
            active: runtimeRoot.appending("current"))
        try context.files.replaceSymlink(
            at: prefix.appending("bin/nucleus-browser"),
            target: "../lib/nucleus-browser/current/bin/nucleus-browser")
        try context.files.replaceSymlink(
            at: prefix.appending(
                "share/applications/dev.nucleus.Browser.desktop"),
            target:
                "../../lib/nucleus-browser/current/share/applications/"
                + "dev.nucleus.Browser.desktop")
        let installed = generations.appending(installID)
        let icons = installed.appending("share/icons/hicolor")
        if try context.files.metadata(for: icons)?.type == .directory {
            for entry in try context.files.listRecursively(icons)
            where entry.relativePath.hasSuffix(
                "/apps/dev.nucleus.Browser.png")
                && entry.metadata.type == .regular
            {
                let size =
                    entry.relativePath.split(separator: "/").first
                    .map(String.init) ?? ""
                guard !size.isEmpty else { continue }
                try context.files.replaceSymlink(
                    at: prefix.appending(
                        "share/icons/hicolor/\(size)/apps/"
                            + "dev.nucleus.Browser.png"),
                    target:
                        "../../../../../lib/nucleus-browser/current/"
                        + "share/icons/hicolor/\(size)/apps/"
                        + "dev.nucleus.Browser.png")
            }
        }
        try context.files.pruneDirectories(
            DirectoryRetentionPlan(
                safetyRoot: runtimeRoot,
                rules: [
                    DirectoryRetentionRule(
                        root: generations,
                        current: runtimeRoot.appending("current"),
                        retain: ChromiumRetention.installationRollbackGenerationCount,
                        naming: .contentIdentity),
                    DirectoryRetentionRule(
                        root: generations,
                        retain: 0,
                        naming: .contentIdentityCandidate),
                ]))
        try await requireSuccess(
            .named("update-desktop-database"),
            [prefix.appending("share/applications").string],
            context: context)
        succeeded = true
    }

    package func validateOutputs(using files: ActionFileSystem) throws {
        let current = normalizedPrefix.appending(
            "lib/nucleus-browser/current")
        guard
            try files.metadataWithoutFollowingSymlinks(for: current)?.type
                == .symbolicLink,
            try files.metadata(
                for: current.appending("nucleus-install-manifest.json"))?.type
                == .regular
        else {
            throw failure("browser installation has no active generation")
        }
    }

    private var normalizedPrefix: FilePath {
        FilePath(
            URL(fileURLWithPath: installation.prefix.string)
                .standardizedFileURL.path)
    }

    private func activeArtifact(files: ActionFileSystem) throws -> FilePath {
        let current = installation.distributionRoot.appending("current")
        guard
            try files.metadataWithoutFollowingSymlinks(for: current)?.type
                == .symbolicLink
        else {
            throw failure("validated browser artifact is missing: \(current)")
        }
        let target = try files.readSymbolicLink(current)
        guard
            target.range(
                of: #"^generations/[0-9a-f]{24}$"#,
                options: .regularExpression) != nil
        else {
            throw failure("browser artifact activation is invalid: \(target)")
        }
        let artifact = installation.distributionRoot.appending(target)
        guard try files.metadata(for: artifact)?.type == .directory,
            try files.metadata(for: artifact.appending("runtime"))?.type
                == .directory
        else {
            throw failure("validated browser artifact is missing: \(current)")
        }
        return artifact
    }

    private func completeWidevine(
        _ root: FilePath,
        files: ActionFileSystem
    ) throws -> Bool {
        try files.metadata(for: root.appending("manifest.json"))?.type == .regular
            && files.metadata(
                for: root.appending(
                    "_platform_specific/linux_x64/libwidevinecdm.so"))?.type
                == .regular
    }

    private func userNamespaceAvailable(
        context: ActionContext
    ) async throws -> Bool {
        let result = try await context.commands.execute(
            CommandSpec(
                executable: .named("unshare"),
                arguments: ["--user", "--map-root-user", "--", "true"],
                workingDirectory: normalizedPrefix,
                environment: installation.environment,
                output: .captured(limit: 64 * 1_024)))
        return result.status == 0
    }

    private func validSystemSandbox(
        sandbox: FilePath,
        source: FilePath,
        context: ActionContext
    ) async throws -> Bool {
        guard
            try context.files.metadataWithoutFollowingSymlinks(
                for: installation.systemSandboxDirectory)?.type == .directory,
            try context.files.metadataWithoutFollowingSymlinks(for: sandbox)?.type
                == .regular,
            try context.files.contentsEqual(at: sandbox, and: source)
        else { return false }
        let result = try await context.commands.execute(
            CommandSpec(
                executable: .named("stat"),
                arguments: [
                    "-c", "%u:%g:%a",
                    installation.systemSandboxDirectory.string,
                    sandbox.string,
                ],
                workingDirectory: normalizedPrefix,
                environment: installation.environment,
                output: .captured(limit: 64 * 1_024)))
        guard result.status == 0 else { return false }
        let lines = result.standardOutput.split(whereSeparator: \.isNewline)
        return lines.count == 2
            && lines[0] == "0:0:755"
            && lines[1] == "0:0:4755"
    }

    private func requireSuccess(
        _ executable: CommandSpec.Executable,
        _ arguments: [String],
        context: ActionContext
    ) async throws {
        let result = try await context.commands.execute(
            CommandSpec(
                executable: executable,
                arguments: arguments,
                workingDirectory: normalizedPrefix,
                environment: installation.environment))
        guard result.status == 0 else {
            throw BrowserInstallationActionFailure.commandFailed(result.status)
        }
    }

    private func text(
        at path: FilePath,
        files: ActionFileSystem
    ) throws -> String {
        guard let value = String(bytes: try files.read(path), encoding: .utf8)
        else { throw failure("file is not valid UTF-8: \(path)") }
        return value
    }

    private func encodedJSON<T: Encodable>(_ value: T) throws -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Array(try encoder.encode(value))
    }

    private func failure(
        _ message: String
    ) -> BrowserInstallationActionFailure {
        .invalidOutput(message)
    }
}

private struct BrowserInstallManifest: Codable {
    let installID: String
    let buildID: String
    let widevineSHA256: String
    let sandbox: String
    let prefix: String
}

private enum BrowserInstallationActionFailure: Error, CustomStringConvertible {
    case commandFailed(Int32)
    case invalidOutput(String)

    var description: String {
        switch self {
        case .commandFailed(let status):
            "browser installation command failed with status \(status)"
        case .invalidOutput(let message):
            message
        }
    }
}
