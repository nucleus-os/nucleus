import AndroidRuntimeColliderRecipe
import ColliderCore
import ColliderPlanning
import ColliderRuntime
import ColliderTesting
import CompositorColliderRecipe
import CoreColliderRecipe
import Foundation
import NativeBuilderColliderRecipe
import ReactNativeColliderRecipe
import ReleaseGateColliderRecipe
import SystemPackage
import Testing
import VulkanColliderRecipe
import WaylandColliderRecipe

@testable import ColliderWorkspaceCommands

private let fixtureSwiftPackageRoot = FilePath("/workspace")
private let fixtureRepositoryRoot = FilePath(
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent().path)

private func selectedTasks(
    in catalog: ComponentCatalog,
    entrypoint: ComponentEntrypointID,
    selection: String?
) throws -> [TaskID] {
    try ColliderPlanner().selectedTasks(
        in: catalog,
        requests: [
            ComponentEntrypointRequest(entrypoint: entrypoint, selection: selection)
        ])
}

private func selectedTestTasks(
    in registry: ComponentRegistry,
    selection: String?
) throws -> [TaskID] {
    let catalog = try registry.componentCatalog()
    var requests = [
        ComponentEntrypointRequest(entrypoint: .testDefault, selection: selection)
    ]
    if selection == nil || selection == "all" {
        requests.append(
            ComponentEntrypointRequest(
                spelling: "release-gate",
                entrypoint: ReleaseGateEntrypoints.test))
    }
    return try ColliderPlanner().selectedTasks(in: catalog, requests: requests)
}

@Test
func explicitHostCatalogAugmentationAloneControlsLinuxOperationExposure() throws {
    let root = try #require(
        discoverWorkspaceRoot(from: FileManager.default.currentDirectoryPath))
    let registry = ComponentRegistry(
        context: WorkspaceContext(
            root: root,
            environment: [:],
            runtime: ColliderRuntime()))
    let shellConfiguration = try registry.shellRuntimeInstallConfiguration(
        prefix: FilePath("/nucleus-runtime"),
        selection: RuntimeBuildSelection())

    let withoutLinuxOperations = try registry.componentCatalog(
        hostAugmentation: HostCatalogAugmentation.none)
    let withLinuxOperations = try registry.componentCatalog(
        hostAugmentation: .linux(
            shellConfiguration: shellConfiguration))

    let shellInstall = ComponentEntrypointRequest(
        spelling: "shell",
        entrypoint: .install)
    let tracyBootstrap = ComponentEntrypointRequest(
        spelling: "tracy",
        entrypoint: .bootstrap)
    #expect(!withoutLinuxOperations.publicEntrypoints.contains(shellInstall))
    #expect(!withoutLinuxOperations.publicEntrypoints.contains(tracyBootstrap))
    #expect(withLinuxOperations.publicEntrypoints.contains(shellInstall))
    #expect(withLinuxOperations.publicEntrypoints.contains(tracyBootstrap))
    #expect(
        !withoutLinuxOperations.routes.contains {
            $0.spelling == "tracy" && $0.requestedEntrypoint == .bootstrap
        })
    #expect(
        withLinuxOperations.routes.contains {
            $0.spelling == "tracy" && $0.requestedEntrypoint == .bootstrap
        })
}

private func fixtureNativeBuilder(
    context: FilePath,
    imageID: FilePath,
    ccache: FilePath,
    swiftSDKRoot: FilePath,
    environment: [String: String]
) throws -> NativeOCIConfiguration {
    var producer = TaskBuilder(
        id: TaskID(rawValue: "native.builder"),
        component: ComponentID(rawValue: "native"))
    let image: ArtifactReference<FileArtifact> = try producer.output(
        "image-id",
        path: imageID,
        validation: .regularFile)
    var swiftSDKProducer = TaskBuilder(
        id: TaskID(rawValue: "swift-sdk.activate-target-sdks"),
        component: ComponentID(rawValue: "swift-sdk"))
    let swiftSDK: ArtifactReference<PathArtifact> = try swiftSDKProducer.output(
        "active-sdk",
        path: swiftSDKRoot,
        validation: .symlinkTarget)
    return NativeOCIConfiguration(
        base: NativeOCIBaseConfiguration(
            context: context,
            image: image,
            ccache: ccache,
            environment: environment),
        swiftSDK: swiftSDK)
}

private func fixtureICULibrary(
    _ target: NativeLinuxTarget,
    root: FilePath = FilePath("/workspace/core")
) throws -> ArtifactReference<FileArtifact> {
    var producer = TaskBuilder(
        id: TaskID(rawValue: "core.skia.\(target.identifier)"),
        component: ComponentID(rawValue: "core"))
    return try producer.output(
        "libicu.a",
        path: root.appending(".skia-build/\(target.identifier)/libicu.a"),
        validation: .regularFile)
}

private func fixtureSkiaExternalSources(
    root: FilePath = FilePath("/workspace/core")
) throws -> ArtifactReference<DirectoryArtifact> {
    var producer = TaskBuilder(
        id: TaskID(rawValue: "core.sources"),
        component: ComponentID(rawValue: "core"))
    return try producer.output(
        "external-sources",
        path: root.appending("third-party/skia/third_party/externals"),
        validation: .nonEmptyDirectory)
}

