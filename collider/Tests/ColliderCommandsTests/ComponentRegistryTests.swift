import AndroidRuntimeColliderRecipe
import ColliderCore
import CompositorColliderRecipe
import CoreColliderRecipe
import Foundation
import ReactNativeColliderRecipe
import SystemPackage
import Testing
import VulkanColliderRecipe
import WaylandColliderRecipe

@testable import ColliderCommands

private let fixtureSwiftPackageRoot = FilePath("/workspace")

@Test func androidToolchainCatalogDrivesColliderVersionsAndNDKSelection() throws {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-android-toolchain-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let catalog = workspace.appendingPathComponent(
        "core/android/gradle/libs.versions.toml")
    try FileManager.default.createDirectory(
        at: catalog.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try Data(
        """
        [versions]
        agp = "9.3.1"
        gradle = "9.5.0"
        compileSdkApi = "37"
        compileSdkMinor = "0"
        minSdk = "24"
        targetSdkApi = "37"
        buildTools = "37.0.0"
        ndk = "30.0.15729638"
        jvm = "17"

        [plugins]
        ignored = { id = "example" }
        """.utf8
    ).write(to: catalog)
    let ndk = workspace.appendingPathComponent("selected-ndk")
    try FileManager.default.createDirectory(
        at: ndk, withIntermediateDirectories: true)
    try Data(
        """
        Pkg.Revision = 30.0.15729638-beta2
        Pkg.BaseRevision = 30.0.15729638
        """.utf8
    ).write(to: ndk.appendingPathComponent("source.properties"))

    let versions = try AndroidToolchainVersions.load(workspaceRoot: FilePath(workspace.path))

    #expect(versions.androidGradlePlugin == "9.3.1")
    #expect(versions.gradle == "9.5.0")
    #expect(versions.compileSDKAPI == 37)
    #expect(versions.compileSDKMinor == 0)
    #expect(versions.minimumSDK == 24)
    #expect(versions.targetSDKAPI == 37)
    #expect(versions.buildTools == "37.0.0")
    #expect(versions.ndk == "30.0.15729638")
    #expect(versions.java == 17)
    #expect(
        try versions.ndkRoot(environment: [
            "NUCLEUS_ANDROID_NDK_HOME": ndk.path
        ]) == FilePath(ndk.path))
}

@Test func runtimeTestSelectionsUseBothLinuxArchitectureLanes() throws {
    let root = try #require(
        discoverWorkspaceRoot(from: FileManager.default.currentDirectoryPath))
    let registry = ComponentRegistry(
        context: WorkspaceContext(
            root: root,
            environment: [:]))
    let all = try registry.selectedTestTasks(nil).map(\.rawValue)

    #expect(
        all == [
            "linux.arm64.test", "linux.x86_64.test",
            "test.release-gate.collection",
            "test.release-gate.compositor-transition",
            "test.release-gate.foundation-lifecycle",
            "test.release-gate.foundation-publication",
            "test.release-gate.platform-transport",
            "test.release-gate.text-editor",
        ])
    #expect(
        try registry.selectedTestTasks("config").map(\.rawValue) == [
            "linux.arm64.test", "linux.x86_64.test",
        ])
    #expect(
        try registry.selectedTestTasks("ipc").map(\.rawValue) == [
            "linux.arm64.test", "linux.x86_64.test",
        ])
    #expect(
        try registry.selectedTestTasks("compositor").map(\.rawValue) == [
            "linux.arm64.test", "linux.x86_64.test",
        ])
    #expect(
        try registry.selectedTestTasks("loader").map(\.rawValue) == [
            "linux.arm64.test-loader", "linux.x86_64.test-loader",
        ])
    #expect(
        try registry.selectedTestTasks("gpu-headless").map(\.rawValue) == [
            "linux.arm64.test-gpu-headless", "linux.x86_64.test-gpu-headless",
        ])
    #expect(
        try registry.selectedTestTasks("gpu-drm").map(\.rawValue) == [
            "compositor-core.test-gpu-drm"
        ])
    #expect(throws: (any Error).self) {
        try registry.selectedTestTasks("unknown")
    }
}

