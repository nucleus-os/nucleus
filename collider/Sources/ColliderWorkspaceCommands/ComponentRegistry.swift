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
    /// The checkout subtrees these flags name. A container has to be able to
    /// see an include path for the flag naming it to mean anything, and the
    /// two drift the moment they are written down separately.
    let checkoutIncludeRoots: [FilePath]
}

package struct ComponentRegistry {
    /// Names the package-root view every Swift build lane mounts.
    ///
    /// One view, not one per lane. What a container reads from the checkout is
    /// decided by a manifest rather than by a target architecture, and the
    /// package-input assembly runs two lanes in a single container, where two
    /// views claiming the same package root would be a conflicting mount.
    static let packageRootViewIdentifier = "checkout"

    package let context: WorkspaceContext

    package init(context: WorkspaceContext) {
        self.context = context
    }

    package func componentCatalog(
        environment environmentOverride: [String: String]? = nil,
        hostAugmentation explicitHostAugmentation: HostCatalogAugmentation? = nil,
        forceSwiftSDKGeneration: Bool = false
    ) async throws -> ComponentCatalog {
        let hostAugmentation =
            try explicitHostAugmentation
            ?? defaultHostCatalogAugmentation()
        var recipeEnvironment = environmentOverride ?? context.taskEnvironment
        let productProvenanceEnvironment = context.productProvenanceEnvironment(
            from: environmentOverride)
        for name in productProvenanceEnvironment.keys {
            recipeEnvironment.removeValue(forKey: name)
        }
        let productEnvironment = recipeEnvironment.merging(
            productProvenanceEnvironment,
            uniquingKeysWith: { _, provenance in provenance })
        let nativeBuilderCache = context.cacheRoot
        // What each Swift build reads from the checkout, decided once here so
        // the view a lane mounts and the subtrees mounted inside it are the
        // same derivation rather than two that must agree.
        let nucleusGraph = try await context.swiftPackageGraphs.graph(
            packageRoot: context.root,
            swiftExecutable: try context.graphSwiftPath())
        let assemblerRoot = context.root.appending("collider")
        let assemblerGraph = try await context.swiftPackageGraphs.graph(
            packageRoot: assemblerRoot,
            swiftExecutable: try context.graphSwiftPath())
        let nucleusIncludeRoots = nativeSDKCompilerConfiguration(
            nativeSDK: context.nativeSDKRoot(for: NativeLinuxTarget(architecture: .arm64)),
            gfxstreamSDKRoot: context.nativeSDKRoot(
                for: NativeLinuxTarget(architecture: .arm64)
            ).appending("android/gfxstream"),
            placement: context.identityPathMap
        ).checkoutIncludeRoots
        let checkoutRoots = checkoutSourceRoots(
            root: context.root,
            packageRoots: (nucleusGraph.manifestPaths
                + assemblerGraph.manifestPaths).map {
                    $0.removingLastComponent()
                },
            widened: nucleusGraph.targetRoots + assemblerGraph.targetRoots,
            exact: nucleusIncludeRoots + nucleusGraph.headerSearchRoots
                + assemblerGraph.headerSearchRoots
                // Not everything a container reads from the checkout is in
                // the package graph. These directories hold data a product is
                // assembled from rather than source it is compiled from: the
                // session package's scripts, unit, and PAM template, and the
                // Android container's AppArmor and seccomp policies. Every
                // action reading them declares it, as file inputs and as a
                // checkout read effect, so the gap was in what this consulted.
                //
                // These two are the whole set. Of the actions across every
                // recipe that declare a checkout read, the rest either run on
                // the host, where nothing is mounted, or belong to a lane that
                // mounts its own component root rather than a package view.
                + [
                    context.layout.compositorSessionPackage,
                    context.layout.androidRuntime.appending("container"),
                ])
        let packageRootViewRoot = nativeBuilderCache.appending("package-root-views")
        let nativeBuilder = try NativeBuilderColliderRecipe.prepare(
            repositoryRoot: context.root,
            context: context.root.appending("collider/images/native-builder"),
            cacheRoot: nativeBuilderCache.appending("build-containers/native"),
            ccache: nativeBuilderCache.appending("ccache/native"),
            environment: recipeEnvironment,
            identityPathMap: context.identityPathMap,
            packageRootViews: [
                try PackageRootViewRequest(
                    identifier: Self.packageRootViewIdentifier,
                    root: context.root,
                    view: packageRootViewRoot.appending(
                        Self.packageRootViewIdentifier),
                    // A resolved graph names every package it contains,
                    // including external dependencies checked out into the
                    // build store. Those reach a container through the
                    // dependency scratch mount rather than the package root,
                    // so the view carries only the manifests that are part of
                    // the checkout it projects. `checkoutSourceRoots` applies
                    // the same cut to directories.
                    files: (nucleusGraph.manifestPaths
                        + assemblerGraph.manifestPaths)
                        .filter { $0.starts(with: context.root) }
                        + [
                            context.root.appending("Package.resolved"),
                            assemblerRoot.appending("Package.resolved"),
                            context.root.appending(
                                "swift-sdk/linux-builder-toolset.json"),
                        ]
                        // Filtered by existence, unlike the directories: a
                        // package legitimately has no mirrors, and resolution
                        // already treats the file's presence as part of what
                        // it resolved against. Without it a container sees
                        // `Package.resolved` naming a location the manifest
                        // does not declare and fetches it.
                        + [context.root, assemblerRoot]
                        .map { swiftPMMirrorConfiguration(under: $0) }
                        .filter {
                            FileManager.default.fileExists(atPath: $0.string)
                        },
                    nestedDirectories: checkoutRoots)
            ])
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
            swiftSDK: swiftTargetSDK.activeSDK,
            packageRootViews: nativeBuilder.packageRootViews)
        var buildContexts: [RecipeBuildContextID: SwiftPMInvocation] = [
            .hostDebug: try await context.swiftPMInvocation()
        ]
        for architecture in PlatformArchitecture.allCases {
            buildContexts[.linux(architecture)] = try await linuxSwiftPMInvocation(
                architecture: architecture,
                builder: nativeConfiguration,
                checkoutRoots: checkoutRoots)
        }
        var linuxReleaseContexts: [PlatformArchitecture: SwiftPMInvocation] = [:]
        for architecture in PlatformArchitecture.allCases {
            let invocation = try await linuxSwiftPMInvocation(
                architecture: architecture,
                configuration: .release,
                builder: nativeConfiguration,
                checkoutRoots: checkoutRoots)
            linuxReleaseContexts[architecture] = invocation
            buildContexts[
                .linux(architecture, configuration: .release)
            ] = invocation
        }
        let runtimeAssembler = try await linuxAssemblerSwiftPMInvocation(
            builder: nativeConfiguration,
            checkoutRoots: checkoutRoots)
        buildContexts[.linuxAssembler] = runtimeAssembler
        for sanitizer in SanitizerKind.allCases {
            buildContexts[.linux(.arm64, sanitizer: sanitizer.rawValue)] =
                try await linuxSwiftPMInvocation(
                    sanitizer: sanitizer.rawValue,
                    linkerFlags: sanitizer == .undefined ? ["-lubsan"] : [],
                    builder: nativeConfiguration,
                    checkoutRoots: checkoutRoots)
        }
        buildContexts[
            .androidARM64(apiLevel: androidToolchain.minimumSDK)
        ] = try await androidSwiftPMInvocation(
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
            identityPathMap: context.identityPathMap,
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
                        let linuxTarget = NativeLinuxTarget(
                            architecture: architecture)
                        let waylandLibraries = context.nativeSDKRoot(
                            for: linuxTarget
                        ).appending("wayland/lib")
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
                                        + architecture.rawValue),
                                targetLibraryRoots:
                                    NucleusLinuxABI.targetLibraryRoots(
                                        triple: linuxTarget.targetTriple,
                                        gnuArchitecture: linuxTarget
                                            .gnuArchitecture)
                                    + [
                                        // Wayland is host-owned, so the payload
                                        // does not ship it, but staging still
                                        // resolves every dependency to check
                                        // its architecture. The Swift SDK
                                        // sysroot has no libwayland, so the
                                        // native SDK is where it is found.
                                        FilePath(
                                            context.identityPathMap
                                                .executionPath(waylandLibraries))
                                    ])
                        )
                    }),
                browserPackageInputs: Dictionary(
                    uniqueKeysWithValues: chromium.packageInputs.map {
                        ($0.key.architecture, $0.value)
                    }),
                androidPackageInputs: androidRuntime.artifacts.packageInputs,
                assemblerSwiftPM: runtimeAssembler,
                packageSourceSnapshotRoot: context.hostBuildRoot.appending(
                    "product-source/linux-packages"),
                productStoreRoot: context.artifactRoot.appending(
                    "product-store"),
                sessionPackage: context.layout.compositorSessionPackage,
                placement: context.identityPathMap,
                environment: productEnvironment)
        let recipeContext = RecipeContext(
            repositoryRoot: context.root,
            cacheRoot: context.cacheRoot,
            buildRoot: context.hostBuildRoot,
            artifactRoot: context.artifactRoot,
            logRoot: context.logRoot,
            environment: recipeEnvironment,
            identityPathMap: context.identityPathMap,
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
            await [
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
        // Generated sources are authored: a human adopts what generation
        // produced, so a build proves the committed copy still matches rather
        // than rewriting it. Each component that commits generated sources
        // verifies them in its own test lane.
        let generatedSourceVerifications: [String: ComponentEntrypointReference] = [
            "android-runtime": ComponentEntrypointReference(
                component: AndroidRuntimeColliderRecipe.descriptor.id,
                entrypoint: ComponentEntrypointID.verifyGeneratedSources),
            "vulkan": ComponentEntrypointReference(
                component: VulkanColliderRecipe.descriptor.id,
                entrypoint: ComponentEntrypointID.verifyGeneratedSources),
            "wayland": ComponentEntrypointReference(
                component: WaylandColliderRecipe.descriptor.id,
                entrypoint: ComponentEntrypointID.verifyGeneratedSources),
        ]
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
                    destinations: generatedSourceVerifications[spelling].map {
                        [linuxTest, $0]
                    } ?? [linuxTest]),
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
                includeLinuxOperations: hostAugmentation.exposesLinuxOperations))
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
        includeLinuxOperations: Bool
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
        expose(AndroidRuntimeEntrypoints.packageInput, to: ["android-runtime"])
        return requests
    }

    func build(
        selection: String?,
        controls: TaskControls
    ) async throws {
        try await checkBrowserPrerequisites(selection: selection, controls: controls)
        let catalog = try await componentCatalog(
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
        let catalog = try await componentCatalog()
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
        let catalog = try await componentCatalog()
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
        let catalog = try await componentCatalog()
        try await context.execute(
            catalog: catalog,
            requests: [
                ComponentEntrypointRequest(
                    entrypoint: .generate,
                    selection: selection)
            ],
            controls: controls)
    }

    /// Copies what generation produced into the checkout.
    ///
    /// This is the adoption half of the generated-source contract and the only
    /// supported way generated sources enter the checkout. A build cannot do
    /// it: the identity that executes builds is denied write access to the
    /// checkout precisely so that a build cannot rewrite what it reads. So a
    /// build proves the two copies agree, and this makes them agree.
    ///
    /// Writing the checkout is an edit, not an execution, so this takes neither
    /// the execution lease nor a run record. It is the same act as opening the
    /// file and saving it, performed by the account that owns the checkout.
    func adoptGeneratedSources(
        _ selection: String
    ) async throws -> GeneratedSourceAdoption {
        let catalog = try await componentCatalog()
        let components = catalog.components.filter {
            $0.descriptor.canonicalName == selection
                || $0.descriptor.aliases.contains(selection)
        }
        guard !components.isEmpty else {
            throw WorkspaceFailure.message("unknown component: \(selection)")
        }
        let mappings = components.flatMap(\.generatedSources)
        guard !mappings.isEmpty else {
            throw WorkspaceFailure.message(
                "component '\(selection)' commits no generated sources")
        }
        let files = context.runtime.actionFileSystem()
        var adopted: [FilePath] = []
        var current: [FilePath] = []
        for mapping in mappings {
            guard try files.metadata(for: mapping.generated) != nil else {
                throw WorkspaceFailure.message(
                    "generated sources are not in the build store: "
                        + "\(mapping.generated)\n"
                        + "  run 'collider generate \(selection)' first")
            }
            if try files.metadata(for: mapping.committed) != nil,
                try files.contentsEqual(at: mapping.generated, and: mapping.committed)
            {
                current.append(mapping.committed)
                continue
            }
            // Through a sibling so an interrupted adoption leaves either the
            // old tree or the new one, never a half-replaced mixture of both.
            guard let name = mapping.committed.lastComponent?.string else {
                throw WorkspaceFailure.message(
                    "generated source destination has no name: \(mapping.committed)")
            }
            let staging = mapping.committed.removingLastComponent()
                .appending("\(name).collider-adopting")
            try files.remove(staging)
            try files.copyTree(from: mapping.generated, to: staging)
            try files.remove(mapping.committed)
            try files.move(from: staging, to: mapping.committed)
            adopted.append(mapping.committed)
        }
        return GeneratedSourceAdoption(
            component: selection,
            adopted: adopted.map(\.string),
            current: current.map(\.string))
    }

    func packageAndroidInputs(controls: TaskControls) async throws {
        let catalog = try await componentCatalog()
        try await context.execute(
            catalog: catalog,
            requests: [
                ComponentEntrypointRequest(
                    entrypoint: AndroidRuntimeEntrypoints.packageInput,
                    selection: AndroidRuntimeColliderRecipe.descriptor.canonicalName)
            ],
            controls: controls)
    }

    func packageLinuxRuntime(controls: TaskControls) async throws {
        try await checkBrowserPrerequisites(
            selection: "browser",
            controls: controls)
        let catalog = try await componentCatalog()
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
        let catalog = try await componentCatalog()
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
        let catalog = try await componentCatalog()
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
        let catalog = try await componentCatalog()
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
        let catalog = try await componentCatalog()
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
        let catalog = try await componentCatalog()
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
    ) async throws -> ShellRuntimePublicationConfiguration {
        let swiftPM = try await context.swiftPMInvocation(
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
            // A development runtime published natively resolves against the
            // host it will run on, through each artifact's own RUNPATH and the
            // staged library root. It is not assembled from a target sysroot.
            targetLibraryRoots: [],
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
        builder: NativeOCIConfiguration,
        checkoutRoots: [FilePath]
    ) async throws -> SwiftPMInvocation {
        let packageRootView = try builder.packageRootView(
            ComponentRegistry.packageRootViewIdentifier)
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
        let guestTargetSDK = NucleusLinuxABI.guestTargetSDK(triple: resolvedTriple)
        let targetRuntimeLibraryDirectory =
            guestTargetSDK + "/usr/lib/\(target.gnuArchitecture)"
        let hostSwiftRuntimeLibraryDirectory = "/opt/swift/usr/lib/swift/linux"
        let hostSwiftCompatibilityLibraryDirectory = "/opt/swift-compat/arm64"
        let hostSwiftBinaryDirectory = "/opt/swift/usr/bin"
        let placement = context.identityPathMap
        let nativeCompiler = nativeSDKCompilerConfiguration(
            nativeSDK: nativeSDK,
            gfxstreamSDKRoot: nativeSDK.appending("android/gfxstream"),
            placement: placement)
        let execution = SwiftPMExecution.oci(
            SwiftPMOCIExecution(
                executionPlatform: .linuxARM64OCI,
                artifactTarget: resolvedArtifactTarget,
                image: builder.image,
                inputArtifacts: [builder.swiftPMOverlay, packageRootView],
                hostname: "nucleus-linux-\(architecture.rawValue)",
                hostWorkingDirectory: root,
                mounts: packageRootMounts(
                    root: root,
                    view: packageRootView.path,
                    nested: checkoutRoots,
                    placement: placement)
                    + [
                        OCIMount(
                            source: nativeSDK,
                            target: placement.executionPath(nativeSDK),
                            access: .readOnly),
                        // The native SDK's include tree links into the materialized
                        // JavaScript workspace and the generated sources beside it,
                        // and those links record the path the container sees, so
                        // both trees are mounted where the declared roots put them.
                        OCIMount(
                            source: ReactNativeColliderRecipe.javaScriptWorkspace(
                                cacheRoot: context.cacheRoot),
                            target: placement.executionPath(
                                ReactNativeColliderRecipe.javaScriptWorkspace(
                                    cacheRoot: context.cacheRoot)),
                            access: .readOnly),
                        OCIMount(
                            source: ReactNativeColliderRecipe.codegenRoot(
                                cacheRoot: context.cacheRoot),
                            target: placement.executionPath(
                                ReactNativeColliderRecipe.codegenRoot(
                                    cacheRoot: context.cacheRoot)),
                            access: .readOnly),
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
                    "NUCLEUS_NATIVE_SDK_ROOT": placement.executionPath(nativeSDK),
                    "NUCLEUS_GFXSTREAM_GUEST_LIBRARY":
                        placement.executionPath(
                            nativeSDK.appending(
                                "android/gfxstream/lib/libvulkan_gfxstream.so")),
                    "NUCLEUS_TARGET_LIBRARY_PATH": [
                        guestTargetSDK + "/usr/lib/swift/linux",
                        placement.executionPath(waylandSDK.appending("lib")),
                        "/lib/\(target.gnuArchitecture)",
                        "/usr/lib/\(target.gnuArchitecture)",
                    ].joined(separator: ":"),
                    "LD_LIBRARY_PATH": [
                        guestTargetSDK + "/usr/lib/swift/linux",
                        hostSwiftRuntimeLibraryDirectory,
                        hostSwiftCompatibilityLibraryDirectory,
                        placement.executionPath(waylandSDK.appending("lib")),
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
        return try await context.swiftPMInvocation(
            buildSystem: .swiftbuild,
            configuration: configuration,
            sanitizer: sanitizer,
            cFlags: nativeCompiler.cFlags + [
                "-I\(placement.executionPath(waylandSDK.appending("include")))"
            ],
            cxxFlags: nativeCompiler.cxxFlags + [
                "-I\(placement.executionPath(waylandSDK.appending("include")))"
            ],
            linkerFlags: nativeCompiler.linkerFlags + [
                "-L\(placement.executionPath(waylandSDK.appending("lib")))",
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
        builder: NativeOCIConfiguration,
        checkoutRoots: [FilePath]
    ) async throws -> SwiftPMInvocation {
        let assemblerView = try builder.packageRootView(
            ComponentRegistry.packageRootViewIdentifier)
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
                inputArtifacts: [builder.swiftPMOverlay, assemblerView],
                hostname: "nucleus-linux-assembler",
                hostWorkingDirectory: packageRoot,
                mounts: packageRootMounts(
                    root: root,
                    view: assemblerView.path,
                    nested: checkoutRoots,
                    placement: context.identityPathMap)
                    + [
                        OCIMount(
                            source: builder.swiftPMOverlay.path,
                            target: "/swiftpm-overlay",
                            access: .readOnly)
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
        return try await context.swiftPMInvocation(
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
    ) async throws -> SwiftPMInvocation {
        let nativeSDK = context.nativeSDKRoot(named: "android-arm64")
        let placement = context.identityPathMap
        let nativeCompiler = nativeSDKCompilerConfiguration(
            nativeSDK: nativeSDK,
            gfxstreamSDKRoot: nativeSDK.appending("android/gfxstream"),
            placement: placement)
        let swiftCxxLibraries = swiftSDKRoot.appending(
            "\(inputs.androidBundleID).artifactbundle/swift-android/"
                + "swift-resources/usr/lib/swift-aarch64/android")
        return try await context.swiftPMInvocation(
            configuration: .release,
            swiftFlags: ["-disable-cmo"],
            cFlags: nativeCompiler.cFlags
                + ["-I\(placement.executionPath(swiftIncludeRoot))"],
            cxxFlags: nativeCompiler.cxxFlags
                + ["-I\(placement.executionPath(swiftIncludeRoot))"],
            linkerFlags: nativeCompiler.linkerFlags
                + ["-L\(placement.executionPath(swiftCxxLibraries))"],
            staticSwiftStandardLibrary: true,
            target: .swiftSDK(
                name: inputs.androidBundleID,
                targetTriple: "aarch64-unknown-linux-android\(toolchain.minimumSDK)"),
            toolchainIdentity: "target-sdk-\(inputs.snapshot)-android",
            swiftExecutable: swiftExecutable)
    }

    /// Search paths a container compilation receives, named where that
    /// container sees them.
    private func nativeSDKCompilerConfiguration(
        nativeSDK: FilePath,
        gfxstreamSDKRoot: FilePath,
        placement: IdentityPathMap
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
        let executionPath = placement.executionPath
        let icuIncludeFlags = [icu.appending("common"), icu.appending("i18n")]
            .flatMap { ["-iquote", executionPath($0)] }
        let includeFlags = includeDirectories.map { "-I\(executionPath($0))" }
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
        let icuRoots = [icu.appending("common"), icu.appending("i18n")]
        return NativeSDKCompilerConfiguration(
            cFlags: icuIncludeFlags + includeFlags,
            cxxFlags: icuIncludeFlags + includeFlags,
            linkerFlags: libraryDirectories.map { "-L\(executionPath($0))" },
            checkoutIncludeRoots: checkoutIncludeRoots(
                of: icuRoots + includeDirectories,
                root: root,
                nativeSDK: nativeSDK))
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
            pkgConfigDirectory: pkgConfigDirectory,
            generatorSourceID: generatorSourceID)
        let linuxTargets = try inputs.linuxTargets.map { target in
            let buildID = try swiftTargetRuntimeBuildID(
                inputs: inputs,
                target: target,
                sourceID: sourceID,
                runtimeBuilderContext: runtimeBuilderContext,
                runtimePreset: runtimePreset)
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
            pkgConfigDirectory: pkgConfigDirectory,
            candidate: paths.artifactRoot.appending(
                "generations/.candidate-\(artifactID)"),
            generation: generation,
            active: paths.artifactRoot.appending("current"),
            ndkRoot: ndkRoot,
            validationFixture: fixture,
            validator: validator,
            swiftExecutable: swiftExecutable,
            sdkDiscoveryRoot: paths.artifactRoot.appending("discovery"),
            displacedRoot: paths.artifactRoot.appending("displaced/\(artifactID)"),
            environment: swiftTargetSDKTaskEnvironment(
                environment,
                runtimeSourceID: sourceID))
    }

}

/// The checkout subtrees a Swift package build reads, derived from the paths
/// its manifest names.
///
/// A container sees what its task declares. The manifest-resolved graph names
/// every target directory SwiftPM owns and the compiler configuration names
/// the vendored include roots its own flags point at, so the set is derived
/// rather than authored — a target that moves moves its mount with it.
///
/// `widened` paths are coalesced to two components below the root and `exact`
/// paths are taken as given, because the two kinds tolerate widening
/// differently. A manifest target sits in a first-party source directory whose
/// siblings are more of the same, so widening `core/swift/Sources/Foo` to
/// `core/swift` costs 56 files across the whole package and removes four
/// fifths of the mounts. A vendored include root sits inside a third-party
/// checkout, so widening `third-party/gfxstream/host/common/include` would
/// mount the entire vendored tree and undo the point of deriving the set.
///
/// A path covered by another in the set is dropped, so nothing is mounted
/// twice and the result does not depend on the order the paths arrived in.
///
/// Deliberately not filtered by what exists: these paths come from the
/// manifest and from the include list the compiler flags are built from, so
/// one that is absent is a defect rather than a path to drop. Dropping it
/// would also make the mount set — and so the task identity — depend on the
/// state of the filesystem it was planned against.
func checkoutSourceRoots(
    root: FilePath,
    packageRoots: [FilePath],
    widened: [FilePath],
    exact: [FilePath]
) -> [FilePath] {
    let packageRoots = Set(packageRoots)
    let candidates = Set(
        (widened.map { coalesced($0, under: root, avoiding: packageRoots) }
            + exact).filter {
                $0 != root && $0.starts(with: root)
            })
    return
        candidates
        .filter { candidate in
            !candidates.contains { $0 != candidate && candidate.starts(with: $0) }
        }
        .sorted { $0.string < $1.string }
}

/// `path` cut to two components below `root`, or `path` where it is already
/// that shallow, never stopping on a package root.
///
/// Widening rests on a target's siblings being more of the same. That holds
/// inside a source directory and fails at a package root, which is where
/// `.build` and `.git` sit. Widening `collider/engine/Sources/ColliderCore` to
/// `collider/engine` mounted 51,514 files of host SwiftPM output -- the exact
/// category established as unable to be an input to any build -- so a
/// candidate landing on a package root takes one more component instead.
///
/// Package roots come from the resolved graph's manifests rather than from
/// probing for build output, so the mount set stays a function of what the
/// package declares rather than of the filesystem it was planned against.
private func coalesced(
    _ path: FilePath,
    under root: FilePath,
    avoiding packageRoots: Set<FilePath>
) -> FilePath {
    guard path.starts(with: root) else { return path }
    let relative = path.string.dropFirst(root.string.count)
        .split(separator: "/")
        .map(String.init)
    var depth = 2
    while depth < relative.count {
        let candidate = relative.prefix(depth).reduce(root) { $0.appending($1) }
        if !packageRoots.contains(candidate) { return candidate }
        depth += 1
    }
    return path
}

/// The mounts for a package root that is a view, plus the subtrees nested
/// inside it.
func packageRootMounts(
    root: FilePath,
    view: FilePath,
    nested: [FilePath],
    placement: IdentityPathMap
) -> [OCIMount] {
    [
        OCIMount(
            source: view,
            target: placement.executionPath(root),
            access: .readOnly)
    ]
        + nested.map {
            OCIMount(
                source: $0,
                target: placement.executionPath($0),
                access: .readOnly)
        }
}

/// The checkout directories a set of include paths names.
///
/// A path under the checkout names itself. A path under one of the render
/// SDK's include links names a checkout directory too, because that link is a
/// symlink recording the path a container sees: following
/// `render/include/skia/src` reaches `core/third-party/skia/src`, which a
/// filter keeping only paths literally under the checkout root drops. The
/// container then follows the link to a directory it cannot see, and the
/// compiler reports a header it was explicitly pointed at as missing.
///
/// A path that is exactly a link resolves to that link's stated subtrees
/// rather than to the directory it points at, because the linked root is
/// Skia's whole vendored checkout.
func checkoutIncludeRoots(
    of includePaths: [FilePath],
    root: FilePath,
    nativeSDK: FilePath
) -> [FilePath] {
    let links = CoreColliderRecipe.renderSDKCheckoutLinks(
        root: root.appending("core"),
        sdkRoot: nativeSDK)
    return includePaths.flatMap { path -> [FilePath] in
        if path.starts(with: root) { return [path] }
        for link in links {
            if path == link.link { return link.rootRelativeSubtrees }
            guard path.starts(with: link.link) else { continue }
            return [
                path.string.dropFirst(link.link.string.count)
                    .split(separator: "/")
                    .reduce(link.checkout) { $0.appending(String($1)) }
            ]
        }
        return []
    }
}
