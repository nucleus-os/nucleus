import ChromiumColliderRecipe
import ColliderCore
import ColliderEngine
import ColliderRuntime
import Foundation
import SystemPackage
import Testing

@Test(arguments: PlatformArchitecture.allCases)
func browserArtifactAssemblyPublishesAValidatedImmutableGeneration(
    architecture: PlatformArchitecture
) async throws {
    let target = ChromiumLinuxTarget(architecture: architecture)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-browser-artifact-\(architecture.rawValue)-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("chromium")
    let output = directory.appendingPathComponent("out")
    let distribution = directory.appendingPathComponent("dist")
    let imageID = directory.appendingPathComponent("image-id")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    try Data("fixture-image".utf8).write(to: imageID)
    try FileManager.default.createDirectory(
        at: output.appendingPathComponent("locales"),
        withIntermediateDirectories: true)
    let required = [
        "chrome", "chrome_crashpad_handler", "chrome_sandbox",
        "icudtl.dat", "resources.pak", "chrome_100_percent.pak",
        "chrome_200_percent.pak", "v8_context_snapshot.bin",
        "libEGL.so", "libGLESv2.so", "libvulkan.so.1",
    ]
    for name in required {
        try Data(name.utf8).write(
            to: output.appendingPathComponent(name))
    }
    try Data("locale".utf8).write(
        to: output.appendingPathComponent("locales/en-US.pak"))
    let icon = source.appendingPathComponent(
        "chrome/app/theme/chromium/linux/product_logo_128.png")
    try FileManager.default.createDirectory(
        at: icon.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try Data("icon".utf8).write(to: icon)
    let launcher = directory.appendingPathComponent("nucleus-browser")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: launcher)
    let desktop = directory.appendingPathComponent("browser.desktop.in")
    try Data(
        "Exec=@NUCLEUS_BROWSER_LAUNCHER@\n".utf8
    ).write(to: desktop)
    let buildID = "abcdefabcdefabcdefabcdef"
    let buildManifest = directory.appendingPathComponent("build-manifest.json")
    try JSONSerialization.data(
        withJSONObject: ["buildID": buildID],
        options: [.sortedKeys]
    ).write(to: buildManifest)
    let tools = directory.appendingPathComponent("tools")
    try FileManager.default.createDirectory(
        at: tools, withIntermediateDirectories: true)
    let ldd = tools.appendingPathComponent("ldd")
    try Data("#!/bin/sh\nprintf 'all resolved\\n'\n".utf8).write(to: ldd)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: ldd.path)
    let assembly = BrowserArtifactAssembly(
        target: target,
        chromiumSource: FilePath(source.path),
        buildManifest: FilePath(buildManifest.path),
        outputWorkspace: chromiumOutputWorkspace(
            product: .browser,
            target: target),
        containerImageID: FilePath(imageID.path),
        distributionRoot: FilePath(distribution.path),
        launcher: FilePath(launcher.path),
        desktopTemplate: FilePath(desktop.path),
        environment: [
            "PATH": tools.path + ":"
                + (ProcessInfo.processInfo.environment["PATH"]
                    ?? "/usr/bin:/bin")
        ])
    let action = AssembleBrowserArtifactAction(assembly: assembly)
    let executions = OCIExecutionRecorder()
    try await execute(
        action,
        recording: executions,
        containerRun: { execution in
            if execution.command == ["browser-stage"] {
                let candidate = try #require(
                    execution.mounts.first { $0.target == "/candidate" }
                ).source
                let runtime = candidate.appending("runtime")
                try FileManager.default.createDirectory(
                    atPath: runtime.string,
                    withIntermediateDirectories: true)
                for name in required {
                    try FileManager.default.copyItem(
                        atPath: output.appendingPathComponent(name).path,
                        toPath: runtime.appending(name).string)
                }
                try FileManager.default.copyItem(
                    atPath: output.appendingPathComponent("locales").path,
                    toPath: runtime.appending("locales").string)
            }
            return CommandResult(status: 0)
        })
    let recorded = await executions.values()
    #expect(
        recorded.map(\.command) == [
            ["browser-stage"], ["validate-browser", architecture.rawValue],
        ])
    let validation = try #require(recorded.last)
    #expect(validation.executionPlatform == .linuxARM64OCI)
    #expect(validation.artifactTarget == target.artifactTarget)
    #expect(validation.intelBinaryTranslationPolicy == .required)
    #expect(validation.command == ["validate-browser", architecture.rawValue])
    #expect(
        try FileManager.default.destinationOfSymbolicLink(
            atPath: distribution.appendingPathComponent("current").path)
            == "generations/\(buildID)")
}

