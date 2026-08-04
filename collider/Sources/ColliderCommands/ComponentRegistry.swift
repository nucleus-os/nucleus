import AndroidRuntimeColliderRecipe
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
import SwiftTargetSDKColliderRecipe
import SystemPackage
import VulkanColliderRecipe
import WaylandColliderRecipe

struct ComponentRegistry {
    let context: WorkspaceContext

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
        let androidToolchain = try AndroidToolchainVersions.load(
            workspaceRoot: context.root)
        let targetSDKInputs = try SwiftTargetSDKInputs.load(
            from: context.layout.swiftSDK.appending("target-sdk-inputs.json"))
        buildContexts[
            .androidARM64(apiLevel: androidToolchain.minimumSDK)
        ] = try context.swiftPMInvocation(
            configuration: .release,
            staticSwiftStandardLibrary: true,
            target: .swiftSDK(
                name: targetSDKInputs.androidBundleID,
                targetTriple:
                    "aarch64-unknown-linux-android\(androidToolchain.minimumSDK)"),
            toolchainIdentity: "target-sdk-\(targetSDKInputs.snapshot)-android")
        let swiftSDKConfiguration = try swiftTargetSDKGenerationConfiguration(
            environment: recipeEnvironment,
            android: androidToolchain,
            inputs: targetSDKInputs)
        let recipeContext = RecipeContext(
            repositoryRoot: context.root,
            cacheRoot: context.cacheRoot,
            nativeSDKRoot: context.nativeSDKRoot.removingLastComponent(),
            environment: recipeEnvironment,
            buildContexts: buildContexts,
            configurations: [
                SwiftTargetSDKColliderRecipe.descriptor.id: swiftSDKConfiguration
            ])
        let componentTypes: [any ColliderComponent.Type] = [
            NativeBuilderColliderRecipe.self,
            BenchmarkColliderRecipe.self,
            ChromiumColliderRecipe.self,
            SanitizerColliderRecipe.self,
            AndroidRuntimeColliderRecipe.self,
            CoreColliderRecipe.self,
            ReactNativeColliderRecipe.self,
            ReleaseGateColliderRecipe.self,
            SwiftTargetSDKColliderRecipe.self,
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
                spelling: "linux",
                requestedEntrypoint: .bootstrap,
                destinations: [
                    ComponentEntrypointReference(
                        component: core,
                        entrypoint: .bootstrap),
                    ComponentEntrypointReference(
                        component: wayland,
                        entrypoint: .bootstrap),
                ]),
            ComponentEntrypointRoute(
                spelling: "android-runtime",
                requestedEntrypoint: .bootstrap,
                destinations: [
                    ComponentEntrypointReference(
                        component: core,
                        entrypoint: .bootstrap),
                    ComponentEntrypointReference(
                        component: wayland,
                        entrypoint: .bootstrap),
                ]),
            ComponentEntrypointRoute(
                spelling: "compositor",
                requestedEntrypoint: .bootstrap,
                destinations: [
                    ComponentEntrypointReference(
                        component: core,
                        entrypoint: .bootstrap),
                    ComponentEntrypointReference(
                        component: wayland,
                        entrypoint: .bootstrap),
                    ComponentEntrypointReference(
                        component: reactNative,
                        entrypoint: .bootstrap),
                ]),
            ComponentEntrypointRoute(
                spelling: "shell",
                requestedEntrypoint: .bootstrap,
                destinations: [
                    ComponentEntrypointReference(
                        component: core,
                        entrypoint: .bootstrap),
                    ComponentEntrypointReference(
                        component: wayland,
                        entrypoint: .bootstrap),
                    ComponentEntrypointReference(
                        component: reactNative,
                        entrypoint: .bootstrap),
                ]),
            ComponentEntrypointRoute(
                spelling: "android",
                requestedEntrypoint: .build,
                destinations: [
                    ComponentEntrypointReference(
                        component: core,
                        entrypoint: .androidBuild)
                ]),
            ComponentEntrypointRoute(
                spelling: "android",
                requestedEntrypoint: .testDefault,
                destinations: [
                    ComponentEntrypointReference(
                        component: core,
                        entrypoint: .androidBuild)
                ]),
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
            ],
            routes: routes)
    }

    func build(
        selection: String?,
        controls: TaskControls
    ) async throws {
        let catalog = try componentCatalog()
        try await context.execute(
            tasks: catalog.tasks,
            selected: try catalog.roots(
                named: .build,
                selection: selection),
            controls: controls)
    }

    func bootstrap(
        selection: String?,
        controls: TaskControls
    ) async throws {
        let catalog = try componentCatalog()
        try await context.execute(
            tasks: catalog.tasks,
            selected: try catalog.roots(
                named: .bootstrap,
                selection: selection),
            controls: controls)
    }

    func test(
        selection: String?,
        controls: TaskControls
    ) async throws {
        let catalog = try componentCatalog()
        var selected = try catalog.roots(
            named: .testDefault,
            selection: selection)
        if selection == nil || selection == "all" {
            selected += try catalog.roots(
                named: .testReleaseGate,
                selection: ReleaseGateColliderRecipe.descriptor.canonicalName)
        }
        try await context.execute(
            tasks: catalog.tasks,
            selected: selected,
            controls: controls)
    }

    func generate(
        _ selection: String,
        controls: TaskControls
    ) async throws {
        let catalog = try componentCatalog()
        try await context.execute(
            tasks: catalog.tasks,
            selected: try catalog.roots(
                named: .generate,
                selection: selection),
            controls: controls)
    }

    func runAndroid(
        _ entrypoint: ComponentEntrypointID,
        controls: TaskControls
    ) async throws {
        let catalog = try componentCatalog()
        try await context.execute(
            tasks: catalog.tasks,
            selected: try catalog.roots(
                named: entrypoint,
                selection: CoreColliderRecipe.descriptor.canonicalName),
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
        let catalog = try componentCatalog()
        try await context.execute(
            tasks: catalog.tasks,
            selected: [
                LinuxTaskIDs.build(.arm64),
                LinuxTaskIDs.build(.x86_64),
            ],
            controls: TaskControls())
    }

    func selectedBuildTasks(
        _ selection: String?
    ) throws -> [TaskID] {
        return try componentCatalog().roots(
            named: .build,
            selection: selection)
    }

    func selectedTestTasks(
        _ selection: String?
    ) throws -> [TaskID] {
        let catalog = try componentCatalog()
        var selected = try catalog.roots(
            named: .testDefault,
            selection: selection)
        if selection == nil || selection == "all" {
            selected += try catalog.roots(
                named: .testReleaseGate,
                selection: ReleaseGateColliderRecipe.descriptor.canonicalName)
        }
        return selected
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

    private func swiftTargetSDKGenerationConfiguration(
        environment: [String: String],
        android: AndroidToolchainVersions,
        inputs: SwiftTargetSDKInputs
    ) throws -> SwiftTargetSDKGenerationConfiguration {
        let recipeRoot = context.layout.swiftSDK
        let inputsFile = recipeRoot.appending("target-sdk-inputs.json")
        let sourceID =
            environment["NUCLEUS_SWIFT_SOURCE_ID"].flatMap {
                $0.isEmpty ? nil : $0
            } ?? "swift-6.4-source"
        let generatorSource = recipeRoot.appending("source/swift-sdk-generator")
        let ndkRoot = try android.ndkRoot(
            environment: environment,
            validate: false,
            fallbackHome: context.cacheRoot.appending("nucleus/unconfigured-home"))
        let paths = SwiftTargetSDKStoragePaths(cacheRoot: context.cacheRoot)
        let fixture = context.root.appending(
            "collider/engine/Sources/ColliderRuntime/Resources/"
                + "ToolchainValidationFixtures/AndroidSDKConsumer")
        let validator = recipeRoot.appending("validate-target-sdk-artifacts.sh")
        let runtimeBuilderContext = recipeRoot.appending("runtime-build-container")
        let runtimePreset = recipeRoot.appending(
            "nucleus-target-runtime-presets.ini")
        let sysrootPreparer = recipeRoot.appending("prepare-linux-sysroot.sh")
        let swiftExecutable = FilePath(
            environment["SWIFT"] ?? "/usr/bin/swift")
        let artifactID = try swiftTargetSDKArtifactID(
            inputsFile: inputsFile,
            validationFixture: fixture,
            validator: validator,
            ndkIdentity: android.ndk,
            xcodeIdentity: try ArtifactHasher.digest(file: swiftExecutable).description,
            sourceID: sourceID,
            runtimeBuilderContext: runtimeBuilderContext,
            runtimePreset: runtimePreset,
            sysrootPreparer: sysrootPreparer,
            generatorSourceID: sourceID)
        let linuxTargets = try inputs.linuxTargets.map { target in
            let buildID = try swiftTargetRuntimeBuildID(
                inputs: inputs,
                target: target,
                sourceID: sourceID,
                runtimeBuilderContext: runtimeBuilderContext,
                runtimePreset: runtimePreset,
                sysrootPreparer: sysrootPreparer)
            let root = paths.runtimeBuildRoot.appending(
                "\(target.architecture.rawValue)/\(buildID)")
            return SwiftLinuxTargetBuildConfiguration(
                target: target,
                runtimeBuildWorkspace: root.appending("build"),
                runtimeCompilerCache: paths.runtimeCompilerCache.appending(
                    target.architecture.rawValue),
                runtimeInstall: root.appending("install"),
                sysroot: root.appending("sysroot"))
        }
        let generation = paths.artifactRoot.appending("generations/\(artifactID)")
        let home =
            environment["HOME"].flatMap {
                $0.isEmpty ? nil : FilePath($0)
            }
            ?? FilePath(FileManager.default.homeDirectoryForCurrentUser.path)
        return SwiftTargetSDKGenerationConfiguration(
            inputs: inputs,
            inputsFile: inputsFile,
            androidAPILevel: android.minimumSDK,
            downloadRoot: paths.downloadRoot,
            generatorSource: generatorSource,
            generatorScratch: paths.generatorScratch,
            sourceWorkspace: recipeRoot.appending("source"),
            sourceID: sourceID,
            runtimeBuilderContext: runtimeBuilderContext,
            runtimeBuilderImageID: paths.runtimeBuilderImageID,
            linuxTargets: linuxTargets,
            sysrootPreparer: sysrootPreparer,
            candidate: paths.artifactRoot.appending(
                "generations/.candidate-\(artifactID)"),
            generation: generation,
            active: paths.artifactRoot.appending("current"),
            ndkRoot: ndkRoot,
            validationFixture: fixture,
            validator: validator,
            swiftExecutable: swiftExecutable,
            sdkDiscoveryRoot: home.appending(".swiftpm/swift-sdks"),
            displacedRoot: paths.artifactRoot.appending("displaced/\(artifactID)"),
            rebuildLock: paths.rebuildLock,
            environment: swiftTargetSDKTaskEnvironment(
                environment,
                runtimeSourceID: sourceID))
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

}
