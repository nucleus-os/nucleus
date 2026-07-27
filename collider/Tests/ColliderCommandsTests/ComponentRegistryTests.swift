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

@Test func androidToolchainCatalogDrivesColliderVersionsAndNDKSelection() throws {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-android-toolchain-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let catalog = workspace.appendingPathComponent(
        "core/android/gradle/libs.versions.toml")
    try FileManager.default.createDirectory(
        at: catalog.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try Data("""
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
        """.utf8).write(to: catalog)
    let ndk = workspace.appendingPathComponent("selected-ndk")
    try FileManager.default.createDirectory(
        at: ndk, withIntermediateDirectories: true)
    try Data("""
        Pkg.Revision = 30.0.15729638-beta2
        Pkg.BaseRevision = 30.0.15729638
        """.utf8).write(to: ndk.appendingPathComponent("source.properties"))

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
    #expect(try versions.ndkRoot(environment: [
        "NUCLEUS_ANDROID_NDK_HOME": ndk.path,
    ]).standardizedFileURL.path == ndk.standardizedFileURL.path)
}

@Test func componentTestSelectionPreservesTheRepositoryOrder() throws {
    let registry = ComponentRegistry(context: WorkspaceContext(
        root: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        environment: [:]))

    #expect(try registry.selectedTestTasks(nil).map(\.rawValue) == [
        "tracy.test", "vulkan.test", "wayland.test", "core.test",
        "linux.test", "rn.test", "compositor-core.test",
        "compositor-core.test-loader",
        "compositor-core.test-gpu-headless",
        "compositor.test", "shell.test", "android-runtime.test",
    ])
    #expect(try registry.selectedTestTasks(.compositor).map(\.rawValue) == [
        "compositor-core.test", "compositor-core.test-loader",
        "compositor-core.test-gpu-headless", "compositor.test",
    ])
    #expect(try registry.selectedTestTasks(.loader).map(\.rawValue) == [
        "compositor-core.test-loader",
    ])
    #expect(try registry.selectedTestTasks(.gpuHeadless).map(\.rawValue) == [
        "compositor-core.test-gpu-headless",
    ])
    #expect(try registry.selectedTestTasks(.gpuDRM).map(\.rawValue) == [
        "compositor-core.test-gpu-drm",
    ])
    #expect(throws: (any Error).self) {
        try ColliderCommand.parseAsRoot(["test", "unknown"])
    }
}

@Test func compatibleSwiftTasksShareOneDeclaredBuildContext() {
    let root = FilePath("/workspace")
    let environment = ["PATH": "/toolchain/bin"]
    let context = SwiftBuildContext(
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
        #expect(task.locks.contains(swiftPM.lock))
        guard case .command(let command) = task.operation else {
            Issue.record("SwiftPM task must be a typed command")
            continue
        }
        #expect(command.arguments.suffix(4) == [
            "--configuration", "debug",
            "--scratch-path", scratch.string,
        ])
    }
}

@Test func incompatibleSwiftBuildContextsUseDifferentScratchPaths() {
    let layout = WorkspaceLayout(root: URL(fileURLWithPath: "/workspace"))
    let debug = SwiftBuildContext(
        configuration: .debug,
        target: .host(identity: "x86_64-linux"),
        toolchainIdentity: "swiftc@first")
    let release = SwiftBuildContext(
        configuration: .release,
        target: .host(identity: "x86_64-linux"),
        toolchainIdentity: "swiftc@first")
    let otherToolchain = SwiftBuildContext(
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
    #expect(context.taskEnvironment["CCACHE_DIR"]
        == "/cache/nucleus/host-ccache")
    #expect(context.taskEnvironment["CCACHE_COMPILERCHECK"] == "content")
    #expect(context.taskEnvironment["CCACHE_MAXSIZE"] == "50G")
    #expect(context.taskEnvironment["CCACHE_SLOPPINESS"]
        == "include_file_ctime,include_file_mtime,locale")
}

@Test func reactNativeBuildProducesTheSwiftHeaderBeforeCompilingTheHost() {
    let root = FilePath("/workspace/react-native")
    let scratch = FilePath("/workspace/.nucleus/swiftpm/fixture")
    let swiftPM = SwiftPMInvocation(
        context: SwiftBuildContext(
            configuration: .debug,
            target: .host(identity: "x86_64-linux"),
            toolchainIdentity: "swiftc@fixture"),
        scratchPath: scratch)

    let task = ReactNativeColliderRecipe.build(
        root: root,
        environment: ["PATH": "/usr/bin"],
        swiftPM: swiftPM)

    guard case .sequence(let operations) = task.operation,
          operations.count == 2,
          case .command(let facade) = operations[0],
          case .command(let package) = operations[1]
    else {
        Issue.record("RN build must build the Swift façade before the package")
        return
    }
    #expect(facade.arguments.prefix(3) == [
        "build", "--target", "NucleusReactRuntimeCxx",
    ])
    #expect(package.arguments.first == "build")
    #expect(facade.environment["NUCLEUS_SWIFTPM_SCRATCH_PATH"]
        == scratch.string)
    #expect(facade.environment["NUCLEUS_SWIFTPM_GENERATED_MODULE_MAPS_PATH"]
        == swiftPM.generatedModuleMaps.string)
    #expect(task.postconditions.contains(PathPostcondition(
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
    try Data("""
        {
          "file_format_version": "1.0.0",
          "ICD": {
            "api_version": "1.3.0",
            "library_path": "\(library.path)"
          }
        }
        """.utf8).write(to: manifest)

    let artifact = try LavapipeTestArtifact.resolve(context: WorkspaceContext(
        root: directory,
        environment: [
            "NUCLEUS_LAVAPIPE_ICD": manifest.path,
            "XDG_CACHE_HOME": directory.appendingPathComponent("cache").path,
        ]))
    #expect(artifact.sourceManifest == FilePath(manifest.path))
    #expect(artifact.library == FilePath(library.path))
    #expect(artifact.stagedManifest == FilePath(directory.appendingPathComponent(
        "cache/nucleus/test-vulkan/lavapipe_icd.json").path))
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
            "NUCLEUS_TEST_DRM_RENDER_NODE": file.path,
        ])
    }
}

