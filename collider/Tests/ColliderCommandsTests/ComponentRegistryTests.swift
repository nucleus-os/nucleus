import AndroidRuntimeColliderRecipe
import ColliderCore
import CoreColliderRecipe
import Foundation
import ReactNativeColliderRecipe
import SystemPackage
import Testing
import TracyColliderRecipe
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

    let versions = try AndroidToolchainVersions.load(workspaceRoot: workspace)

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
        ]).standardizedFileURL.path == ndk.standardizedFileURL.path)
}

@Test func componentTestSelectionPreservesTheRepositoryOrder() throws {
    let registry = ComponentRegistry(
        context: WorkspaceContext(
            root: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            environment: [:]))

    #expect(
        try registry.selectedTestTasks(nil).map(\.rawValue) == [
            "tracy.test", "vulkan.test", "wayland.test", "core.test",
            "config.test", "ipc.test",
            "linux.test", "rn.test", "compositor-core.test",
            "compositor-core.test-loader",
            "compositor-core.test-gpu-headless",
            "compositor.test", "shell.test", "android-runtime.test",
        ])
    #expect(
        try registry.selectedTestTasks(.config).map(\.rawValue) == [
            "config.test"
        ])
    #expect(
        try registry.selectedTestTasks(.ipc).map(\.rawValue) == [
            "ipc.test"
        ])
    #expect(
        try registry.selectedTestTasks(.compositor).map(\.rawValue) == [
            "compositor-core.test", "compositor-core.test-loader",
            "compositor-core.test-gpu-headless", "compositor.test",
        ])
    #expect(
        try registry.selectedTestTasks(.loader).map(\.rawValue) == [
            "compositor-core.test-loader"
        ])
    #expect(
        try registry.selectedTestTasks(.gpuHeadless).map(\.rawValue) == [
            "compositor-core.test-gpu-headless"
        ])
    #expect(
        try registry.selectedTestTasks(.gpuDRM).map(\.rawValue) == [
            "compositor-core.test-gpu-drm"
        ])
    #expect(throws: (any Error).self) {
        try ColliderCommand.parseAsRoot(["test", "unknown"])
    }
}

@Test func compatibleSwiftTasksShareOneDeclaredBuildContext() {
    let root = FilePath("/workspace")
    let environment = ["PATH": "/toolchain/bin"]
    let context = SwiftBuildContext(
        packageRoot: fixtureSwiftPackageRoot,
        configuration: .debug,
        target: .host(identity: "x86_64-linux"),
        toolchainIdentity: "/toolchain/bin/swiftc@fixture")
    let scratch = root.appending(".nucleus/swiftpm/fixture")
    let swiftPM = SwiftPMInvocation(
        context: context,
        scratchPath: scratch)

    let tasks = [
        TracyColliderRecipe.build(
            root: root.appending("swift-tracy"),
            environment: environment,
            swiftPM: swiftPM),
        CoreColliderRecipe.build(
            root: root.appending("core"),
            environment: environment,
            swiftPM: swiftPM),
    ]

    for task in tasks {
        #expect(task.inputs.contains(swiftPM.identityInput))
        #expect(task.outputs.isEmpty)
        #expect(task.postconditions == [swiftPM.postcondition])
        #expect(!task.locks.contains(swiftPM.lock))
        #expect(task.swiftProducts.count == 1)
        #expect(task.swiftProducts[0].invocation == swiftPM)
        #expect(task.operation == .sequence([]))
    }
}

@Test func incompatibleSwiftBuildContextsUseDifferentScratchPaths() {
    let layout = WorkspaceLayout(root: URL(fileURLWithPath: "/workspace"))
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
        root: URL(fileURLWithPath: "/workspace"),
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
        root: URL(fileURLWithPath: "/workspace"),
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
        root: workspace,
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
        root: workspace,
        environment: ["HOME": "/home/fixture"])
    try context.reclaimSwiftBuildContexts()

    for stale in contexts {
        #expect(!manager.fileExists(atPath: stale.path))
    }
    #expect(manager.fileExists(atPath: unrelated.path))
}

@Test func reactNativeBuildProducesTheSwiftHeaderBeforeCompilingTheHost() {
    let root = FilePath("/workspace/react-native")
    let scratch = FilePath("/workspace/.nucleus/swiftpm/fixture")
    let swiftPM = SwiftPMInvocation(
        context: SwiftBuildContext(
            packageRoot: fixtureSwiftPackageRoot,
            configuration: .debug,
            target: .host(identity: "x86_64-linux"),
            toolchainIdentity: "swiftc@fixture"),
        scratchPath: scratch)

    let task = ReactNativeColliderRecipe.build(
        root: root,
        environment: ["PATH": "/usr/bin"],
        swiftPM: swiftPM)

    #expect(task.operation == .sequence([]))
    #expect(
        task.swiftProducts.map(\.qualifiedProduct) == [
            "react-native:NucleusReactRuntime"
        ])
    #expect(
        task.postconditions.contains(
            PathPostcondition(
                path: swiftPM.generatedSwiftHeader("NucleusReactRuntimeCxx"),
                validation: .regularFile)))
}

