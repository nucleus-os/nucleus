import AndroidRuntimeColliderRecipe
import ArgumentParser
import ColliderCore
import ColliderRuntime
import CompositorColliderRecipe
import CoreColliderRecipe
import Foundation
import LinuxColliderRecipe
import NativeBuilderColliderRecipe
import ReactNativeColliderRecipe
import ShellColliderRecipe
import SystemPackage
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
        try linuxArchitectureTasks()
    }

    func testTasks(
        selection: ComponentSelection?,
        drmRenderNodeResolver: ([String: String]) throws -> String =
            requiredDRMRenderNode
    ) throws -> [TaskDeclaration] {
        let environment = context.taskEnvironment
        var tasks = try buildTasks()
        let effectiveSelection = selection ?? .all
        if effectiveSelection == .gpuDRM {
            let swiftPM = try context.swiftPMInvocation()
            var drmEnvironment = environment
            drmEnvironment["NUCLEUS_TEST_DRM_RENDER_NODE"] =
                try drmRenderNodeResolver(environment)
            tasks.append(
                CompositorColliderRecipe.preflightDRMGPU(
                    root: context.layout.compositorCore,
                    environment: drmEnvironment,
                    swiftPM: swiftPM))
            tasks.append(
                CompositorColliderRecipe.testDRMGPU(
                    root: context.layout.compositorCore,
                    environment: drmEnvironment,
                    swiftPM: swiftPM))
        }
        if selection == nil || selection == .all {
            tasks += try releaseGateTasks()
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
            let waylandRoot = layout.swiftWayland
            let nativeBuilder = nativeBuilderConfiguration(
                coreRoot: layout.core)
            for target in linuxNativeTargets {
                let sdk = WaylandColliderRecipe.buildNativeSDK(
                    root: waylandRoot,
                    sdkRoot: nativeSDKRoot(for: target),
                    environment: environment,
                    target: target,
                    builder: nativeBuilder)
                tasks.append(sdk)
                selected.append(sdk.id)
            }
        }

        if needsCore {
            let coreRoot = layout.core
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
                    sdkRoot: nativeSDKRoot(for: target),
                    target: target)
                tasks += [skia, sdk]
                selected.append(sdk.id)
            }
        }

        if needsRN {
            let rnRoot = layout.reactNative
            let nativeBuilder = nativeBuilderConfiguration(
                coreRoot: layout.core)
            let javascript =
                ReactNativeColliderRecipe.installJavaScriptDependencies(
                    root: rnRoot,
                    environment: environment,
                    builder: nativeBuilder)
            let generate = ReactNativeColliderRecipe.generate(
                root: rnRoot,
                environment: environment,
                builder: nativeBuilder)
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
                    sdkRoot: nativeSDKRoot(for: target),
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
        let task: TaskDeclaration
        var tasks: [TaskDeclaration]
        switch component {
        case .reactNative:
            let root = layout.reactNative
            let builder = nativeBuilderConfiguration(
                coreRoot: layout.core)
            let image = NativeBuilderColliderRecipe.prepare(builder)
            let dependencies =
                ReactNativeColliderRecipe.installJavaScriptDependencies(
                    root: root,
                    environment: environment,
                    builder: builder)
            task = ReactNativeColliderRecipe.generate(
                root: root,
                environment: environment,
                builder: builder)
            tasks = [image, dependencies, task]
        case .vulkan:
            let swiftPM = try context.swiftPMInvocation()
            task = VulkanColliderRecipe.generate(
                root: layout.swiftVulkan,
                environment: environment,
                swiftPM: swiftPM)
            tasks = [task]
        case .wayland:
            let swiftPM = try linuxSwiftPMInvocation()
            let root = layout.swiftWayland
            let builder = nativeBuilderConfiguration(
                coreRoot: layout.core)
            let image = NativeBuilderColliderRecipe.prepare(builder)
            let target = NativeLinuxTarget(architecture: .arm64)
            let scannerSDKRoot = nativeSDKRoot(for: target)
            let scannerSDK = WaylandColliderRecipe.buildNativeSDK(
                root: root,
                sdkRoot: scannerSDKRoot,
                environment: environment,
                target: target,
                builder: builder)
            task = try WaylandColliderRecipe.generate(
                root: root,
                environment: environment,
                swiftPM: swiftPM,
                builder: builder,
                scannerSDK: scannerSDKRoot.appending("wayland"))
            tasks = [image, scannerSDK, task]
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
        let android = context.layout.core.appending("android")
        let gradle = TaskDeclaration(
            id: TaskID(rawValue: "core.android.build"),
            component: ComponentID(rawValue: "core"),
            dependencies: [CoreTaskIDs.validateAndroidHost],
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
        let selected = CoreTaskIDs.validateAndroidHost
        try await context.execute(
            tasks: tasks,
            selected: [selected],
            controls: controls)
    }

    func validateAndroidHost(
        library: String?,
        controls: TaskControls
    ) async throws {
        let core = context.layout.core
        let toolchain = try AndroidToolchainVersions.load(
            workspaceRoot: context.root)
        let ndk = try toolchain.ndkRoot(environment: context.environment)
        let supplied = library.map {
            resolveWorkspacePath($0, relativeTo: context.root)
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
            ndk: ndk,
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
        let root = context.layout.androidRuntime
        let tasks = try AndroidRuntimeColliderRecipe.aospSourceTasks(
            root: root,
            environment: context.taskEnvironment)
        try await context.execute(
            tasks: tasks,
            selected: [AndroidRuntimeTaskIDs.aospSourceLock],
            controls: controls)
    }

    func prepareAndroidRuntimeSource(
        controls: TaskControls
    ) async throws {
        let tasks = try AndroidRuntimeColliderRecipe.aospSourceTasks(
            root: context.layout.androidRuntime,
            environment: context.taskEnvironment)
        try await context.execute(
            tasks: tasks,
            selected: [AndroidRuntimeTaskIDs.aospSource],
            controls: controls)
    }

    func buildAndroidRuntimeImage(
        controls: TaskControls
    ) async throws {
        let tasks = try AndroidRuntimeColliderRecipe.aospImageTasks(
            root: context.layout.androidRuntime,
            environment: context.taskEnvironment)
        try await context.execute(
            tasks: tasks,
            selected: [AndroidRuntimeTaskIDs.aospImage],
            controls: controls)
    }

    func buildAndroidRuntimeHost() async throws {
        let tasks = try buildTasks()
        try await context.execute(
            tasks: tasks,
            selected: [
                LinuxTaskIDs.build(.arm64),
                LinuxTaskIDs.build(.x86_64),
            ],
            controls: TaskControls())
    }

    func selectedBuildTasks(
        _ selection: ComponentSelection?
    ) throws -> [TaskID] {
        let selection = selection ?? .all
        switch selection {
        case .all, .runtime, .tracy, .vulkan, .wayland, .core, .config,
            .ipc, .linux, .reactNative, .compositor, .shell, .androidRuntime:
            return [
                LinuxTaskIDs.build(.arm64),
                LinuxTaskIDs.build(.x86_64),
            ]
        case .swiftSDK, .android, .browser, .loader, .gpuHeadless, .gpuDRM:
            throw WorkspaceFailure.message(
                "\(selection.rawValue) is not a runtime build component")
        }
    }

    func selectedTestTasks(
        _ selection: ComponentSelection?
    ) throws -> [TaskID] {
        let selection = selection ?? .all
        switch selection {
        case .all, .runtime, .tracy, .vulkan, .wayland, .core, .config,
            .ipc, .linux, .reactNative, .compositor, .shell, .androidRuntime:
            var selected = [
                LinuxTaskIDs.test(.arm64),
                LinuxTaskIDs.test(.x86_64),
            ]
            if selection == .all {
                selected += Self.releaseGateIDs.map(TaskID.init(rawValue:))
            }
            return selected
        case .loader:
            return [
                LinuxTaskIDs.testLoader(.arm64),
                LinuxTaskIDs.testLoader(.x86_64),
            ]
        case .gpuHeadless:
            return [
                LinuxTaskIDs.testGPUHeadless(.arm64),
                LinuxTaskIDs.testGPUHeadless(.x86_64),
            ]
        case .gpuDRM:
            return [CompositorTaskIDs.testGPUDRM]
        case .swiftSDK, .android, .browser:
            throw WorkspaceFailure.message(
                "\(selection.rawValue) is not a runtime test component")
        }
    }

    private static let releaseGateSuites: [(id: String, package: String, suite: String)] = [
        ("foundation-publication", "core", "NucleusFoundationPublicationStressTests"),
        ("foundation-lifecycle", "core", "NucleusFoundationLifecycleStressTests"),
        ("text-editor", "core", "NucleusTextEditorStressTests"),
        ("collection", "core", "NucleusCollectionStressTests"),
        (
            "platform-transport",
            "integration-tests/window-client-conformance",
            "NucleusPlatformTransportStressTests"
        ),
        (
            "compositor-transition",
            "compositor",
            "NucleusCompositorTransitionStressTests"
        ),
    ]

    private static let releaseGateIDs = releaseGateSuites.map {
        "test.release-gate.\($0.id)"
    }

    private func releaseGateTasks() throws -> [TaskDeclaration] {
        let swiftPM = try linuxSwiftPMInvocation(configuration: .release)
        let environment = context.taskEnvironment
        return Self.releaseGateSuites.map { suite in
            let requirement = swiftPM.testProduct(
                package: suite.package,
                testProduct: suite.suite,
                packageRoot: context.layout.root,
                environment: environment,
                arguments: ["--filter", suite.suite])
            return TaskDeclaration(
                id: TaskID(rawValue: "test.release-gate.\(suite.id)"),
                component: ComponentID(rawValue: "release-gate"),
                dependencies: [
                    NativeBuilderTaskIDs.prepare,
                    AndroidRuntimeTaskIDs.gfxstream(
                        NativeLinuxTarget(architecture: .arm64)),
                ],
                swiftTests: [requirement],
                inputs: [swiftPM.identityInput],
                locks: [.checkout("test-release-gate")],
                cachePolicy: .always,
                operation: .sequence([]))
        }
    }

    func linuxArchitectureTasks() throws -> [TaskDeclaration] {
        let root = context.layout.root
        let builder = nativeBuilderConfiguration(
            coreRoot: context.layout.core)
        let image = NativeBuilderColliderRecipe.prepare(builder)
        let sdkRoot = context.cacheRoot.appending(
            "nucleus/swift-target-sdks/current/swift-sdks")
        let environment = context.taskEnvironment

        func tasks(
            architecture: PlatformArchitecture,
            triple: String,
            artifactTarget: ArtifactTarget,
            translation: OCIIntelBinaryTranslationPolicy
        ) throws -> [TaskDeclaration] {
            let target = NativeLinuxTarget(architecture: architecture)
            let nativeSDK = nativeSDKRoot(for: target)
            let swiftPM = try linuxSwiftPMInvocation(
                architecture: architecture,
                triple: triple,
                artifactTarget: artifactTarget,
                translation: translation)
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

    func linuxSwiftPMInvocation(
        architecture: PlatformArchitecture = .arm64,
        triple: String? = nil,
        artifactTarget: ArtifactTarget? = nil,
        translation: OCIIntelBinaryTranslationPolicy? = nil,
        configuration: SwiftBuildConfiguration = .debug,
        sanitizer: String? = nil,
        linkerFlags additionalLinkerFlags: [String] = []
    ) throws -> SwiftPMInvocation {
        let root = context.layout.root
        let target = NativeLinuxTarget(architecture: architecture)
        let resolvedTriple = triple ?? target.targetTriple
        let resolvedArtifactTarget = artifactTarget ?? target.artifactTarget
        let resolvedTranslation = translation ?? target.intelBinaryTranslationPolicy
        let builder = nativeBuilderConfiguration(
            coreRoot: context.layout.core)
        let sdkRoot = context.cacheRoot.appending(
            "nucleus/swift-target-sdks/current/swift-sdks")
        let guestSDKRoot = "/home/nucleus-build/.swiftpm/swift-sdks"
        let imageIdentity = try ArtifactHasher.digest(tree: builder.context).description
        let sdkIdentity = try ArtifactHasher.digest(tree: sdkRoot).description
        let toolchainIdentity = "nucleus-linux-build@\(imageIdentity)+\(sdkIdentity)"
        let nativeSDK = nativeSDKRoot(for: target)
        let waylandSDK = nativeSDK.appending("wayland")
        let swiftPMUserRoot = root.appending(
            ".nucleus/swiftpm-user/\(target.identifier)")
        let guestTargetSDK =
            guestSDKRoot
            + "/nucleus-swift-6.4-linux.artifactbundle/swift-linux/"
            + resolvedTriple + "/ubuntu-noble.sdk"
        let architectureLibraryDirectory = "/usr/lib/\(target.gnuArchitecture)"
        let targetRuntimeLibraryDirectory =
            guestTargetSDK + "/usr/lib/\(target.gnuArchitecture)"
        let execution = SwiftPMExecution.oci(
            SwiftPMOCIExecution(
                executionPlatform: .linuxARM64OCI,
                artifactTarget: resolvedArtifactTarget,
                imageID: builder.imageID,
                hostname: "nucleus-linux-\(architecture.rawValue)",
                hostWorkingDirectory: root,
                mounts: [
                    OCIMount(source: root, target: root.string, access: .readWrite),
                    OCIMount(source: nativeSDK, target: nativeSDK.string, access: .readOnly),
                    OCIMount(source: builder.ccache, target: "/ccache", access: .readWrite),
                    OCIMount(
                        source: swiftPMUserRoot.appending("cache"),
                        target: "/home/nucleus-build/.cache",
                        access: .readWrite),
                    OCIMount(
                        source: swiftPMUserRoot.appending("configuration"),
                        target: "/home/nucleus-build/.swiftpm",
                        access: .readWrite),
                    OCIMount(source: sdkRoot, target: guestSDKRoot, access: .readOnly),
                ],
                intelBinaryTranslationPolicy: resolvedTranslation,
                resourceLimits: .parallelBuild,
                containerEnvironment: [
                    "CCACHE_DIR": "/ccache",
                    "HOME": "/home/nucleus-build",
                    "NUCLEUS_GFXSTREAM_BUILD_ROOT":
                        root.appending("android-runtime/.gfxstream-build/\(target.identifier)")
                        .string,
                    "NUCLEUS_NATIVE_SDK_ROOT": nativeSDK.string,
                    "LD_LIBRARY_PATH": [
                        "/opt/nucleus-vulkan-loader/\(target.gnuArchitecture)/lib",
                        guestTargetSDK + "/usr/lib/swift/linux",
                        targetRuntimeLibraryDirectory,
                        waylandSDK.appending("lib").string,
                        architectureLibraryDirectory,
                    ].joined(separator: ":"),
                    "PKG_CONFIG_LIBDIR":
                        waylandSDK.appending("lib/pkgconfig").string
                        + ":\(architectureLibraryDirectory)/pkgconfig:/usr/share/pkgconfig",
                    "SWIFT_TOOLCHAIN": "/opt/swift/usr",
                    "VK_DRIVER_FILES": "/usr/share/vulkan/icd.d/lvp_icd.json",
                    "VK_ICD_FILENAMES": "/usr/share/vulkan/icd.d/lvp_icd.json",
                ]))
        return try context.swiftPMInvocation(
            configuration: configuration,
            sanitizer: sanitizer,
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
            ] + additionalLinkerFlags,
            toolsets: [root.appending("swift-sdk/linux-builder-toolset.json")],
            target: .swiftSDK(
                name: "nucleus-swift-6.4-linux",
                targetTriple: resolvedTriple),
            execution: execution,
            toolchainIdentity: toolchainIdentity)
    }

    private func androidHostTasks() async throws -> [TaskDeclaration] {
        let root = context.layout.core
        let environment = context.taskEnvironment
        let toolchain = try AndroidToolchainVersions.load(
            workspaceRoot: context.root)
        let ndk = try toolchain.ndkRoot(environment: context.environment)
        let nativeBuilder = nativeBuilderConfiguration(coreRoot: root)
        let source = try CoreColliderRecipe.prepareSkiaDependencies(
            root: root, environment: environment)
        let builder = NativeBuilderColliderRecipe.prepare(nativeBuilder)
        let skia = CoreColliderRecipe.buildSkiaAndroid(
            root: root,
            minimumAndroidAPI: toolchain.minimumSDK,
            environment: environment,
            builder: nativeBuilder)
        let androidNativeSDKRoot = context.nativeSDKRoot(named: "android-arm64")
        var androidEnvironment = environment
        androidEnvironment["NUCLEUS_NATIVE_SDK_ROOT"] = androidNativeSDKRoot.string
        let sdk = CoreColliderRecipe.publishAndroidRenderSDK(
            root: root,
            sdkRoot: androidNativeSDKRoot,
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
            environment: androidEnvironment,
            swiftPM: swiftPM,
            dependencies: [sdk.id])
        let validate = CoreColliderRecipe.validateAndroidHost(
            root: root,
            library: swiftPM.configurationProducts.appending(
                "libnucleus-android.so"),
            ndk: ndk,
            environment: androidEnvironment,
            dependencies: [build.id])
        return [source, builder, skia, sdk, build, validate]
    }

    private var nativeSDKRoot: FilePath {
        context.nativeSDKRoot
    }

    private func nativeSDKRoot(for target: NativeLinuxTarget) -> FilePath {
        context.nativeSDKRoot(for: target)
    }

    private func nativeBuilderConfiguration(
        coreRoot: FilePath
    ) -> NativeOCIConfiguration {
        let cache = context.cacheRoot.appending("nucleus")
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