private func fixtureReactNativeNodeModules(
    root: FilePath
) throws -> ArtifactReference<DirectoryArtifact> {
    var producer = TaskBuilder(
        id: TaskID(rawValue: "rn.javascript-dependencies"),
        component: ComponentID(rawValue: "rn"))
    return try producer.output(
        "node-modules",
        path: root.appending("third-party/react-native/node_modules"),
        validation: .nonEmptyDirectory)
}

@Test func linuxBuildLanesUseMatchingCompilerArchitectures() throws {
    let environment = ["HOME": "/tmp/nucleus-fixture"]
    let registry = ComponentRegistry(
        context: WorkspaceContext(
            root: fixtureRepositoryRoot,
            environment: environment,
            runtime: ColliderRuntime()))
    let builder = try fixtureNativeBuilder(
        context: fixtureRepositoryRoot.appending("core/build-container"),
        imageID: FilePath("/cache/native/image-id"),
        ccache: FilePath("/cache/native/ccache"),
        swiftSDKRoot: FilePath("/cache/swift-sdks"),
        environment: environment)

    let arm64 = try registry.linuxSwiftPMInvocation(
        architecture: .arm64,
        builder: builder)
    let x86_64 = try registry.linuxSwiftPMInvocation(
        architecture: .x86_64,
        builder: builder)

    guard case .oci(let armExecution) = arm64.context.execution,
        case .oci(let x86Execution) = x86_64.context.execution
    else {
        Issue.record("Linux SwiftPM builds must execute in OCI")
        return
    }
    let armWritable = armExecution.mounts.filter { $0.access == .readWrite }
        .map(\.source)
    let x86Writable = x86Execution.mounts.filter { $0.access == .readWrite }
        .map(\.source)

    #expect(
        arm64.swiftExecutable
            == .path(FilePath("/opt/swift/usr/bin/swift")))
    #expect(
        x86_64.swiftExecutable
            == .path(FilePath("/opt/swift-x86_64/usr/bin/swift")))
    #expect(
        NativeLinuxTarget(architecture: .arm64).containerSwiftSDKRoot
            .hasSuffix(
                "/aarch64-unknown-linux-gnu/"
                    + NucleusLinuxABI.sdkDirectoryName))
    #expect(
        NativeLinuxTarget(architecture: .x86_64).containerSwiftSDKRoot
            .hasSuffix(
                "/x86_64-unknown-linux-gnu/"
                    + NucleusLinuxABI.sdkDirectoryName))
    #expect(
        armExecution.mounts.contains(
            OCIMount(
                source: fixtureRepositoryRoot,
                target: fixtureRepositoryRoot.string,
                access: .readOnly)))
    #expect(armWritable.contains { arm64.scratchPath.isContained(in: $0) })
    #expect(x86Writable.contains { x86_64.scratchPath.isContained(in: $0) })
    #expect(
        armWritable.allSatisfy { armPath in
            x86Writable.allSatisfy { !$0.overlaps(armPath) }
        })
}

@Test func reactNativeDependencyInstallRejectsContainerFailure() async throws {
    let root = FilePath("/workspace/react-native")
    let task = try ReactNativeColliderRecipe.installJavaScriptDependencies(
        root: root,
        environment: ["PATH": "/usr/bin"],
        builder: try fixtureNativeBuilder(
            context: FilePath("/workspace/core/build-container"),
            imageID: FilePath("/cache/native/image-id"),
            ccache: FilePath("/cache/native/ccache"),
            swiftSDKRoot: FilePath("/cache/swift-sdks"),
            environment: ["PATH": "/usr/bin"])
    ).task
    let action = try #require(task.action)

    await #expect(throws: ActionContainerExecutorFailure.self) {
        _ = try await recordActionExecution(
            action,
            containerResult: { _ in CommandResult(status: 1) })
    }
}

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

@Test func runtimeTestSelectionsUseNativeARM64LinuxLane() throws {
    let root = try #require(
        discoverWorkspaceRoot(from: FileManager.default.currentDirectoryPath))
    let registry = ComponentRegistry(
        context: WorkspaceContext(
            root: root,
            environment: [:],
            runtime: ColliderRuntime()))
    let catalog = try registry.componentCatalog()
    let nativeTest = try #require(
        catalog.tasks.first { $0.id == TaskID(rawValue: "linux.arm64.test") })
    let nativeTestRequirement = try #require(nativeTest.swiftTests.first)
    #expect(
        nativeTestRequirement.arguments == [
            "--parallel", "--num-workers", "12", "--skip",
            "gpu(DRM|Loader|Headless)_",
        ])
    #expect(nativeTestRequirement.invocation.context.maximumParallelism == 12)
    if case .oci(let execution) = nativeTestRequirement.invocation.context.execution {
        #expect(execution.resourceLimits == .parallelBuild)
        #expect(execution.resourceLimits.cpuCount == 12)
    } else {
        Issue.record("native Linux tests must execute in the ARM64 OCI builder")
    }
    let all = try selectedTestTasks(in: registry, selection: nil).map(\.rawValue)

    #expect(
        all == [
            "linux.arm64.test",
            "test.release-gate.collection",
            "test.release-gate.compositor-transition",
            "test.release-gate.foundation-lifecycle",
            "test.release-gate.foundation-publication",
            "test.release-gate.platform-transport",
            "test.release-gate.text-editor",
        ])
    #expect(
        try selectedTestTasks(in: registry, selection: "config").map(\.rawValue) == [
            "linux.arm64.test"
        ])
    #expect(
        try selectedTestTasks(in: registry, selection: "ipc").map(\.rawValue) == [
            "linux.arm64.test"
        ])
    #expect(
        try selectedTestTasks(in: registry, selection: "compositor").map(\.rawValue) == [
            "linux.arm64.test"
        ])
    #expect(
        try selectedTestTasks(in: registry, selection: "loader").map(\.rawValue) == [
            "linux.arm64.test-loader"
        ])
    #expect(
        try selectedTestTasks(in: registry, selection: "gpu-headless").map(\.rawValue) == [
            "linux.arm64.test-gpu-headless"
        ])
    #expect(
        try selectedTestTasks(in: registry, selection: "gpu-drm").map(\.rawValue) == [
            "compositor-core.test-gpu-drm"
        ])
    #expect(throws: (any Error).self) {
        try selectedTestTasks(in: registry, selection: "unknown")
    }
}

