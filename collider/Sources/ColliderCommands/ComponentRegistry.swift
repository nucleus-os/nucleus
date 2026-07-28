import ArgumentParser
import AndroidRuntimeColliderRecipe
import ColliderCore
import ColliderRuntime
import CompositorAppColliderRecipe
import CompositorColliderRecipe
import ConfigColliderRecipe
import CoreColliderRecipe
import IPCColliderRecipe
import Foundation
import LinuxColliderRecipe
import ReactNativeColliderRecipe
import ShellColliderRecipe
import SystemPackage
import TracyColliderRecipe
import VulkanColliderRecipe
import WaylandColliderRecipe

enum ComponentSelection: String, CaseIterable, ExpressibleByArgument {
    case all
    case runtime
    case toolchain
    case android
    case browser
    case tracy
    case vulkan
    case wayland
    case core
    case config
    case ipc
    case linux
    case reactNative = "rn"
    case compositor
    case shell
    case androidRuntime = "android-runtime"
    case loader
    case gpuHeadless = "gpu-headless"
    case gpuDRM = "gpu-drm"
}

enum GeneratorComponent {
    case reactNative
    case vulkan
    case wayland
}

struct ComponentRegistry {
    let context: WorkspaceContext

    private func buildTasks() throws -> [TaskDeclaration] {
        let layout = context.layout
        let environment = context.taskEnvironment
        let swiftPM = try context.swiftPMInvocation()
        return [
            TracyColliderRecipe.build(
                root: FilePath(layout.swiftTracy.path),
                environment: environment,
                swiftPM: swiftPM),
            VulkanColliderRecipe.build(
                root: FilePath(layout.swiftVulkan.path),
                environment: environment,
                swiftPM: swiftPM),
            WaylandColliderRecipe.build(
                root: FilePath(layout.swiftWayland.path),
                environment: environment,
                swiftPM: swiftPM),
            CoreColliderRecipe.build(
                root: FilePath(layout.core.path),
                environment: environment,
                swiftPM: swiftPM),
            ConfigColliderRecipe.build(
                root: FilePath(layout.config.path),
                environment: environment,
                swiftPM: swiftPM),
            IPCColliderRecipe.build(
                root: FilePath(layout.ipc.path),
                environment: environment,
                swiftPM: swiftPM),
            LinuxColliderRecipe.build(
                root: FilePath(layout.platformLinux.path),
                environment: environment,
                swiftPM: swiftPM),
            ReactNativeColliderRecipe.build(
                root: FilePath(layout.reactNative.path),
                environment: environment,
                swiftPM: swiftPM),
            CompositorColliderRecipe.build(
                root: FilePath(layout.compositorCore.path),
                environment: environment,
                swiftPM: swiftPM),
            CompositorAppColliderRecipe.build(
                root: FilePath(layout.compositorApp.path),
                environment: environment,
                swiftPM: swiftPM),
            ShellColliderRecipe.build(
                root: FilePath(layout.shell.path),
                environment: environment,
                swiftPM: swiftPM),
        ] + (try AndroidRuntimeColliderRecipe.tasks(
            root: FilePath(layout.androidRuntime.path),
            repositoryRoot: layout.rootPath,
            environment: environment,
            swiftPM: swiftPM))
    }