@Test(arguments: PlatformArchitecture.allCases)
func cefArtifactAssemblyPublishesSDKAndChecksummedArchive(
    architecture: PlatformArchitecture
) async throws {
    let target = ChromiumLinuxTarget(architecture: architecture)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-cef-artifact-\(architecture.rawValue)-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source")
    let chromium = source.appendingPathComponent("chromium/src")
    let output = chromium.appendingPathComponent("out/Release_GN_x64")
    let distribution = directory.appendingPathComponent("dist")
    let imageID = directory.appendingPathComponent("image-id")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    try Data("fixture-image".utf8).write(to: imageID)
    try FileManager.default.createDirectory(
        at: output, withIntermediateDirectories: true)
    let buildID = "1234567890abcdef12345678"
    let buildManifest = directory.appendingPathComponent("build-manifest.json")
    try JSONSerialization.data(
        withJSONObject: ["buildID": buildID],
        options: [.sortedKeys]
    ).write(to: buildManifest)
    let checkout = "abcdefa000000000000000000000000000000000"
    let version = "1.2.3.4"
    let distributor = chromium.appendingPathComponent(
        "cef/tools/make_distrib.py")
    try FileManager.default.createDirectory(
        at: distributor.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try Data(
        """
        import sys
        from pathlib import Path
        output = next(
            argument.split('=', 1)[1]
            for argument in sys.argv
            if argument.startswith('--output-dir=')
        )
        root = Path(output) / (
            'cef_binary_fixture+gabcdefa+chromium-\(version)'
            '_\(target.cefPlatformName)_minimal'
        )
        for path in [
            root / 'Release',
            root / 'Resources',
            root / 'include',
        ]:
            path.mkdir(parents=True, exist_ok=True)
        for relative in [
            'Release/libcef.so',
            'Release/chrome-sandbox',
            'Release/icudtl.dat',
            'include/cef_version_info.h',
            'Resources/resources.pak',
        ]:
            path = root / relative
            path.write_text('fixture')
        """.utf8
    ).write(to: distributor)
    let versionManager = chromium.appendingPathComponent(
        "cef/tools/version_manager.py")
    try FileManager.default.createDirectory(
        at: versionManager.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try Data("raise SystemExit(0)\n".utf8).write(to: versionManager)
    let tools = directory.appendingPathComponent("tools")
    try FileManager.default.createDirectory(
        at: tools, withIntermediateDirectories: true)
    let ldd = tools.appendingPathComponent("ldd")
    try Data("#!/bin/sh\nprintf 'all resolved\\n'\n".utf8).write(to: ldd)
    let cc = tools.appendingPathComponent("cc")
    try Data(
        """
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-o" ]; then
            out="$2"
            break
          fi
          shift
        done
        printf '#!/bin/sh\\nexit 0\\n' > "$out"
        chmod 755 "$out"
        """.utf8
    ).write(to: cc)
    let tar = tools.appendingPathComponent("tar")
    try Data(
        """
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-cf" ]; then
            printf 'deterministic archive fixture' > "$2"
            exit 0
          fi
          shift
        done
        exit 64
        """.utf8
    ).write(to: tar)
    for executable in [ldd, cc, tar] {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path)
    }
    let environment = [
        "PATH": tools.path + ":"
            + (ProcessInfo.processInfo.environment["PATH"]
                ?? "/usr/bin:/bin")
    ]
    let assembly = CEFArtifactAssembly(
        target: target,
        chromiumSource: FilePath(chromium.path),
        buildManifest: FilePath(buildManifest.path),
        outputWorkspace: chromiumOutputWorkspace(
            product: .cef,
            target: target),
        containerImageID: FilePath(imageID.path),
        distributionRoot: FilePath(distribution.path),
        cefCheckout: checkout,
        chromiumVersion: version,
        environment: environment)
    let action = AssembleCEFArtifactAction(assembly: assembly)
    let executions = OCIExecutionRecorder()
    try await execute(
        action,
        recording: executions,
        containerRun: { execution in
            switch execution.command.first {
            case "cef-make-distrib":
                let candidate = try #require(
                    execution.mounts.first { $0.target == "/distribution" }
                ).source
                let root = candidate.appending(
                    "cef_binary_fixture+gabcdefa+chromium-\(version)"
                        + "_\(target.cefPlatformName)_minimal")
                for relative in ["Release", "Resources", "include"] {
                    try FileManager.default.createDirectory(
                        atPath: root.appending(relative).string,
                        withIntermediateDirectories: true)
                }
                for relative in [
                    "Release/libcef.so",
                    "Release/chrome-sandbox",
                    "Release/icudtl.dat",
                    "include/cef_version_info.h",
                    "Resources/resources.pak",
                ] {
                    try Data("fixture".utf8).write(
                        to: URL(fileURLWithPath: root.appending(relative).string))
                }
            case "cef-archive":
                let candidate = try #require(
                    execution.mounts.first { $0.target == "/candidate" }
                ).source
                let archive = try #require(execution.command.dropFirst().first)
                try Data("deterministic archive fixture".utf8).write(
                    to: URL(
                        fileURLWithPath: candidate.appending(
                            "artifacts/\(archive)"
                        ).string))
            case "validate-cef", "cef-version-check":
                break
            default:
                Issue.record("unexpected CEF container command: \(execution.command)")
                return CommandResult(status: 64)
            }
            return CommandResult(status: 0)
        })
    let recorded = await executions.values()
    #expect(
        recorded.map(\.command.first) == [
            "cef-make-distrib", "validate-cef", "cef-version-check", "cef-archive",
        ])
    #expect(
        recorded.allSatisfy {
            $0.executionPlatform == .linuxARM64OCI
                && $0.artifactTarget == target.artifactTarget
                && $0.intelBinaryTranslationPolicy == .required
        })
    #expect(
        try FileManager.default.destinationOfSymbolicLink(
            atPath: distribution.appendingPathComponent(
                "current-release"
            ).path) == "releases/\(buildID)")
    let artifactNames = try FileManager.default.contentsOfDirectory(
        atPath: distribution.appendingPathComponent(
            "artifacts-current"
        ).path)
    #expect(
        artifactNames.contains {
            $0.hasSuffix(".tar.gz.sha256")
        })
}