@Test func migratedGeneratorsInvokeComponentToolsWithoutCommandPlugins() {
    let root = FilePath("/workspace")
    let environment = ["PATH": "/usr/bin"]
    let swiftPM = SwiftPMInvocation(
        context: SwiftBuildContext(
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
    #expect(vulkanCommand.executable == .named("swift"))
    #expect(vulkanCommand.arguments == [
        "run", "VulkanGen",
        "/workspace/swift-vulkan/third-party/vk.xml",
        "/workspace/swift-vulkan/Sources/Vulkan/Vulkan.swift",
        "1",
        "--configuration", "debug",
        "--scratch-path", "/workspace/.nucleus/swiftpm/fixture",
    ])

    let reactNative = ReactNativeColliderRecipe.generate(
        root: root.appending("react-native"),
        environment: environment)
    guard case .command(let reactNativeCommand) = reactNative.operation else {
        Issue.record("React Native generation must be a typed command")
        return
    }
    #expect(reactNativeCommand.executable == .named("node"))
    #expect(reactNativeCommand.arguments == [
        "/workspace/react-native/tools/generate-rn-spec.js",
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
                configuration: .debug,
                target: .host(identity: "x86_64-linux"),
                toolchainIdentity: "swiftc@fixture"),
            scratchPath: FilePath(
                workspace.appendingPathComponent(
                    ".nucleus/swiftpm/fixture").path)))
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
    #expect(buildCommands.count == 1)
    #expect(generatorCommands.count == 2)
    #expect(scannerCommands.count == 62 * 3)
    #expect(commands.allSatisfy {
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
        #expect(commands[0].executable
            == .path(root.appending("third-party/skia/bin/gn")))
        #expect(commands[1].executable == .named("ninja"))
        #expect(commands.allSatisfy {
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
        #expect(commands.allSatisfy {
            $0.executable == .named("cmake")
                || $0.executable == .named("ninja")
        })
        #expect(commands.allSatisfy {
            !$0.arguments.contains("build-rn-support")
                && !$0.arguments.contains("build-rn-cxx")
        })
    }
    #expect(runtime.dependencies == [
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
                configuration: .debug,
                target: .host(identity: "x86_64-linux"),
                toolchainIdentity: "swiftc@fixture"),
            scratchPath: FilePath(scratch.path)))
    guard case .copyMatchingFile(let copy) = task.operation else {
        Issue.record("RN host archive staging must be a typed matched copy")
        return
    }
    #expect(copy.searchDirectory == FilePath(directory.appendingPathComponent(
        "scratch/out/Products").path))
    #expect(copy.childDirectoryPrefix == "Debug-")
    #expect(copy.fileName == "libNucleusReactRuntimeHostCxx.a")
    #expect(copy.destination == FilePath(directory.appendingPathComponent(
        ".cxx-build/debug/libNucleusReactRuntimeHostCxx.a").path))
}

@Test func androidImageRecipeHasIndependentArtifactBoundaries() throws {
    let workspace = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let tasks = try AndroidRuntimeColliderRecipe.aospImageTasks(
        root: FilePath(workspace.appendingPathComponent(
            "android-runtime").path),
        environment: ["PATH": "/usr/bin"])
    let pipelineIDs = tasks.map(\.id.rawValue).filter {
        $0.hasPrefix("android-runtime.aosp-")
    }
    #expect(pipelineIDs.contains(
        "android-runtime.aosp-build-container"))
    #expect(pipelineIDs.suffix(5) == [
        "android-runtime.aosp-compile",
        "android-runtime.aosp-sign",
        "android-runtime.aosp-assemble-images",
        "android-runtime.aosp-validate",
        "android-runtime.aosp-image",
    ])
    let container = try #require(tasks.first {
        $0.id.rawValue == "android-runtime.aosp-build-container"
    })
    #expect({
        guard case .prepareAOSPBuildContainer = container.operation else {
            return false
        }
        return true
    }())
    let operations = Array(tasks.suffix(5)).map(\.operation)
    let publication = try #require(tasks.last)
    #expect(publication.outputs.contains {
        $0.path.string.hasSuffix(".aosp-build/current")
    })
    #expect(publication.outputs.contains {
        $0.path.string.contains(".aosp-build/generations/")
            && $0.path.string.hasSuffix("/images/system.img")
    })
    #expect({
        guard case .compileAOSPProduct = operations[0] else {
            return false
        }
        return true
    }())
    #expect({
        guard case .signAOSPProduct = operations[1] else {
            return false
        }
        return true
    }())
    #expect({
        guard case .assembleAOSPProductImages = operations[2] else {
            return false
        }
        return true
    }())
    #expect({
        guard case .validateAOSPProduct = operations[3] else {
            return false
        }
        return true
    }())
    #expect({
        guard case .publishAOSPProduct = operations[4] else {
            return false
        }
        return true
    }())
}