    private func testTasks(
        selection: ComponentSelection?
    ) throws -> [TaskDeclaration] {
        let layout = context.layout
        let environment = context.taskEnvironment
        let swiftPM = try context.swiftPMInvocation()
        var tasks = try buildTasks() + [
            TracyColliderRecipe.test(
                root: FilePath(layout.swiftTracy.path),
                environment: environment,
                swiftPM: swiftPM),
            VulkanColliderRecipe.test(
                root: FilePath(layout.swiftVulkan.path),
                environment: environment,
                swiftPM: swiftPM),
            WaylandColliderRecipe.test(
                root: FilePath(layout.swiftWayland.path),
                environment: environment,
                swiftPM: swiftPM),
            CoreColliderRecipe.test(
                root: FilePath(layout.core.path),
                environment: environment,
                swiftPM: swiftPM),
            ConfigColliderRecipe.test(
                root: FilePath(layout.config.path),
                environment: environment,
                swiftPM: swiftPM),
            IPCColliderRecipe.test(
                root: FilePath(layout.ipc.path),
                environment: environment,
                swiftPM: swiftPM),
            LinuxColliderRecipe.test(
                root: FilePath(layout.platformLinux.path),
                environment: environment,
                swiftPM: swiftPM),
            ReactNativeColliderRecipe.test(
                root: FilePath(layout.reactNative.path),
                environment: environment,
                swiftPM: swiftPM),
            CompositorColliderRecipe.test(
                root: FilePath(layout.compositorCore.path),
                environment: environment,
                swiftPM: swiftPM),
            CompositorAppColliderRecipe.test(
                root: FilePath(layout.compositorApp.path),
                environment: environment,
                swiftPM: swiftPM),
            ShellColliderRecipe.test(
                root: FilePath(layout.shell.path),
                environment: environment,
                swiftPM: swiftPM),
            AndroidRuntimeColliderRecipe.test(
                root: FilePath(layout.androidRuntime.path),
                environment: environment,
                swiftPM: swiftPM),
        ]
        let effectiveSelection = selection ?? .all
        if [.all, .runtime, .compositor, .loader].contains(
            effectiveSelection)
        {
            tasks += [
            CompositorColliderRecipe.preflightVulkanLoader(
                root: FilePath(layout.compositorCore.path),
                environment: environment,
                swiftPM: swiftPM),
            CompositorColliderRecipe.testVulkanLoader(
                root: FilePath(layout.compositorCore.path),
                environment: environment,
                swiftPM: swiftPM),
            ]
        }
        if [.all, .runtime, .compositor, .gpuHeadless].contains(
            effectiveSelection)
        {
            let lavapipe = try LavapipeTestArtifact.resolve(context: context)
            var headlessEnvironment = environment
            headlessEnvironment["VK_ICD_FILENAMES"] =
                lavapipe.stagedManifest.string
            headlessEnvironment["VK_DRIVER_FILES"] =
                lavapipe.stagedManifest.string
            tasks += [
                lavapipe.task,
            CompositorColliderRecipe.preflightHeadlessGPU(
                root: FilePath(layout.compositorCore.path),
                environment: headlessEnvironment,
                lavapipeTask: lavapipe.task.id,
                swiftPM: swiftPM),
            CompositorColliderRecipe.testHeadlessGPU(
                root: FilePath(layout.compositorCore.path),
                environment: headlessEnvironment,
                swiftPM: swiftPM),
            ]
        }
        if effectiveSelection == .gpuDRM {
            var drmEnvironment = environment
            drmEnvironment["NUCLEUS_TEST_DRM_RENDER_NODE"] =
                try requiredDRMRenderNode(environment: environment)
            tasks.append(CompositorColliderRecipe.preflightDRMGPU(
                root: FilePath(layout.compositorCore.path),
                environment: drmEnvironment,
                swiftPM: swiftPM))
            tasks.append(CompositorColliderRecipe.testDRMGPU(
                root: FilePath(layout.compositorCore.path),
                environment: drmEnvironment,
                swiftPM: swiftPM))
        }
        return tasks
    }

    func build(
        selection: ComponentSelection?,
        controls: TaskControls
    ) async throws {
        try await context.execute(
            tasks: try buildTasks(),
            selected: try selectedBuildTasks(selection),
            controls: controls)
    }