@Test func unselectedDRMWorkDoesNotProbeHardware() throws {
    let root = try #require(
        discoverWorkspaceRoot(from: FileManager.default.currentDirectoryPath))
    let registry = ComponentRegistry(
        context: WorkspaceContext(
            root: root,
            environment: ["SWIFTC": "/definitely/unavailable/swiftc"]))
    let catalog = try registry.componentCatalog()
    let declared = Set(catalog.tasks.map(\.id))
    for selection in [
        "runtime", "tracy", "vulkan", "wayland", "core", "config", "ipc",
        "linux", "rn", "compositor", "shell", "android-runtime", "browser",
        "android", "loader", "gpu-headless",
    ] {
        #expect(
            declared.isSuperset(
                of: try catalog.roots(
                    named: .testDefault,
                    selection: selection)))
    }
    #expect(throws: (any Error).self) {
        try catalog.roots(named: .testDefault, selection: "swift-sdk")
    }

    for selection in [
        "all", "runtime", "tracy", "vulkan", "wayland", "core", "config",
        "ipc", "linux", "rn", "compositor", "shell", "android-runtime",
        "browser", "swift-sdk", "android",
    ] {
        #expect(
            declared.isSuperset(
                of: try catalog.roots(named: .build, selection: selection)))
    }
    for selection in ["loader", "gpu-headless", "gpu-drm"] {
        #expect(throws: (any Error).self) {
            try catalog.roots(named: .build, selection: selection)
        }
    }
}

@Test func gfxstreamArchitectureBuildsHaveIndependentLocks() {
    let repositoryRoot = FilePath("/workspace")
    let runtimeRoot = repositoryRoot.appending("android-runtime")
    let environment = ["PATH": "/usr/bin"]
    let builder = NativeOCIConfiguration(
        context: repositoryRoot.appending("core/build-container"),
        imageID: repositoryRoot.appending(".nucleus/native-builder/image-id"),
        ccache: repositoryRoot.appending(".nucleus/ccache"),
        swiftSDKRoot: repositoryRoot.appending(".nucleus/swift-sdks"),
        environment: environment)
    let arm64 = AndroidRuntimeColliderRecipe.buildGfxstream(
        root: runtimeRoot,
        repositoryRoot: repositoryRoot,
        environment: environment,
        target: NativeLinuxTarget(architecture: .arm64),
        builder: builder)
    let x86_64 = AndroidRuntimeColliderRecipe.buildGfxstream(
        root: runtimeRoot,
        repositoryRoot: repositoryRoot,
        environment: environment,
        target: NativeLinuxTarget(architecture: .x86_64),
        builder: builder)

    #expect(Set(arm64.locks).isDisjoint(with: Set(x86_64.locks)))
    #expect(
        arm64.locks == [
            .checkout("android-runtime-gfxstream-linux-arm64")
        ])
    #expect(
        x86_64.locks == [
            .checkout("android-runtime-gfxstream-linux-x86_64")
        ])
}

@Test func incompatibleSwiftBuildContextsUseDifferentScratchPaths() {
    let layout = WorkspaceLayout(root: FilePath("/workspace"))
    let debug = SwiftBuildContext(
        packageRoot: fixtureSwiftPackageRoot,
        configuration: .debug,
        target: .host(identity: "x86_64-linux"),
        toolchainIdentity: "swiftc@first")
    let release = SwiftBuildContext(
        packageRoot: fixtureSwiftPackageRoot,
        configuration: .release,
        target: .host(identity: "x86_64-linux"),
        toolchainIdentity: "swiftc@first")
    let otherToolchain = SwiftBuildContext(
        packageRoot: fixtureSwiftPackageRoot,
        configuration: .debug,
        target: .host(identity: "x86_64-linux"),
        toolchainIdentity: "swiftc@second")

    #expect(layout.swiftScratch(for: debug) != layout.swiftScratch(for: release))
    #expect(
        layout.swiftScratch(for: debug)
            != layout.swiftScratch(for: otherToolchain))
    #expect(layout.swiftScratch(for: debug) == layout.swiftScratch(for: debug))
}

@Test func workspaceEnvironmentDefinesOneReviewedHostCCachePolicy() {
    let context = WorkspaceContext(
        root: FilePath("/workspace"),
        environment: [
            "HOME": "/home/fixture",
            "XDG_CACHE_HOME": "/cache",
        ])

    #expect(context.taskEnvironment["CCACHE_BASEDIR"] == "/workspace")
    #expect(
        context.taskEnvironment["CCACHE_DIR"]
            == "/cache/nucleus/host-ccache")
    #expect(context.taskEnvironment["CCACHE_COMPILERCHECK"] == "content")
    #expect(context.taskEnvironment["CCACHE_MAXSIZE"] == "50G")
    #expect(
        context.taskEnvironment["CCACHE_SLOPPINESS"]
            == "include_file_ctime,include_file_mtime,locale")
}

