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

package struct ComponentRegistry {
    package let context: WorkspaceContext

    package init(context: WorkspaceContext) {
        self.context = context
    }

    package func componentCatalog(
        environment environmentOverride: [String: String]? = nil,
        hostAugmentation explicitHostAugmentation: HostCatalogAugmentation? = nil,
        androidPackageInputs: [PlatformArchitecture: FilePath] = [:],
        forceSwiftSDKGeneration: Bool = false
    ) throws -> ComponentCatalog {
        let hostAugmentation =
            try explicitHostAugmentation
            ?? defaultHostCatalogAugmentation()
        let recipeEnvironment = environmentOverride ?? context.taskEnvironment
        let nativeBuilderCache = context.cacheRoot
        let nativeBuilder = try NativeBuilderColliderRecipe.prepare(
            repositoryRoot: context.root,
            context: context.root.appending("collider/images/native-builder"),
            cacheRoot: nativeBuilderCache.appending("build-containers/native"),
            ccache: nativeBuilderCache.appending("ccache/native"),
            environment: recipeEnvironment)
        let androidToolchain = try AndroidToolchainVersions.load(
            workspaceRoot: context.root)
        let targetSDKInputs = try SwiftTargetSDKInputs.load(
            from: context.layout.swiftSDK.appending("target-sdk-inputs.json"))
        let swiftSDKConfiguration = try swiftTargetSDKGenerationConfiguration(
            environment: recipeEnvironment,
            android: androidToolchain,
            inputs: targetSDKInputs,
            runtimeBuilderBaseImage: nativeBuilder.configuration.image)
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
        var linuxReleaseContexts: [PlatformArchitecture: SwiftPMInvocation] = [:]
        for architecture in PlatformArchitecture.allCases {
            let invocation = try linuxSwiftPMInvocation(
                architecture: architecture,
                configuration: .release,
                builder: nativeConfiguration)
            linuxReleaseContexts[architecture] = invocation
            buildContexts[
                .linux(architecture, configuration: .release)
            ] = invocation
        }
        let runtimeAssembler = try linuxAssemblerSwiftPMInvocation(
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
            swiftIncludeRoot: swiftTargetSDK.activeSwift.path
                .removingLastComponent()
                .removingLastComponent()
                .appending("include"),
            swiftExecutable: swiftTargetSDK.activeSwift.executable)
        var configurations: [ComponentID: any RecipeConfiguration] = [
            SwiftTargetSDKColliderRecipe.descriptor.id: swiftSDKConfiguration,
            NativeBuilderColliderRecipe.descriptor.id:
                NativeBuilderGraphConfiguration(
                    builder: nativeConfiguration,
                    nativeSDKRoot: context.nativeSDKRoot.removingLastComponent()),
        ]
        if let androidPackageConfiguration = hostAugmentation.androidPackageConfiguration {
            configurations[AndroidRuntimeColliderRecipe.descriptor.id] =
                androidPackageConfiguration
        }
        if let shellConfiguration = hostAugmentation.shellConfiguration {
            configurations[ShellColliderRecipe.descriptor.id] = shellConfiguration
        }
        let baseRecipeContext = RecipeContext(
            repositoryRoot: context.root,
            cacheRoot: context.cacheRoot,
            buildRoot: context.hostBuildRoot,
            artifactRoot: context.artifactRoot,
            identityRoot: context.identityRoot,
            logRoot: context.logRoot,
            environment: recipeEnvironment,
            buildContexts: buildContexts,
            configurations: configurations)
        let chromium = try ChromiumColliderRecipe.prepare(in: baseRecipeContext)
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
        configurations[LinuxColliderRecipe.descriptor.id] =
            LinuxRuntimeArtifactConfiguration(
                lanes: try Dictionary(
                    uniqueKeysWithValues: PlatformArchitecture.allCases.map {
                        architecture in
                        guard let invocation = linuxReleaseContexts[architecture]
                        else {
                            throw WorkspaceFailure.message(
                                "missing Linux release context for "
                                    + architecture.rawValue)
                        }
                        return (
                            architecture,
                            LinuxRuntimeArtifactLane(
                                runtimeSwiftPM: invocation,
                                artifactRoot: context.artifactRoot.appending(
                                    "runtime/linux-\(architecture.rawValue)"),
                                packageRoot: context.artifactRoot.appending(
                                    "packages/linux-\(architecture.rawValue)"),
                                packageWorkRoot: context.artifactRoot.appending(
                                    "package-work/linux-\(architecture.rawValue)"),
                                productPublicationRoot: context.artifactRoot.appending(
                                    "package-publication/linux-"
                                        + architecture.rawValue),
                                qualificationRoot: context.artifactRoot.appending(
                                    "package-qualification/linux-"
                                        + architecture.rawValue))
                        )
                    }),
                browserPackageInputs: Dictionary(
                    uniqueKeysWithValues: chromium.packageInputs.map {
                        ($0.key.architecture, $0.value)
                    }),
                androidPackageInputs:
                    androidPackageInputs.isEmpty ? nil : androidPackageInputs,
                assemblerSwiftPM: runtimeAssembler,
                packageSourceSnapshotRoot: context.hostBuildRoot.appending(
                    "product-source/linux-packages"),
                productStoreRoot: context.artifactRoot.appending(
                    "product-store"),
                sessionPackage: context.layout.compositorSessionPackage,
                environment: recipeEnvironment)
        let recipeContext = RecipeContext(
            repositoryRoot: context.root,
            cacheRoot: context.cacheRoot,
            buildRoot: context.hostBuildRoot,
            artifactRoot: context.artifactRoot,
            logRoot: context.logRoot,
            environment: recipeEnvironment,
            buildContexts: buildContexts,
            configurations: configurations)
        let componentTypes: [any ColliderComponent.Type] = [
            BenchmarkColliderRecipe.self,
            SanitizerColliderRecipe.self,
            ReleaseGateColliderRecipe.self,
            ShellColliderRecipe.self,
            LinuxColliderRecipe.self,
            CompositorColliderRecipe.self,
            VulkanColliderRecipe.self,
        ]
        let components =
            [
                try ColliderStorageComponent.makeComponent(in: context),
                try ColliderSelfComponent.makeComponent(in: context),
                nativeBuilder.component, swiftTargetSDK.component,
                chromium.component,
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
        let shell = ShellColliderRecipe.descriptor.id
        let collider = ColliderSelfComponent.descriptor.id
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
        let androidGeneratedSourceVerification = ComponentEntrypointReference(
            component: AndroidRuntimeColliderRecipe.descriptor.id,
            entrypoint: AndroidRuntimeEntrypoints.verifyGeneratedSources)
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
        if hostAugmentation.exposesLinuxOperations {
            shellBootstrapDestinations.append(
                ComponentEntrypointReference(
                    component: shell,
                    entrypoint: .bootstrap))
        }
        var routes = runtimeSpellings.flatMap { spelling in
            [
                ComponentEntrypointRoute(
                    spelling: spelling,
                    requestedEntrypoint: .build,
                    destinations: [linuxBuild]),
                ComponentEntrypointRoute(
                    spelling: spelling,
                    requestedEntrypoint: .testDefault,
                    destinations:
                        spelling == "android-runtime"
                        ? [linuxTest, androidGeneratedSourceVerification]
                        : [linuxTest]),
            ]
        }
        routes += [
            ComponentEntrypointRoute(
                spelling: "linux-runtime",
                requestedEntrypoint: LinuxEntrypoints.packageRuntime,
                destinations: [
                    ComponentEntrypointReference(
                        component: linux,
                        entrypoint: LinuxEntrypoints.packageRuntime)
                ]),
            ComponentEntrypointRoute(
                spelling: "linux-runtime",
                requestedEntrypoint: .build,
                destinations: [
                    ComponentEntrypointReference(
                        component: linux,
                        entrypoint: LinuxEntrypoints.runtimeArtifact)
                ]),
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
                        component: AndroidRuntimeColliderRecipe.descriptor.id,
                        entrypoint: .bootstrap),
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
                        entrypoint: CoreEntrypoints.androidVerify)
                ]),
            ComponentEntrypointRoute(
                spelling: "android-native",
                requestedEntrypoint: .build,
                destinations: [
                    ComponentEntrypointReference(
                        component: core,
                        entrypoint: CoreEntrypoints.androidNative)
                ]),
            ComponentEntrypointRoute(
                spelling: "android-source",
                requestedEntrypoint: .bootstrap,
                destinations: [
                    ComponentEntrypointReference(
                        component: AndroidRuntimeColliderRecipe.descriptor.id,
                        entrypoint: ComponentEntrypointID(rawValue: "aosp.source"))
                ]),
            ComponentEntrypointRoute(
                spelling: "android-image",
                requestedEntrypoint: .build,
                destinations: [
                    ComponentEntrypointReference(
                        component: AndroidRuntimeColliderRecipe.descriptor.id,
                        entrypoint: ComponentEntrypointID(rawValue: "aosp.image"))
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
        if hostAugmentation.exposesLinuxOperations {
            routes.append(
                ComponentEntrypointRoute(
                    spelling: "tracy",
                    requestedEntrypoint: .bootstrap,
                    destinations: [
                        ComponentEntrypointReference(
                            component: shell,
                            entrypoint: .bootstrap)
                    ]))
        }
        let catalog = ComponentCatalog(
            components: components,
            groups: [
                ComponentSelectionGroup(
                    name: "all",
                    components: runtime.union([collider])),
                ComponentSelectionGroup(name: "runtime", components: runtime),
            ],
            routes: routes,
            publicEntrypoints: publicEntrypoints(
                includeLinuxOperations: hostAugmentation.exposesLinuxOperations,
                includeAndroidPackage:
                    hostAugmentation.androidPackageConfiguration != nil))
        try StorageCatalog.validate(
            catalog.storage,
            forbiddenRemovalRoots: [
                FilePath("/"), context.root,
                context.cacheRoot,
                FilePath(FileManager.default.homeDirectoryForCurrentUser),
            ])
        try StorageCatalog.validateProducers(catalog.storage, tasks: catalog.tasks)
        try StorageCatalog.validateWritableEffects(catalog.storage, tasks: catalog.tasks)
        return catalog
    }

    private func publicEntrypoints(
        includeLinuxOperations: Bool,
        includeAndroidPackage: Bool
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
        expose(
            .build,
            to: runtimeSpellings
                + [
                    "android", "android-native", "android-image", "browser",
                    "chromium", "linux-runtime",
                ])
        expose(
            .testDefault,
            to: runtimeSpellings
                + [
                    "android", "browser", "chromium", "gpu-headless",
                    "gpu-drm", "loader",
                ])
        expose(.testDefault, to: ["collider"])
        var bootstrapSpellings = [
            "all", "runtime", "linux", "native-builder", "core",
            "react-native", "rn", "wayland", "android-runtime",
            "android-source", "compositor", "shell", "browser", "chromium",
        ]
        if includeLinuxOperations { bootstrapSpellings.append("tracy") }
        expose(.bootstrap, to: bootstrapSpellings)
        expose(.generate, to: ["android-runtime", "vulkan", "wayland"])
        expose(LinuxEntrypoints.packageRuntime, to: ["linux-runtime"])
        if includeLinuxOperations { expose(.install, to: ["shell"]) }
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
        if includeAndroidPackage {
            expose(AndroidRuntimeEntrypoints.packageInput, to: ["android-runtime"])
        }
        return requests
    }

    func build(
        selection: String?,
        controls: TaskControls
    ) async throws {
        try await checkBrowserPrerequisites(selection: selection, controls: controls)
        let catalog = try componentCatalog(
            forceSwiftSDKGeneration:
                selection == SwiftTargetSDKColliderRecipe.descriptor.canonicalName
                && controls.rebuild)
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
        try await checkBrowserPrerequisites(selection: selection, controls: controls)
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
        try await checkBrowserPrerequisites(selection: selection, controls: controls)
        let catalog = try componentCatalog()
        if selection == ReleaseGateColliderRecipe.descriptor.canonicalName {
            try await context.execute(
                catalog: catalog,
                requests: [
                    ComponentEntrypointRequest(
                        entrypoint: ReleaseGateEntrypoints.test,
                        selection: selection)
                ],
                controls: controls)
            return
        }
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

    func packageLinuxRuntime(
        androidPackageInputs: [PlatformArchitecture: FilePath],
        controls: TaskControls
    ) async throws {
        try await checkBrowserPrerequisites(
            selection: "browser",
            controls: controls)
        let catalog = try componentCatalog(
            androidPackageInputs: androidPackageInputs)
        try await context.execute(
            catalog: catalog,
            requests: [
                ComponentEntrypointRequest(
                    entrypoint: LinuxEntrypoints.packageRuntime,
                    selection: "linux-runtime")
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

    private func checkBrowserPrerequisites(
        selection: String?,
        controls: TaskControls
    ) async throws {
        guard !controls.dryRun,
            selection == "browser" || selection == "chromium"
        else { return }
        try await WorkspaceDoctor(context: context).run(
            scope: .browser,
            dryRun: false,
            quiet: true)
    }

    package func shellRuntimePublicationConfiguration(
        prefix: FilePath,
        selection: RuntimeBuildSelection
    ) throws -> ShellRuntimePublicationConfiguration {
        let swiftPM = try context.swiftPMInvocation(
            configuration: selection.optimization == .debug ? .debug : .release,
            sanitizer: selection.sanitizer?.rawValue,
            cFlags: selection.tracy ? ["-DTRACY_ENABLE"] : [],
            linkerFlags: selection.sanitizer == .undefined ? ["-lubsan"] : [])
        return ShellRuntimePublicationConfiguration(
            swiftPM: swiftPM,
            prefix: prefix,
            generationsRoot: runtimeGenerationsRoot(for: prefix),
            packageManifestsRoot: runtimePackageManifestsRoot(for: prefix),
            sessionPackage: context.layout.compositorSessionPackage,
            buildMetadata: selection.metadata,
            environment: context.taskEnvironment)
    }

    private func runtimeGenerationsRoot(for prefix: FilePath) -> FilePath {
        context.stateRoot.appending("runtime")
            .appending(runtimeGenerationKey(for: prefix))
            .appending("generations")
    }

    private func runtimePackageManifestsRoot(for prefix: FilePath) -> FilePath {
        context.stateRoot.appending("runtime")
            .appending(runtimeGenerationKey(for: prefix))
            .appending("package-manifests")
    }

    private func runtimeGenerationKey(for prefix: FilePath) -> String {
        let standardized = prefix.normalizedForComparison()
        let root = context.root.normalizedForComparison()
        if standardized == root { return "root" }
        if let subpath = standardized.relativeSubpath(from: root) {
            let relative = subpath.string
            let sanitized = String(
                relative.map { character in
                    character.isLetter || character.isNumber ? character : "-"
                }
            )
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if !sanitized.isEmpty { return sanitized }
        }
        let digest = ArtifactHasher.digest(bytes: Array(standardized.string.utf8))
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
    func linuxSwiftPMInvocation(
        architecture: PlatformArchitecture = .arm64,
        triple: String? = nil,
        artifactTarget: ArtifactTarget? = nil,
        configuration: SwiftBuildConfiguration = .debug,
        sanitizer: String? = nil,
        linkerFlags additionalLinkerFlags: [String] = [],
        builder: NativeOCIConfiguration
    ) throws -> SwiftPMInvocation {
        let root = context.layout.root
        let target = NativeLinuxTarget(architecture: architecture)
        let resolvedTriple = triple ?? target.targetTriple
        let resolvedArtifactTarget = artifactTarget ?? target.artifactTarget
        let guestSDKRoot = SwiftPMInvocation.ociSwiftSDKDirectory.string
        let sourceID =
            context.taskEnvironment["NUCLEUS_SWIFT_SOURCE_ID"]
            ?? "swift-6.4"
        let toolchainIdentity =
            "nucleus-linux-build-\(sourceID)-swiftpm-overlay-"
            + builder.swiftPMOverlayRevision + "-"
            + architecture.rawValue
        let nativeSDK = context.nativeSDKRoot(for: target)
        let waylandSDK = nativeSDK.appending("wayland")
        let swiftPMRoot = context.cacheRoot.appending(
            "swiftpm/\(target.identifier)")
        let swiftPMDependencyCache = context.cacheRoot.appending(
            "swiftpm-user/cache")
        let guestTargetSDK =
            guestSDKRoot
            + "/nucleus-swift-6.4-linux.artifactbundle/swift-linux/"
            + resolvedTriple + "/" + NucleusLinuxABI.sdkDirectoryName
        let targetRuntimeLibraryDirectory =
            guestTargetSDK + "/usr/lib/\(target.gnuArchitecture)"
        let hostSwiftRuntimeLibraryDirectory = "/opt/swift/usr/lib/swift/linux"
        let hostSwiftCompatibilityLibraryDirectory = "/opt/swift-compat/arm64"
        let hostSwiftBinaryDirectory = "/opt/swift/usr/bin"
        let nativeCompiler = nativeSDKCompilerConfiguration(
            nativeSDK: nativeSDK,
            gfxstreamSDKRoot: nativeSDK.appending("android/gfxstream"))
        let execution = SwiftPMExecution.oci(
            SwiftPMOCIExecution(
                executionPlatform: .linuxARM64OCI,
                artifactTarget: resolvedArtifactTarget,
                image: builder.image,
                inputArtifacts: [builder.swiftPMOverlay],
                hostname: "nucleus-linux-\(architecture.rawValue)",
                hostWorkingDirectory: root,
                mounts: [
                    OCIMount(source: root, target: root.string, access: .readOnly),
                    OCIMount(source: nativeSDK, target: nativeSDK.string, access: .readOnly),
                    OCIMount(
                        source: builder.swiftSDKRoot,
                        target: guestSDKRoot,
                        access: .readOnly),
                    OCIMount(
                        source: builder.swiftPMOverlay.path,
                        target: "/swiftpm-overlay",
                        access: .readOnly),
                ],
                buildWorkspace: PersistentWorkspaceDeclaration(
                    identity: PersistentWorkspaceIdentity(
                        key: "nucleus-swiftpm",
                        artifactTarget: resolvedArtifactTarget,
                        role: "build"),
                    capacityBytes: 100 * 1_024 * 1_024 * 1_024,
                    filesystem: .ext4,
                    journal: .writeback64MiB),
                compilerCacheWorkspace: PersistentWorkspaceDeclaration(
                    identity: PersistentWorkspaceIdentity(
                        key: "nucleus-swiftpm-ccache",
                        artifactTarget: resolvedArtifactTarget,
                        role: "compiler-cache"),
                    capacityBytes: 50 * 1_024 * 1_024 * 1_024,
                    filesystem: .ext4,
                    journal: .writeback64MiB,
                    retentionPolicy: .toolManagedLimit(
                        maximumBytes: 50 * 1_024 * 1_024 * 1_024)),
                hostDependencyCache: swiftPMDependencyCache,
                resourceLimits: .parallelBuild,
                containerEnvironment: [
                    "CCACHE_DIR": "/ccache",
                    "HOME": "/home/nucleus-build",
                    "NUCLEUS_NATIVE_SDK_ROOT": nativeSDK.string,
                    "NUCLEUS_GFXSTREAM_GUEST_LIBRARY":
                        nativeSDK.appending(
                            "android/gfxstream/lib/libvulkan_gfxstream.so"
                        ).string,
                    "NUCLEUS_TARGET_LIBRARY_PATH": [
                        guestTargetSDK + "/usr/lib/swift/linux",
                        waylandSDK.appending("lib").string,
                        "/lib/\(target.gnuArchitecture)",
                        "/usr/lib/\(target.gnuArchitecture)",
                    ].joined(separator: ":"),
                    "LD_LIBRARY_PATH": [
                        guestTargetSDK + "/usr/lib/swift/linux",
                        hostSwiftRuntimeLibraryDirectory,
                        hostSwiftCompatibilityLibraryDirectory,
                        waylandSDK.appending("lib").string,
                    ].joined(separator: ":"),
                    "SWIFTPM_CUSTOM_BIN_DIR": hostSwiftBinaryDirectory,
                    "PATH": "/swiftpm-overlay/usr/bin:"
                        + hostSwiftBinaryDirectory
                        + ":/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                    "PKG_CONFIG_PATH":
                        guestTargetSDK + "/usr/lib/\(target.gnuArchitecture)/pkgconfig"
                        + ":" + guestTargetSDK + "/usr/share/pkgconfig",
                    "PKG_CONFIG_SYSROOT_DIR": guestTargetSDK,
                    "VK_DRIVER_FILES": "/usr/share/vulkan/icd.d/lvp_icd.json",
                    "VK_ICD_FILENAMES": "/usr/share/vulkan/icd.d/lvp_icd.json",
                ],
                environmentProjection: nucleusSwiftPMEnvironmentProjection,
                swiftPMExecutable: "/swiftpm-overlay/usr/bin/swift-package-manager"))
        return try context.swiftPMInvocation(
            buildSystem: .swiftbuild,
            configuration: configuration,
            sanitizer: sanitizer,
            cFlags: nativeCompiler.cFlags + [
                "-I\(waylandSDK.appending("include").string)"
            ],
            cxxFlags: nativeCompiler.cxxFlags + [
                "-I\(waylandSDK.appending("include").string)"
            ],
            linkerFlags: nativeCompiler.linkerFlags + [
                "-L\(waylandSDK.appending("lib").string)",
                "-L\(targetRuntimeLibraryDirectory)",
            ] + additionalLinkerFlags,
            toolsets: [root.appending("swift-sdk/linux-builder-toolset.json")],
            target: .swiftSDK(
                name: "nucleus-swift-6.4-linux",
                targetTriple: resolvedTriple),
            execution: execution,
            toolchainIdentity: toolchainIdentity,
            scratchRoot: swiftPMRoot,
            swiftExecutable: .path("/opt/swift/usr/bin/swift"))
    }

    private func linuxAssemblerSwiftPMInvocation(
        builder: NativeOCIConfiguration
    ) throws -> SwiftPMInvocation {
        let root = context.layout.root
        let packageRoot = root.appending("collider")
        let scratchRoot = context.cacheRoot.appending(
            "swiftpm-tools/runtime-assembler")
        let swiftPMDependencyCache = context.cacheRoot.appending(
            "swiftpm-user/cache")
        let execution = SwiftPMExecution.oci(
            SwiftPMOCIExecution(
                executionPlatform: .linuxARM64OCI,
                artifactTarget: .linuxARM64,
                image: builder.image,
                inputArtifacts: [builder.swiftPMOverlay],
                hostname: "nucleus-linux-assembler",
                hostWorkingDirectory: packageRoot,
                mounts: [
                    OCIMount(source: root, target: root.string, access: .readOnly),
                    OCIMount(
                        source: builder.swiftPMOverlay.path,
                        target: "/swiftpm-overlay",
                        access: .readOnly),
                ],
                buildWorkspace: PersistentWorkspaceDeclaration(
                    identity: PersistentWorkspaceIdentity(
                        key: "collider-swiftpm-tools",
                        artifactTarget: .linuxARM64,
                        role: "build"),
                    capacityBytes: 100 * 1_024 * 1_024 * 1_024,
                    filesystem: .ext4,
                    journal: .writeback64MiB),
                hostDependencyCache: swiftPMDependencyCache,
                resourceLimits: .build,
                containerEnvironment: [
                    "HOME": "/home/nucleus-build",
                    "LD_LIBRARY_PATH":
                        "/opt/swift/usr/lib/swift/linux:/opt/swift-compat/arm64",
                    "SWIFTPM_CUSTOM_BIN_DIR": "/opt/swift/usr/bin",
                    "PATH":
                        "/swiftpm-overlay/usr/bin:/opt/swift/usr/bin:"
                        + "/usr/local/sbin:/usr/local/bin:"
                        + "/usr/sbin:/usr/bin:/sbin:/bin",
                ],
                environmentProjection: nucleusSwiftPMEnvironmentProjection,
                swiftPMExecutable: "/swiftpm-overlay/usr/bin/swift-package-manager"))
        return try context.swiftPMInvocation(
            packageRoot: packageRoot,
            configuration: .release,
            debugInformationFormat: SwiftDebugInformationFormat.none,
            swiftFlags: ["-use-ld=lld"],
            target: .host(identity: "aarch64-unknown-linux-gnu"),
            execution: execution,
            toolchainIdentity: "nucleus-linux-builder-swiftpm-overlay-"
                + builder.swiftPMOverlayRevision,
            scratchRoot: scratchRoot,
            swiftExecutable: .path("/opt/swift/usr/bin/swift"))
    }

    package func androidSwiftPMInvocation(
        toolchain: AndroidToolchainVersions,
        inputs: SwiftTargetSDKInputs,
        swiftSDKRoot: FilePath,
        swiftIncludeRoot: FilePath,
        swiftExecutable: CommandSpec.Executable
    ) throws -> SwiftPMInvocation {
        let nativeSDK = context.nativeSDKRoot(named: "android-arm64")
        let nativeCompiler = nativeSDKCompilerConfiguration(
            nativeSDK: nativeSDK,
            gfxstreamSDKRoot: nativeSDK.appending("android/gfxstream"))
        let swiftCxxLibraries = swiftSDKRoot.appending(
            "\(inputs.androidBundleID).artifactbundle/swift-android/"
                + "swift-resources/usr/lib/swift-aarch64/android")
        return try context.swiftPMInvocation(
            configuration: .release,
            swiftFlags: ["-disable-cmo"],
            cFlags: nativeCompiler.cFlags + ["-I\(swiftIncludeRoot.string)"],
            cxxFlags: nativeCompiler.cxxFlags + ["-I\(swiftIncludeRoot.string)"],
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
        gfxstreamSDKRoot: FilePath
    ) -> NativeSDKCompilerConfiguration {
        let root = context.layout.root
        let render = nativeSDK.appending("render")
        let rn = nativeSDK.appending("rn")
        let reactNative = rn.appending("include/react-native")
        let reactCommon = reactNative.appending("ReactCommon")
        let icu = root.appending(
            "core/third-party/skia/third_party/externals/icu/source")
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
            render.appending("include/skia"),
            render.appending("include/skia/src"),
            render.appending("include/skia/include/third_party/vulkan"),
            render.appending("include/skia/src/gpu/vk/vulkanmemoryallocator"),
            render.appending("include/skia/third_party/externals/vulkanmemoryallocator/include"),
            render.appending("include/skia/third_party/externals/vulkan-headers/include"),
            rn.appending("include"),
            reactCommon.appending("jsi"),
            rn.appending("include/hermes/API"),
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
            rn.appending("include/react-native-worklets"),
            rn.appending("include/react-native-reanimated"),
            rn.appending("include/react-native-reanimated-native-view"),
            rn.appending("include/rn-library-codegen"),
            reactNative,
            reactNative.appending("React"),
            rn.appending("include/react-cxx-platform"),
            reactCommon,
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
        let icuIncludeFlags = [icu.appending("common"), icu.appending("i18n")]
            .flatMap { ["-iquote", $0.string] }
        let includeFlags = includeDirectories.map { "-I\($0.string)" }
        let libraryDirectories = [
            render.appending("lib/skia-graphite"),
            render.appending("lib/skia-graphite-android-arm64"),
            rn.appending("lib/rn/hermes"),
            rn.appending("lib/rn/runtime/reactnative"),
            rn.appending("lib/rn/runtime/glog"),
            rn.appending("lib/rn/support/fmt"),
            rn.appending("lib/rn/support/double-conversion/src"),
            gfxstreamSDKRoot.appending("lib"),
        ]
        return NativeSDKCompilerConfiguration(
            cFlags: icuIncludeFlags + includeFlags,
            cxxFlags: icuIncludeFlags + includeFlags,
            linkerFlags: libraryDirectories.map { "-L\($0.string)" })
    }

    private func swiftTargetSDKGenerationConfiguration(
        environment: [String: String],
        android: AndroidToolchainVersions,
        inputs: SwiftTargetSDKInputs,
        runtimeBuilderBaseImage: ArtifactReference
    ) throws -> SwiftTargetSDKGenerationConfiguration {
        let recipeRoot = context.layout.swiftSDK
        let inputsFile = recipeRoot.appending("target-sdk-inputs.json")
        let sourceID =
            environment["NUCLEUS_SWIFT_SOURCE_ID"].flatMap {
                $0.isEmpty ? nil : $0
            } ?? "swift-6.4-source"
        let generatorSource = recipeRoot.appending("source/swift-sdk-generator")
        let generatorSourceID =
            environment["NUCLEUS_SWIFT_SDK_GENERATOR_SOURCE_ID"].flatMap {
                $0.isEmpty ? nil : $0
            } ?? sourceID
        let ndkRoot = try android.ndkRoot(
            environment: environment,
            validate: false,
            fallbackHome: context.cacheRoot.appending("unconfigured-home"))
        let paths = SwiftTargetSDKStoragePaths(
            cacheRoot: context.cacheRoot,
            hostBuildRoot: context.hostBuildRoot)
        let fixture = context.root.appending(
            "swift-sdk/validation/AndroidSDKConsumer")
        let validator = recipeRoot.appending("validate-target-sdk-artifacts.sh")
        let runtimeBuilderContext = recipeRoot.appending("runtime-build-container")
        let runtimePreset = recipeRoot.appending(
            "nucleus-target-runtime-presets.ini")
        let sysrootPreparer = recipeRoot.appending("prepare-linux-sysroot.sh")
        let sdkPackageSanitizer = recipeRoot.appending(
            "sanitize-linux-sdk-package.sh")
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
            sdkPackageSanitizer: sdkPackageSanitizer,
            pkgConfigDirectory: pkgConfigDirectory,
            generatorSourceID: generatorSourceID)
        let linuxTargets = try inputs.linuxTargets.map { target in
            let buildID = try swiftTargetRuntimeBuildID(
                inputs: inputs,
                target: target,
                sourceID: sourceID,
                runtimeBuilderContext: runtimeBuilderContext,
                runtimePreset: runtimePreset,
                sysrootPreparer: sysrootPreparer)
            let root = paths.artifactRoot.appending(
                "runtime-inputs/\(target.architecture.rawValue)/\(buildID)")
            return SwiftLinuxTargetBuildConfiguration(
                target: target,
                runtimeBuildWorkspace: PersistentWorkspaceDeclaration(
                    identity: PersistentWorkspaceIdentity(
                        key: "swift-target-runtime-intermediates",
                        artifactTarget: target.architecture.artifactTarget,
                        role: "build"),
                    capacityBytes: 200 * 1_024 * 1_024 * 1_024,
                    filesystem: .ext4,
                    journal: .writeback64MiB),
                runtimeCompilerCacheWorkspace: PersistentWorkspaceDeclaration(
                    identity: PersistentWorkspaceIdentity(
                        key: "swift-target-runtime-ccache",
                        artifactTarget: target.architecture.artifactTarget,
                        role: "compiler-cache"),
                    capacityBytes: 50 * 1_024 * 1_024 * 1_024,
                    filesystem: .ext4,
                    journal: .writeback64MiB,
                    retentionPolicy: .toolManagedLimit(
                        maximumBytes: 50 * 1_024 * 1_024 * 1_024)),
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
            runtimeBuilderBaseImage: runtimeBuilderBaseImage,
            linuxTargets: linuxTargets,
            sysrootPreparer: sysrootPreparer,
            sdkPackageSanitizer: sdkPackageSanitizer,
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
            environment: swiftTargetSDKTaskEnvironment(
                environment,
                runtimeSourceID: sourceID))
    }

}