@Test func lavapipeArtifactStagesAnAbsoluteValidatedICDManifest() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-lavapipe-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let library = directory.appendingPathComponent("libvulkan_lvp.so")
    try Data("fixture".utf8).write(to: library)
    let manifest = directory.appendingPathComponent("lvp_icd.json")
    try Data(
        """
        {
          "file_format_version": "1.0.0",
          "ICD": {
            "api_version": "1.3.0",
            "library_path": "\(library.path)"
          }
        }
        """.utf8
    ).write(to: manifest)

    let artifact = try LavapipeTestArtifact.resolve(
        context: WorkspaceContext(
            root: directory,
            environment: [
                "NUCLEUS_LAVAPIPE_ICD": manifest.path,
                "XDG_CACHE_HOME": directory.appendingPathComponent("cache").path,
            ]))
    #expect(artifact.sourceManifest == FilePath(manifest.path))
    #expect(artifact.library == FilePath(library.path))
    #expect(
        artifact.stagedManifest
            == FilePath(
                directory.appendingPathComponent(
                    "cache/nucleus/test-vulkan/lavapipe_icd.json"
                ).path))
    let staged = String(decoding: artifact.stagedBytes, as: UTF8.self)
    #expect(staged.contains(#""library_path" : "\#(library.path)""#))
    #expect(artifact.task.id == TaskID(rawValue: "workspace.lavapipe-icd"))
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
        environment: environment)
    guard case .command(let reactNativeCommand) = reactNative.operation else {
        Issue.record("React Native generation must be a typed command")
        return
    }
    #expect(reactNativeCommand.executable == .named("node"))
    #expect(
        reactNativeCommand.arguments == [
            "/workspace/react-native/tools/generate-rn-spec.js"
        ])
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
                ).path)))
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
    let scannerCommands = commands.filter {
        $0.executable == .named("wayland-scanner")
    }
    #expect(buildCommands.isEmpty)
    #expect(
        task.swiftProducts.map(\.qualifiedProduct) == [
            "swift-wayland:SwiftWaylandGen"
        ])
    #expect(generatorCommands.count == 2)
    #expect(scannerCommands.count == 62 * 3)
    #expect(
        commands.allSatisfy {
            !$0.arguments.contains("generate-wayland")
        })
}

@Test func skiaRecipesInvokeGNAndNinjaWithoutACommandPlugin() {
    let root = FilePath("/workspace/core")
    let environment = [
        "PATH": "/usr/bin",
        "NUCLEUS_ANDROID_NDK_HOME": "/opt/android-ndk",
    ]
    for task in [
        CoreColliderRecipe.buildSkia(root: root, environment: environment),
        CoreColliderRecipe.buildSkiaAndroid(
            root: root,
            ndk: FilePath("/opt/android-ndk"),
            minimumAndroidAPI: 24,
            environment: environment),
    ] {
        guard case .sequence(let operations) = task.operation else {
            Issue.record("Skia provisioning must be an ordered task sequence")
            continue
        }
        let commands = operations.compactMap { operation -> CommandSpec? in
            guard case .command(let command) = operation else { return nil }
            return command
        }
        #expect(commands.count == 2)
        #expect(
            commands[0].executable
                == .path(root.appending("third-party/skia/bin/gn")))
        #expect(commands[1].executable == .named("ninja"))
        #expect(
            commands.allSatisfy {
                !$0.arguments.contains("build-skia")
                    && $0.executable != .named("sh")
                    && $0.executable != .named("bash")
            })
    }
}

@Test func reactNativeSupportRecipesInvokeCMakeAndNinjaDirectly() {
    let root = FilePath("/workspace/react-native")
    let environment = ["PATH": "/usr/bin"]
    let support = ReactNativeColliderRecipe.buildSupportLibraries(
        root: root, environment: environment)
    let runtime = ReactNativeColliderRecipe.buildCxxRuntime(
        root: root, environment: environment)
    for task in [support, runtime] {
        guard case .sequence(let operations) = task.operation else {
            Issue.record("RN native provisioning must be an ordered task sequence")
            continue
        }
        let commands = operations.compactMap { operation -> CommandSpec? in
            guard case .command(let command) = operation else { return nil }
            return command
        }
        #expect(!commands.isEmpty)
        #expect(
            commands.allSatisfy {
                $0.executable == .named("cmake")
                    || $0.executable == .named("ninja")
            })
        #expect(
            commands.allSatisfy {
                !$0.arguments.contains("build-rn-support")
                    && !$0.arguments.contains("build-rn-cxx")
            })
    }
    #expect(
        runtime.dependencies == [
            TaskID(rawValue: "rn.support"),
            TaskID(rawValue: "rn.generate"),
            TaskID(rawValue: "rn.boost"),
            TaskID(rawValue: "rn.hermes"),
        ])
}