@Test func workspaceEnvironmentRetainsEveryPackageBuildDescription() {
    let context = WorkspaceContext(
        root: FilePath("/workspace"),
        environment: ["HOME": "/home/fixture"])

    // Every workspace package plans one Swift Build description for `build` and
    // one for `test` against the shared scratch directory. Retaining fewer than
    // the workspace produces purges descriptions the same run needs again, and
    // each purge re-plans that package graph from scratch.
    let descriptions = 40
    let onDisk = context.taskEnvironment["BuildDescriptionOnDiskCacheSize"]
        .flatMap(Int.init)
    let inMemory = context.taskEnvironment["BuildDescriptionInMemoryCacheSize"]
        .flatMap(Int.init)

    #expect((onDisk ?? 0) >= descriptions)
    #expect((inMemory ?? 0) >= descriptions)
}

@Test func languageServerSharesTheWorkspaceBuildDirectory() throws {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-lsp-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    try FileManager.default.createDirectory(
        at: workspace, withIntermediateDirectories: true)
    let context = WorkspaceContext(
        root: FilePath(workspace.path),
        environment: ["HOME": "/home/fixture"])
    func invocation(_ digest: String) -> SwiftPMInvocation {
        return SwiftPMInvocation(
            context: SwiftBuildContext(
                packageRoot: fixtureSwiftPackageRoot,
                configuration: .debug,
                target: .host(identity: "x86_64-linux"),
                toolchainIdentity: "swiftc@\(digest)"),
            scratchPath: FilePath(
                workspace.appendingPathComponent(
                    ".nucleus/swiftpm/unsanitized/sha256-\(digest)"
                ).path))
    }
    func published() throws -> [String: Any] {
        let data = try Data(
            contentsOf: workspace.appendingPathComponent(
                ".sourcekit-lsp/config.json"))
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    try context.publishLanguageServerConfiguration(invocation("first"))
    let first = try published()
    let firstSwiftPM = first["swiftPM"] as! [String: Any]

    // The workspace build directory, named the way the workspace names it, so
    // the language server's builds and the workspace's builds are the same work.
    // The language server resolves a relative directory against each package it
    // finds, so the name has to be absolute to mean one directory.
    #expect(
        firstSwiftPM["scratchPath"] as? String
            == invocation("first").scratchPath.string)
    #expect((firstSwiftPM["scratchPath"] as? String)?.hasPrefix("/") == true)
    #expect(firstSwiftPM["configuration"] as? String == "debug")
    #expect(firstSwiftPM["workspacePlan"] == nil)
    #expect(first["backgroundPreparationMode"] as? String == "build")

    // Manifests that need SwiftPM's generated header directory read it from the
    // host environment, which has to name the same directory a build names.
    let shell = try String(
        contentsOf: workspace.appendingPathComponent(".nucleus/swiftpm/environment.sh"),
        encoding: .utf8)
    #expect(
        shell.contains(
            "export NUCLEUS_SWIFTPM_SCRATCH_PATH='\(invocation("first").scratchPath.string)'"))
    #expect(
        shell.contains(
            "export NUCLEUS_SWIFTPM_GENERATED_MODULE_MAPS_PATH='"
                + invocation("first").generatedModuleMaps.string + "'"))
    #expect(!shell.contains("NUCLEUS_SWIFTPM_WORKSPACE_PLAN"))

    // A build context that resolves somewhere new republishes rather than
    // leaving the language server pointed at a directory nothing maintains.
    try context.publishLanguageServerConfiguration(invocation("second"))
    #expect(
        (try published()["swiftPM"] as! [String: Any])["scratchPath"] as? String
            == invocation("second").scratchPath.string)
}

