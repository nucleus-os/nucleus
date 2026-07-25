import ArgumentParser
import AndroidRuntimeColliderRecipe
import ColliderCore
import ColliderRuntime
import CompositorAppColliderRecipe
import CompositorColliderRecipe
import CoreColliderRecipe
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
        let root = FilePath(context.root.path)
        let environment = context.taskEnvironment
        return [
            TracyColliderRecipe.build(root: root.appending("swift-tracy"), environment: environment),
            VulkanColliderRecipe.build(root: root.appending("swift-vulkan"), environment: environment),
            WaylandColliderRecipe.build(root: root.appending("swift-wayland"), environment: environment),
            CoreColliderRecipe.build(root: root.appending("core"), environment: environment),
            LinuxColliderRecipe.build(root: root.appending("platform-linux"), environment: environment),
            ReactNativeColliderRecipe.build(root: root.appending("react-native"), environment: environment),
            CompositorColliderRecipe.build(root: root.appending("compositor/compositor-core"), environment: environment),
            CompositorAppColliderRecipe.build(root: root.appending("compositor/compositor"), environment: environment),
            ShellColliderRecipe.build(root: root.appending("shell"), environment: environment),
        ] + (try AndroidRuntimeColliderRecipe.tasks(
            root: root.appending("android-runtime"),
            repositoryRoot: root,
            environment: environment))
    }

    private func testTasks(
        selection: ComponentSelection?
    ) throws -> [TaskDeclaration] {
        let root = FilePath(context.root.path)
        let environment = context.taskEnvironment
        var tasks = try buildTasks() + [
            TracyColliderRecipe.test(
                root: root.appending("swift-tracy"), environment: environment),
            VulkanColliderRecipe.test(
                root: root.appending("swift-vulkan"), environment: environment),
            WaylandColliderRecipe.test(
                root: root.appending("swift-wayland"), environment: environment),
            CoreColliderRecipe.test(
                root: root.appending("core"), environment: environment),
            LinuxColliderRecipe.test(
                root: root.appending("platform-linux"), environment: environment),
            ReactNativeColliderRecipe.test(
                root: root.appending("react-native"), environment: environment),
            CompositorColliderRecipe.test(
                root: root.appending("compositor/compositor-core"),
                environment: environment),
            CompositorAppColliderRecipe.test(
                root: root.appending("compositor/compositor"),
                environment: environment),
            ShellColliderRecipe.test(
                root: root.appending("shell"), environment: environment),
            AndroidRuntimeColliderRecipe.test(
                root: root.appending("android-runtime"), environment: environment),
        ]
        let effectiveSelection = selection ?? .all
        if [.all, .runtime, .compositor, .loader].contains(
            effectiveSelection)
        {
            tasks += [
            CompositorColliderRecipe.preflightVulkanLoader(
                root: root.appending("compositor/compositor-core"),
                environment: environment),
            CompositorColliderRecipe.testVulkanLoader(
                root: root.appending("compositor/compositor-core"),
                environment: environment),
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
                root: root.appending("compositor/compositor-core"),
                environment: headlessEnvironment,
                lavapipeTask: lavapipe.task.id),
            CompositorColliderRecipe.testHeadlessGPU(
                root: root.appending("compositor/compositor-core"),
                environment: headlessEnvironment),
            ]
        }
        if effectiveSelection == .gpuDRM {
            var drmEnvironment = environment
            drmEnvironment["NUCLEUS_TEST_DRM_RENDER_NODE"] =
                try requiredDRMRenderNode(environment: environment)
            tasks.append(CompositorColliderRecipe.preflightDRMGPU(
                root: root.appending("compositor/compositor-core"),
                environment: drmEnvironment))
            tasks.append(CompositorColliderRecipe.testDRMGPU(
                root: root.appending("compositor/compositor-core"),
                environment: drmEnvironment))
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
        let root = FilePath(context.root.path)
        let environment = context.taskEnvironment
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

        let tracySource = try await tracySourceTask(
            root: root,
            environment: environment)
        tasks.append(tracySource)
        tasks = addingDependency(
            TaskID(rawValue: "workspace.tracy-sources"),
            to: TaskID(rawValue: "tracy.build"),
            in: tasks)

        if needsCore {
            let coreRoot = root.appending("core")
            let source = try await coreSourceTask(
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
            let rnRoot = root.appending("react-native")
            let source = try await reactNativeSourceTask(
                root: rnRoot, environment: environment)
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
                root: rnRoot, environment: environment)
            let swiftHost = ReactNativeColliderRecipe.buildSwiftHostCxx(
                root: rnRoot, environment: environment)
            let stage = try ReactNativeColliderRecipe.stageHostArchive(
                root: rnRoot, configuration: "debug")
                .addingDependencies([swiftHost.id])
            let sdk = ReactNativeColliderRecipe.publishNativeSDK(
                root: rnRoot,
                sdkRoot: nativeSDKRoot)
            tasks += [
                source, javascript, types, generate, boost, hermes, support,
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
        let root = FilePath(context.root.path)
        let environment = context.taskEnvironment
        let task: TaskDeclaration
        var tasks: [TaskDeclaration]
        switch component {
        case .reactNative:
            let source = try await reactNativeSourceTask(
                root: root.appending("react-native"),
                environment: environment)
            let dependencies =
                ReactNativeColliderRecipe.installJavaScriptDependencies(
                    root: root.appending("react-native"),
                    environment: environment)
            let types = ReactNativeColliderRecipe.generateStrictTypes(
                root: root.appending("react-native"),
                environment: environment)
            task = ReactNativeColliderRecipe.generate(
                root: root.appending("react-native"), environment: environment)
            tasks = [source, dependencies, types, task]
        case .vulkan:
            task = VulkanColliderRecipe.generate(
                root: root.appending("swift-vulkan"), environment: environment)
            tasks = [task]
        case .wayland:
            task = try WaylandColliderRecipe.generate(
                root: root.appending("swift-wayland"), environment: environment)
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
        let android = FilePath(context.root.path).appending("core/android")
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
        let core = FilePath(context.root.path).appending("core")
        let supplied = library.map {
            FilePath(URL(
                fileURLWithPath: $0,
                relativeTo: context.root).standardizedFileURL.path)
        }
        let task = CoreColliderRecipe.validateAndroidHost(
            root: core,
            library: supplied,
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
        let root = FilePath(context.root.path).appending("android-runtime")
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
            root: FilePath(context.root.path).appending("android-runtime"),
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
            root: FilePath(context.root.path).appending("android-runtime"),
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

    private func coreSourceTask(
        root: FilePath,
        environment: [String: String]
    ) async throws -> TaskDeclaration {
        CoreColliderRecipe.synchronizeSources(
            root: root,
            repositoryRoot: FilePath(context.root.path),
            sourceIdentity: try await sourceIdentity([
                "core/third-party",
                "third-party/swift-java",
                "third-party/swift-java-jni-core",
            ]),
            environment: environment)
    }

    private func androidHostTasks() async throws -> [TaskDeclaration] {
        let root = FilePath(context.root.path).appending("core")
        let environment = context.taskEnvironment
        let source = try await coreSourceTask(
            root: root,
            environment: environment)
        let skia = CoreColliderRecipe.buildSkiaAndroid(
            root: root, environment: environment)
        let sdk = CoreColliderRecipe.publishRenderSDK(
            root: root,
            sdkRoot: nativeSDKRoot,
            dependencies: [skia.id])
        let sourceID =
            environment["NUCLEUS_SWIFT_SOURCE_ID"] ?? "release-6.4.x"
        let build = CoreColliderRecipe.buildAndroidHost(
            root: root,
            sourceID: sourceID,
            environment: environment,
            dependencies: [sdk.id])
        let validate = CoreColliderRecipe.validateAndroidHost(
            root: root,
            environment: environment,
            dependencies: [build.id])
        return [source, skia, sdk, build, validate]
    }

    private func tracySourceTask(
        root: FilePath,
        environment: [String: String]
    ) async throws -> TaskDeclaration {
        let source = root.appending("swift-tracy/third-party/tracy")
        return TaskDeclaration(
            id: TaskID(rawValue: "workspace.tracy-sources"),
            component: ComponentID(rawValue: "tracy"),
            inputs: [
                .file(root.appending(".gitmodules")),
                .optionalTree(
                    source,
                    fallback: try await sourceIdentity([
                        "swift-tracy/third-party/tracy",
                    ])),
                .tool(.named("git")),
            ],
            outputs: [
                OutputDeclaration(
                    path: source.appending("public/TracyClient.cpp"),
                    validation: .regularFile),
            ],
            locks: [.checkout("tracy-sources")],
            operation: .command(CommandSpec(
                executable: .named("git"),
                arguments: [
                    "submodule", "update", "--init", "--recursive",
                    "swift-tracy/third-party/tracy",
                ],
                workingDirectory: root,
                environment: environment)))
    }

    private func reactNativeSourceTask(
        root: FilePath,
        environment: [String: String]
    ) async throws -> TaskDeclaration {
        ReactNativeColliderRecipe.synchronizeSources(
            root: root,
            repositoryRoot: FilePath(context.root.path),
            sourceIdentity: try await sourceIdentity([
                "react-native/third-party",
            ]),
            environment: environment)
    }

    private func sourceIdentity(_ paths: [String]) async throws -> [UInt8] {
        Array(try await context.run(
            "git",
            ["ls-files", "--stage"] + paths,
            directory: context.root,
            capture: true).utf8)
    }

    private var nativeSDKRoot: FilePath {
        if let explicit = context.taskEnvironment["NUCLEUS_NATIVE_SDK_ROOT"] {
            return FilePath(explicit)
        }
        return FilePath(context.cacheRoot
            .appendingPathComponent("nucleus/nucleus-native-sdk").path)
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
        var directory: ObjCBool = false
        guard !path.isEmpty,
              FileManager.default.fileExists(
                atPath: path, isDirectory: &directory),
              directory.boolValue
        else {
            throw WorkspaceFailure.message(
                "required host directory was not resolved: \(path)")
        }
        return FilePath(path)
    }

    private func requiredFile(_ path: String) throws -> FilePath {
        var directory: ObjCBool = false
        guard path.hasPrefix("/"),
              FileManager.default.fileExists(
                atPath: path, isDirectory: &directory),
              !directory.boolValue
        else {
            throw WorkspaceFailure.message(
                "required host library was not resolved: \(path)")
        }
        return FilePath(path)
    }
}