    func bootstrap(
        selection: ComponentSelection?,
        controls: TaskControls
    ) async throws {
        let selection = selection ?? .all
        guard ![
            .toolchain, .android, .browser, .loader, .gpuHeadless, .gpuDRM,
        ].contains(selection) else {
            throw WorkspaceFailure.message(
                "\(selection.rawValue) is not a runtime bootstrap component")
        }
        let name = selection.rawValue
        let layout = context.layout
        let environment = context.taskEnvironment
        let swiftPM = try context.swiftPMInvocation()
        let needsCore = [
            "all", "runtime", "core", "linux", "rn", "compositor",
            "shell", "android-runtime",
        ].contains(name)
        let needsRN = [
            "all", "runtime", "rn", "compositor", "shell",
        ].contains(name)
        var tasks = try buildTasks()
        var selected = try selectedBuildTasks(
            selection == .runtime ? nil : selection)

        if selection == .all || selection == .runtime
            || selection == .compositor
        {
            let lavapipe = try LavapipeTestArtifact.resolve(context: context)
            tasks.append(lavapipe.task)
            selected.append(lavapipe.task.id)
        }

        if needsCore {
            let coreRoot = FilePath(layout.core.path)
            let source = CoreColliderRecipe.prepareSkiaDependencies(
                root: coreRoot, environment: environment)
            let skia = CoreColliderRecipe.buildSkia(
                root: coreRoot, environment: environment)
            let sdk = CoreColliderRecipe.publishRenderSDK(
                root: coreRoot,
                sdkRoot: nativeSDKRoot)
            tasks += [source, skia, sdk]
            tasks = addingDependency(
                sdk.id,
                to: TaskID(rawValue: "core.build"),
                in: tasks)
        }

        if needsRN {
            let rnRoot = FilePath(layout.reactNative.path)
            let javascript =
                ReactNativeColliderRecipe.installJavaScriptDependencies(
                    root: rnRoot, environment: environment)
            let types = ReactNativeColliderRecipe.generateStrictTypes(
                root: rnRoot, environment: environment)
            let generate = ReactNativeColliderRecipe.generate(
                root: rnRoot, environment: environment)
            let boost = try ReactNativeColliderRecipe.provisionBoost(
                root: rnRoot, environment: environment)
            let hermes = ReactNativeColliderRecipe.buildHermes(
                root: rnRoot,
                environment: environment,
                host: try await hermesHostDependencies())
            let support = ReactNativeColliderRecipe.buildSupportLibraries(
                root: rnRoot, environment: environment)
            let cxx = ReactNativeColliderRecipe.buildCxxRuntime(
                root: rnRoot, environment: environment)
            let swiftCxx = ReactNativeColliderRecipe.buildSwiftCxxFacade(
                root: rnRoot,
                environment: environment,
                swiftPM: swiftPM)
            let swiftHost = ReactNativeColliderRecipe.buildSwiftHostCxx(
                root: rnRoot,
                environment: environment,
                swiftPM: swiftPM)
            let stage = try ReactNativeColliderRecipe.stageHostArchive(
                root: rnRoot,
                swiftPM: swiftPM)
                .addingDependencies([swiftHost.id])
            let sdk = ReactNativeColliderRecipe.publishNativeSDK(
                root: rnRoot,
                sdkRoot: nativeSDKRoot)
            tasks += [
                javascript, types, generate, boost, hermes, support,
                cxx, swiftCxx, swiftHost, stage, sdk,
            ]
            tasks = addingDependency(
                sdk.id,
                to: TaskID(rawValue: "rn.build"),
                in: tasks)
        }

        try await context.execute(
            tasks: tasks,
            selected: selected,
            controls: controls)
    }

    func test(
        selection: ComponentSelection?,
        controls: TaskControls
    ) async throws {
        try await context.execute(
            tasks: try testTasks(selection: selection),
            selected: try selectedTestTasks(selection),
            controls: controls)
    }