@Test func toolchainRebuildReclaimsEverySupersededSwiftBuildContext() throws {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-contexts-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let manager = FileManager.default
    let swiftPM = workspace.appendingPathComponent(
        ".nucleus/swiftpm", isDirectory: true)
    let contexts = ["unsanitized", "thread"].map {
        swiftPM.appendingPathComponent(
            "\($0)/sha256-\(String(repeating: "a", count: 64))",
            isDirectory: true)
    }
    for context in contexts {
        try manager.createDirectory(at: context, withIntermediateDirectories: true)
        try Data("stale".utf8).write(
            to: context.appendingPathComponent("build.db"))
    }
    // Only content-addressed build contexts are the rebuild's to reclaim.
    let unrelated = swiftPM.appendingPathComponent(
        "unsanitized/notes", isDirectory: true)
    try manager.createDirectory(at: unrelated, withIntermediateDirectories: true)

    let context = WorkspaceContext(
        root: FilePath(workspace.path),
        environment: ["HOME": "/home/fixture"])
    try context.reclaimSwiftBuildContexts()

    for stale in contexts {
        #expect(!manager.fileExists(atPath: stale.path))
    }
    #expect(manager.fileExists(atPath: unrelated.path))
}

@Test func releaseGatesDeclareTheLinuxARM64OCIContext() throws {
    let root = try #require(
        discoverWorkspaceRoot(from: FileManager.default.currentDirectoryPath))
    let registry = ComponentRegistry(
        context: WorkspaceContext(
            root: root,
            environment: [:]))
    let catalog = try registry.componentCatalog()
    let allTasks = catalog.tasks
    let releaseTasks = allTasks.filter {
        $0.component.rawValue == "release-gate"
    }

    #expect(
        Set(allTasks.map(\.id)).isSuperset(
            of: try catalog.roots(named: .testDefault, selection: "all")
                + catalog.roots(
                    named: .testReleaseGate,
                    selection: "release-gate")))
    #expect(releaseTasks.count == 6)
    #expect(
        releaseTasks.allSatisfy { task in
            guard task.swiftTests.count == 1,
                case .oci(let execution) =
                    task.swiftTests[0].invocation.context.execution
            else { return false }
            return execution.executionPlatform == .linuxARM64OCI
        })
}

@Test func drmSelectionResolvesTheRecipeOwnedTask() throws {
    let repositoryRoot = try #require(
        discoverWorkspaceRoot(from: FileManager.default.currentDirectoryPath))
    let root = repositoryRoot.appending("compositor/compositor-core")
    let swiftPM = SwiftPMInvocation(
        context: SwiftBuildContext(
            packageRoot: fixtureSwiftPackageRoot,
            configuration: .debug,
            target: .host(identity: "fixture-linux"),
            toolchainIdentity: "swiftc@fixture"),
        scratchPath: FilePath("/workspace/.nucleus/swiftpm/fixture"))
    let task = CompositorColliderRecipe.testDRMGPU(
        root: root,
        environment: [:],
        swiftPM: swiftPM)
    let registry = ComponentRegistry(
        context: WorkspaceContext(root: repositoryRoot, environment: [:]))

    #expect(task.id == CompositorTaskIDs.testGPUDRM)
    #expect(try registry.selectedTestTasks("gpu-drm") == [task.id])
}

@Test func drmLaneRejectsAConfiguredNonRenderNode() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-not-a-render-node-\(UUID().uuidString)")
    try Data().write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }

    #expect(throws: (any Error).self) {
        try requiredDRMRenderNode(environment: [
            "NUCLEUS_TEST_DRM_RENDER_NODE": file.path
        ])
    }
}

