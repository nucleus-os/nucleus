import ColliderCore
import Foundation
import SystemPackage

extension ColliderRuntime {
    func installBrowser(
        _ installation: BrowserInstallation,
        stage: TaskID
    ) async throws {
        let artifactLink = installation.distributionRoot.appending("current")
        let artifactURL = URL(fileURLWithPath: artifactLink.string)
            .resolvingSymlinksInPath()
        let artifact = FilePath(artifactURL.path)
        guard browserInstallationDirectory(artifact),
              browserInstallationDirectory(artifact.appending("runtime"))
        else {
            throw RuntimeFailure.invalidOutput(
                "validated browser artifact is missing: \(artifactLink)")
        }
        let buildID = try chromiumBuildID(
            artifact.appending("nucleus-build-manifest.json"))
        let widevineCandidates = [
            artifact.appending("runtime/WidevineCdm"),
        ] + installation.widevineCandidates
        guard let widevine = widevineCandidates.first(where: {
            browserInstallationFile($0.appending("manifest.json"))
                && browserInstallationFile($0.appending(
                    "_platform_specific/linux_x64/libwidevinecdm.so"))
        }) else {
            throw RuntimeFailure.invalidOutput(
                "a complete Linux x64 WidevineCdm installation is required")
        }
        let widevineManifestDigest = try ArtifactHasher.digest(
            file: widevine.appending("manifest.json")).description
        let widevineLibraryDigest = try ArtifactHasher.digest(
            file: widevine.appending(
                "_platform_specific/linux_x64/"
                    + "libwidevinecdm.so")).description
        let widevineID = ArtifactHasher.digest(bytes: Array(
            (widevineManifestDigest + widevineLibraryDigest).utf8))
            .description

        let sandboxSource = artifact.appending("runtime/chrome_sandbox")
        let systemSandbox = installation.systemSandboxDirectory.appending(
            "chrome-sandbox")
        var sandboxID = "user-namespace"
        if !(try await userNamespaceAvailable(
            environment: installation.environment, stage: stage))
        {
            guard browserInstallationFile(sandboxSource) else {
                throw RuntimeFailure.invalidOutput(
                    "setuid sandbox build artifact is missing: "
                        + sandboxSource.string)
            }
            if !validSystemSandbox(
                directory: installation.systemSandboxDirectory,
                sandbox: systemSandbox,
                source: sandboxSource)
            {
                try await checkedBrowserInstallCommand(
                    .named("sudo"),
                    [
                        "install", "-d", "-o", "root", "-g", "root",
                        "-m", "0755",
                        installation.systemSandboxDirectory.string,
                    ],
                    environment: installation.environment,
                    stage: stage)
                try await checkedBrowserInstallCommand(
                    .named("sudo"),
                    [
                        "install", "-o", "root", "-g", "root",
                        "-m", "4755",
                        sandboxSource.string, systemSandbox.string,
                    ],
                    environment: installation.environment,
                    stage: stage)
            }
            guard validSystemSandbox(
                directory: installation.systemSandboxDirectory,
                sandbox: systemSandbox,
                source: sandboxSource)
            else {
                throw RuntimeFailure.invalidOutput(
                    "setuid sandbox installation is invalid: "
                        + systemSandbox.string)
            }
            sandboxID = try ArtifactHasher.digest(
                file: systemSandbox).description
        }

        let prefix = FilePath(URL(
            fileURLWithPath: installation.prefix.string)
            .standardizedFileURL.path)
        guard prefix.string != "/" else {
            throw RuntimeFailure.invalidOutput(
                "browser installation prefix must not be /")
        }
        let launcherPath = prefix.appending("bin/nucleus-browser").string
        let forbidden = CharacterSet(charactersIn: "\n\r\\\"$`%")
        guard launcherPath.rangeOfCharacter(from: forbidden) == nil else {
            throw RuntimeFailure.invalidOutput(
                "browser install prefix is unsafe in a desktop Exec field: "
                    + prefix.string)
        }
        let launcher = artifact.appending("bin/nucleus-browser")
        let desktopTemplate = artifact.appending(
            "share/applications/dev.nucleus.Browser.desktop.in")
        let identityBytes = [
            buildID, widevineID, sandboxID, prefix.string,
            try ArtifactHasher.digest(file: launcher).description,
            try ArtifactHasher.digest(file: desktopTemplate).description,
        ].joined(separator: "\n")
        let installDigest = ArtifactHasher.digest(
            bytes: Array(identityBytes.utf8))
        let installID = installDigest.bytes.prefix(12).map {
            String(format: "%02x", $0)
        }.joined()
        let runtimeRoot = prefix.appending("lib/nucleus-browser")
        let generations = runtimeRoot.appending("generations")
        try FileManager.default.createDirectory(
            atPath: generations.string,
            withIntermediateDirectories: true)
        let candidate = generations.appending(
            ".\(installID).\(UUID().uuidString).prepared")
        try FileManager.default.createDirectory(
            atPath: candidate.string,
            withIntermediateDirectories: false)
        var succeeded = false
        defer {
            if !succeeded {
                try? FileManager.default.removeItem(atPath: candidate.string)
            }
        }
        for name in try FileManager.default.contentsOfDirectory(
            atPath: artifact.string)
        {
            try FileManager.default.copyItem(
                atPath: artifact.appending(name).string,
                toPath: candidate.appending(name).string)
        }
        let installedWidevine = candidate.appending(
            "runtime/WidevineCdm")
        try? FileManager.default.removeItem(
            atPath: installedWidevine.string)
        try FileManager.default.copyItem(
            atPath: widevine.string,
            toPath: installedWidevine.string)
        let desktop = candidate.appending(
            "share/applications/dev.nucleus.Browser.desktop")
        let template = try String(
            contentsOf: URL(fileURLWithPath: candidate.appending(
                "share/applications/"
                    + "dev.nucleus.Browser.desktop.in").string),
            encoding: .utf8)
        try DurableFile.write(
            Data(template.replacingOccurrences(
                of: "@NUCLEUS_BROWSER_LAUNCHER@",
                with: launcherPath).utf8),
            to: desktop)
        try FileManager.default.removeItem(
            atPath: candidate.appending(
                "share/applications/"
                    + "dev.nucleus.Browser.desktop.in").string)
        try await checkedBrowserInstallCommand(
            .named("bash"),
            ["-n", candidate.appending("bin/nucleus-browser").string],
            environment: installation.environment,
            stage: stage)
        if browserExecutable(
            "desktop-file-validate",
            environment: installation.environment)
        {
            try await checkedBrowserInstallCommand(
                .named("desktop-file-validate"),
                [desktop.string],
                environment: installation.environment,
                stage: stage)
        }
        let linker = try await execute(
            CommandSpec(
                executable: .named("ldd"),
                arguments: [
                    candidate.appending(
                        "runtime/nucleus-browser-bin").string,
                ],
                workingDirectory: candidate,
                environment: installation.environment,
                output: .captured(limit: 4 * 1_024 * 1_024)),
            stage: stage)
        guard linker.status == 0,
              !linker.standardOutput.contains("not found")
        else {
            throw RuntimeFailure.invalidOutput(
                "installed browser has unresolved dynamic libraries")
        }
        try DurableFile.writeJSON(
            BrowserInstallManifest(
                schema: 1,
                installID: installID,
                buildID: buildID,
                widevineSHA256: widevineID,
                sandbox: sandboxID,
                prefix: prefix.string),
            to: candidate.appending("nucleus-install-manifest.json"))
        try GenerationPublisher.publish(
            candidate: candidate,
            generation: generations.appending(installID),
            active: runtimeRoot.appending("current"))
        try DirectoryLifecycle.activate(
            target:
                "../lib/nucleus-browser/current/bin/nucleus-browser",
            link: prefix.appending("bin/nucleus-browser"))
        try DirectoryLifecycle.activate(
            target:
                "../../lib/nucleus-browser/current/share/applications/"
                + "dev.nucleus.Browser.desktop",
            link: prefix.appending(
                "share/applications/dev.nucleus.Browser.desktop"))
        let installed = generations.appending(installID)
        let icons = installed.appending("share/icons/hicolor")
        if browserInstallationDirectory(icons) {
            for size in try FileManager.default.contentsOfDirectory(
                atPath: icons.string)
            {
                let icon = icons.appending(
                    "\(size)/apps/dev.nucleus.Browser.png")
                guard browserInstallationFile(icon) else { continue }
                try DirectoryLifecycle.activate(
                    target:
                        "../../../../../lib/nucleus-browser/current/"
                        + "share/icons/hicolor/\(size)/apps/"
                        + "dev.nucleus.Browser.png",
                    link: prefix.appending(
                        "share/icons/hicolor/\(size)/apps/"
                            + "dev.nucleus.Browser.png"))
            }
        }
        try DirectoryLifecycle.prune(DirectoryRetentionPlan(
            safetyRoot: runtimeRoot,
            rules: [
                DirectoryRetentionRule(
                    root: generations,
                    current: runtimeRoot.appending("current"),
                    retain: 2,
                    naming: .contentIdentity),
            ]))
        if browserExecutable(
            "update-desktop-database",
            environment: installation.environment)
        {
            _ = try await execute(
                CommandSpec(
                    executable: .named("update-desktop-database"),
                    arguments: [
                        prefix.appending("share/applications").string,
                    ],
                    workingDirectory: prefix,
                    environment: installation.environment),
                stage: stage)
        }
        succeeded = true
    }