@Test func unselectedWorkDoesNotRequireDRMHardware() throws {
    let root = try #require(
        discoverWorkspaceRoot(from: FileManager.default.currentDirectoryPath))
    let registry = ComponentRegistry(
        context: WorkspaceContext(
            root: root,
            environment: ["SWIFTC": "/definitely/unavailable/swiftc"],
            runtime: ColliderRuntime()))
    let catalog = try registry.componentCatalog()
    let declared = Set(catalog.tasks.map(\.id))
    for selection in [
        "runtime", "tracy", "vulkan", "wayland", "core", "config", "ipc",
        "linux", "rn", "compositor", "shell", "android-runtime", "browser",
        "android", "loader", "gpu-headless",
    ] {
        #expect(
            declared.isSuperset(
                of: try selectedTasks(
                    in: catalog,
                    entrypoint: .testDefault,
                    selection: selection)))
    }
    #expect(throws: (any Error).self) {
        try selectedTasks(
            in: catalog,
            entrypoint: .testDefault,
            selection: "swift-sdk")
    }

    for selection in [
        "all", "runtime", "tracy", "vulkan", "wayland", "core", "config",
        "ipc", "linux", "rn", "compositor", "shell", "android-runtime",
        "browser", "swift-sdk", "android",
    ] {
        #expect(
            declared.isSuperset(
                of: try selectedTasks(
                    in: catalog,
                    entrypoint: .build,
                    selection: selection)))
    }
    for selection in ["loader", "gpu-headless", "gpu-drm"] {
        #expect(throws: (any Error).self) {
            try selectedTasks(
                in: catalog,
                entrypoint: .build,
                selection: selection)
        }
    }
}

@Test func gfxstreamArchitectureBuildsHaveIndependentLocks() throws {
    let repositoryRoot = FilePath("/workspace")
    let runtimeRoot = repositoryRoot.appending("android-runtime")
    let environment = ["PATH": "/usr/bin"]
    let builder = try fixtureNativeBuilder(
        context: repositoryRoot.appending("core/build-container"),
        imageID: repositoryRoot.appending(".nucleus/native-builder/image-id"),
        ccache: repositoryRoot.appending(".nucleus/ccache"),
        swiftSDKRoot: repositoryRoot.appending(".nucleus/swift-sdks"),
        environment: environment)
    let arm64 = try AndroidRuntimeColliderRecipe.buildGfxstream(
        root: runtimeRoot,
        repositoryRoot: repositoryRoot,
        environment: environment,
        target: NativeLinuxTarget(architecture: .arm64),
        builder: builder
    ).task
    let x8664 = try AndroidRuntimeColliderRecipe.buildGfxstream(
        root: runtimeRoot,
        repositoryRoot: repositoryRoot,
        environment: environment,
        target: NativeLinuxTarget(architecture: .x86_64),
        builder: builder
    ).task

    #expect(Set(arm64.locks).isDisjoint(with: Set(x8664.locks)))
    #expect(
        arm64.locks == [
            .checkout("android-runtime-gfxstream-linux-arm64")
        ])
    #expect(
        x8664.locks == [
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
    let otherJobCount = SwiftBuildContext(
        packageRoot: fixtureSwiftPackageRoot,
        configuration: .debug,
        target: .host(identity: "x86_64-linux"),
        toolchainIdentity: "swiftc@first",
        maximumParallelism: 4)

    #expect(layout.swiftScratch(for: debug) != layout.swiftScratch(for: release))
    #expect(
        layout.swiftScratch(for: debug)
            != layout.swiftScratch(for: otherToolchain))
    #expect(
        layout.swiftScratch(for: debug)
            == layout.swiftScratch(for: otherJobCount))
    #expect(layout.swiftScratch(for: debug) == layout.swiftScratch(for: debug))
}