@Test func migratedGeneratorsInvokeComponentToolsWithoutCommandPlugins() {
    let root = FilePath("/workspace")
    let environment = ["PATH": "/usr/bin"]
    let swiftPM = SwiftPMInvocation(
        context: SwiftBuildContext(
            packageRoot: fixtureSwiftPackageRoot,
            configuration: .debug,
            target: .host(identity: "x86_64-linux"),
            toolchainIdentity: "swiftc@fixture"),
        scratchPath: root.appending(".nucleus/swiftpm/fixture"))

    let vulkan = VulkanColliderRecipe.generate(
        root: root.appending("swift-vulkan"),
        environment: environment,
        swiftPM: swiftPM)
    guard case .command(let vulkanCommand) = vulkan.operation else {
        Issue.record("Vulkan generation must be a typed command")
        return
    }
    #expect(
        vulkan.swiftProducts.map(\.qualifiedProduct) == [
            "swift-vulkan:VulkanGen"
        ])
    #expect(
        vulkanCommand.executable
            == .taskOutput(swiftPM.executable("VulkanGen")))
    #expect(
        vulkanCommand.arguments == [
            "/workspace/swift-vulkan/third-party/vk.xml",
            "/workspace/swift-vulkan/Sources/Vulkan/Vulkan.swift",
            "1",
        ])

    let reactNative = ReactNativeColliderRecipe.generate(
        root: root.appending("react-native"),
        environment: environment,
        builder: NativeOCIConfiguration(
            context: root.appending("core/build-container"),
            imageID: FilePath("/cache/native/image-id"),
            ccache: FilePath("/cache/native/ccache"),
            swiftSDKRoot: FilePath("/cache/swift-sdks"),
            environment: environment))
    guard case .runOCI(let reactNativeCommand) = reactNative.operation else {
        Issue.record("React Native generation must be a typed OCI command")
        return
    }
    #expect(
        reactNativeCommand.command == [
            "javascript",
            "/opt/node/bin/node",
            "/workspace/react-native/tools/generate-rn-spec.js",
        ])
    #expect(
        reactNativeCommand.workingDirectory
            == "/workspace/react-native/third-party/react-native")
}

@Test func waylandGenerationIsOneColliderOwnedCommandSequence() throws {
    let workspace = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let task = try WaylandColliderRecipe.generate(
        root: FilePath(workspace.appendingPathComponent("swift-wayland").path),
        environment: ["PATH": "/usr/bin"],
        swiftPM: SwiftPMInvocation(
            context: SwiftBuildContext(
                packageRoot: fixtureSwiftPackageRoot,
                configuration: .debug,
                target: .host(identity: "x86_64-linux"),
                toolchainIdentity: "swiftc@fixture"),
            scratchPath: FilePath(
                workspace.appendingPathComponent(
                    ".nucleus/swiftpm/fixture"
                ).path)),
        builder: NativeOCIConfiguration(
            context: FilePath(workspace.appendingPathComponent("core/build-container").path),
            imageID: FilePath("/cache/native/image-id"),
            ccache: FilePath("/cache/native/ccache"),
            swiftSDKRoot: FilePath("/cache/swift-sdks"),
            environment: ["PATH": "/usr/bin"]),
        scannerSDK: FilePath("/cache/native-sdk/linux-arm64/wayland"))
    guard case .sequence(let operations) = task.operation else {
        Issue.record("Wayland generation must be one ordered task sequence")
        return
    }
    let commands = operations.compactMap { operation -> CommandSpec? in
        guard case .command(let command) = operation else { return nil }
        return command
    }
    let buildCommands = commands.filter {
        $0.executable == .named("swift")
    }
    let generatorCommands = commands.filter {
        if case .taskOutput = $0.executable { return true }
        return false
    }
    let scannerContainers = operations.filter {
        guard case .runOCI(let execution) = $0 else { return false }
        return execution.hostname == "wayland-source-generation"
    }
    #expect(buildCommands.isEmpty)
    #expect(
        task.swiftProducts.map(\.qualifiedProduct) == [
            "swift-wayland:SwiftWaylandGen"
        ])
    #expect(generatorCommands.count == 2)
    #expect(scannerContainers.count == 1)
    if case .runOCI(let scanner) = scannerContainers[0] {
        #expect(scanner.command.first == "wayland-generate")
    }
    #expect(
        commands.allSatisfy {
            !$0.arguments.contains("generate-wayland")
        })
}

@Test func skiaRecipesUseTheIsolatedNativeBuilder() {
    let root = FilePath("/workspace/core")
    let environment = [
        "PATH": "/usr/bin",
        "NUCLEUS_ANDROID_NDK_HOME": "/opt/android-ndk",
    ]
    let builder = NativeOCIConfiguration(
        context: root.appending("build-container"),
        imageID: FilePath("/cache/native/image-id"),
        ccache: FilePath("/cache/ccache/native"),
        swiftSDKRoot: FilePath("/cache/swift-sdks"),
        environment: environment)
    let linuxARM64 = NativeLinuxTarget(architecture: .arm64)
    for task in [
        CoreColliderRecipe.buildSkiaLinux(
            root: root,
            environment: environment,
            target: linuxARM64,
            builder: builder),
        CoreColliderRecipe.buildSkiaAndroid(
            root: root,
            minimumAndroidAPI: 24,
            environment: environment,
            builder: builder),
    ] {
        guard case .sequence(let operations) = task.operation else {
            Issue.record("Skia provisioning must be an ordered task sequence")
            continue
        }
        let executions = operations.compactMap {
            operation -> OCIExecution? in
            guard case .runOCI(let execution) = operation else {
                return nil
            }
            return execution
        }
        #expect(executions.count == 2)
        #expect(executions.allSatisfy { $0.imageID == builder.imageID })
        #expect(
            executions.allSatisfy {
                $0.mounts.contains(
                    OCIMount(
                        source: root.appending("third-party/skia"),
                        target: "/src",
                        access: .readOnly))
            })
        #expect(
            executions.allSatisfy {
                $0.mounts.filter { $0.access == .readWrite }
                    .map(\.target).sorted() == ["/build", "/ccache"]
            })
        #expect(executions[0].command.contains("/src/bin/gn"))
        #expect(executions[1].command.contains("ninja"))
    }
}

