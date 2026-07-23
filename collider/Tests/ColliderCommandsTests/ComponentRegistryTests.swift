import AndroidRuntimeColliderRecipe
import ColliderCore
import CoreColliderRecipe
import Foundation
import ReactNativeColliderRecipe
import SystemPackage
import Testing
import VulkanColliderRecipe
import WaylandColliderRecipe
@testable import ColliderCommands

@Test func componentTestSelectionPreservesTheRepositoryOrder() throws {
    let registry = ComponentRegistry(context: WorkspaceContext(
        root: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        environment: [:]))

    #expect(try registry.selectedTestTasks(nil).map(\.rawValue) == [
        "tracy.test", "vulkan.test", "wayland.test", "core.test",
        "linux.test", "rn.test", "compositor-core.test",
        "compositor.test", "shell.test", "android-runtime.test",
    ])
    #expect(try registry.selectedTestTasks("compositor").map(\.rawValue) == [
        "compositor-core.test", "compositor.test",
    ])
    #expect(throws: WorkspaceFailure.self) {
        try registry.selectedTestTasks("unknown")
    }
}

@Test func migratedGeneratorsInvokeComponentToolsWithoutCommandPlugins() {
    let root = FilePath("/workspace")
    let environment = ["PATH": "/usr/bin"]

    let vulkan = VulkanColliderRecipe.generate(
        root: root.appending("swift-vulkan"),
        environment: environment)
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
    let task = try WaylandColliderRecipe.generate(
        root: FilePath(workspace.appendingPathComponent("swift-wayland").path),
        environment: ["PATH": "/usr/bin"])
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
            root: root, environment: environment),
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
    let product = directory.appendingPathComponent(
        ".build/out/Products/Debug-linux-x86_64")
    try FileManager.default.createDirectory(
        at: product, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = product.appendingPathComponent(
        "libNucleusReactRuntimeHostCxx.a")
    try Data("archive".utf8).write(to: archive)
    let task = try ReactNativeColliderRecipe.stageHostArchive(
        root: FilePath(directory.path),
        configuration: "debug")
    guard case .copyMatchingFile(let copy) = task.operation else {
        Issue.record("RN host archive staging must be a typed matched copy")
        return
    }
    #expect(copy.searchDirectory == FilePath(directory.appendingPathComponent(
        ".build/out/Products").path))
    #expect(copy.childDirectoryPrefix == "Debug-")
    #expect(copy.fileName == "libNucleusReactRuntimeHostCxx.a")
    #expect(copy.destination == FilePath(directory.appendingPathComponent(
        ".cxx-build/debug/libNucleusReactRuntimeHostCxx.a").path))
}

@Test func gfxstreamRecipeUsesTypedValidationAndMesonOperations() throws {
    let workspace = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let tasks = try AndroidRuntimeColliderRecipe.tasks(
        root: FilePath(workspace.appendingPathComponent(
            "android-runtime").path),
        repositoryRoot: FilePath(workspace.path),
        environment: [
            "PATH": "/usr/bin",
            "SWIFT_TOOLCHAIN": "/toolchain",
        ])
    let task = try #require(tasks.first {
        $0.id == TaskID(rawValue: "android-runtime.gfxstream")
    })
    guard case .sequence(let operations) = task.operation else {
        Issue.record("gfxstream must be one typed task sequence")
        return
    }
    #expect(operations.count == 6)
    #expect(operations.filter {
        if case .validateGitCheckout = $0 { return true }
        return false
    }.count == 2)
    #expect(operations.filter {
        if case .configureMeson = $0 { return true }
        return false
    }.count == 2)
    #expect(operations.allSatisfy {
        guard case .command(let command) = $0 else { return true }
        return command.executable != .named("sh")
            && command.executable != .named("bash")
    })
}