    private func userNamespaceAvailable(
        environment: [String: String],
        stage: TaskID
    ) async throws -> Bool {
        guard browserExecutable("unshare", environment: environment) else {
            return false
        }
        let result = try await execute(
            CommandSpec(
                executable: .named("unshare"),
                arguments: ["--user", "--map-root-user", "--", "true"],
                workingDirectory: FilePath("/tmp"),
                environment: environment,
                output: .captured(limit: 64 * 1_024)),
            stage: stage)
        return result.status == 0
    }

    private func checkedBrowserInstallCommand(
        _ executable: CommandSpec.Executable,
        _ arguments: [String],
        environment: [String: String],
        stage: TaskID
    ) async throws {
        let result = try await execute(
            CommandSpec(
                executable: executable,
                arguments: arguments,
                workingDirectory: FilePath("/tmp"),
                environment: environment),
            stage: stage)
        guard result.status == 0 else {
            throw RuntimeFailure.commandFailed(status: result.status)
        }
    }
}

private struct BrowserInstallManifest: Codable {
    let schema: UInt32
    let installID: String
    let buildID: String
    let widevineSHA256: String
    let sandbox: String
    let prefix: String
}

private func validSystemSandbox(
    directory: FilePath,
    sandbox: FilePath,
    source: FilePath
) -> Bool {
    guard let directoryMetadata = try? directory.stat(
        followTargetSymlink: false),
          directoryMetadata.type == .directory,
          let sandboxAttributes =
            try? FileManager.default.attributesOfItem(
                atPath: sandbox.string),
          let directoryAttributes =
            try? FileManager.default.attributesOfItem(
                atPath: directory.string),
          (directoryAttributes[.ownerAccountID] as? NSNumber)?.uint32Value == 0,
          (directoryAttributes[.groupOwnerAccountID] as? NSNumber)?
            .uint32Value == 0,
          (directoryAttributes[.posixPermissions] as? NSNumber)?
            .uint16Value == 0o755,
          (sandboxAttributes[.ownerAccountID] as? NSNumber)?.uint32Value == 0,
          (sandboxAttributes[.groupOwnerAccountID] as? NSNumber)?
            .uint32Value == 0,
          (sandboxAttributes[.posixPermissions] as? NSNumber)?
            .uint16Value == 0o4755,
          let installed = try? Data(
            contentsOf: URL(fileURLWithPath: sandbox.string)),
          let expected = try? Data(
            contentsOf: URL(fileURLWithPath: source.string))
    else { return false }
    return installed == expected
}

private func browserExecutable(
    _ name: String,
    environment: [String: String]
) -> Bool {
    (environment["PATH"] ?? "/usr/bin:/bin")
        .split(separator: ":", omittingEmptySubsequences: false)
        .map(String.init)
        .contains {
            FileManager.default.isExecutableFile(
                atPath: FilePath($0).appending(name).string)
        }
}

private func browserInstallationFile(_ path: FilePath) -> Bool {
    guard let metadata = try? path.stat(followTargetSymlink: true) else {
        return false
    }
    return metadata.type == .regular
}

private func browserInstallationDirectory(_ path: FilePath) -> Bool {
    guard let metadata = try? path.stat(followTargetSymlink: true) else {
        return false
    }
    return metadata.type == .directory
}