@Test func nativeArchitectureBuildsHaveIndependentLocks() {
    let coreRoot = FilePath("/workspace/core")
    let reactNativeRoot = FilePath("/workspace/react-native")
    let environment = [
        "PATH": "/usr/bin",
        "NUCLEUS_ANDROID_NDK_HOME": "/opt/android-ndk",
    ]
    let builder = NativeOCIConfiguration(
        context: coreRoot.appending("build-container"),
        imageID: FilePath("/cache/native/image-id"),
        ccache: FilePath("/cache/ccache/native"),
        swiftSDKRoot: FilePath("/cache/swift-sdks"),
        environment: environment)
    let arm64 = NativeLinuxTarget(architecture: .arm64)
    let x86_64 = NativeLinuxTarget(architecture: .x86_64)
    let architecturePairs = [
        (
            CoreColliderRecipe.buildSkiaLinux(
                root: coreRoot,
                environment: environment,
                target: arm64,
                builder: builder),
            CoreColliderRecipe.buildSkiaLinux(
                root: coreRoot,
                environment: environment,
                target: x86_64,
                builder: builder)
        ),
        (
            ReactNativeColliderRecipe.buildHermes(
                root: reactNativeRoot,
                environment: environment,
                target: arm64,
                builder: builder),
            ReactNativeColliderRecipe.buildHermes(
                root: reactNativeRoot,
                environment: environment,
                target: x86_64,
                builder: builder)
        ),
        (
            ReactNativeColliderRecipe.buildSupportLibraries(
                root: reactNativeRoot,
                environment: environment,
                target: arm64,
                builder: builder),
            ReactNativeColliderRecipe.buildSupportLibraries(
                root: reactNativeRoot,
                environment: environment,
                target: x86_64,
                builder: builder)
        ),
        (
            ReactNativeColliderRecipe.buildCxxRuntime(
                root: reactNativeRoot,
                environment: environment,
                target: arm64,
                builder: builder),
            ReactNativeColliderRecipe.buildCxxRuntime(
                root: reactNativeRoot,
                environment: environment,
                target: x86_64,
                builder: builder)
        ),
    ]

    for (armTask, x86Task) in architecturePairs {
        #expect(Set(armTask.locks).isDisjoint(with: Set(x86Task.locks)))
    }
}

@Test func reactNativeSupportRecipesUseTheIsolatedNativeBuilder() {
    let root = FilePath("/workspace/react-native")
    let environment = ["PATH": "/usr/bin"]
    let builder = NativeOCIConfiguration(
        context: FilePath("/workspace/core/build-container"),
        imageID: FilePath("/cache/native/image-id"),
        ccache: FilePath("/cache/ccache/native"),
        swiftSDKRoot: FilePath("/cache/swift-sdks"),
        environment: environment)
    let target = NativeLinuxTarget(architecture: .arm64)
    let support = ReactNativeColliderRecipe.buildSupportLibraries(
        root: root, environment: environment, target: target, builder: builder)
    let runtime = ReactNativeColliderRecipe.buildCxxRuntime(
        root: root, environment: environment, target: target, builder: builder)
    for task in [support, runtime] {
        guard case .sequence(let operations) = task.operation else {
            Issue.record("RN native provisioning must be an ordered task sequence")
            continue
        }
        let nativeOperations = operations.compactMap {
            operation -> OCIExecution? in
            guard case .runOCI(let execution) = operation else {
                return nil
            }
            return execution
        }
        #expect(!nativeOperations.isEmpty)
        #expect(
            nativeOperations.allSatisfy {
                $0.command.first == "react-native"
                    && $0.mounts.contains(
                        OCIMount(
                            source: root,
                            target: "/src",
                            access: .readOnly))
                    && $0.mounts.contains(
                        OCIMount(
                            source: root.appending(".rn-build"),
                            target: "/build",
                            access: .readWrite))
            })
    }
    #expect(
        runtime.dependencies == [
            TaskID(rawValue: "rn.support.linux-arm64"),
            TaskID(rawValue: "rn.generate"),
            TaskID(rawValue: "rn.boost"),
            TaskID(rawValue: "rn.hermes.linux-arm64"),
        ])
}

