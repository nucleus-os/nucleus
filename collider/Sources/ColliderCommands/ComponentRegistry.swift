import AndroidRuntimeColliderRecipe
import ChromiumColliderRecipe
import ColliderCore
import ColliderPersistence
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

private struct NativeSDKCompilerConfiguration {
    let cFlags: [String]
    let cxxFlags: [String]
    let linkerFlags: [String]
}

struct ComponentRegistry {
    let context: WorkspaceContext

    func componentCatalog(
        environment environmentOverride: [String: String]? = nil,
        shellConfiguration: ShellRuntimeInstallConfiguration? = nil,
        androidAddonConfiguration: AndroidAddonPackageConfiguration? = nil,
        forceSwiftSDKGeneration: Bool = false
    ) throws -> ComponentCatalog {
        let recipeEnvironment = environmentOverride ?? context.taskEnvironment
        let nativeBuilderCache = context.cacheRoot.appending("nucleus")
        let nativeBuilder = try NativeBuilderColliderRecipe.prepare(
            context: context.layout.core.appending("build-container"),
            imageID: nativeBuilderCache.appending(
                "build-containers/native/image-id"),
            ccache: nativeBuilderCache.appending("ccache/native"),
            environment: recipeEnvironment)
        let androidToolchain = try AndroidToolchainVersions.load(
            workspaceRoot: context.root)
        let targetSDKInputs = try SwiftTargetSDKInputs.load(
            from: context.layout.swiftSDK.appending("target-sdk-inputs.json"))
        let swiftSDKConfiguration = try swiftTargetSDKGenerationConfiguration(
            environment: recipeEnvironment,
            android: androidToolchain,
            inputs: targetSDKInputs)
        let swiftTargetSDK = try SwiftTargetSDKColliderRecipe.prepare(
            swiftSDKConfiguration,
            reuseActiveGeneration: !forceSwiftSDKGeneration)
        let nativeConfiguration = NativeOCIConfiguration(
            base: nativeBuilder.configuration,
            swiftSDK: swiftTargetSDK.activeSDK)
        var buildContexts: [RecipeBuildContextID: SwiftPMInvocation] = [
            .hostDebug: try context.swiftPMInvocation()
        ]
        for architecture in PlatformArchitecture.allCases {
            buildContexts[.linux(architecture)] = try linuxSwiftPMInvocation(
                architecture: architecture,
                builder: nativeConfiguration)
        }
        buildContexts[.linux(.arm64, configuration: .release)] =
            try linuxSwiftPMInvocation(
                configuration: .release,
                builder: nativeConfiguration)
        for sanitizer in SanitizerKind.allCases {
            buildContexts[.linux(.arm64, sanitizer: sanitizer.rawValue)] =
                try linuxSwiftPMInvocation(
                    sanitizer: sanitizer.rawValue,
                    linkerFlags: sanitizer == .undefined ? ["-lubsan"] : [],
                    builder: nativeConfiguration)
        }
        buildContexts[
            .androidARM64(apiLevel: androidToolchain.minimumSDK)
        ] = try androidSwiftPMInvocation(
            toolchain: androidToolchain,
            inputs: targetSDKInputs,
            swiftSDKRoot: swiftTargetSDK.activeSDK.path,
            swiftExecutable: swiftTargetSDK.activeSwift.executable)
        var configurations: [ComponentID: any RecipeConfiguration] = [
            SwiftTargetSDKColliderRecipe.descriptor.id: swiftSDKConfiguration,
            NativeBuilderColliderRecipe.descriptor.id:
                NativeBuilderGraphConfiguration(
                    builder: nativeConfiguration,
                    nativeSDKRoot: context.nativeSDKRoot.removingLastComponent()),
        ]
        if let androidAddonConfiguration {
            configurations[AndroidRuntimeColliderRecipe.descriptor.id] =
                androidAddonConfiguration
        }
        #if os(Linux)
        configurations[ShellColliderRecipe.descriptor.id] =
            if let shellConfiguration {
                shellConfiguration
            } else {
                try shellRuntimeInstallConfiguration(
                    prefix: context.layout.installPrefix,
                    options: RuntimeBuildOptions())
            }
        #endif
        let baseRecipeContext = RecipeContext(
            repositoryRoot: context.root,
            cacheRoot: context.cacheRoot,
            environment: recipeEnvironment,
            buildContexts: buildContexts,
            configurations: configurations)
        let coreArtifacts = try CoreColliderRecipe.prepare(in: baseRecipeContext)
        let androidRuntime = try AndroidRuntimeColliderRecipe.prepare(
            in: baseRecipeContext)
        let waylandArtifacts = try WaylandColliderRecipe.prepare(
            in: baseRecipeContext)
        let reactNativeArtifacts = try ReactNativeColliderRecipe.prepare(
            in: baseRecipeContext,
            skiaExternalSources: coreArtifacts.skiaExternalSources,
            icuLibraries: coreArtifacts.linuxICULibraries)
        var targetArtifacts: [NativeLinuxTarget: ArtifactReferenceSet] = [:]
        func merge(_ artifacts: [NativeLinuxTarget: ArtifactReferenceSet]) {
            for (target, references) in artifacts {
                targetArtifacts[target, default: ArtifactReferenceSet()]
                    .append(contentsOf: references)
            }
        }
        for (target, gfxstream) in androidRuntime.artifacts.gfxstream {
            var artifacts = ArtifactReferenceSet(gfxstream.hostBackend)
            artifacts.append(gfxstream.guestVulkanDriver)
            targetArtifacts[target, default: ArtifactReferenceSet()]
                .append(contentsOf: artifacts)
        }
        merge(coreArtifacts.nativeSDKs)
        merge(reactNativeArtifacts.artifacts.nativeSDKs)
        merge(waylandArtifacts.nativeSDKs)
        for architecture in PlatformArchitecture.allCases {
            let target = NativeLinuxTarget(architecture: architecture)
            targetArtifacts[target, default: ArtifactReferenceSet()]
                .append(swiftTargetSDK.activeSDK)
        }
        configurations[NativeBuilderColliderRecipe.descriptor.id] =
            NativeBuilderGraphConfiguration(
                builder: nativeConfiguration,
                nativeSDKRoot: context.nativeSDKRoot.removingLastComponent(),
                targetArtifacts: targetArtifacts)
        let recipeContext = RecipeContext(
            repositoryRoot: context.root,
            cacheRoot: context.cacheRoot,
            environment: recipeEnvironment,
            buildContexts: buildContexts,
            configurations: configurations)
        let componentTypes: [any ColliderComponent.Type] = [
            BenchmarkColliderRecipe.self,
            ChromiumColliderRecipe.self,
            SanitizerColliderRecipe.self,
            ReleaseGateColliderRecipe.self,
            ShellColliderRecipe.self,
            LinuxColliderRecipe.self,
            CompositorColliderRecipe.self,
            VulkanColliderRecipe.self,
        ]
        let components =
            [
                nativeBuilder.component, swiftTargetSDK.component,
                coreArtifacts.component,
                androidRuntime.component, reactNativeArtifacts.component,
                waylandArtifacts.component,
            ]
            + (try componentTypes.map {
                try $0.makeComponent(in: recipeContext)
            })
        let core = CoreColliderRecipe.descriptor.id
        let wayland = WaylandColliderRecipe.descriptor.id
        let reactNative = ReactNativeColliderRecipe.descriptor.id
        let linux = LinuxColliderRecipe.descriptor.id
        #if os(Linux)
        let shell = ShellColliderRecipe.descriptor.id
        #endif
        let runtime = Set([
            NativeBuilderColliderRecipe.descriptor.id,
            AndroidRuntimeColliderRecipe.descriptor.id,
            core,
            reactNative,
            wayland,
            linux,
            CompositorColliderRecipe.descriptor.id,
            ShellColliderRecipe.descriptor.id,
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
        var shellBootstrapDestinations = [
            ComponentEntrypointReference(
                component: core,
                entrypoint: .bootstrap),
            ComponentEntrypointReference(
                component: wayland,
                entrypoint: .bootstrap),
            ComponentEntrypointReference(
                component: reactNative,
                entrypoint: .bootstrap),
        ]
        #if os(Linux)
        shellBootstrapDestinations.append(
            ComponentEntrypointReference(
                component: shell,
                entrypoint: .bootstrap))
        #endif
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
                destinations: shellBootstrapDestinations),
            ComponentEntrypointRoute(
                spelling: "android",
                requestedEntrypoint: .build,
                destinations: [
                    ComponentEntrypointReference(
                        component: core,
                        entrypoint: CoreEntrypoints.androidBuild)
                ]),
            ComponentEntrypointRoute(
                spelling: "android",
                requestedEntrypoint: .testDefault,
                destinations: [
                    ComponentEntrypointReference(
                        component: core,
                        entrypoint: CoreEntrypoints.androidBuild)
                ]),
            ComponentEntrypointRoute(
                spelling: "gpu-headless",
                requestedEntrypoint: .testDefault,
                destinations: [
                    ComponentEntrypointReference(
                        component: linux,
                        entrypoint: LinuxEntrypoints.testGPUHeadless)
                ]),
            ComponentEntrypointRoute(
                spelling: "gpu-drm",
                requestedEntrypoint: .testDefault,
                destinations: [
                    ComponentEntrypointReference(
                        component: CompositorColliderRecipe.descriptor.id,
                        entrypoint: CompositorEntrypoints.testGPUDRM)
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
        #if os(Linux)
        routes.append(
            ComponentEntrypointRoute(
                spelling: "tracy",
                requestedEntrypoint: .bootstrap,
                destinations: [
                    ComponentEntrypointReference(
                        component: shell,
                        entrypoint: .bootstrap)
                ]))
        #endif
        return ComponentCatalog(
            components: components,
            groups: [
                ComponentSelectionGroup(name: "all", components: runtime),
                ComponentSelectionGroup(name: "runtime", components: runtime),
            ],
            routes: routes,
            publicEntrypoints: publicEntrypoints(
                includeAndroidAddon: androidAddonConfiguration != nil))
    }

    private func publicEntrypoints(
        includeAndroidAddon: Bool
    ) -> [ComponentEntrypointRequest] {
        var requests: [ComponentEntrypointRequest] = []
        func expose(
            _ entrypoint: ComponentEntrypointID,
            to spellings: [String]
        ) {
            requests += spellings.map {
                ComponentEntrypointRequest(
                    spelling: $0,
                    entrypoint: entrypoint)
            }
        }

        let runtimeSpellings = [
            "all", "runtime", "linux", "tracy", "vulkan", "wayland",
            "core", "config", "ipc", "rn", "compositor", "shell",
            "android-runtime",
        ]
        expose(.build, to: runtimeSpellings + ["android", "browser", "chromium"])
        expose(
            .testDefault,
            to: runtimeSpellings
                + [
                    "android", "browser", "chromium", "gpu-headless",
                    "gpu-drm", "loader",
                ])
        var bootstrapSpellings = [
            "all", "runtime", "linux", "native-builder", "core",
            "react-native", "rn", "wayland", "android-runtime",
            "compositor", "shell", "browser", "chromium",
        ]
        #if os(Linux)
        bootstrapSpellings.append("tracy")
        #endif
        expose(.bootstrap, to: bootstrapSpellings)
        expose(.generate, to: ["react-native", "rn", "vulkan", "wayland"])
        expose(.install, to: ["browser", "chromium"])
        #if os(Linux)
        expose(.install, to: ["shell"])
        #endif
        expose(BenchmarkEntrypoints.run, to: ["benchmark"])
        expose(SanitizerKind.address.entrypoint, to: ["sanitize"])
        expose(SanitizerKind.undefined.entrypoint, to: ["sanitize"])
        expose(SanitizerKind.thread.entrypoint, to: ["sanitize"])
        expose(ReleaseGateEntrypoints.test, to: ["release-gate"])
        expose(CoreEntrypoints.androidBuild, to: ["core"])
        expose(CoreEntrypoints.androidNative, to: ["core"])
        expose(CoreEntrypoints.androidVerify, to: ["core"])
        expose(
            ComponentEntrypointID(rawValue: "aosp.source-lock"),
            to: ["android-runtime"])
        expose(
            ComponentEntrypointID(rawValue: "aosp.source"),
            to: ["android-runtime"])
        expose(
            ComponentEntrypointID(rawValue: "aosp.image"),
            to: ["android-runtime"])
        expose(.build, to: ["swift-sdk"])
        if includeAndroidAddon {
            expose(AndroidRuntimeEntrypoints.packageAddon, to: ["android-runtime"])
        }
        return requests
    }

    func build(
        selection: String?,
        controls: TaskControls
    ) async throws {
        let catalog = try componentCatalog()
        try await context.execute(
            catalog: catalog,
            requests: [
                ComponentEntrypointRequest(
                    entrypoint: .build,
                    selection: selection)
            ],
            controls: controls)
    }

    func bootstrap(
        selection: String?,
        controls: TaskControls
    ) async throws {
        let catalog = try componentCatalog()
        try await context.execute(
            catalog: catalog,
            requests: [
                ComponentEntrypointRequest(
                    entrypoint: .bootstrap,
                    selection: selection)
            ],
            controls: controls)
    }

    func test(
        selection: String?,
        controls: TaskControls
    ) async throws {
        let catalog = try componentCatalog()
        var requests = [
            ComponentEntrypointRequest(
                entrypoint: .testDefault,
                selection: selection)
        ]
        if selection == nil || selection == "all" {
            requests.append(
                ComponentEntrypointRequest(
                    entrypoint: ReleaseGateEntrypoints.test,
                    selection: ReleaseGateColliderRecipe.descriptor.canonicalName))
        }
        try await context.execute(
            catalog: catalog,
            requests: requests,
            controls: controls)
    }

    func generate(
        _ selection: String,
        controls: TaskControls
    ) async throws {
        let catalog = try componentCatalog()
        try await context.execute(
            catalog: catalog,
            requests: [
                ComponentEntrypointRequest(
                    entrypoint: .generate,
                    selection: selection)
            ],
            controls: controls)
    }

    func runAndroid(
        _ entrypoint: ComponentEntrypointID,
        controls: TaskControls
    ) async throws {
        let catalog = try componentCatalog()
        try await context.execute(
            catalog: catalog,
            requests: [
                ComponentEntrypointRequest(
                    entrypoint: entrypoint,
                    selection: CoreColliderRecipe.descriptor.canonicalName)
            ],
            controls: controls)
    }

    func verifyAndroidRuntimeSourceLock(
        controls: TaskControls
    ) async throws {
        let catalog = try componentCatalog()
        try await context.execute(
            catalog: catalog,
            requests: [
                ComponentEntrypointRequest(
                    entrypoint: ComponentEntrypointID(rawValue: "aosp.source-lock"),
                    selection: AndroidRuntimeColliderRecipe.descriptor.canonicalName)
            ],
            controls: controls)
    }

    func prepareAndroidRuntimeSource(
        controls: TaskControls
    ) async throws {
        let catalog = try componentCatalog()
        try await context.execute(
            catalog: catalog,
            requests: [
                ComponentEntrypointRequest(
                    entrypoint: ComponentEntrypointID(rawValue: "aosp.source"),
                    selection: AndroidRuntimeColliderRecipe.descriptor.canonicalName)
            ],
            controls: controls)
    }

    func buildAndroidRuntimeImage(
        controls: TaskControls
    ) async throws {
        let catalog = try componentCatalog()
        try await context.execute(
            catalog: catalog,
            requests: [
                ComponentEntrypointRequest(
                    entrypoint: ComponentEntrypointID(rawValue: "aosp.image"),
                    selection: AndroidRuntimeColliderRecipe.descriptor.canonicalName)
            ],
            controls: controls)
    }

    func buildAndroidRuntimeHost() async throws {
        let catalog = try componentCatalog()
        try await context.execute(
            catalog: catalog,
            requests: [
                ComponentEntrypointRequest(entrypoint: .build, selection: "linux")
            ],
            controls: TaskControls())
    }

    #if os(Linux)
    func buildTracyReceivers(
        controls: TaskControls = TaskControls()
    ) async throws {
        let catalog = try componentCatalog()
        try await context.execute(
            catalog: catalog,
            requests: [
                ComponentEntrypointRequest(
                    entrypoint: .bootstrap,
                    selection: "tracy")
            ],
            controls: controls)
    }

    func packageAndroidAddon(
        runtimeRoot: FilePath?,
        aospGeneration: FilePath,
        usesManagedAOSPGeneration: Bool,
        compatibility: FilePath,
        aospSigningKey: FilePath,
        addonSigningKey: FilePath,
        output: FilePath,
        controls: TaskControls = TaskControls()
    ) async throws {
        let configuration = AndroidAddonPackageConfiguration(
            swiftPM: try context.swiftPMInvocation(configuration: .release),
            runtimeRoot: runtimeRoot,
            runtimeScratch: context.layout.work.appending(
                "android-addon-runtime"),
            aospGeneration: aospGeneration,
            usesManagedAOSPGeneration: usesManagedAOSPGeneration,
            compatibility: compatibility,
            aospSigningKey: aospSigningKey,
            addonSigningKey: addonSigningKey,
            output: output,
            appArmorPolicy: context.layout.androidRuntime.appending(
                "container/lxc-nucleus-android.apparmor"),
            seccompPolicy: context.layout.androidRuntime.appending(
                "container/nucleus-android.seccomp"),
            environment: context.taskEnvironment)
        let catalog = try componentCatalog(
            androidAddonConfiguration: configuration)
        try await context.execute(
            catalog: catalog,
            requests: [
                ComponentEntrypointRequest(
                    entrypoint: AndroidRuntimeEntrypoints.packageAddon,
                    selection: AndroidRuntimeColliderRecipe.descriptor.canonicalName)
            ],
            controls: controls)
    }

    func installSession(
        prefix: FilePath,
        options: RuntimeBuildOptions,
        controls: TaskControls = TaskControls()
    ) async throws {
        let configuration = try shellRuntimeInstallConfiguration(
            prefix: prefix,
            options: options)
        let catalog = try componentCatalog(
            shellConfiguration: configuration)
        try await context.execute(
            catalog: catalog,
            requests: [
                ComponentEntrypointRequest(
                    entrypoint: .install,
                    selection: ShellColliderRecipe.descriptor.canonicalName)
            ],
            controls: controls)
    }

    private func shellRuntimeInstallConfiguration(
        prefix: FilePath,
        options: RuntimeBuildOptions
    ) throws -> ShellRuntimeInstallConfiguration {
        let swiftPM = try context.swiftPMInvocation(
            configuration: options.optimization == .debug ? .debug : .release,
            sanitizer: options.sanitizer?.rawValue,
            cFlags: options.tracy ? ["-DTRACY_ENABLE"] : [],
            linkerFlags: options.sanitizer == .undefined ? ["-lubsan"] : [])
        return ShellRuntimeInstallConfiguration(
            swiftPM: swiftPM,
            prefix: prefix,
            generationsRoot: runtimeGenerationsRoot(for: prefix),
            sessionPackage: context.layout.compositorSessionPackage,
            kernelContract: context.layout.androidRuntime.appending(
                "Sources/NucleusAndroidRuntimeCore/AndroidRuntimeKernelRequirements.swift"),
            trustKey: context.environment["NUCLEUS_ANDROID_ADDON_TRUST_KEY"]
                .flatMap { $0.isEmpty ? nil : FilePath($0) },
            buildMetadata: options.metadata,
            environment: context.taskEnvironment)
    }

    private func runtimeGenerationsRoot(for prefix: FilePath) -> FilePath {
        context.layout.runtimeState
            .appending(runtimeGenerationKey(for: prefix))
            .appending("generations")
    }

    private func runtimeGenerationKey(for prefix: FilePath) -> String {
        let standardized = URL(fileURLWithPath: prefix.string)
            .standardizedFileURL.path
        let root = URL(fileURLWithPath: context.root.string)
            .standardizedFileURL.path
        if standardized == root { return "root" }
        if standardized.hasPrefix(root + "/") {
            let relative = String(standardized.dropFirst(root.count + 1))
            let sanitized = String(
                relative.map { character in
                    character.isLetter || character.isNumber ? character : "-"
                }
            )
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if !sanitized.isEmpty { return sanitized }
        }
        let digest = ArtifactHasher.digest(bytes: Array(standardized.utf8))
        return "external-" + hex(digest.bytes.prefix(8))
    }

    private func hex(_ bytes: some Sequence<UInt8>) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var result: [UInt8] = []
        for byte in bytes {
            result.append(digits[Int(byte >> 4)])
            result.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: result, as: UTF8.self)
    }
    #endif

    func linuxSwiftPMInvocation(
        architecture: PlatformArchitecture = .arm64,
        triple: String? = nil,
        artifactTarget: ArtifactTarget? = nil,
        translation: OCIIntelBinaryTranslationPolicy? = nil,
        configuration: SwiftBuildConfiguration = .debug,
        sanitizer: String? = nil,
        linkerFlags additionalLinkerFlags: [String] = [],
        builder: NativeOCIConfiguration
    ) throws -> SwiftPMInvocation {
        let root = context.layout.root
        let target = NativeLinuxTarget(architecture: architecture)
        let resolvedTriple = triple ?? target.targetTriple
        let resolvedArtifactTarget = artifactTarget ?? target.artifactTarget
        let resolvedTranslation = translation ?? target.intelBinaryTranslationPolicy
        let guestSDKRoot = "/home/nucleus-build/.swiftpm/swift-sdks"
        let sourceID =
            context.taskEnvironment["NUCLEUS_SWIFT_SOURCE_ID"]
            ?? "swift-6.4"
        let toolchainIdentity =
            "nucleus-linux-build-\(sourceID)-\(architecture.rawValue)"
        let nativeSDK = context.nativeSDKRoot(for: target)
        let waylandSDK = nativeSDK.appending("wayland")
        let swiftPMUserRoot = root.appending(
            ".nucleus/swiftpm-user/\(target.identifier)")
        let guestTargetSDK =
            guestSDKRoot
            + "/nucleus-swift-6.4-linux.artifactbundle/swift-linux/"
            + resolvedTriple + "/ubuntu-noble.sdk"
        let targetRuntimeLibraryDirectory =
            guestTargetSDK + "/usr/lib/\(target.gnuArchitecture)"
        let nativeCompiler = nativeSDKCompilerConfiguration(
            nativeSDK: nativeSDK,
            gfxstreamBuildRoot: root.appending(
                "android-runtime/.gfxstream-build/\(target.identifier)"))
        let execution = SwiftPMExecution.oci(
            SwiftPMOCIExecution(
                executionPlatform: .linuxARM64OCI,
                artifactTarget: resolvedArtifactTarget,
                image: builder.image,
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
                    OCIMount(
                        source: builder.swiftSDKRoot,
                        target: guestSDKRoot,
                        access: .readOnly),
                ],
                intelBinaryTranslationPolicy: resolvedTranslation,
                resourceLimits: .parallelBuild,
                containerEnvironment: [
                    "CCACHE_DIR": "/ccache",
                    "HOME": "/home/nucleus-build",
                    "NUCLEUS_GFXSTREAM_BUILD_ROOT":
                        root.appending("android-runtime/.gfxstream-build/\(target.identifier)")
                        .string,
                    "LD_LIBRARY_PATH": [
                        "/opt/nucleus-vulkan-loader/\(target.gnuArchitecture)/lib",
                        guestTargetSDK + "/usr/lib/swift/linux",
                        targetRuntimeLibraryDirectory,
                        waylandSDK.appending("lib").string,
                    ].joined(separator: ":"),
                    "PKG_CONFIG_LIBDIR":
                        guestTargetSDK + "/usr/lib/\(target.gnuArchitecture)/pkgconfig"
                        + ":" + guestTargetSDK + "/usr/share/pkgconfig",
                    "PKG_CONFIG_SYSROOT_DIR": guestTargetSDK,
                    "VK_DRIVER_FILES": "/usr/share/vulkan/icd.d/lvp_icd.json",
                    "VK_ICD_FILENAMES": "/usr/share/vulkan/icd.d/lvp_icd.json",
                ]))
        return try context.swiftPMInvocation(
            configuration: configuration,
            sanitizer: sanitizer,
            cFlags: nativeCompiler.cFlags + [
                "-I\(waylandSDK.appending("include").string)"
            ],
            cxxFlags: nativeCompiler.cxxFlags + [
                "-I\(waylandSDK.appending("include").string)"
            ],
            linkerFlags: nativeCompiler.linkerFlags + [
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

    private func androidSwiftPMInvocation(
        toolchain: AndroidToolchainVersions,
        inputs: SwiftTargetSDKInputs,
        swiftSDKRoot: FilePath,
        swiftExecutable: CommandSpec.Executable
    ) throws -> SwiftPMInvocation {
        let nativeSDK = context.nativeSDKRoot(named: "android-arm64")
        let nativeCompiler = nativeSDKCompilerConfiguration(
            nativeSDK: nativeSDK,
            gfxstreamBuildRoot: context.layout.androidRuntime.appending(
                ".gfxstream-build/android-arm64"))
        let swiftCxxLibraries = swiftSDKRoot.appending(
            "\(inputs.androidBundleID).artifactbundle/swift-android/"
                + "swift-resources/usr/lib/swift-aarch64/android")
        return try context.swiftPMInvocation(
            configuration: .release,
            swiftFlags: ["-disable-cmo"],
            cFlags: nativeCompiler.cFlags,
            cxxFlags: nativeCompiler.cxxFlags,
            linkerFlags: nativeCompiler.linkerFlags + ["-L\(swiftCxxLibraries.string)"],
            staticSwiftStandardLibrary: true,
            target: .swiftSDK(
                name: inputs.androidBundleID,
                targetTriple: "aarch64-unknown-linux-android\(toolchain.minimumSDK)"),
            toolchainIdentity: "target-sdk-\(inputs.snapshot)-android",
            swiftExecutable: swiftExecutable)
    }

    private func nativeSDKCompilerConfiguration(
        nativeSDK: FilePath,
        gfxstreamBuildRoot: FilePath
    ) -> NativeSDKCompilerConfiguration {
        let root = context.layout.root
        let render = nativeSDK.appending("render")
        let rn = nativeSDK.appending("rn")
        let reactNative = rn.appending("include/react-native/packages/react-native")
        let reactCommon = reactNative.appending("ReactCommon")
        let includeDirectories = [
            root.appending("third-party/mesa/src/gfxstream/guest/iostream/include"),
            root.appending("third-party/mesa/src/gfxstream/guest/vulkan_enc"),
            root.appending("third-party/gfxstream/host/common/include"),
            root.appending("third-party/gfxstream/host/features/include"),
            root.appending("third-party/gfxstream/host/include"),
            root.appending("third-party/gfxstream/host/iostream/include"),
            root.appending("third-party/gfxstream/host/library/include"),
            root.appending("react-native/swiftpm/cmodules/NucleusReactRuntimeCxxBridge"),
            root.appending("react-native/swift/Sources/NucleusReactRuntime/cxx/include"),
            root.appending("core/render-cxx/skia/include"),
            root.appending("react-native/swiftpm/shims/NucleusReactRuntimeSwift"),
            render.appending("include/skia"),
            render.appending("include/skia/src"),
            render.appending("include/skia/include/third_party/vulkan"),
            render.appending("include/skia/src/gpu/vk/vulkanmemoryallocator"),
            render.appending("include/skia/third_party/externals/vulkanmemoryallocator/include"),
            render.appending("include/skia/third_party/externals/vulkan-headers/include"),
            rn.appending("include"),
            rn.appending("include/hermes/API"),
            rn.appending("include/hermes/API/jsi"),
            rn.appending("include/hermes/public"),
            rn.appending("include/hermes/include"),
            rn.appending("include/folly"),
            rn.appending("include/boost"),
            rn.appending("include/glog-gen"),
            rn.appending("include/glog/src"),
            rn.appending("include/fmt/include"),
            rn.appending("include/fast_float/include"),
            rn.appending("include/rn-codegen"),
            rn.appending("include/rn-codegen/FBReactNativeSpec"),
            reactNative,
            reactNative.appending("React"),
            reactNative.appending("ReactCxxPlatform"),
            reactCommon,
            reactCommon.appending("jsi"),
            reactCommon.appending("callinvoker"),
            reactCommon.appending("jsiexecutor"),
            reactCommon.appending("yoga"),
            reactCommon.appending("runtimeexecutor"),
            reactCommon.appending("react/nativemodule/core"),
            reactCommon.appending("react/renderer/components/view/platform/cxx"),
            reactCommon.appending("react/renderer/components/scrollview/platform/cxx"),
            reactCommon.appending("react/renderer/graphics/platform/cxx"),
            reactCommon.appending("react/renderer/imagemanager"),
            reactCommon.appending("react/renderer/imagemanager/platform/cxx"),
            reactCommon.appending("react/utils/platform/cxx"),
            reactCommon.appending("react/renderer/components/text/platform/cxx"),
            reactCommon.appending("react/renderer/textlayoutmanager/platform/cxx"),
            reactCommon.appending("reactperflogger"),
        ]
        let includeFlags = includeDirectories.map { "-I\($0.string)" }
        let libraryDirectories = [
            render.appending("lib/skia-graphite"),
            render.appending("lib/skia-graphite-android-arm64"),
            rn.appending("lib/rn/hermes"),
            rn.appending("lib/rn/reactnative"),
            rn.appending("lib/rn/glog"),
            rn.appending("lib/rn/fmt"),
            rn.appending("lib/rn/double-conversion/src"),
            gfxstreamBuildRoot.appending("host/host"),
        ]
        return NativeSDKCompilerConfiguration(
            cFlags: includeFlags,
            cxxFlags: includeFlags,
            linkerFlags: libraryDirectories.map { "-L\($0.string)" })
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
            "swift-sdk/validation/AndroidSDKConsumer")
        let validator = recipeRoot.appending("validate-target-sdk-artifacts.sh")
        let runtimeBuilderContext = recipeRoot.appending("runtime-build-container")
        let runtimePreset = recipeRoot.appending(
            "nucleus-target-runtime-presets.ini")
        let sysrootPreparer = recipeRoot.appending("prepare-linux-sysroot.sh")
        let pkgConfigDirectory = recipeRoot.appending("pkgconfig")
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
            pkgConfigDirectory: pkgConfigDirectory,
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
            pkgConfigDirectory: pkgConfigDirectory,
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

}
