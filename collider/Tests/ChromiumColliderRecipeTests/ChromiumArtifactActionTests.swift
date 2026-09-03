import ChromiumColliderRecipe
import ColliderCore
import ColliderEngine
import ColliderPersistence
import ColliderRuntime
import Foundation
import LinuxPackageContracts
import SystemPackage
import Testing

@Test
func chromiumBuildMaterializesSourceOnceBeforeUsingOnlyPersistentWorkspaces() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-chromium-build-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source")
    let chromium = source.appendingPathComponent("chromium/src")
    let clang = chromium.appendingPathComponent(
        "third_party/llvm-build/Linux_x64/bin/clang")
    let metadata = directory.appendingPathComponent("metadata")
    let imageID = directory.appendingPathComponent("image-id")
    try FileManager.default.createDirectory(
        at: clang.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: metadata,
        withIntermediateDirectories: true)
    try Data("clang".utf8).write(to: clang)
    try Data("fixture-image".utf8).write(to: imageID)
    let entrypoint = try fixtureEntrypoint(imageID: imageID)
    try JSONSerialization.data(
        withJSONObject: ["sourceID": "0123456789abcdef01234567"],
        options: [.sortedKeys]
    ).write(to: source.appendingPathComponent("source-provenance.json"))

    let target = ChromiumLinuxTarget(architecture: .arm64)
    let action = BuildChromiumProductAction(
        build: ChromiumProductBuild(
            product: .browser,
            target: target,
            sourceRoot: FilePath(source.path),
            buildManifest: FilePath(
                metadata.appendingPathComponent("build-manifest.json").path),
            inputRoot: FilePath(metadata.appendingPathComponent("inputs").path),
            sourceWorkspace: chromiumSourceWorkspace(),
            outputWorkspace: chromiumOutputWorkspace(
                product: .browser,
                target: target),
            compilerCacheWorkspace: chromiumCompilerCacheWorkspace(
                target: target),
            entrypoint: entrypoint,
            gnArguments: "is_debug=false",
            targets: ["chrome"],
            jobs: 12,
            environment: ["PATH": "/usr/bin:/bin"]))
    let executions = OCIExecutionRecorder()
    try await execute(
        action,
        recording: executions,
        containerRun: { execution in
            switch execution.command.first {
            case "materialize-source", "build":
                return CommandResult(status: 0)
            default:
                Issue.record(
                    "unexpected Chromium build command: \(execution.command)")
                return CommandResult(status: 64)
            }
        })
    let recorded = await executions.values()
    #expect(
        recorded.map(\.command.first) == [
            "materialize-source", "build",
        ])
    let build = try #require(recorded.dropFirst().first)
    #expect(
        build.command == [
            "build", "0123456789abcdef01234567", "is_debug=false", "12",
            "chrome",
        ])
    let materialization = try #require(recorded.first)
    #expect(
        materialization.mounts.map(\.target)
            == ["/collider-entrypoints/fixture", "/host-source"])
    #expect(materialization.persistentWorkspaceMounts.map(\.target) == ["/source"])
    #expect(materialization.persistentWorkspaceMounts.first?.access == .readWrite)
    #expect(materialization.executableRequirements.isEmpty)
    for execution in recorded.dropFirst() {
        #expect(!execution.mounts.contains { $0.target == "/source" })
        #expect(
            execution.persistentWorkspaceMounts.first?.target == "/source")
        #expect(
            execution.persistentWorkspaceMounts.first?.access == .readOnly)
    }
}

