import ColliderCore
import Foundation
import SwiftTargetSDKColliderRecipe
import SystemPackage

enum ColliderStorageComponent {
    static let descriptor = ComponentDescriptor(
        id: ComponentID(rawValue: "collider-storage"),
        canonicalName: "collider-storage",
        directoryName: ".nucleus")

    static func makeComponent(in context: WorkspaceContext) throws -> ComponentDefinition {
        let owner = descriptor.id
        let root = context.root
        let state = context.layout.state
        let cache = context.cacheRoot.appending("nucleus")
        return try ComponentDefinition(
            descriptor: descriptor,
            tasks: [],
            entrypoints: [],
            storage: [
                StorageDeclaration(
                    id: "checkout-state",
                    owner: owner,
                    producers: [.runtime("task-state")],
                    storageClass: .incremental,
                    root: state,
                    safetyRoot: root,
                    cleanupPolicy: .protected,
                    retention: "task state and workflow locks remain with the checkout"),
                StorageDeclaration(
                    id: "run-records",
                    owner: owner,
                    producers: [.runtime("run-registry")],
                    storageClass: .runRecord,
                    root: context.layout.runs,
                    safetyRoot: state,
                    cleanupPolicy: .automaticRetention,
                    workflowLock: context.layout.locks.appending("cache-prune.lock"),
                    retention:
                        "running records, the 20 newest terminal records, and the newest failed record are retained"
                ),
                StorageDeclaration(
                    id: "downloads",
                    owner: owner,
                    producers: [.runtime("download-manager")],
                    storageClass: .download,
                    root: cache.appending("downloads"),
                    safetyRoot: cache,
                    cleanupPolicy: .protected,
                    retention:
                        "content-addressed downloads remain while referenced by the resolved graph"
                ),
                StorageDeclaration(
                    id: "host-compiler-cache",
                    owner: owner,
                    producers: [.runtime("host-swiftpm")],
                    storageClass: .cache,
                    root: cache.appending("host-ccache"),
                    safetyRoot: cache,
                    cleanupPolicy: .explicitClean,
                    workflowLock: context.layout.locks.appending("host-compiler-cache.lock"),
                    retention: "host compiler results remain reusable until explicit clean"),
                StorageDeclaration(
                    id: "swift-package-cache",
                    owner: owner,
                    producers: [.runtime("swiftpm")],
                    storageClass: .cache,
                    root: cache.appending("swiftpm-user"),
                    safetyRoot: cache,
                    cleanupPolicy: .explicitClean,
                    workflowLock: context.layout.locks.appending("swift-package-cache.lock"),
                    retention: "locked Swift package sources remain reusable until explicit clean"),
                StorageDeclaration(
                    id: "swiftpm-builds",
                    owner: owner,
                    producers: [.runtime("swiftpm")],
                    storageClass: .incremental,
                    root: cache.appending("swiftpm"),
                    safetyRoot: cache,
                    cleanupPolicy: .explicitClean,
                    workflowLock: context.layout.locks.appending("swiftpm-builds.lock"),
                    retention:
                        "destination-specific SwiftPM state remains reusable until explicit clean"),
                StorageDeclaration(
                    id: "swiftpm-tool-builds",
                    owner: owner,
                    producers: [.runtime("swiftpm")],
                    storageClass: .incremental,
                    root: cache.appending("swiftpm-tools"),
                    safetyRoot: cache,
                    cleanupPolicy: .explicitClean,
                    workflowLock: context.layout.locks.appending("swiftpm-tool-builds.lock"),
                    retention:
                        "Collider-owned Swift tool products remain reusable until explicit clean"),
                StorageDeclaration(
                    id: "android-sdk",
                    owner: owner,
                    producers: [.runtime("android-toolchain")],
                    storageClass: .published,
                    root: FilePath(
                        context.environment["ANDROID_SDK_ROOT"]
                            ?? context.cacheRoot.appending("android-sdk").string),
                    safetyRoot: FilePath(
                        context.environment["ANDROID_SDK_ROOT"]
                            ?? context.cacheRoot.appending("android-sdk").string),
                    cleanupPolicy: .protected,
                    retention: "the pinned Android SDK remains provisioned"),
            ])
    }
}