@Test func browserInstallationPublishesOneVersionedPrefixGeneration() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-browser-install-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let distribution = directory.appendingPathComponent("distribution")
    let buildID = "fedcbafedcbafedcbafedcba"
    let artifact = distribution.appendingPathComponent(
        "generations/\(buildID)")
    let runtime = artifact.appendingPathComponent("runtime")
    let widevine = runtime.appendingPathComponent("WidevineCdm")
    try FileManager.default.createDirectory(
        at: widevine.appendingPathComponent(
            "_platform_specific/linux_x64"),
        withIntermediateDirectories: true)
    for (path, value) in [
        (runtime.appendingPathComponent("nucleus-browser-bin"), "browser"),
        (runtime.appendingPathComponent("chrome_sandbox"), "sandbox"),
        (widevine.appendingPathComponent("manifest.json"), "{}"),
        (
            widevine.appendingPathComponent(
                "_platform_specific/linux_x64/libwidevinecdm.so"),
            "widevine"
        ),
    ] {
        try Data(value.utf8).write(to: path)
    }
    let launcher = artifact.appendingPathComponent("bin/nucleus-browser")
    try FileManager.default.createDirectory(
        at: launcher.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: launcher)
    let desktop = artifact.appendingPathComponent(
        "share/applications/dev.nucleus.Browser.desktop.in")
    try FileManager.default.createDirectory(
        at: desktop.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try Data(
        "[Desktop Entry]\nType=Application\n"
            .appending("Exec=@NUCLEUS_BROWSER_LAUNCHER@\n").utf8
    ).write(to: desktop)
    let icon = artifact.appendingPathComponent(
        "share/icons/hicolor/128x128/apps/dev.nucleus.Browser.png")
    try FileManager.default.createDirectory(
        at: icon.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try Data("icon".utf8).write(to: icon)
    try JSONSerialization.data(
        withJSONObject: ["buildID": buildID],
        options: [.sortedKeys]
    ).write(
        to: artifact.appendingPathComponent(
            "nucleus-build-manifest.json"))
    try FileManager.default.createSymbolicLink(
        atPath: distribution.appendingPathComponent("current").path,
        withDestinationPath: "generations/\(buildID)")

    let tools = directory.appendingPathComponent("tools")
    try FileManager.default.createDirectory(
        at: tools, withIntermediateDirectories: true)
    for (name, source) in [
        ("ldd", "#!/bin/sh\nprintf 'all resolved\\n'\n"),
        ("unshare", "#!/bin/sh\nexit 0\n"),
        ("bash", "#!/bin/sh\nexec /bin/bash \"$@\"\n"),
        ("sudo", "#!/bin/sh\nexit 0\n"),
        ("stat", "#!/bin/sh\nexit 0\n"),
        ("desktop-file-validate", "#!/bin/sh\nexit 0\n"),
        ("update-desktop-database", "#!/bin/sh\nexit 0\n"),
    ] {
        let executable = tools.appendingPathComponent(name)
        try Data(source.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path)
    }
    let prefix = directory.appendingPathComponent("prefix")
    try await ColliderRuntime().execute(
        InstallBrowserAction(
            installation: BrowserInstallation(
                distributionRoot: FilePath(distribution.path),
                prefix: FilePath(prefix.path),
                environment: ["PATH": tools.path])))
    let current = prefix.appendingPathComponent(
        "lib/nucleus-browser/current")
    let target = try FileManager.default.destinationOfSymbolicLink(
        atPath: current.path)
    #expect(target.hasPrefix("generations/"))
    #expect(
        try FileManager.default.destinationOfSymbolicLink(
            atPath: prefix.appendingPathComponent(
                "bin/nucleus-browser"
            ).path)
            == "../lib/nucleus-browser/current/bin/nucleus-browser")
}

private actor OCIExecutionRecorder {
    private var executions: [OCIExecution] = []

    func append(_ execution: OCIExecution) {
        executions.append(execution)
    }

    func values() -> [OCIExecution] {
        executions
    }
}

private func execute<Action: ColliderAction>(
    _ action: Action,
    recording recorder: OCIExecutionRecorder,
    containerRun: @escaping @Sendable (OCIExecution) async throws -> CommandResult
) async throws {
    let files = ColliderRuntime().actionFileSystem()
    let context = ActionContext(
        files: files,
        cancellation: ActionCancellation {},
        logger: ActionLogger { _ in },
        commands: ActionCommandExecutor { _ in
            throw ActionContainerExecutorFailure.unavailable
        },
        downloads: ActionDownloader { _, _ in },
        containers: ActionContainerExecutor(
            run: { execution in
                await recorder.append(execution)
                return try await containerRun(execution)
            }))
    try await action.execute(in: context)
    try action.validateOutputs(using: files)
}