@Test func hermesRecipeUsesTypedCommandsAndArchiveMerge() {
    let root = FilePath("/workspace/react-native")
    let environment = ["PATH": "/usr/bin"]
    let task = ReactNativeColliderRecipe.buildHermes(
        root: root,
        environment: environment,
        host: HermesHostDependencies(
            icuIncludeDirectory: FilePath("/usr/include"),
            icuUCLibrary: FilePath("/usr/lib/libicuuc.so"),
            icuI18NLibrary: FilePath("/usr/lib/libicui18n.so"),
            icuDataLibrary: FilePath("/usr/lib/libicudata.so"),
            cxxRuntimeLibrary: FilePath("/toolchain/lib/libc++.so.1")))
    guard case .sequence(let operations) = task.operation else {
        Issue.record("Hermes provisioning must be an ordered task sequence")
        return
    }
    #expect(operations.count == 3)
    guard case .command(let configure) = operations[0],
        case .command(let build) = operations[1],
        case .mergeStaticArchives(let merge) = operations[2]
    else {
        Issue.record("Hermes must configure, build, then merge its archives")
        return
    }
    #expect(configure.executable == .named("cmake"))
    #expect(build.executable == .named("ninja"))
    #expect(build.environment["LD_LIBRARY_PATH"] == "/toolchain/lib")
    #expect(merge.archiver == .named("ar"))
    #expect(merge.indexer == .named("ranlib"))
    #expect(merge.excludedFilePrefixes == ["libgtest"])
}

@Test func reactNativeHostArchiveStagingIsATypedCopy() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-rn-host-archive-\(UUID().uuidString)")
    let scratch = directory.appendingPathComponent("scratch")
    let product = scratch.appendingPathComponent(
        "out/Products/Debug-linux-x86_64")
    try FileManager.default.createDirectory(
        at: product, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = product.appendingPathComponent(
        "libNucleusReactRuntimeHostCxx.a")
    try Data("archive".utf8).write(to: archive)
    let task = try ReactNativeColliderRecipe.stageHostArchive(
        root: FilePath(directory.path),
        swiftPM: SwiftPMInvocation(
            context: SwiftBuildContext(
                packageRoot: fixtureSwiftPackageRoot,
                configuration: .debug,
                target: .host(identity: "x86_64-linux"),
                toolchainIdentity: "swiftc@fixture"),
            scratchPath: FilePath(scratch.path)))
    guard case .copyMatchingFile(let copy) = task.operation else {
        Issue.record("RN host archive staging must be a typed matched copy")
        return
    }
    #expect(
        copy.searchDirectory
            == FilePath(
                directory.appendingPathComponent(
                    "scratch/out/Products"
                ).path))
    #expect(copy.childDirectoryPrefix == "Debug-")
    #expect(copy.fileName == "libNucleusReactRuntimeHostCxx.a")
    #expect(
        copy.destination
            == FilePath(
                directory.appendingPathComponent(
                    ".cxx-build/debug/libNucleusReactRuntimeHostCxx.a"
                ).path))
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
        pipelineIDs.contains(
            "android-runtime.aosp-build-container"))
    #expect(
        pipelineIDs.suffix(5) == [
            "android-runtime.aosp-compile",
            "android-runtime.aosp-sign",
            "android-runtime.aosp-assemble-images",
            "android-runtime.aosp-validate",
            "android-runtime.aosp-image",
        ])
    let container = try #require(
        tasks.first {
            $0.id.rawValue == "android-runtime.aosp-build-container"
        })
    #expect(
        {
            guard case .prepareAOSPBuildContainer = container.operation else {
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
            guard case .compileAOSPProduct = operations[0] else {
                return false
            }
            return true
        }())
    #expect(
        {
            guard case .signAOSPProduct = operations[1] else {
                return false
            }
            return true
        }())
    #expect(
        {
            guard case .assembleAOSPProductImages = operations[2] else {
                return false
            }
            return true
        }())
    #expect(
        {
            guard case .validateAOSPProduct = operations[3] else {
                return false
            }
            return true
        }())
    #expect(
        {
            guard case .publishAOSPProduct = operations[4] else {
                return false
            }
            return true
        }())
}
