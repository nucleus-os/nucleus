import AndroidRuntimeColliderRecipe
import ArgumentParser
import ColliderCore
import ColliderRuntime
import CompositorAppColliderRecipe
import CompositorColliderRecipe
import ConfigColliderRecipe
import CoreColliderRecipe
import Foundation
import IPCColliderRecipe
import LinuxColliderRecipe
import NativeBuilderColliderRecipe
import ReactNativeColliderRecipe
import ShellColliderRecipe
import SystemPackage
import TracyColliderRecipe
import VulkanColliderRecipe
import WaylandColliderRecipe

enum ComponentSelection: String, CaseIterable, ExpressibleByArgument {
    case all
    case runtime
    case swiftSDK = "swift-sdk"
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
        let linuxLanes = try linuxArchitectureTasks()
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
        ]
            + IPCColliderRecipe.builds(
                root: FilePath(layout.ipc.path),
                environment: environment,
                swiftPM: swiftPM
            )
            + LinuxColliderRecipe.builds(
                root: FilePath(layout.platformLinux.path),
                environment: environment,
                swiftPM: swiftPM
            )
            + linuxLanes
    }

    private func testTasks(
        selection: ComponentSelection?
    ) throws -> [TaskDeclaration] {
        let layout = context.layout
        let environment = context.taskEnvironment
        let swiftPM = try context.swiftPMInvocation()
        var tasks =
            try buildTasks() + [
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
            ]
            + ConfigColliderRecipe.tests(
                root: FilePath(layout.config.path),
                environment: environment,
                swiftPM: swiftPM
            )
            + ShellColliderRecipe.tests(
                root: FilePath(layout.shell.path),
                environment: environment,
                swiftPM: swiftPM
            )
            + IPCColliderRecipe.tests(
                root: FilePath(layout.ipc.path),
                environment: environment,
                swiftPM: swiftPM
            )
            + LinuxColliderRecipe.tests(
                root: FilePath(layout.platformLinux.path),
                environment: environment,
                swiftPM: swiftPM)
        let effectiveSelection = selection ?? .all
        if [.all, .runtime, .compositor].contains(
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
        if effectiveSelection == .gpuDRM {
            var drmEnvironment = environment
            drmEnvironment["NUCLEUS_TEST_DRM_RENDER_NODE"] =
                try requiredDRMRenderNode(environment: environment)
            tasks.append(
                CompositorColliderRecipe.preflightDRMGPU(
                    root: FilePath(layout.compositorCore.path),
                    environment: drmEnvironment,
                    swiftPM: swiftPM))
            tasks.append(
                CompositorColliderRecipe.testDRMGPU(
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
        guard
            ![
                .swiftSDK, .android, .browser, .loader, .gpuHeadless, .gpuDRM,
            ].contains(selection)
        else {
            throw WorkspaceFailure.message(
                "\(selection.rawValue) is not a runtime bootstrap component")
        }
        let name = selection.rawValue
        let layout = context.layout
        let environment = context.taskEnvironment
        let needsCore = [
            "all", "runtime", "core", "linux", "rn", "compositor",
            "shell", "android-runtime",
        ].contains(name)
        let needsRN = [
            "all", "runtime", "rn", "compositor", "shell",
        ].contains(name)
        let needsWayland = [
            "all", "runtime", "wayland", "core", "linux", "rn",
            "compositor", "shell", "android-runtime",
        ].contains(name)
        var tasks = try buildTasks()
        var selected: [TaskID] = []

        if needsWayland {
            let waylandRoot = FilePath(layout.swiftWayland.path)
            let nativeBuilder = nativeBuilderConfiguration(
                coreRoot: FilePath(layout.core.path))
            for target in linuxNativeTargets {
                let sdk = WaylandColliderRecipe.buildNativeSDK(
                    root: waylandRoot,
                    sdkRoot: nativeSDKRoot,
                    environment: environment,
                    target: target,
                    builder: nativeBuilder)
                tasks.append(sdk)
                selected.append(sdk.id)
            }
        }

        if needsCore {
            let coreRoot = FilePath(layout.core.path)
            let nativeBuilder = nativeBuilderConfiguration(coreRoot: coreRoot)
            let source = try CoreColliderRecipe.prepareSkiaDependencies(
                root: coreRoot, environment: environment)
            tasks.append(source)
            for target in linuxNativeTargets {
                let skia = CoreColliderRecipe.buildSkiaLinux(
                    root: coreRoot,
                    environment: environment,
                    target: target,
                    builder: nativeBuilder)
                let sdk = CoreColliderRecipe.publishLinuxRenderSDK(
                    root: coreRoot,
                    sdkRoot: nativeSDKRoot,
                    target: target)
                tasks += [skia, sdk]
                selected.append(sdk.id)
            }
        }

        if needsRN {
            let rnRoot = FilePath(layout.reactNative.path)
            let nativeBuilder = nativeBuilderConfiguration(
                coreRoot: FilePath(layout.core.path))
            let javascript =
                ReactNativeColliderRecipe.installJavaScriptDependencies(
                    root: rnRoot, environment: environment)
            let generate = ReactNativeColliderRecipe.generate(
                root: rnRoot, environment: environment)
            let boost = try ReactNativeColliderRecipe.provisionBoost(
                root: rnRoot, environment: environment)
            tasks += [javascript, generate, boost]
            for target in linuxNativeTargets {
                let hermes = ReactNativeColliderRecipe.buildHermes(
                    root: rnRoot,
                    environment: environment,
                    target: target,
                    builder: nativeBuilder)
                let support = ReactNativeColliderRecipe.buildSupportLibraries(
                    root: rnRoot,
                    environment: environment,
                    target: target,
                    builder: nativeBuilder)
                let cxx = ReactNativeColliderRecipe.buildCxxRuntime(
                    root: rnRoot,
                    environment: environment,
                    target: target,
                    builder: nativeBuilder)
                let sdk = ReactNativeColliderRecipe.publishNativeSDK(
                    root: rnRoot,
                    sdkRoot: nativeSDKRoot,
                    target: target)
                tasks += [hermes, support, cxx, sdk]
                selected.append(sdk.id)
            }
        }

        if !selected.isEmpty {
            try await context.execute(
                tasks: tasks,
                selected: selected,
                controls: controls)
        }
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
            task = ReactNativeColliderRecipe.generate(
                root: root, environment: environment)
            tasks = [dependencies, task]
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
            operation: .command(
                CommandSpec(
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
            FilePath(
                URL(
                    fileURLWithPath: $0,
                    relativeTo: context.root
                ).standardizedFileURL.path)
        }
        let sourceID = try requiredSwiftSourceID(context.taskEnvironment)
        let swiftPM = try context.swiftPMInvocation(
            configuration: .release,
            staticSwiftStandardLibrary: true,
            target: .swiftSDK(
                name: "swift-\(sourceID)_android",
                targetTriple:
                    "aarch64-unknown-linux-android\(toolchain.minimumSDK)"))
        let task = CoreColliderRecipe.validateAndroidHost(
            root: core,
            library: supplied
                ?? swiftPM.configurationProducts.appending(
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
            selected: [
                TaskID(rawValue: "linux.arm64.build"),
                TaskID(rawValue: "linux.x86_64.build"),
            ],
            controls: TaskControls())
    }

    private func selectedBuildTasks(
        _ selection: ComponentSelection?
    ) throws -> [TaskID] {
        let selection = selection ?? .all
        if runtimeLinuxSelections.contains(selection) {
            return [
                TaskID(rawValue: "linux.arm64.build"),
                TaskID(rawValue: "linux.x86_64.build"),
            ]
        }
        guard
            ![
                .swiftSDK, .android, .browser, .loader, .gpuHeadless, .gpuDRM,
            ].contains(selection)
        else {
            throw WorkspaceFailure.message(
                "\(selection.rawValue) is not a runtime build component")
        }
        return [TaskID(rawValue: selection.rawValue + ".build")]
    }

    func selectedTestTasks(
        _ selection: ComponentSelection?
    ) throws -> [TaskID] {
        let selection = selection ?? .all
        if runtimeLinuxSelections.contains(selection) {
            return ["linux.arm64.test", "linux.x86_64.test"].map {
                TaskID(rawValue: $0)
            }
        }
        let taskNames: [ComponentSelection: [String]] = [
            .tracy: ["tracy.test"],
            .vulkan: ["vulkan.test"],
            .wayland: ["wayland.test"],
            .core: ["core.test"],
            .config: ["config.test"],
            .ipc: ["ipc.test"],
            .linux: ["linux.arm64.test", "linux.x86_64.test"],
            .reactNative: ["rn.test"],
            .compositor: ["linux.arm64.test", "linux.x86_64.test"],
            .shell: ["linux.arm64.test", "linux.x86_64.test"],
            .androidRuntime: ["linux.arm64.test", "linux.x86_64.test"],
            .loader: ["linux.arm64.test-loader", "linux.x86_64.test-loader"],
            .gpuHeadless: [
                "linux.arm64.test-gpu-headless",
                "linux.x86_64.test-gpu-headless",
            ],
            .gpuDRM: ["compositor-core.test-gpu-drm"],
        ]
        guard let selected = taskNames[selection] else {
            throw WorkspaceFailure.message(
                "\(selection.rawValue) is not a runtime test component")
        }
        return selected.map { TaskID(rawValue: $0) }
    }

    private func linuxArchitectureTasks() throws -> [TaskDeclaration] {
        let root = context.layout.rootPath
        let builder = nativeBuilderConfiguration(
            coreRoot: FilePath(context.layout.core.path))
        let image = NativeBuilderColliderRecipe.prepare(builder)
        let sdkRoot = FilePath(context.cacheRoot.path).appending(
            "nucleus/swift-target-sdks/current/swift-sdks")
        let guestSDKRoot = "/home/nucleus-build/.swiftpm/swift-sdks"
        let imageIdentity = try ArtifactHasher.digest(tree: builder.context)
            .description
        let sdkIdentity = try ArtifactHasher.digest(tree: sdkRoot).description
        let toolchainIdentity =
            "nucleus-linux-build@\(imageIdentity)+\(sdkIdentity)"
        let environment = context.taskEnvironment

        func tasks(
            architecture: PlatformArchitecture,
            triple: String,
            artifactTarget: ArtifactTarget,
            translation: OCIIntelBinaryTranslationPolicy
        ) throws -> [TaskDeclaration] {
            let target = NativeLinuxTarget(architecture: architecture)
            let nativeSDK = nativeSDKRoot.appending(target.identifier)
            let waylandSDK = nativeSDK.appending("wayland")
            let swiftPMUserRoot = root.appending(
                ".nucleus/swiftpm-user/\(target.identifier)")
            let guestTargetSDK =
                guestSDKRoot
                + "/nucleus-swift-6.4-linux.artifactbundle/swift-linux/"
                + triple + "/ubuntu-noble.sdk"
            let mounts = [
                OCIMount(
                    source: root,
                    target: root.string,
                    access: .readWrite),
                OCIMount(
                    source: nativeSDK,
                    target: nativeSDK.string,
                    access: .readOnly),
                OCIMount(
                    source: builder.ccache,
                    target: "/ccache",
                    access: .readWrite),
                OCIMount(
                    source: swiftPMUserRoot.appending("cache"),
                    target: "/home/nucleus-build/.cache",
                    access: .readWrite),
                OCIMount(
                    source: swiftPMUserRoot.appending("configuration"),
                    target: "/home/nucleus-build/.swiftpm",
                    access: .readWrite),
                OCIMount(
                    source: sdkRoot,
                    target: guestSDKRoot,
                    access: .readOnly),
            ]
            let architectureLibraryDirectory =
                "/usr/lib/\(target.gnuArchitecture)"
            let vulkanLoaderLibraryDirectory =
                "/opt/nucleus-vulkan-loader/\(target.gnuArchitecture)/lib"
            let targetRuntimeLibraryDirectory =
                guestTargetSDK + "/usr/lib/\(target.gnuArchitecture)"
            let swiftRuntimeLibraryDirectory =
                guestTargetSDK + "/usr/lib/swift/linux"
            let execution = SwiftPMExecution.oci(
                SwiftPMOCIExecution(
                    executionPlatform: .linuxARM64OCI,
                    artifactTarget: artifactTarget,
                    imageID: builder.imageID,
                    hostname: "nucleus-linux-\(architecture.rawValue)",
                    hostWorkingDirectory: root,
                    mounts: mounts,
                    intelBinaryTranslationPolicy: translation,
                    resourceLimits: .parallelBuild,
                    containerEnvironment: [
                        "CCACHE_DIR": "/ccache",
                        "HOME": "/home/nucleus-build",
                        "NUCLEUS_GFXSTREAM_BUILD_ROOT":
                            root.appending("android-runtime/.gfxstream-build/\(target.identifier)")
                            .string,
                        "NUCLEUS_NATIVE_SDK_ROOT": nativeSDK.string,
                        "LD_LIBRARY_PATH": [
                            vulkanLoaderLibraryDirectory,
                            swiftRuntimeLibraryDirectory,
                            targetRuntimeLibraryDirectory,
                            waylandSDK.appending("lib").string,
                            architectureLibraryDirectory,
                        ].joined(separator: ":"),
                        "PKG_CONFIG_LIBDIR":
                            waylandSDK.appending("lib/pkgconfig").string
                            + ":\(architectureLibraryDirectory)/pkgconfig:/usr/share/pkgconfig",
                        "SWIFT_TOOLCHAIN": "/opt/swift/usr",
                        "VK_DRIVER_FILES":
                            "/usr/share/vulkan/icd.d/lvp_icd.json",
                        "VK_ICD_FILENAMES":
                            "/usr/share/vulkan/icd.d/lvp_icd.json",
                    ]))
            let swiftPM = try context.swiftPMInvocation(
                cFlags: [
                    "-I\(waylandSDK.appending("include").string)",
                    "-idirafter/usr/include",
                    "-idirafter/usr/include/\(target.gnuArchitecture)",
                ],
                cxxFlags: [
                    "-I\(waylandSDK.appending("include").string)",
                    "-idirafter/usr/include",
                    "-idirafter/usr/include/\(target.gnuArchitecture)",
                ],
                linkerFlags: [
                    "-L/opt/nucleus-swiftpm-libcxx",
                    "-L\(waylandSDK.appending("lib").string)",
                    "-L\(targetRuntimeLibraryDirectory)",
                ],
                toolsets: [
                    root.appending("swift-sdk/linux-builder-toolset.json")
                ],
                target: .swiftSDK(
                    name: "nucleus-swift-6.4-linux",
                    targetTriple: triple),
                execution: execution,
                toolchainIdentity: toolchainIdentity)
            let gfxstream = AndroidRuntimeColliderRecipe.buildGfxstream(
                root: root.appending("android-runtime"),
                repositoryRoot: root,
                environment: environment,
                target: target,
                builder: builder)
            return [gfxstream]
                + LinuxColliderRecipe.architectureLane(
                    architecture: architecture,
                    root: root,
                    environment: environment,
                    swiftPM: swiftPM,
                    imageTask: image.id,
                    nativeDependencies: [gfxstream.id],
                    sdkRoot: sdkRoot,
                    nativeSDKRoot: nativeSDK)
        }

        return [image]
            + (try tasks(
                architecture: .arm64,
                triple: "aarch64-unknown-linux-gnu",
                artifactTarget: .linuxARM64,
                translation: .disabled))
            + (try tasks(
                architecture: .x86_64,
                triple: "x86_64-unknown-linux-gnu",
                artifactTarget: .linuxX86_64,
                translation: .required))
    }

    private func androidHostTasks() async throws -> [TaskDeclaration] {
        let root = FilePath(context.layout.core.path)
        let environment = context.taskEnvironment
        let toolchain = try AndroidToolchainVersions.load(
            workspaceRoot: context.root)
        let ndk = FilePath(
            try toolchain.ndkRoot(environment: context.environment).path)
        let nativeBuilder = nativeBuilderConfiguration(coreRoot: root)
        let source = try CoreColliderRecipe.prepareSkiaDependencies(
            root: root, environment: environment)
        let builder = NativeBuilderColliderRecipe.prepare(nativeBuilder)
        let skia = CoreColliderRecipe.buildSkiaAndroid(
            root: root,
            minimumAndroidAPI: toolchain.minimumSDK,
            environment: environment,
            builder: nativeBuilder)
        let sdk = CoreColliderRecipe.publishRenderSDK(
            root: root,
            sdkRoot: nativeSDKRoot,
            dependencies: [skia.id])
        let sourceID = try requiredSwiftSourceID(environment)
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
        return [source, builder, skia, sdk, build, validate]
    }

    private var nativeSDKRoot: FilePath {
        FilePath(context.nativeSDKRoot.path)
    }

    private func nativeBuilderConfiguration(
        coreRoot: FilePath
    ) -> NativeOCIConfiguration {
        let cache = FilePath(context.cacheRoot.path).appending("nucleus")
        return NativeOCIConfiguration(
            context: coreRoot.appending("build-container"),
            imageID: cache.appending("build-containers/native/image-id"),
            ccache: cache.appending("ccache/native"),
            swiftSDKRoot: cache.appending(
                "swift-target-sdks/current/swift-sdks"),
            environment: context.taskEnvironment)
    }

    private func requiredSwiftSourceID(
        _ environment: [String: String]
    ) throws -> String {
        guard let sourceID = environment["NUCLEUS_SWIFT_SOURCE_ID"],
            !sourceID.isEmpty
        else {
            throw WorkspaceFailure.message(
                "NUCLEUS_SWIFT_SOURCE_ID is missing; source tools/host-env.sh")
        }
        return sourceID
    }

    private var linuxNativeTargets: [NativeLinuxTarget] {
        [
            NativeLinuxTarget(architecture: .arm64),
            NativeLinuxTarget(architecture: .x86_64),
        ]
    }

    private var runtimeLinuxSelections: Set<ComponentSelection> {
        [
            .all, .runtime, .tracy, .vulkan, .wayland, .core, .config,
            .ipc, .linux, .reactNative, .compositor, .shell, .androidRuntime,
        ]
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

}