@Test func hostScratchIdentityFollowsCompilerInsteadOfTargetSDKSource() throws {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-host-swift-identity-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    try FileManager.default.createDirectory(
        at: workspace, withIntermediateDirectories: true)
    try Data("// swift-tools-version: 6.4\n".utf8).write(
        to: workspace.appendingPathComponent("Package.swift"))
    let firstCompiler = workspace.appendingPathComponent("first-swiftc")
    let secondCompiler = workspace.appendingPathComponent("second-swiftc")
    try Data("first compiler".utf8).write(to: firstCompiler)
    try Data("second compiler".utf8).write(to: secondCompiler)

    func invocation(sourceID: String, compiler: URL) throws -> SwiftPMInvocation {
        try WorkspaceContext(
            root: FilePath(workspace.path),
            environment: [
                "HOME": workspace.path,
                "NUCLEUS_SWIFT_SOURCE_ID": sourceID,
                "SWIFTC": compiler.path,
            ],
            runtime: ColliderRuntime()
        ).swiftPMInvocation()
    }

    let first = try invocation(sourceID: "target-source-a", compiler: firstCompiler)
    let changedSource = try invocation(
        sourceID: "target-source-b", compiler: firstCompiler)
    let changedCompiler = try invocation(
        sourceID: "target-source-a", compiler: secondCompiler)

    #expect(first.scratchPath == changedSource.scratchPath)
    #expect(first.context.identityBytes == changedSource.context.identityBytes)
    #expect(first.scratchPath != changedCompiler.scratchPath)
    #expect(first.context.identityBytes != changedCompiler.context.identityBytes)
}

@Test func workspaceEnvironmentDefinesOneReviewedHostCCachePolicy() {
    let context = WorkspaceContext(
        root: FilePath("/workspace"),
        environment: [
            "HOME": "/home/fixture",
            "XDG_CACHE_HOME": "/cache",
        ],
        runtime: ColliderRuntime())

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

@Test func workspacePolicyOwnsCacheNamespaceAndRunEnvironment() {
    let context = WorkspaceContext(
        root: FilePath("/workspace"),
        environment: [
            "HOME": "/home/fixture",
            "XDG_CACHE_HOME": "/cache",
            "NUCLEUS_RUN_DIR": "/runs/current",
            "NUCLEUS_RUN_LOG": "/runs/current/run.log",
        ],
        runtime: ColliderRuntime())

    #expect(context.cacheRoot == FilePath("/cache"))
    #expect(
        nucleusCacheLayout(environment: context.environment).downloads
            == FilePath("/cache/nucleus/downloads"))
    #expect(context.taskEnvironment["NUCLEUS_RUN_DIR"] == nil)
    #expect(context.taskEnvironment["NUCLEUS_RUN_LOG"] == nil)
    #expect(context.environment["NUCLEUS_RUN_DIR"] == "/runs/current")
}

