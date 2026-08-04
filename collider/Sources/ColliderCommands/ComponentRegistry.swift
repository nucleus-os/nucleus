import AndroidRuntimeColliderRecipe
import ArgumentParser
import ChromiumColliderRecipe
import ColliderCore
import ColliderRuntime
import CompositorColliderRecipe
import CoreColliderRecipe
import Foundation
import LinuxColliderRecipe
import NativeBuilderColliderRecipe
import QualificationColliderRecipe
import ReactNativeColliderRecipe
import ReleaseGateColliderRecipe
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
        try componentCatalog().tasks
    }

    func componentCatalog(
        environment environmentOverride: [String: String]? = nil
    ) throws -> ComponentCatalog {
        let recipeEnvironment = environmentOverride ?? context.taskEnvironment
        var buildContexts: [RecipeBuildContextID: SwiftPMInvocation] = [
            .hostDebug: try context.swiftPMInvocation()
        ]
        for architecture in PlatformArchitecture.allCases {
            buildContexts[.linux(architecture)] = try linuxSwiftPMInvocation(
                architecture: architecture)
        }
        buildContexts[.linux(.arm64, configuration: .release)] =
            try linuxSwiftPMInvocation(configuration: .release)
        for sanitizer in SanitizerKind.allCases {
            buildContexts[.linux(.arm64, sanitizer: sanitizer.rawValue)] =
                try linuxSwiftPMInvocation(
                    sanitizer: sanitizer.rawValue,
                    linkerFlags: sanitizer == .undefined ? ["-lubsan"] : [])
        }
        let recipeContext = RecipeContext(
            repositoryRoot: context.root,
            cacheRoot: context.cacheRoot,
            nativeSDKRoot: context.nativeSDKRoot.removingLastComponent(),
            environment: recipeEnvironment,
            buildContexts: buildContexts)
        let componentTypes: [any ColliderComponent.Type] = [
            NativeBuilderColliderRecipe.self,
            BenchmarkColliderRecipe.self,
            ChromiumColliderRecipe.self,
            SanitizerColliderRecipe.self,
            AndroidRuntimeColliderRecipe.self,
            CoreColliderRecipe.self,
            ReactNativeColliderRecipe.self,
            ReleaseGateColliderRecipe.self,
            WaylandColliderRecipe.self,
            LinuxColliderRecipe.self,
            CompositorColliderRecipe.self,
            VulkanColliderRecipe.self,
        ]
        let components = try componentTypes.map {
            try $0.makeComponent(in: recipeContext)
        }
        let core = CoreColliderRecipe.descriptor.id
        let wayland = WaylandColliderRecipe.descriptor.id
        let reactNative = ReactNativeColliderRecipe.descriptor.id
        let linux = LinuxColliderRecipe.descriptor.id
        let runtime = Set([
            NativeBuilderColliderRecipe.descriptor.id,
            AndroidRuntimeColliderRecipe.descriptor.id,
            core,
            reactNative,
            wayland,
            linux,
            CompositorColliderRecipe.descriptor.id,
            VulkanColliderRecipe.descriptor.id,
        ])
        let runtimeSpellings = [
            "tracy", "vulkan", "wayland", "core", "config", "ipc",
            "rn", "compositor", "shell", "android-runtime",
        ]
        let linuxBuild = ComponentEntrypointReference(
            component: linux,
            entrypoint: .build)
        let linuxTest = ComponentEntrypointReference(
            component: linux,
            entrypoint: .testDefault)
        var routes = runtimeSpellings.flatMap { spelling in
            [
                ComponentEntrypointRoute(
                    spelling: spelling,
                    requestedEntrypoint: .build,
                    destinations: [linuxBuild]),
                ComponentEntrypointRoute(
                    spelling: spelling,
                    requestedEntrypoint: .testDefault,
                    destinations: [linuxTest]),
            ]
        }
        routes += [
            ComponentEntrypointRoute(
                spelling: "gpu-headless",
                requestedEntrypoint: .testDefault,
                destinations: [
                    ComponentEntrypointReference(
                        component: linux,
                        entrypoint: .testGPUHeadless)
                ]),
            ComponentEntrypointRoute(
                spelling: "gpu-drm",
                requestedEntrypoint: .testDefault,
                destinations: [
                    ComponentEntrypointReference(
                        component: CompositorColliderRecipe.descriptor.id,
                        entrypoint: .testGPUDRM)
                ]),
            ComponentEntrypointRoute(
                spelling: "loader",
                requestedEntrypoint: .testDefault,
                destinations: [
                    ComponentEntrypointReference(
                        component: linux,
                        entrypoint: ComponentEntrypointID(rawValue: "test.loader"))
                ]),
        ]
        return try ComponentCatalog(
            components: components,
            groups: [
                ComponentSelectionGroup(name: "all", components: runtime),
                ComponentSelectionGroup(name: "runtime", components: runtime),
                ComponentSelectionGroup(
                    name: "linux-runtime",
                    components: [core, wayland]),
                ComponentSelectionGroup(
                    name: "desktop-runtime",
                    components: [core, wayland, reactNative]),
            ],
            routes: routes)
    }

    func testTasks(
        selection: ComponentSelection?
    ) throws -> [TaskDeclaration] {
        _ = selection
        return try buildTasks()
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
                .swiftSDK, .android, .loader, .gpuHeadless, .gpuDRM,
            ].contains(selection)
        else {
            throw WorkspaceFailure.message(
                "\(selection.rawValue) is not a runtime bootstrap component")
        }
        let catalog = try componentCatalog()
        let catalogSelection: String
        switch selection {
        case .all, .runtime:
            catalogSelection = selection.rawValue
        case .core, .wayland, .reactNative:
            catalogSelection = selection.rawValue
        case .browser:
            catalogSelection = ChromiumColliderRecipe.descriptor.canonicalName
        case .linux, .androidRuntime:
            catalogSelection = "linux-runtime"
        case .compositor, .shell:
            catalogSelection = "desktop-runtime"
        case .tracy, .vulkan, .config, .ipc:
            throw WorkspaceFailure.message(
                "\(selection.rawValue) has no bootstrap entrypoint")
        case .swiftSDK, .android, .loader, .gpuHeadless, .gpuDRM:
            preconditionFailure("non-runtime bootstrap selection escaped validation")
        }
        try await context.execute(
            tasks: catalog.tasks,
            selected: try catalog.roots(
                named: .bootstrap,
                selection: catalogSelection),
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
        let selection: String
        switch component {
        case .reactNative:
            selection = ReactNativeColliderRecipe.descriptor.canonicalName
        case .vulkan:
            selection = VulkanColliderRecipe.descriptor.canonicalName
        case .wayland:
            selection = WaylandColliderRecipe.descriptor.canonicalName
        }
        let catalog = try componentCatalog()
        try await context.execute(
            tasks: catalog.tasks,
            selected: try catalog.roots(
                named: .generate,
                selection: selection),
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
        let catalog = try componentCatalog()
        try await context.execute(
            tasks: catalog.tasks,
            selected: try catalog.roots(
                named: ComponentEntrypointID(rawValue: "aosp.source-lock"),
                selection: AndroidRuntimeColliderRecipe.descriptor.canonicalName),
            controls: controls)
    }

    func prepareAndroidRuntimeSource(
        controls: TaskControls
    ) async throws {
        let catalog = try componentCatalog()
        try await context.execute(
            tasks: catalog.tasks,
            selected: try catalog.roots(
                named: ComponentEntrypointID(rawValue: "aosp.source"),
                selection: AndroidRuntimeColliderRecipe.descriptor.canonicalName),
            controls: controls)
    }

    func buildAndroidRuntimeImage(
        controls: TaskControls
    ) async throws {
        let catalog = try componentCatalog()
        try await context.execute(
            tasks: catalog.tasks,
            selected: try catalog.roots(
                named: ComponentEntrypointID(rawValue: "aosp.image"),
                selection: AndroidRuntimeColliderRecipe.descriptor.canonicalName),
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
            return try componentCatalog().roots(
                named: .build,
                selection: selection.rawValue)
        case .browser:
            return try componentCatalog().roots(
                named: .build,
                selection: ChromiumColliderRecipe.descriptor.canonicalName)
        case .swiftSDK, .android, .loader, .gpuHeadless, .gpuDRM:
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
            let catalog = try componentCatalog()
            var selected = try catalog.roots(
                named: .testDefault,
                selection: selection.rawValue)
            if selection == .all {
                selected += try catalog.roots(
                    named: .testReleaseGate,
                    selection: ReleaseGateColliderRecipe.descriptor.canonicalName)
            }
            return selected
        case .loader, .gpuHeadless, .gpuDRM:
            return try componentCatalog().roots(
                named: .testDefault,
                selection: selection.rawValue)
        case .browser:
            return try componentCatalog().roots(
                named: .testDefault,
                selection: ChromiumColliderRecipe.descriptor.canonicalName)
        case .swiftSDK, .android:
            throw WorkspaceFailure.message(
                "\(selection.rawValue) is not a runtime test component")
        }
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
        let sourceID =
            context.taskEnvironment["NUCLEUS_SWIFT_SOURCE_ID"]
            ?? "swift-6.4"
        let toolchainIdentity =
            "nucleus-linux-build-\(sourceID)-\(architecture.rawValue)"
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
