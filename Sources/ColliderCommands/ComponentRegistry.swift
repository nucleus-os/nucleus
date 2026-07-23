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

    private func testTasks() throws -> [TaskDeclaration] {
        let root = FilePath(context.root.path)
        let environment = context.taskEnvironment
        return try buildTasks() + [
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
    }

    func build(selection: String?, controls: TaskControls) throws {
        try context.execute(
            tasks: try buildTasks(),
            selected: try selectedBuildTasks(selection),
            controls: controls)
    }

    func bootstrap(selection: String?, controls: TaskControls) throws {
        let name = selection ?? "all"
        let supported = Set([
            "all", "runtime", "tracy", "vulkan", "wayland", "core",
            "linux", "rn", "compositor", "shell", "android-runtime",
        ])
        guard supported.contains(name) else {
            throw WorkspaceFailure.message(
                "unknown runtime component '\(name)'")
        }
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

        let tracySource = try tracySourceTask(
            root: root,
            environment: environment)
        tasks.append(tracySource)
        tasks = addingDependency(
            TaskID(rawValue: "workspace.tracy-sources"),
            to: TaskID(rawValue: "tracy.build"),
            in: tasks)

        if needsCore {
            let coreRoot = root.appending("core")
            let source = try coreSourceTask(
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
            let source = try reactNativeSourceTask(
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
                host: try hermesHostDependencies())
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

        let selected = try selectedBuildTasks(
            name == "runtime" ? nil : name)
        try context.execute(tasks: tasks, selected: selected, controls: controls)
    }

    func test(selection: String?, controls: TaskControls) throws {
        try context.execute(
            tasks: try testTasks(),
            selected: try selectedTestTasks(selection),
            controls: controls)
    }

    func generate(_ component: String, controls: TaskControls) throws {
        let root = FilePath(context.root.path)
        let environment = context.taskEnvironment
        let task: TaskDeclaration
        var tasks: [TaskDeclaration]
        switch component {
        case "rn":
            let source = try reactNativeSourceTask(
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
        case "vulkan":
            task = VulkanColliderRecipe.generate(
                root: root.appending("swift-vulkan"), environment: environment)
            tasks = [task]
        case "wayland":
            task = try WaylandColliderRecipe.generate(
                root: root.appending("swift-wayland"), environment: environment)
            tasks = [task]
        default:
            throw WorkspaceFailure.message("unknown generator '\(component)'")
        }
        try context.execute(tasks: tasks, selected: [task.id], controls: controls)
    }

    func buildAndroidHost(
        gradleArguments: [String],
        controls: TaskControls
    ) throws {
        let tasks = try androidHostTasks()
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
        try context.execute(
            tasks: tasks + [gradle],
            selected: [gradle.id],
            controls: controls)
    }

    func buildAndroidNative(controls: TaskControls) throws {
        let tasks = try androidHostTasks()
        let selected = TaskID(rawValue: "core.android-host.validate")
        try context.execute(tasks: tasks, selected: [selected], controls: controls)
    }

    func validateAndroidHost(
        library: String?,
        controls: TaskControls
    ) throws {
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
        try context.execute(tasks: [task], selected: [task.id], controls: controls)
    }

    private func selectedBuildTasks(_ selection: String?) throws -> [TaskID] {
        let name = selection ?? "all"
        if name == "all" || name == "runtime" {
            return [
                TaskID(rawValue: "shell.build"),
                TaskID(rawValue: "android-runtime.build"),
            ]
        }
        let supported = Set([
            "tracy", "vulkan", "wayland", "core", "linux", "rn", "compositor", "shell",
            "android-runtime",
        ])
        guard supported.contains(name) else {
            throw WorkspaceFailure.message(
                "unknown runtime component '\(name)'; expected all, tracy, vulkan, wayland, core, linux, rn, compositor, shell, or android-runtime")
        }
        return [TaskID(rawValue: name + ".build")]
    }

    func selectedTestTasks(_ selection: String?) throws -> [TaskID] {
        let name = selection ?? "all"
        if name == "all" || name == "runtime" {
            return [
                "tracy.test", "vulkan.test", "wayland.test", "core.test",
                "linux.test", "rn.test", "compositor-core.test",
                "compositor.test", "shell.test",
                "android-runtime.test",
            ].map { TaskID(rawValue: $0) }
        }
        let taskNames: [String: [String]] = [
            "tracy": ["tracy.test"],
            "vulkan": ["vulkan.test"],
            "wayland": ["wayland.test"],
            "core": ["core.test"],
            "linux": ["linux.test"],
            "rn": ["rn.test"],
            "compositor": ["compositor-core.test", "compositor.test"],
            "shell": ["shell.test"],
            "android-runtime": ["android-runtime.test"],
        ]
        guard let selected = taskNames[name] else {
            throw WorkspaceFailure.message(
                "unknown runtime component '\(name)'; expected all, tracy, vulkan, wayland, core, linux, rn, compositor, shell, or android-runtime")
        }
        return selected.map { TaskID(rawValue: $0) }
    }

    private func hermesHostDependencies() throws -> HermesHostDependencies {
        let include = try requiredDirectory(context.run(
            "pkg-config",
            ["--variable=includedir", "icu-uc"],
            capture: true))
        let libraryDirectory = try requiredDirectory(context.run(
            "pkg-config",
            ["--variable=libdir", "icu-uc"],
            capture: true))
        return try HermesHostDependencies(
            icuIncludeDirectory: include,
            icuUCLibrary: resolveHostLibrary(
                "libicuuc.so", preferredDirectory: libraryDirectory),
            icuI18NLibrary: resolveHostLibrary(
                "libicui18n.so", preferredDirectory: libraryDirectory),
            icuDataLibrary: resolveHostLibrary(
                "libicudata.so", preferredDirectory: libraryDirectory),
            cxxRuntimeLibrary: requiredFile(context.run(
                "clang++",
                ["-print-file-name=libc++.so.1"],
                capture: true)))
    }

    private func coreSourceTask(
        root: FilePath,
        environment: [String: String]
    ) throws -> TaskDeclaration {
        CoreColliderRecipe.synchronizeSources(
            root: root,
            repositoryRoot: FilePath(context.root.path),
            sourceIdentity: try sourceIdentity([
                "core/third-party",
                "third-party/swift-java",
                "third-party/swift-java-jni-core",
            ]),
            environment: environment)
    }

    private func androidHostTasks() throws -> [TaskDeclaration] {
        let root = FilePath(context.root.path).appending("core")
        let environment = context.taskEnvironment
        let source = try coreSourceTask(root: root, environment: environment)
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
    ) throws -> TaskDeclaration {
        let source = root.appending("swift-tracy/third-party/tracy")
        return TaskDeclaration(
            id: TaskID(rawValue: "workspace.tracy-sources"),
            component: ComponentID(rawValue: "tracy"),
            inputs: [
                .file(root.appending(".gitmodules")),
                .optionalTree(
                    source,
                    fallback: try sourceIdentity([
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
    ) throws -> TaskDeclaration {
        ReactNativeColliderRecipe.synchronizeSources(
            root: root,
            repositoryRoot: FilePath(context.root.path),
            sourceIdentity: try sourceIdentity([
                "react-native/third-party",
            ]),
            environment: environment)
    }

    private func sourceIdentity(_ paths: [String]) throws -> [UInt8] {
        Array(try context.run(
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
    ) throws -> FilePath {
        let preferred = preferredDirectory.appending(name)
        if FileManager.default.fileExists(atPath: preferred.string) {
            return preferred
        }
        return try requiredFile(context.run(
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