@Test func workspaceEnvironmentRetainsEveryPackageBuildDescription() {
    let context = WorkspaceContext(
        root: FilePath("/workspace"),
        environment: ["HOME": "/home/fixture"],
        runtime: ColliderRuntime())

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
        environment: ["HOME": "/home/fixture"],
        runtime: ColliderRuntime())
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
        environment: ["HOME": "/home/fixture"],
        runtime: ColliderRuntime())
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
            environment: [:],
            runtime: ColliderRuntime()))
    let catalog = try registry.componentCatalog()
    let allTasks = catalog.tasks
    let releaseTasks = allTasks.filter {
        $0.component.rawValue == "release-gate"
    }

    #expect(
        Set(allTasks.map(\.id)).isSuperset(
            of: try selectedTasks(
                in: catalog,
                entrypoint: .testDefault,
                selection: "all")
                + selectedTasks(
                    in: catalog,
                    entrypoint: ReleaseGateEntrypoints.test,
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
        context: WorkspaceContext(
            root: repositoryRoot,
            environment: [:],
            runtime: ColliderRuntime()))

    #expect(task.id == CompositorTaskIDs.testGPUDRM)
    #expect(try selectedTestTasks(in: registry, selection: "gpu-drm") == [task.id])
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

@Test func migratedGeneratorsInvokeComponentToolsWithoutCommandPlugins() async throws {
    let root = FilePath("/workspace")
    let environment = ["PATH": "/usr/bin"]
    let swiftPM = SwiftPMInvocation(
        context: SwiftBuildContext(
            packageRoot: fixtureSwiftPackageRoot,
            configuration: .debug,
            target: .host(identity: "x86_64-linux"),
            toolchainIdentity: "swiftc@fixture"),
        scratchPath: root.appending(".nucleus/swiftpm/fixture"))

    let vulkan = try VulkanColliderRecipe.generate(
        root: root.appending("swift-vulkan"),
        environment: environment,
        swiftPM: swiftPM)
    guard let vulkanAction = vulkan.task.action else {
        Issue.record("Vulkan generation must be a recipe-owned action")
        return
    }
    #expect(
        vulkan.tasks.flatMap(\.swiftProducts).map(\.qualifiedProduct) == [
            "swift-vulkan:VulkanGen"
        ])
    #expect(vulkan.task.assessmentPolicy == .incremental)
    #expect(
        vulkanAction.kind == ActionKind(rawValue: "vulkan.generate-bindings"))
    let vulkanTools = vulkanAction.requirements.tools
    #expect(vulkanTools.count == 1)
    let vulkanTool = try #require(vulkanTools.first)
    #expect(vulkanTool.name == "vulkan-generator")
    #expect(vulkanTool.role == .semantic)
    guard case .artifact = vulkanTool.executable else {
        Issue.record("Vulkan generator must be a typed artifact executable")
        return
    }

    let reactNative = try ReactNativeColliderRecipe.generate(
        root: root.appending("react-native"),
        environment: environment,
        dependencies: fixtureReactNativeNodeModules(
            root: root.appending("react-native")),
        builder: try fixtureNativeBuilder(
            context: root.appending("core/build-container"),
            imageID: FilePath("/cache/native/image-id"),
            ccache: FilePath("/cache/native/ccache"),
            swiftSDKRoot: FilePath("/cache/swift-sdks"),
            environment: environment)
    ).task
    guard let reactNativeCommand = try await ociExecutions(in: reactNative.action).first else {
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

@Test func waylandGenerationIsOneColliderOwnedAction() async throws {
    let workspace = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let root = FilePath(workspace.appendingPathComponent("swift-wayland").path)
    let builder = try fixtureNativeBuilder(
        context: FilePath(workspace.appendingPathComponent("core/build-container").path),
        imageID: FilePath("/cache/native/image-id"),
        ccache: FilePath("/cache/native/ccache"),
        swiftSDKRoot: FilePath("/cache/swift-sdks"),
        environment: ["PATH": "/usr/bin"])
    let nativeSDK = try WaylandColliderRecipe.buildNativeSDK(
        root: root,
        sdkRoot: FilePath("/cache/native-sdk/linux-arm64"),
        environment: ["PATH": "/usr/bin"],
        target: NativeLinuxTarget(architecture: .arm64),
        nativeScanner: nil,
        builder: builder)
    let scanner = try #require(nativeSDK.scanner)
    let generation = try WaylandColliderRecipe.generate(
        root: root,
        environment: ["PATH": "/usr/bin"],
        swiftPM: SwiftPMInvocation(
            context: SwiftBuildContext(
                packageRoot: fixtureSwiftPackageRoot,
                configuration: .debug,
                target: .swiftSDK(
                    name: "nucleus-swift-6.4-linux",
                    targetTriple: "aarch64-unknown-linux-gnu"),
                toolchainIdentity: "swiftc@fixture",
                execution: .oci(
                    SwiftPMOCIExecution(
                        executionPlatform: .linuxARM64OCI,
                        artifactTarget: .linuxARM64,
                        image: builder.image,
                        hostname: "swift-wayland-fixture",
                        hostWorkingDirectory: root,
                        mounts: []))),
            scratchPath: FilePath(
                workspace.appendingPathComponent(
                    ".nucleus/swiftpm/fixture"
                ).path)),
        builder: builder,
        scanner: scanner)
    let task = generation.task
    guard let action = task.action else {
        Issue.record("Wayland generation must be one recipe-owned action")
        return
    }
    let generationContainers = try await ociExecutions(in: task.action).filter {
        $0.hostname == "wayland-source-generation"
    }
    #expect(
        generation.tasks.flatMap(\.swiftProducts).map(\.qualifiedProduct) == [
            "swift-wayland:SwiftWaylandGen"
        ])
    #expect(task.swiftProducts.isEmpty)
    #expect(task.assessmentPolicy == .incremental)
    #expect(
        action.kind == ActionKind(rawValue: "wayland.generate-swift-sources"))
    #expect(generationContainers.count == 3)
    #expect(
        generationContainers.allSatisfy {
            $0.command.first == "wayland-generate"
        })
    #expect(
        action.requirements.tools.map(\.role) == [.semantic, .semantic])
    #expect(
        action.requirements.tools.allSatisfy {
            if case .artifact = $0.executable { true } else { false }
        })
}

@Test func skiaRecipesUseTheIsolatedNativeBuilder() async throws {
    let root = fixtureRepositoryRoot.appending("core")
    let environment = [
        "PATH": "/usr/bin",
        "NUCLEUS_ANDROID_NDK_HOME": "/opt/android-ndk",
    ]
    let builder = try fixtureNativeBuilder(
        context: root.appending("build-container"),
        imageID: FilePath("/cache/native/image-id"),
        ccache: FilePath("/cache/ccache/native"),
        swiftSDKRoot: FilePath("/cache/swift-sdks"),
        environment: environment)
    let linuxARM64 = NativeLinuxTarget(architecture: .arm64)
    let sources = try CoreColliderRecipe.prepareSkiaDependencies(
        root: root,
        environment: environment,
        builder: builder.base)
    let sourceTask = try #require(
        sources.tasks.first { $0.id == CoreTaskIDs.sources })
    guard let sourceAction = sourceTask.action else {
        Issue.record("Skia source preparation must be a recipe-owned action")
        return
    }
    #expect(sourceAction.kind == "core.materialize-skia-dependencies")
    let gnInstall = try #require(
        sources.tasks.first { $0.id == CoreTaskIDs.gnInstall })
    guard let gnAction = gnInstall.action else {
        Issue.record("GN installation must be a recipe-owned action")
        return
    }
    #expect(gnAction.kind == "core.install-skia-gn")
    #expect(
        Set(gnInstall.dependencies) == [
            CoreTaskIDs.gnDownload,
            TaskID(rawValue: "native.builder"),
        ])
    #expect(gnInstall.assessmentPolicy == .incremental)
    let gnExecutions = try await ociExecutions(in: gnInstall.action)
    #expect(gnExecutions.count == 1)
    #expect(gnExecutions[0].command == ["extract-gn"])
    #expect(gnExecutions[0].executionPlatform == .linuxARM64OCI)
    #expect(gnExecutions[0].artifactTarget == .linuxARM64)
    for task in [
        try CoreColliderRecipe.buildSkiaLinux(
            root: root,
            environment: environment,
            target: linuxARM64,
            sources: sources,
            builder: builder
        ).task,
        try CoreColliderRecipe.buildSkiaAndroid(
            root: root,
            minimumAndroidAPI: 24,
            environment: environment,
            sources: sources,
            builder: builder
        ).task,
    ] {
        guard let action = task.action else {
            Issue.record("Skia provisioning must be a recipe-owned action")
            continue
        }
        #expect(action.kind == "core.build-skia")
        let executions = try await ociExecutions(in: task.action)
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
                let writableTargets = $0.mounts.filter { $0.access == .readWrite }
                    .map(\.target)
                return writableTargets.contains("/ccache")
                    && writableTargets.contains("/build")
            })
        #expect(executions[0].command.contains("/src/bin/gn"))
        #expect(executions[1].command.contains("ninja"))
    }
}