@Test func hermesRecipeBuildsAndMergesInsideTheARM64Guest() {
    let root = FilePath("/workspace/react-native")
    let environment = ["PATH": "/usr/bin"]
    let builder = NativeOCIConfiguration(
        context: FilePath("/workspace/core/build-container"),
        imageID: FilePath("/cache/native/image-id"),
        ccache: FilePath("/cache/ccache/native"),
        swiftSDKRoot: FilePath("/cache/swift-sdks"),
        environment: environment)
    let task = ReactNativeColliderRecipe.buildHermes(
        root: root,
        environment: environment,
        target: NativeLinuxTarget(architecture: .x86_64),
        builder: builder)
    guard case .sequence(let operations) = task.operation else {
        Issue.record("Hermes provisioning must be an ordered task sequence")
        return
    }
    #expect(operations.count == 3)
    guard case .runOCI(let configure) = operations[0],
        case .runOCI(let build) = operations[1],
        case .runOCI(let merge) = operations[2]
    else {
        Issue.record("every Hermes operation must use the native builder")
        return
    }
    #expect(configure.command.first == "react-native")
    #expect(configure.command.contains("cmake"))
    #expect(build.command.contains("ninja"))
    #expect(merge.command.contains("/tools/merge-static-archives.sh"))
    let executions = [configure, build, merge]
    #expect(executions.allSatisfy { $0.executionPlatform == .linuxARM64OCI })
    #expect(executions.allSatisfy { $0.artifactTarget == .linuxX86_64 })
    #expect(
        executions.allSatisfy {
            $0.intelBinaryTranslationPolicy == .required
        })
}

@Test func waylandCrossBuildUsesTheNativeARM64ScannerSDK() {
    let root = FilePath("/workspace/swift-wayland")
    let armSDKRoot = FilePath("/cache/native-sdk/linux-arm64")
    let x86SDKRoot = FilePath("/cache/native-sdk/linux-x86_64")
    let environment = ["PATH": "/usr/bin"]
    let builder = NativeOCIConfiguration(
        context: FilePath("/workspace/core/build-container"),
        imageID: FilePath("/cache/native/image-id"),
        ccache: FilePath("/cache/ccache/native"),
        swiftSDKRoot: FilePath("/cache/swift-sdks"),
        environment: environment)
    let arm = WaylandColliderRecipe.buildNativeSDK(
        root: root,
        sdkRoot: armSDKRoot,
        environment: environment,
        target: NativeLinuxTarget(architecture: .arm64),
        builder: builder)
    let x86 = WaylandColliderRecipe.buildNativeSDK(
        root: root,
        sdkRoot: x86SDKRoot,
        environment: environment,
        target: NativeLinuxTarget(architecture: .x86_64),
        builder: builder)

    #expect(arm.dependencies == [TaskID(rawValue: "native.builder")])
    #expect(
        x86.dependencies == [
            TaskID(rawValue: "native.builder"),
            TaskID(rawValue: "wayland.native-sdk.linux-arm64"),
        ])
    #expect(
        arm.outputs.contains {
            $0.path
                == FilePath(
                    "/cache/native-sdk/linux-arm64/wayland/bin/wayland-scanner")
        })

    guard case .sequence(let armOperations) = arm.operation,
        case .runOCI(let armConfigure) = armOperations[4],
        case .sequence(let x86Operations) = x86.operation,
        case .runOCI(let x86Configure) = x86Operations[4]
    else {
        Issue.record("Wayland SDK builds must configure inside the ARM64 builder")
        return
    }

    #expect(armConfigure.executionPlatform == .linuxARM64OCI)
    #expect(armConfigure.artifactTarget == .linuxARM64)
    #expect(armConfigure.intelBinaryTranslationPolicy == .disabled)
    #expect(armConfigure.command.contains("--prefix=/native-wayland"))

    #expect(x86Configure.executionPlatform == .linuxARM64OCI)
    #expect(x86Configure.artifactTarget == .linuxX86_64)
    #expect(x86Configure.intelBinaryTranslationPolicy == .required)
    #expect(x86Configure.command.contains("--prefix=/sdk"))
    #expect(x86Configure.command.contains("--cross-file=/build-support/linux-x86_64.ini"))
    #expect(
        x86Configure.mounts.contains {
            $0.source == FilePath("/cache/native-sdk/linux-arm64/wayland")
                && $0.target == "/native-wayland"
                && $0.access == .readOnly
        })
    #expect(
        x86Configure.containerEnvironment["PKG_CONFIG_PATH_FOR_BUILD"]
            == "/native-wayland/lib/pkgconfig")
    #expect(
        x86Configure.containerEnvironment["PKG_CONFIG_LIBDIR_FOR_BUILD"]
            == "/native-wayland/lib/pkgconfig")
}