    func generate(
        _ component: GeneratorComponent,
        controls: TaskControls
    ) async throws {
        let layout = context.layout
        let environment = context.taskEnvironment
        let swiftPM = try context.swiftPMInvocation()
        let task: TaskDeclaration
        var tasks: [TaskDeclaration]
        switch component {
        case .reactNative:
            let root = FilePath(layout.reactNative.path)
            let dependencies =
                ReactNativeColliderRecipe.installJavaScriptDependencies(
                    root: root,
                    environment: environment)
            let types = ReactNativeColliderRecipe.generateStrictTypes(
                root: root,
                environment: environment)
            task = ReactNativeColliderRecipe.generate(
                root: root, environment: environment)
            tasks = [dependencies, types, task]
        case .vulkan:
            task = VulkanColliderRecipe.generate(
                root: FilePath(layout.swiftVulkan.path),
                environment: environment,
                swiftPM: swiftPM)
            tasks = [task]
        case .wayland:
            task = try WaylandColliderRecipe.generate(
                root: FilePath(layout.swiftWayland.path),
                environment: environment,
                swiftPM: swiftPM)
            tasks = [task]
        }
        try await context.execute(
            tasks: tasks,
            selected: [task.id],
            controls: controls)
    }

    func buildAndroidHost(
        gradleArguments: [String],
        controls: TaskControls
    ) async throws {
        let tasks = try await androidHostTasks()
        let android = FilePath(context.layout.core.path).appending("android")
        let gradle = TaskDeclaration(
            id: TaskID(rawValue: "core.android.build"),
            component: ComponentID(rawValue: "core"),
            dependencies: [TaskID(rawValue: "core.android-host.validate")],
            inputs: [
                .file(android.appending("settings.gradle.kts")),
                .file(android.appending("build.gradle.kts")),
                .file(android.appending("gradle/libs.versions.toml")),
                .tree(android.appending("nucleus/src")),
                .tree(android.appending("smoke-app/src")),
                .tool(.path(android.appending("gradlew"))),
                .value(
                    name: "gradle-arguments",
                    bytes: Array(gradleArguments.joined(separator: "\u{0}").utf8)),
            ],
            locks: [.checkout("core-android-gradle")],
            cachePolicy: .always,
            operation: .command(CommandSpec(
                executable: .path(android.appending("gradlew")),
                arguments: gradleArguments.isEmpty
                    ? ["verifyDebug"] : gradleArguments,
                workingDirectory: android,
                environment: context.taskEnvironment)))
        try await context.execute(
            tasks: tasks + [gradle],
            selected: [gradle.id],
            controls: controls)
    }

    func buildAndroidNative(controls: TaskControls) async throws {
        let tasks = try await androidHostTasks()
        let selected = TaskID(rawValue: "core.android-host.validate")
        try await context.execute(
            tasks: tasks,
            selected: [selected],
            controls: controls)
    }

    func validateAndroidHost(
        library: String?,
        controls: TaskControls
    ) async throws {
        let core = FilePath(context.layout.core.path)
        let toolchain = try AndroidToolchainVersions.load(
            workspaceRoot: context.root)
        let ndk = try toolchain.ndkRoot(environment: context.environment)
        let supplied = library.map {
            FilePath(URL(
                fileURLWithPath: $0,
                relativeTo: context.root).standardizedFileURL.path)
        }
        let sourceID =
            context.taskEnvironment["NUCLEUS_SWIFT_SOURCE_ID"]
                ?? "release-6.4.x"
        let swiftPM = try context.swiftPMInvocation(
            configuration: .release,
            staticSwiftStandardLibrary: true,
            target: .swiftSDK(
                name: "swift-\(sourceID)_android",
                targetTriple:
                    "aarch64-unknown-linux-android\(toolchain.minimumSDK)"))
        let task = CoreColliderRecipe.validateAndroidHost(
            root: core,
            library: supplied ?? swiftPM.configurationProducts.appending(
                "libnucleus-android.so"),
            ndk: FilePath(ndk.path),
            environment: context.taskEnvironment,
            dependencies: [])
        try await context.execute(
            tasks: [task],
            selected: [task.id],
            controls: controls)
    }