@Test func nativeArchitectureBuildsHaveIndependentWritableState() async throws {
    let coreRoot = fixtureRepositoryRoot.appending("core")
    let reactNativeRoot = FilePath("/workspace/react-native")
    let environment = [
        "PATH": "/usr/bin",
        "NUCLEUS_ANDROID_NDK_HOME": "/opt/android-ndk",
    ]
    let builder = try fixtureNativeBuilder(
        context: coreRoot.appending("build-container"),
        imageID: FilePath("/cache/native/image-id"),
        ccache: FilePath("/cache/ccache/native"),
        swiftSDKRoot: FilePath("/cache/swift-sdks"),
        environment: environment)
    let arm64 = NativeLinuxTarget(architecture: .arm64)
    let x8664 = NativeLinuxTarget(architecture: .x86_64)
    let skiaSources = try CoreColliderRecipe.prepareSkiaDependencies(
        root: coreRoot,
        environment: environment,
        builder: builder.base)
    let boost = try ReactNativeColliderRecipe.provisionBoost(
        root: reactNativeRoot,
        environment: environment
    ).active
    let generated = try ReactNativeColliderRecipe.generate(
        root: reactNativeRoot,
        environment: environment,
        dependencies: fixtureReactNativeNodeModules(root: reactNativeRoot),
        builder: builder
    ).spec
    let armHermes = try ReactNativeColliderRecipe.buildHermes(
        root: reactNativeRoot,
        environment: environment,
        target: arm64,
        skiaExternalSources: skiaSources.externalSources,
        icuLibrary: fixtureICULibrary(arm64, root: coreRoot),
        builder: builder)
    let x86Hermes = try ReactNativeColliderRecipe.buildHermes(
        root: reactNativeRoot,
        environment: environment,
        target: x8664,
        skiaExternalSources: skiaSources.externalSources,
        icuLibrary: fixtureICULibrary(x8664, root: coreRoot),
        builder: builder)
    let armSupport = try ReactNativeColliderRecipe.buildSupportLibraries(
        root: reactNativeRoot,
        environment: environment,
        target: arm64,
        builder: builder)
    let x86Support = try ReactNativeColliderRecipe.buildSupportLibraries(
        root: reactNativeRoot,
        environment: environment,
        target: x8664,
        builder: builder)
    let architecturePairs = [
        (
            try CoreColliderRecipe.buildSkiaLinux(
                root: coreRoot,
                environment: environment,
                target: arm64,
                sources: skiaSources,
                builder: builder
            ).task,
            try CoreColliderRecipe.buildSkiaLinux(
                root: coreRoot,
                environment: environment,
                target: x8664,
                sources: skiaSources,
                builder: builder
            ).task
        ),
        (armHermes.task, x86Hermes.task),
        (armSupport.task, x86Support.task),
        (
            try ReactNativeColliderRecipe.buildCxxRuntime(
                root: reactNativeRoot,
                environment: environment,
                target: arm64,
                boost: boost,
                generated: generated,
                hermes: armHermes,
                support: armSupport,
                builder: builder
            ).task,
            try ReactNativeColliderRecipe.buildCxxRuntime(
                root: reactNativeRoot,
                environment: environment,
                target: x8664,
                boost: boost,
                generated: generated,
                hermes: x86Hermes,
                support: x86Support,
                builder: builder
            ).task
        ),
    ]

    for (armTask, x86Task) in architecturePairs {
        #expect(Set(armTask.locks).isDisjoint(with: Set(x86Task.locks)))
        let armWritable = try await ociExecutions(in: armTask.action).flatMap {
            $0.mounts.filter { $0.access == .readWrite }.map(\.source)
        }
        let x86Writable = try await ociExecutions(in: x86Task.action).flatMap {
            $0.mounts.filter { $0.access == .readWrite }.map(\.source)
        }
        #expect(
            armWritable.allSatisfy { armPath in
                x86Writable.allSatisfy { !$0.overlaps(armPath) }
            })
    }
}