@Test func reactNativeSDKPublishesArchitectureMatchedContainerArtifacts() {
    let root = FilePath("/workspace/react-native")
    let sdkRoot = FilePath("/cache/native-sdk/linux-x86_64")
    let target = NativeLinuxTarget(architecture: .x86_64)
    let native = ReactNativeColliderRecipe.publishNativeSDK(
        root: root,
        sdkRoot: sdkRoot,
        target: target)

    #expect(
        native.dependencies == [
            TaskID(rawValue: "core.native-sdk.linux-x86_64"),
            TaskID(rawValue: "rn.cxx.linux-x86_64"),
        ])
    #expect(
        native.outputs.allSatisfy {
            $0.path.string.hasPrefix("/cache/native-sdk/linux-x86_64/rn/")
        })
}

@Test func androidImageRecipeHasIndependentArtifactBoundaries() throws {
    let workspace = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let tasks = try AndroidRuntimeColliderRecipe.aospImageTasks(
        root: FilePath(
            workspace.appendingPathComponent(
                "android-runtime"
            ).path),
        environment: ["PATH": "/usr/bin"])
    let pipelineIDs = tasks.map(\.id.rawValue).filter {
        $0.hasPrefix("android-runtime.aosp-")
    }
    #expect(
        Set(tasks.map(\.id)).isSuperset(of: [
            AndroidRuntimeTaskIDs.aospSourceLock,
            AndroidRuntimeTaskIDs.aospSource,
            AndroidRuntimeTaskIDs.aospImage,
        ]))
    #expect(
        pipelineIDs.contains(
            "android-runtime.aosp-builder-image"))
    #expect(
        pipelineIDs.suffix(5) == [
            "android-runtime.aosp-compile",
            "android-runtime.aosp-sign",
            "android-runtime.aosp-assemble-images",
            "android-runtime.aosp-validate",
            "android-runtime.aosp-image",
        ])
    let builderImage = try #require(
        tasks.first {
            $0.id.rawValue == "android-runtime.aosp-builder-image"
        })
    #expect(
        {
            guard case .prepareOCIImage = builderImage.operation else {
                return false
            }
            return true
        }())
    let operations = Array(tasks.suffix(5)).map(\.operation)
    let publication = try #require(tasks.last)
    #expect(
        publication.outputs.contains {
            $0.path.string.hasSuffix(".aosp-build/current")
        })
    #expect(
        publication.outputs.contains {
            $0.path.string.contains(".aosp-build/generations/")
                && $0.path.string.hasSuffix("/images/system.img")
        })
    #expect(
        {
            guard case .aospProduct(.compile, _) = operations[0] else {
                return false
            }
            return true
        }())
    #expect(
        {
            guard case .aospProduct(.sign, _) = operations[1] else {
                return false
            }
            return true
        }())
    #expect(
        {
            guard case .aospProduct(.assembleImages, _) = operations[2] else {
                return false
            }
            return true
        }())
    #expect(
        {
            guard case .aospProduct(.validate, _) = operations[3] else {
                return false
            }
            return true
        }())
    #expect(
        {
            guard case .aospProduct(.publish, _) = operations[4] else {
                return false
            }
            return true
        }())
}