/// Chromium compiles every translation unit with `-fmodules`, and ccache
/// refuses to cache such a command unless depend mode is on and `modules`
/// sloppiness is granted -- it reports `could_not_use_modules` and runs the
/// compiler. A cache directory configured without those two therefore stores
/// nothing at all while looking configured, which is what a 30 GiB volume
/// holding 68 MiB after four complete builds looked like. The inherited
/// environment must not be able to take them back off, either.
@Test func chromiumBuildCachesModuleCompilationsAndKeepsThatSettingItself()
    async throws
{
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-chromium-ccache-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source")
    let chromium = source.appendingPathComponent("chromium/src")
    let clang = chromium.appendingPathComponent(
        "third_party/llvm-build/Linux_x64/bin/clang")
    let metadata = directory.appendingPathComponent("metadata")
    let imageID = directory.appendingPathComponent("image-id")
    try FileManager.default.createDirectory(
        at: clang.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: metadata,
        withIntermediateDirectories: true)
    try Data("clang".utf8).write(to: clang)
    try Data("fixture-image".utf8).write(to: imageID)
    let entrypoint = try fixtureEntrypoint(imageID: imageID)
    try JSONSerialization.data(
        withJSONObject: ["sourceID": "0123456789abcdef01234567"],
        options: [.sortedKeys]
    ).write(to: source.appendingPathComponent("source-provenance.json"))

    let target = ChromiumLinuxTarget(architecture: .arm64)
    let action = BuildChromiumProductAction(
        build: ChromiumProductBuild(
            product: .cef,
            target: target,
            sourceRoot: FilePath(source.path),
            buildManifest: FilePath(
                metadata.appendingPathComponent("build-manifest.json").path),
            inputRoot: FilePath(metadata.appendingPathComponent("inputs").path),
            sourceWorkspace: chromiumSourceWorkspace(),
            outputWorkspace: chromiumOutputWorkspace(
                product: .cef,
                target: target),
            compilerCacheWorkspace: chromiumCompilerCacheWorkspace(
                target: target),
            entrypoint: entrypoint,
            gnArguments: "is_debug=false",
            targets: ["libcef"],
            jobs: 12,
            environment: [
                "PATH": "/usr/bin:/bin",
                "CCACHE_DEPEND": "0",
                "CCACHE_SLOPPINESS": "",
            ]))
    let executions = OCIExecutionRecorder()
    try await execute(
        action,
        recording: executions,
        containerRun: { _ in CommandResult(status: 0) })

    let build = try #require(
        await executions.values().first { $0.command.first == "build" })
    // Asserted on `containerEnvironment`, which is the only environment the
    // container process is given. The first version of this test read
    // `environment` and passed against a build whose ccache was receiving no
    // configuration at all.
    #expect(build.containerEnvironment["CCACHE_DIR"] == "/ccache")
    #expect(build.containerEnvironment["CCACHE_DEPEND"] == "1")
    #expect(build.containerEnvironment["CCACHE_SLOPPINESS"] == "modules")
    #expect(build.containerEnvironment["CCACHE_COMPILERCHECK"] == "content")
    #expect(build.persistentWorkspaceMounts.contains { $0.target == "/ccache" })

    // The source lock serializes the product builds, so each one has the host
    // to itself. Half an allocation would leave the other half idle for hours.
    #expect(build.resourceLimits == .build)
    #expect(build.resourceLimits != .parallelBuild)
}

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
    // Every size the package contract declares, because the assembly now
    // refuses to publish a generation missing one of them.
    for size in browserIconSizes {
        let icon = source.appendingPathComponent(
            "chrome/app/theme/chromium/linux/product_logo_\(size).png")
        try FileManager.default.createDirectory(
            at: icon.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("icon".utf8).write(to: icon)
    }
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
        sourceWorkspace: chromiumSourceWorkspace(),
        outputWorkspace: chromiumOutputWorkspace(
            product: .browser,
            target: target),
        entrypoint: try fixtureEntrypoint(imageID: imageID),
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
    #expect(validation.executableRequirements.isEmpty)
    #expect(validation.command == ["validate-browser", architecture.rawValue])
    let payloadTarget = try FileManager.default.destinationOfSymbolicLink(
        atPath: distribution.appendingPathComponent("current").path)
    let payload = distribution.appendingPathComponent(payloadTarget)
    let payloadDigest = try ArtifactHasher.digest(tree: FilePath(payload.path))
    #expect(
        payloadTarget
            == "generations/sha256-\(payloadDigest.hexadecimal)")

    let packageInputRoot = directory.appendingPathComponent("package-input")
    let packagePublication = BrowserPackageInputPublication(
        target: target.artifactTarget,
        distributionRoot: FilePath(distribution.path),
        packageInputRoot: FilePath(packageInputRoot.path))
    try await execute(
        PublishBrowserPackageInputAction(publication: packagePublication),
        recording: executions,
        containerRun: { execution in
            Issue.record(
                "package-input publication must not execute a container: \(execution)")
            return CommandResult(status: 64)
        })
    let packageInput = try validatedBrowserPackageInput(
        packagePublication,
        files: ColliderRuntime().actionFileSystem())
    #expect(packageInput.packageName == "nucleus-browser")
    #expect(packageInput.artifactTarget == target.artifactTarget)
    #expect(packageInput.payloadDigest == payloadDigest)
    #expect(packageInput.payloadGeneration == payloadTarget)
    try Data("substituted".utf8).write(
        to: payload.appendingPathComponent("runtime/icudtl.dat"))
    #expect(throws: (any Error).self) {
        try validatedBrowserPackageInput(
            packagePublication,
            files: ColliderRuntime().actionFileSystem())
    }
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
        sourceWorkspace: chromiumSourceWorkspace(),
        outputWorkspace: chromiumOutputWorkspace(
            product: .cef,
            target: target),
        entrypoint: try fixtureEntrypoint(imageID: imageID),
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
            case "validate-cef":
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
            "cef-make-distrib", "validate-cef", "cef-archive",
        ])
    #expect(
        recorded.allSatisfy {
            $0.executionPlatform == .linuxARM64OCI
                && $0.artifactTarget == target.artifactTarget
        })
    // Assembling and archiving move files and need no translation. Validation
    // compiles a consumer against the SDK, with Chromium's checked-in x86_64
    // clang, and without declaring that it got no translation and no compiler:
    // the step failed with `/usr/bin/clang: No such file or directory`.
    #expect(recorded[0].executableRequirements.isEmpty)
    #expect(
        recorded[1].executableRequirements.contains {
            $0.architecture == .x86_64 && $0.executable.hasSuffix("clang++")
        })
    #expect(recorded[2].executableRequirements.isEmpty)
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

private func fixtureEntrypoint(
    imageID: URL
) throws -> OCIMountedEntrypoint {
    let executable = imageID.deletingLastPathComponent().appendingPathComponent(
        "entrypoint.sh")
    try Data("#!/bin/sh\nexec \"$@\"\n".utf8).write(to: executable)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: executable.path)
    var builder = TaskBuilder(
        id: TaskID(rawValue: "fixture.container-image"),
        component: ComponentID(rawValue: "fixture"))
    let image = try builder.output(
        "image-id",
        path: FilePath(imageID.path),
        validation: .regularFile)
    return OCIMountedEntrypoint(
        image: image,
        executable: FilePath(executable.path),
        containerDirectory: "/collider-entrypoints/fixture")
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