@Test func reactNativeSupportRecipesUseTheIsolatedNativeBuilder() async throws {
    let root = FilePath("/workspace/react-native")
    let environment = ["PATH": "/usr/bin"]
    let builder = try fixtureNativeBuilder(
        context: FilePath("/workspace/core/build-container"),
        imageID: FilePath("/cache/native/image-id"),
        ccache: FilePath("/cache/ccache/native"),
        swiftSDKRoot: FilePath("/cache/swift-sdks"),
        environment: environment)
    let target = NativeLinuxTarget(architecture: .arm64)
    let boost = try ReactNativeColliderRecipe.provisionBoost(
        root: root,
        environment: environment
    ).active
    let generated = try ReactNativeColliderRecipe.generate(
        root: root,
        environment: environment,
        dependencies: fixtureReactNativeNodeModules(root: root),
        builder: builder
    ).spec
    let hermes = try ReactNativeColliderRecipe.buildHermes(
        root: root,
        environment: environment,
        target: target,
        skiaExternalSources: fixtureSkiaExternalSources(),
        icuLibrary: fixtureICULibrary(target),
        builder: builder)
    let support = try ReactNativeColliderRecipe.buildSupportLibraries(
        root: root, environment: environment, target: target, builder: builder)
    let runtime = try ReactNativeColliderRecipe.buildCxxRuntime(
        root: root,
        environment: environment,
        target: target,
        boost: boost,
        generated: generated,
        hermes: hermes,
        support: support,
        builder: builder)
    for task in [support.task, runtime.task] {
        guard let action = task.action else {
            Issue.record("RN native provisioning must be a recipe-owned action")
            continue
        }
        #expect(action.kind == "rn.run-native-build")
        let nativeOperations = try await ociExecutions(in: task.action)
        #expect(!nativeOperations.isEmpty)
        #expect(
            nativeOperations.allSatisfy {
                $0.command.first == "react-native"
                    && $0.mounts.contains(
                        OCIMount(
                            source: root.appending("third-party"),
                            target: "/src",
                            access: .readOnly))
                    && $0.mounts.contains(
                        OCIMount(
                            source: root.appending(".rn-build/linux-arm64"),
                            target: "/build",
                            access: .readWrite))
            })
    }
    #expect(
        Set(runtime.task.dependencies) == [
            TaskID(rawValue: "native.builder"),
            TaskID(rawValue: "rn.support.linux-arm64"),
            TaskID(rawValue: "rn.generate"),
            TaskID(rawValue: "rn.boost"),
            TaskID(rawValue: "rn.hermes.linux-arm64"),
            TaskID(rawValue: "swift-sdk.activate-target-sdks"),
        ])
}

@Test func hermesRecipeBuildsAndMergesInsideTheARM64Guest() async throws {
    let root = FilePath("/workspace/react-native")
    let environment = ["PATH": "/usr/bin"]
    let builder = try fixtureNativeBuilder(
        context: FilePath("/workspace/core/build-container"),
        imageID: FilePath("/cache/native/image-id"),
        ccache: FilePath("/cache/ccache/native"),
        swiftSDKRoot: FilePath("/cache/swift-sdks"),
        environment: environment)
    let task = try ReactNativeColliderRecipe.buildHermes(
        root: root,
        environment: environment,
        target: NativeLinuxTarget(architecture: .x86_64),
        skiaExternalSources: fixtureSkiaExternalSources(),
        icuLibrary: fixtureICULibrary(
            NativeLinuxTarget(architecture: .x86_64)),
        builder: builder
    ).task
    guard let action = task.action else {
        Issue.record("Hermes provisioning must be a recipe-owned action")
        return
    }
    #expect(action.kind == "rn.run-native-build")
    let executions = try await ociExecutions(in: task.action)
    try #require(executions.count == 3)
    let configure = executions[0]
    let build = executions[1]
    let merge = executions[2]
    #expect(configure.command.first == "react-native")
    #expect(configure.command.contains("cmake"))
    #expect(
        configure.command.contains(
            "-DJSI_DIR=/src/react-native/packages/react-native/ReactCommon/jsi"
        ))
    #expect(
        task.inputs.contains(
            .tree(
                root.appending(
                    "third-party/react-native/packages/react-native/ReactCommon/jsi"
                ))))
    #expect(build.command.contains("ninja"))
    #expect(merge.command.contains("/tools/merge-static-archives.sh"))
    #expect(executions.allSatisfy { $0.executionPlatform == .linuxARM64OCI })
    #expect(executions.allSatisfy { $0.artifactTarget == .linuxX86_64 })
    #expect(
        task.dependencies.contains(
            TaskID(rawValue: "core.skia.linux-x86_64")))
    #expect(
        executions.allSatisfy {
            $0.intelBinaryTranslationPolicy == .required
        })
}