    func verifyAndroidRuntimeSourceLock(
        controls: TaskControls
    ) async throws {
        let root = FilePath(context.layout.androidRuntime.path)
        let tasks = try AndroidRuntimeColliderRecipe.aospSourceTasks(
            root: root,
            environment: context.taskEnvironment)
        let selected = TaskID(rawValue: "android-runtime.aosp-source-lock")
        try await context.execute(
            tasks: tasks,
            selected: [selected],
            controls: controls)
    }

    func prepareAndroidRuntimeSource(
        controls: TaskControls
    ) async throws {
        let tasks = try AndroidRuntimeColliderRecipe.aospSourceTasks(
            root: FilePath(context.layout.androidRuntime.path),
            environment: context.taskEnvironment)
        let selected = TaskID(rawValue: "android-runtime.aosp-source")
        try await context.execute(
            tasks: tasks,
            selected: [selected],
            controls: controls)
    }

    func buildAndroidRuntimeImage(
        controls: TaskControls
    ) async throws {
        let tasks = try AndroidRuntimeColliderRecipe.aospImageTasks(
            root: FilePath(context.layout.androidRuntime.path),
            environment: context.taskEnvironment)
        let selected = TaskID(rawValue: "android-runtime.aosp-image")
        try await context.execute(
            tasks: tasks,
            selected: [selected],
            controls: controls)
    }

    func buildAndroidRuntimeHost() async throws {
        let tasks = try buildTasks()
        try await context.execute(
            tasks: tasks,
            selected: [TaskID(rawValue: "android-runtime.build")],
            controls: TaskControls())
    }

    private func selectedBuildTasks(
        _ selection: ComponentSelection?
    ) throws -> [TaskID] {
        let selection = selection ?? .all
        if selection == .all || selection == .runtime {
            return [
                TaskID(rawValue: "shell.build"),
                TaskID(rawValue: "android-runtime.build"),
            ]
        }
        guard ![
            .toolchain, .android, .browser, .loader, .gpuHeadless, .gpuDRM,
        ].contains(selection) else {
            throw WorkspaceFailure.message(
                "\(selection.rawValue) is not a runtime build component")
        }
        return [TaskID(rawValue: selection.rawValue + ".build")]
    }

    func selectedTestTasks(
        _ selection: ComponentSelection?
    ) throws -> [TaskID] {
        let selection = selection ?? .all
        if selection == .all || selection == .runtime {
            return [
                "tracy.test", "vulkan.test", "wayland.test", "core.test",
                "config.test", "ipc.test",
                "linux.test", "rn.test", "compositor-core.test",
                "compositor-core.test-loader",
                "compositor-core.test-gpu-headless",
                "compositor.test", "shell.test",
                "android-runtime.test",
            ].map { TaskID(rawValue: $0) }
        }
        let taskNames: [ComponentSelection: [String]] = [
            .tracy: ["tracy.test"],
            .vulkan: ["vulkan.test"],
            .wayland: ["wayland.test"],
            .core: ["core.test"],
            .config: ["config.test"],
            .ipc: ["ipc.test"],
            .linux: ["linux.test"],
            .reactNative: ["rn.test"],
            .compositor: [
                "compositor-core.test",
                "compositor-core.test-loader",
                "compositor-core.test-gpu-headless",
                "compositor.test",
            ],
            .shell: ["shell.test"],
            .androidRuntime: ["android-runtime.test"],
            .loader: ["compositor-core.test-loader"],
            .gpuHeadless: ["compositor-core.test-gpu-headless"],
            .gpuDRM: ["compositor-core.test-gpu-drm"],
        ]
        guard let selected = taskNames[selection] else {
            throw WorkspaceFailure.message(
                "\(selection.rawValue) is not a runtime test component")
        }
        return selected.map { TaskID(rawValue: $0) }
    }

