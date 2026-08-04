import ChromiumColliderRecipe
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage
import Testing

@Test func browserArtifactAssemblyPublishesAValidatedImmutableGeneration() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-browser-artifact-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("chromium")
    let output = directory.appendingPathComponent("out")
    let distribution = directory.appendingPathComponent("dist")
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
    try JSONSerialization.data(
        withJSONObject: ["buildID": buildID],
        options: [.sortedKeys]
    ).write(
        to: output.appendingPathComponent(
            ".nucleus-built-build.json"))
    let tools = directory.appendingPathComponent("tools")
    try FileManager.default.createDirectory(
        at: tools, withIntermediateDirectories: true)
    let ldd = tools.appendingPathComponent("ldd")
    try Data("#!/bin/sh\nprintf 'all resolved\\n'\n".utf8).write(to: ldd)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: ldd.path)
    let assembly = BrowserArtifactAssembly(
        chromiumSource: FilePath(source.path),
        buildOutput: FilePath(output.path),
        distributionRoot: FilePath(distribution.path),
        launcher: FilePath(launcher.path),
        desktopTemplate: FilePath(desktop.path),
        environment: [
            "PATH": tools.path + ":"
                + (ProcessInfo.processInfo.environment["PATH"]
                    ?? "/usr/bin:/bin")
        ])
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.assemble-browser-artifact"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(
                path: FilePath(
                    distribution.appendingPathComponent(
                        "current"
                    ).path),
                validation: .exists)
        ],
        assessmentPolicy: .always,
        operation: .action(
            try AnyColliderAction(
                AssembleBrowserArtifactAction(assembly: assembly))))
    _ = try await ColliderRuntime().execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))
    #expect(
        try FileManager.default.destinationOfSymbolicLink(
            atPath: distribution.appendingPathComponent("current").path)
            == "generations/\(buildID)")
}

@Test func cefArtifactAssemblyPublishesSDKAndChecksummedArchive() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-cef-artifact-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source")
    let chromium = source.appendingPathComponent("chromium/src")
    let output = chromium.appendingPathComponent("out/Release_GN_x64")
    let depot = directory.appendingPathComponent("depot_tools")
    let distribution = directory.appendingPathComponent("dist")
    try FileManager.default.createDirectory(
        at: output, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: depot, withIntermediateDirectories: true)
    let buildID = "1234567890abcdef12345678"
    try JSONSerialization.data(
        withJSONObject: ["buildID": buildID],
        options: [.sortedKeys]
    ).write(
        to: output.appendingPathComponent(
            ".nucleus-built-build.json"))
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
            '_linux64_minimal'
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
        chromiumSource: FilePath(chromium.path),
        buildOutput: FilePath(output.path),
        depotTools: FilePath(depot.path),
        distributionRoot: FilePath(distribution.path),
        cefCheckout: checkout,
        chromiumVersion: version,
        environment: environment)
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.assemble-cef-artifact"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(
                path: FilePath(
                    distribution.appendingPathComponent(
                        "current"
                    ).path),
                validation: .exists)
        ],
        assessmentPolicy: .always,
        operation: .action(
            try AnyColliderAction(
                AssembleCEFArtifactAction(assembly: assembly))))
    _ = try await ColliderRuntime().execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))
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
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.install-browser"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(
                path: FilePath(
                    prefix.appendingPathComponent(
                        "lib/nucleus-browser/current"
                    ).path),
                validation: .exists)
        ],
        assessmentPolicy: .always,
        operation: .action(
            try AnyColliderAction(
                InstallBrowserAction(
                    installation: BrowserInstallation(
                        distributionRoot: FilePath(distribution.path),
                        prefix: FilePath(prefix.path),
                        environment: ["PATH": tools.path])))))
    _ = try await ColliderRuntime().execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))
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