extension ComponentRegistry {
    func attachingStorageOwnership(
        to component: ComponentDefinition
    ) throws -> ComponentDefinition {
        let root = context.root
        let cache = context.cacheRoot.appending("nucleus")
        let componentRoot = root.appending(component.descriptor.directoryName)
        let owner = component.descriptor.id

        func taskProducers(
            _ matches: (String) -> Bool
        ) throws -> Set<StorageProducer> {
            let producers = component.tasks.compactMap { task in
                matches(task.id.rawValue) ? StorageProducer.task(task.id) : nil
            }
            guard !producers.isEmpty else {
                throw StorageCatalogFailure.invalid(
                    "component storage has no resolved producer task: \(owner)")
            }
            return Set(producers)
        }

        func declaration(
            id: String,
            producers: Set<StorageProducer>,
            storageClass: StorageClass,
            root: FilePath,
            safetyRoot: FilePath,
            cleanupPolicy: StorageCleanupPolicy = .explicitClean,
            workflowLock: FilePath,
            activeGenerationLink: FilePath? = nil,
            retention: String
        ) -> StorageDeclaration {
            StorageDeclaration(
                id: id,
                owner: owner,
                producers: producers,
                storageClass: storageClass,
                root: root,
                safetyRoot: safetyRoot,
                cleanupPolicy: cleanupPolicy,
                workflowLock: workflowLock,
                activeGenerationLink: activeGenerationLink,
                retention: retention)
        }

        let declarations: [StorageDeclaration]
        switch owner.rawValue {
        case "native":
            let metadata = cache.appending("build-containers/native")
            let ccache = cache.appending("ccache/native")
            let producers = try taskProducers { $0 == "native.builder" }
            declarations = [
                declaration(
                    id: "native-builder-metadata",
                    producers: producers,
                    storageClass: .cache,
                    root: metadata,
                    safetyRoot: cache.appending("build-containers"),
                    workflowLock: context.layout.locks.appending("native-builder-image.lock"),
                    retention: "the native builder image and generated context remain reusable"),
                declaration(
                    id: "native-builder-ccache",
                    producers: producers,
                    storageClass: .cache,
                    root: ccache,
                    safetyRoot: cache.appending("ccache"),
                    workflowLock: context.layout.locks.appending("native-builder-image.lock"),
                    retention: "native builder compiler results remain reusable"),
            ]

        case "swift-sdk":
            let paths = SwiftTargetSDKStoragePaths(cacheRoot: context.cacheRoot)
            let producers = Set(component.tasks.map { StorageProducer.task($0.id) })
            declarations = [
                declaration(
                    id: "swift-target-sdk-generations",
                    producers: producers,
                    storageClass: .generation,
                    root: paths.artifactRoot.appending("generations"),
                    safetyRoot: paths.artifactRoot,
                    cleanupPolicy: .explicitPrune,
                    workflowLock: paths.rebuildLock,
                    activeGenerationLink: paths.artifactRoot.appending("current"),
                    retention:
                        "the active generation is protected; inactive generations are prunable"),
                declaration(
                    id: "swift-sdk-generator-build",
                    producers: producers,
                    storageClass: .incremental,
                    root: paths.generatorScratch,
                    safetyRoot: cache.appending("build"),
                    workflowLock: context.layout.locks.appending("swift-sdk-generator.lock"),
                    retention: "the generator build remains reusable until explicit clean"),
                declaration(
                    id: "swift-runtime-build",
                    producers: producers,
                    storageClass: .incremental,
                    root: paths.runtimeBuildRoot,
                    safetyRoot: cache.appending("build"),
                    workflowLock: context.layout.locks.appending("swift-target-runtime.lock"),
                    retention: "architecture-specific target runtime builds remain reusable"),
                declaration(
                    id: "swift-runtime-builder-metadata",
                    producers: producers,
                    storageClass: .cache,
                    root: paths.runtimeBuilderImageID.removingLastComponent(),
                    safetyRoot: cache.appending("build-containers"),
                    workflowLock: context.layout.locks.appending(
                        "swift-linux-runtime-builder-image.lock"),
                    retention: "the target-runtime builder image remains reusable"),
                declaration(
                    id: "swift-runtime-ccache",
                    producers: producers,
                    storageClass: .cache,
                    root: paths.runtimeCompilerCache,
                    safetyRoot: cache.appending("ccache"),
                    workflowLock: context.layout.locks.appending("swift-target-runtime.lock"),
                    retention: "target-runtime compiler results remain reusable"),
            ]

        case "core":
            let skiaProducers = try taskProducers {
                $0 == "core.gn-download" || $0 == "core.gn-install" || $0 == "core.sources"
                    || $0.contains("core.skia.")
            }
            var values = [
                declaration(
                    id: "core-skia-build",
                    producers: skiaProducers,
                    storageClass: .incremental,
                    root: componentRoot.appending(".skia-build"),
                    safetyRoot: componentRoot,
                    workflowLock: context.layout.locks.appending("core-native-build.lock"),
                    retention: "Skia dependency and target build trees remain reusable")
            ]
            let nativeRoot = context.nativeSDKRoot.removingLastComponent()
            for target in ["linux-arm64", "linux-x86_64", "android-arm64"] {
                let producerID =
                    target == "android-arm64"
                    ? "core.native-sdk.android-arm64" : "core.native-sdk.\(target)"
                let sdkRoot = nativeRoot.appending(target)
                values.append(
                    declaration(
                        id: "core-render-sdk-\(target)",
                        producers: try taskProducers { $0 == producerID },
                        storageClass: .published,
                        root: sdkRoot.appending("render"),
                        safetyRoot: sdkRoot,
                        workflowLock: sdkRoot.appending(".render.lock"),
                        retention: "the validated render SDK remains published"))
            }
            declarations = values

        case "rn":
            let javascript = try taskProducers { $0 == "rn.javascript-dependencies" }
            let native = try taskProducers {
                $0.hasPrefix("rn.") && $0 != "rn.javascript-dependencies"
            }
            var values = [
                declaration(
                    id: "rn-native-build",
                    producers: native,
                    storageClass: .incremental,
                    root: componentRoot.appending(".rn-build"),
                    safetyRoot: componentRoot,
                    workflowLock: context.layout.locks.appending("rn-native-build.lock"),
                    retention: "Hermes and React Native native build trees remain reusable"),
                declaration(
                    id: "rn-node-modules",
                    producers: javascript,
                    storageClass: .generation,
                    root: componentRoot.appending("node_modules"),
                    safetyRoot: componentRoot,
                    workflowLock: cache.appending("bun/linux-multiarch/.collider.lock"),
                    retention:
                        "the lockfile-selected JavaScript dependency generation remains active"),
                declaration(
                    id: "rn-javascript-cache",
                    producers: javascript,
                    storageClass: .cache,
                    root: cache.appending("bun/linux-multiarch"),
                    safetyRoot: cache.appending("bun"),
                    workflowLock: cache.appending("bun/linux-multiarch/.collider.lock"),
                    retention: "Bun package archives remain reusable"),
            ]
            let nativeRoot = context.nativeSDKRoot.removingLastComponent()
            for target in ["linux-arm64", "linux-x86_64"] {
                let sdkRoot = nativeRoot.appending(target)
                values.append(
                    declaration(
                        id: "rn-sdk-\(target)",
                        producers: try taskProducers { $0 == "rn.native-sdk.\(target)" },
                        storageClass: .published,
                        root: sdkRoot.appending("rn"),
                        safetyRoot: sdkRoot,
                        workflowLock: sdkRoot.appending(".rn.lock"),
                        retention: "the validated React Native SDK remains published"))
            }
            declarations = values

        case "wayland":
            var values: [StorageDeclaration] = []
            let nativeRoot = context.nativeSDKRoot.removingLastComponent()
            for target in ["linux-arm64", "linux-x86_64"] {
                let producers = try taskProducers { $0 == "wayland.native-sdk.\(target)" }
                let sdkRoot = nativeRoot.appending(target)
                values += [
                    declaration(
                        id: "wayland-build-\(target)",
                        producers: producers,
                        storageClass: .incremental,
                        root: componentRoot.appending(".wayland-build/\(target)"),
                        safetyRoot: componentRoot.appending(".wayland-build"),
                        workflowLock: context.layout.locks.appending(
                            "wayland-native-\(target).lock"),
                        retention: "the architecture-specific Wayland build remains reusable"),
                    declaration(
                        id: "wayland-sdk-\(target)",
                        producers: producers,
                        storageClass: .published,
                        root: sdkRoot.appending("wayland"),
                        safetyRoot: sdkRoot,
                        workflowLock: context.layout.locks.appending(
                            "wayland-native-\(target).lock"),
                        retention: "the validated Wayland SDK remains published"),
                ]
            }
            declarations = values

        case "android-runtime":
            let aosp = try taskProducers { $0.hasPrefix("android-runtime.aosp-") }
            var values = [
                declaration(
                    id: "android-aosp-build",
                    producers: aosp,
                    storageClass: .generation,
                    root: componentRoot.appending(".aosp-build"),
                    safetyRoot: componentRoot,
                    workflowLock: context.layout.locks.appending("android-runtime-aosp-build.lock"),
                    activeGenerationLink: componentRoot.appending(".aosp-build/current"),
                    retention:
                        "the active AOSP image generation and build intermediates remain available"),
                declaration(
                    id: "android-aosp-ccache",
                    producers: aosp,
                    storageClass: .cache,
                    root: cache.appending("aosp-ccache"),
                    safetyRoot: cache,
                    workflowLock: context.layout.locks.appending(
                        "android-runtime-aosp-ccache.lock"),
                    retention: "AOSP compiler results remain reusable"),
            ]
            for target in ["linux-arm64", "linux-x86_64"] {
                values.append(
                    declaration(
                        id: "android-gfxstream-build-\(target)",
                        producers: try taskProducers {
                            $0 == "android-runtime.gfxstream.\(target)"
                        },
                        storageClass: .incremental,
                        root: componentRoot.appending(".gfxstream-build/\(target)"),
                        safetyRoot: componentRoot.appending(".gfxstream-build"),
                        workflowLock: context.layout.locks.appending(
                            "android-runtime-gfxstream-\(target).lock"),
                        retention: "the architecture-specific gfxstream build remains reusable"))
            }
            declarations = values

        case "linux":
            let artifactRoot = cache.appending("runtime-artifacts/linux-arm64")
            declarations = [
                declaration(
                    id: "linux-runtime-artifacts",
                    producers: try taskProducers { $0 == "linux.arm64.runtime-artifact" },
                    storageClass: .generation,
                    root: artifactRoot,
                    safetyRoot: cache.appending("runtime-artifacts"),
                    workflowLock: artifactRoot.appending(".publish.lock"),
                    activeGenerationLink: artifactRoot.appending("current"),
                    retention: "the active assembled Linux runtime remains published")
            ]

        case "browser":
            let browserCache = cache.appending("cef")
            declarations = [
                declaration(
                    id: "browser-build-and-publications",
                    producers: Set(component.tasks.map { StorageProducer.task($0.id) }),
                    storageClass: .generation,
                    root: browserCache,
                    safetyRoot: cache,
                    workflowLock: browserCache.appending("locks/cache-retention.lock"),
                    retention:
                        "source, build, and validated browser generations follow browser retention")
            ]

        default:
            declarations = []
        }
        return try component.addingStorage(declarations)
    }
}