@Test func waylandCrossBuildUsesTheNativeARM64ScannerSDK() async throws {
    let root = FilePath("/workspace/swift-wayland")
    let armSDKRoot = FilePath("/cache/native-sdk/linux-arm64")
    let x86SDKRoot = FilePath("/cache/native-sdk/linux-x86_64")
    let environment = ["PATH": "/usr/bin"]
    let builder = try fixtureNativeBuilder(
        context: FilePath("/workspace/core/build-container"),
        imageID: FilePath("/cache/native/image-id"),
        ccache: FilePath("/cache/ccache/native"),
        swiftSDKRoot: FilePath("/cache/swift-sdks"),
        environment: environment)
    let armArtifacts = try WaylandColliderRecipe.buildNativeSDK(
        root: root,
        sdkRoot: armSDKRoot,
        environment: environment,
        target: NativeLinuxTarget(architecture: .arm64),
        nativeScanner: nil,
        builder: builder)
    let scanner = try #require(armArtifacts.scanner)
    let x86Artifacts = try WaylandColliderRecipe.buildNativeSDK(
        root: root,
        sdkRoot: x86SDKRoot,
        environment: environment,
        target: NativeLinuxTarget(architecture: .x86_64),
        nativeScanner: scanner,
        builder: builder)
    let arm = armArtifacts.task
    let x86 = x86Artifacts.task

    #expect(
        Set(arm.dependencies) == [
            TaskID(rawValue: "native.builder"),
            TaskID(rawValue: "swift-sdk.activate-target-sdks"),
        ])
    #expect(
        Set(x86.dependencies) == [
            TaskID(rawValue: "native.builder"),
            TaskID(rawValue: "swift-sdk.activate-target-sdks"),
            TaskID(rawValue: "wayland.native-sdk.linux-arm64"),
        ])
    #expect(
        arm.outputs.contains {
            $0.path
                == FilePath(
                    "/cache/native-sdk/linux-arm64/wayland/bin/wayland-scanner")
        })

    guard let armAction = arm.action,
        let x86Action = x86.action
    else {
        Issue.record("Wayland SDK builds must configure inside the ARM64 builder")
        return
    }
    #expect(armAction.kind == "wayland.build-native-sdk")
    #expect(x86Action.kind == "wayland.build-native-sdk")
    let armConfigure = try #require(
        try await ociExecutions(in: arm.action).first {
            $0.command.starts(with: ["wayland", "meson", "setup"])
        })
    let x86Configure = try #require(
        try await ociExecutions(in: x86.action).first {
            $0.command.starts(with: ["wayland", "meson", "setup"])
        })

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

@Test func reactNativeSDKPublishesArchitectureMatchedContainerArtifacts() throws {
    let root = FilePath("/workspace/react-native")
    let sdkRoot = FilePath("/cache/native-sdk/linux-x86_64")
    let target = NativeLinuxTarget(architecture: .x86_64)
    let environment = ["PATH": "/usr/bin"]
    let builder = try fixtureNativeBuilder(
        context: FilePath("/workspace/core/build-container"),
        imageID: FilePath("/cache/native/image-id"),
        ccache: FilePath("/cache/ccache/native"),
        swiftSDKRoot: FilePath("/cache/swift-sdks"),
        environment: environment)
    let boost = try ReactNativeColliderRecipe.provisionBoost(
        root: root,
        environment: environment
    ).active
    let generated = try ReactNativeColliderRecipe.generate(
        root: root,
        environment: environment,
        dependencies: fixtureReactNativeNodeModules(root: root),
        builder: builder
    ).spec
    let hermes = try ReactNativeColliderRecipe.buildHermes(
        root: root,
        environment: environment,
        target: target,
        skiaExternalSources: fixtureSkiaExternalSources(),
        icuLibrary: fixtureICULibrary(target),
        builder: builder)
    let support = try ReactNativeColliderRecipe.buildSupportLibraries(
        root: root,
        environment: environment,
        target: target,
        builder: builder)
    let runtime = try ReactNativeColliderRecipe.buildCxxRuntime(
        root: root,
        environment: environment,
        target: target,
        boost: boost,
        generated: generated,
        hermes: hermes,
        support: support,
        builder: builder)
    let nativeArtifacts = try ReactNativeColliderRecipe.publishNativeSDK(
        root: root,
        sdkRoot: sdkRoot,
        target: target,
        runtime: runtime)
    let native = nativeArtifacts.task

    #expect(
        Set(native.dependencies) == [
            TaskID(rawValue: "rn.cxx.linux-x86_64")
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
        cacheRoot: FilePath("/cache"),
        environment: ["PATH": "/usr/bin"]
    ).tasks
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
            guard let action = builderImage.action else {
                return false
            }
            return action.kind == "android-runtime.prepare-aosp-builder-image"
        }())
    let operations = Array(tasks.suffix(5)).map(\.action)
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
            guard let action = operations[0] else {
                return false
            }
            return action.kind == "android-runtime.compile-aosp-product"
        }())
    #expect(
        {
            guard let action = operations[1] else {
                return false
            }
            return action.kind == "android-runtime.sign-aosp-product"
        }())
    #expect(
        {
            guard let action = operations[2] else {
                return false
            }
            return action.kind == "android-runtime.assemble-aosp-product-images"
        }())
    #expect(
        {
            guard let action = operations[3] else {
                return false
            }
            return action.kind == "android-runtime.validate-aosp-product"
        }())
    #expect(
        {
            guard let action = operations[4] else {
                return false
            }
            return action.kind == "android-runtime.publish-aosp-product"
        }())
}