    private func hermesHostDependencies() async throws -> HermesHostDependencies {
        let include = try requiredDirectory(await context.run(
            "pkg-config",
            ["--variable=includedir", "icu-uc"],
            capture: true))
        let libraryDirectory = try requiredDirectory(await context.run(
            "pkg-config",
            ["--variable=libdir", "icu-uc"],
            capture: true))
        return try HermesHostDependencies(
            icuIncludeDirectory: include,
            icuUCLibrary: await resolveHostLibrary(
                "libicuuc.so", preferredDirectory: libraryDirectory),
            icuI18NLibrary: await resolveHostLibrary(
                "libicui18n.so", preferredDirectory: libraryDirectory),
            icuDataLibrary: await resolveHostLibrary(
                "libicudata.so", preferredDirectory: libraryDirectory),
            cxxRuntimeLibrary: requiredFile(await context.run(
                "clang++",
                ["-print-file-name=libc++.so.1"],
                capture: true)))
    }

    private func androidHostTasks() async throws -> [TaskDeclaration] {
        let root = FilePath(context.layout.core.path)
        let environment = context.taskEnvironment
        let toolchain = try AndroidToolchainVersions.load(
            workspaceRoot: context.root)
        let ndk = FilePath(
            try toolchain.ndkRoot(environment: context.environment).path)
        let source = CoreColliderRecipe.prepareSkiaDependencies(
            root: root, environment: environment)
        let skia = CoreColliderRecipe.buildSkiaAndroid(
            root: root,
            ndk: ndk,
            minimumAndroidAPI: toolchain.minimumSDK,
            environment: environment)
        let sdk = CoreColliderRecipe.publishRenderSDK(
            root: root,
            sdkRoot: nativeSDKRoot,
            dependencies: [skia.id])
        let sourceID =
            environment["NUCLEUS_SWIFT_SOURCE_ID"] ?? "release-6.4.x"
        let swiftPM = try context.swiftPMInvocation(
            configuration: .release,
            staticSwiftStandardLibrary: true,
            target: .swiftSDK(
                name: "swift-\(sourceID)_android",
                targetTriple:
                    "aarch64-unknown-linux-android\(toolchain.minimumSDK)"))
        let build = CoreColliderRecipe.buildAndroidHost(
            root: root,
            environment: environment,
            swiftPM: swiftPM,
            dependencies: [sdk.id])
        let validate = CoreColliderRecipe.validateAndroidHost(
            root: root,
            library: swiftPM.configurationProducts.appending(
                "libnucleus-android.so"),
            ndk: ndk,
            environment: environment,
            dependencies: [build.id])
        return [source, skia, sdk, build, validate]
    }

    private var nativeSDKRoot: FilePath {
        FilePath(context.nativeSDKRoot.path)
    }

    private func addingDependency(
        _ dependency: TaskID,
        to task: TaskID,
        in tasks: [TaskDeclaration]
    ) -> [TaskDeclaration] {
        tasks.map {
            $0.id == task ? $0.addingDependencies([dependency]) : $0
        }
    }

    private func resolveHostLibrary(
        _ name: String,
        preferredDirectory: FilePath
    ) async throws -> FilePath {
        let preferred = preferredDirectory.appending(name)
        if FileManager.default.fileExists(atPath: preferred.string) {
            return preferred
        }
        return try requiredFile(await context.run(
            "clang",
            ["-print-file-name=\(name)"],
            capture: true))
    }

    private func requiredDirectory(_ path: String) throws -> FilePath {
        let values = try? URL(fileURLWithPath: path).resourceValues(
            forKeys: [.isDirectoryKey])
        guard !path.isEmpty,
              values?.isDirectory == true
        else {
            throw WorkspaceFailure.message(
                "required host directory was not resolved: \(path)")
        }
        return FilePath(path)
    }

    private func requiredFile(_ path: String) throws -> FilePath {
        let values = try? URL(fileURLWithPath: path).resourceValues(
            forKeys: [.isDirectoryKey])
        guard path.hasPrefix("/"),
              values?.isDirectory == false
        else {
            throw WorkspaceFailure.message(
                "required host library was not resolved: \(path)")
        }
        return FilePath(path)
    }
}
