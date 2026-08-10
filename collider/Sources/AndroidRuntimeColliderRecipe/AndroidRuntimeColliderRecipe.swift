import ColliderCore
import Foundation
import NativeBuilderColliderRecipe
import SystemPackage

private enum AOSPBuildImageActionKind: OCIEntrypointImageActionKind {
    static let actionKind: ActionKind = "android-runtime.prepare-aosp-build-image"
}

private enum AOSPArtifactImageActionKind: OCIEntrypointImageActionKind {
    static let actionKind: ActionKind = "android-runtime.prepare-aosp-artifact-image"
}

private enum GfxstreamImageActionKind: OCIEntrypointImageActionKind {
    static let actionKind: ActionKind = "android-runtime.prepare-gfxstream-image"
}

package enum AndroidRuntimeEntrypoints {
    package static let packageAddon = ComponentEntrypointID(
        rawValue: "package.android-addon")
}

package enum AndroidRuntimeTaskIDs {
    package static let aospSourceLock = TaskID(
        rawValue: "android-runtime.aosp-source-lock")
    package static let aospSource = TaskID(rawValue: "android-runtime.aosp-source")
    package static let aospImage = TaskID(rawValue: "android-runtime.aosp-image")
    package static let aospBuildTools = TaskID(
        rawValue: "android-runtime.aosp-build-tools")
    package static let aospArtifactTools = TaskID(
        rawValue: "android-runtime.aosp-artifact-tools")
    package static let gfxstreamTools = TaskID(
        rawValue: "android-runtime.gfxstream-tools")

    package static func gfxstream(_ target: NativeLinuxTarget) -> TaskID {
        TaskID(rawValue: "android-runtime.gfxstream.\(target.identifier)")
    }
}

public enum AndroidRuntimeColliderRecipe: ColliderComponent {
    static let rollbackGenerationCount: UInt32 = 1

    package struct GfxstreamArtifacts: Sendable {
        package let task: TaskDeclaration
        package let hostBackend: ArtifactReference<FileArtifact>
        package let guestVulkanDriver: ArtifactReference<FileArtifact>
    }

    package struct Artifacts: Sendable {
        package let gfxstream: [NativeLinuxTarget: GfxstreamArtifacts]
        package let activeAOSPGeneration: ArtifactReference<PathArtifact>
    }

    package struct PreparedComponent: Sendable {
        package let component: ComponentDefinition
        package let artifacts: Artifacts
    }

    public static let descriptor = ComponentDescriptor(
        id: ComponentID(rawValue: "android-runtime"),
        canonicalName: "android-runtime",
        directoryName: "android-runtime")

    private static let component = ComponentID(rawValue: "android-runtime")

    private struct SourceLockArtifacts {
        let task: TaskDeclaration
        let verification: ArtifactReference<JSONArtifact>
    }

    private struct RepoLauncherArtifacts {
        let task: TaskDeclaration
        let executable: ArtifactReference<FileArtifact>
    }

    private struct SourceArtifacts {
        let tasks: [TaskDeclaration]
        let provenance: ArtifactReference<JSONArtifact>
    }

    private struct SourceTaskArtifacts {
        let task: TaskDeclaration
        let provenance: ArtifactReference<JSONArtifact>
    }

    private struct SigningArtifacts {
        let task: TaskDeclaration
        let identity: ArtifactReference<JSONArtifact>
        let directory: ArtifactReference<DirectoryArtifact>
    }

    private struct CompileArtifacts {
        let task: TaskDeclaration
        let unsignedTargetFiles: ArtifactReference<FileArtifact>
        let result: TaskResultReference<AOSPCompileResult>
    }

    private struct AOSPContainerArtifacts {
        let tasks: [TaskDeclaration]
        let buildImage: ArtifactReference<FileArtifact>
        let artifactImage: ArtifactReference<FileArtifact>
        let cacheRoot: FilePath
    }

    private struct GfxstreamContainerArtifacts {
        let task: TaskDeclaration
        let image: ArtifactReference<FileArtifact>
        let cacheRoot: FilePath
    }

    private struct AssembleArtifacts {
        let task: TaskDeclaration
        let targetFiles: ArtifactReference<FileArtifact>
        let imageArchive: ArtifactReference<FileArtifact>
        let images: [ArtifactReference<FileArtifact>]
    }

    package struct AOSPImageArtifacts: Sendable {
        package let tasks: [TaskDeclaration]
        package let activeGeneration: ArtifactReference<PathArtifact>
    }

    public static func makeComponent(
        in context: RecipeContext
    ) throws -> ComponentDefinition {
        try prepare(in: context).component
    }

    package static func prepare(
        in context: RecipeContext
    ) throws -> PreparedComponent {
        let native = try context.configuration(
            NativeBuilderGraphConfiguration.self,
            for: NativeBuilderColliderRecipe.descriptor.id)
        let root = context.componentRoot(descriptor)
        let aospSourceRoot = try aospSourceRoot(
            root: root,
            environment: context.environment)
        let aospBuildRoot = aospBuildRoot(
            root: root,
            environment: context.environment)
        let aospContainers = try aospContainerTasks(
            root: root,
            cacheRoot: context.cacheRoot.appending(
                "nucleus/android-runtime/build-container"),
            dependencyImage: native.builder.dependencyImage,
            environment: context.environment)
        let aosp = try aospImageTasks(
            root: root,
            sourceRoot: aospSourceRoot,
            buildImage: aospContainers.buildImage,
            artifactImage: aospContainers.artifactImage,
            environment: context.environment)
        let gfxstreamContainer = try gfxstreamContainerTask(
            root: root,
            cacheRoot: context.cacheRoot.appending(
                "nucleus/android-runtime/gfxstream-build-container"),
            dependencyImage: native.builder.dependencyImage,
            environment: context.environment)
        var tasks = aospContainers.tasks + aosp.tasks + [gfxstreamContainer.task]
        var gfxstreamRoots: Set<TaskID> = []
        var gfxstreamArtifacts: [NativeLinuxTarget: GfxstreamArtifacts] = [:]
        for architecture in PlatformArchitecture.allCases {
            let target = NativeLinuxTarget(architecture: architecture)
            let artifacts = try buildGfxstream(
                root: root,
                repositoryRoot: context.repositoryRoot,
                sdkRoot: native.nativeSDK(for: target),
                environment: context.environment,
                target: target,
                image: gfxstreamContainer.image,
                builder: native.builder)
            tasks.append(artifacts.task)
            gfxstreamRoots.insert(artifacts.task.id)
            gfxstreamArtifacts[target] = artifacts
        }
        var entrypoints = [
            ComponentEntrypoint(id: .bootstrap, roots: gfxstreamRoots),
            ComponentEntrypoint(
                id: ComponentEntrypointID(rawValue: "aosp.source-lock"),
                roots: [AndroidRuntimeTaskIDs.aospSourceLock]),
            ComponentEntrypoint(
                id: ComponentEntrypointID(rawValue: "aosp.source"),
                roots: [AndroidRuntimeTaskIDs.aospSource]),
            ComponentEntrypoint(
                id: ComponentEntrypointID(rawValue: "aosp.image"),
                roots: [AndroidRuntimeTaskIDs.aospImage]),
        ]
        var platformStorage: [StorageDeclaration] = []
        #if os(Linux)
        if let configuration = try context.configurationIfPresent(
            AndroidAddonPackageConfiguration.self,
            for: descriptor.id)
        {
            let package = try addonPackageTask(
                configuration: configuration,
                repositoryRoot: context.repositoryRoot,
                managedAOSPGeneration: aosp.activeGeneration)
            tasks.append(package)
            entrypoints.append(
                ComponentEntrypoint(
                    id: AndroidRuntimeEntrypoints.packageAddon,
                    roots: [package.id]))
            platformStorage = [
                StorageDeclaration(
                    id: "android-addon-packaging-scratch",
                    owner: descriptor.id,
                    producers: [.task(package.id)],
                    storageClass: .incremental,
                    root: configuration.runtimeScratch,
                    safetyRoot: configuration.runtimeScratch.removingLastComponent(),
                    cleanupPolicy: .explicitClean,
                    retention: "Android add-on packaging scratch remains until explicit clean"),
                StorageDeclaration(
                    id: "android-addon-publication",
                    owner: descriptor.id,
                    producers: [.task(package.id)],
                    storageClass: .published,
                    root: configuration.output,
                    safetyRoot: configuration.output,
                    cleanupPolicy: .protected,
                    retention: "the requested downloadable Android add-on remains published"),
            ]
        }
        #endif
        let aospProductProducers = Set(
            [
                "android-runtime.aosp-compile",
                "android-runtime.aosp-sign",
                "android-runtime.aosp-assemble-images",
                "android-runtime.aosp-validate",
                AndroidRuntimeTaskIDs.aospImage.rawValue,
            ].map { StorageProducer.task(TaskID(rawValue: $0)) })
        var storage = [
            StorageDeclaration(
                id: "android-aosp-source",
                owner: descriptor.id,
                producers: [.task(AndroidRuntimeTaskIDs.aospSource)],
                storageClass: .source,
                root: aospSourceRoot,
                safetyRoot: aospSourceRoot.removingLastComponent(),
                cleanupPolicy: .protected,
                retention: "the exact Repo-managed AOSP source checkout remains materialized"),
            StorageDeclaration(
                id: "android-aosp-signing-identity",
                owner: descriptor.id,
                producers: [
                    .task(TaskID(rawValue: "android-runtime.aosp-signing-identity"))
                ],
                storageClass: .identity,
                root: root.appending(".aosp-signing"),
                safetyRoot: root,
                cleanupPolicy: .protected,
                retention: "AOSP private signing identity is never a cleanup candidate"),
            StorageDeclaration(
                id: "android-aosp-tools",
                owner: descriptor.id,
                producers: [
                    .task(AndroidRuntimeTaskIDs.aospSourceLock),
                    .task(TaskID(rawValue: "android-runtime.aosp-repo-launcher")),
                ],
                storageClass: .cache,
                root: root.appending(".aosp-tools"),
                safetyRoot: root,
                cleanupPolicy: .explicitClean,
                retention: "verified Repo tooling and source-lock reports remain reusable"),
            StorageDeclaration(
                id: "android-aosp-container-tools",
                owner: descriptor.id,
                producers: Set(
                    aospContainers.tasks.map { StorageProducer.task($0.id) }),
                storageClass: .cache,
                root: aospContainers.cacheRoot,
                safetyRoot: aospContainers.cacheRoot.removingLastComponent(),
                cleanupPolicy: .explicitClean,
                retention:
                    "the AOSP build and artifact entrypoint images remain reusable"),
            StorageDeclaration(
                id: "android-gfxstream-container-tools",
                owner: descriptor.id,
                producers: [.task(gfxstreamContainer.task.id)],
                storageClass: .cache,
                root: gfxstreamContainer.cacheRoot,
                safetyRoot: gfxstreamContainer.cacheRoot.removingLastComponent(),
                cleanupPolicy: .explicitClean,
                retention: "the gfxstream entrypoint image remains reusable"),
            StorageDeclaration(
                id: "android-aosp-build",
                owner: descriptor.id,
                producers: aospProductProducers,
                storageClass: .generation,
                root: aospBuildRoot.appending("generations"),
                safetyRoot: aospBuildRoot,
                cleanupPolicy: .automaticRetention,
                activeGenerationLink: aospBuildRoot.appending("current"),
                rollbackGenerationCount: rollbackGenerationCount,
                retention:
                    "the active signed AOSP artifact generation remains available"),
        ]
        for architecture in PlatformArchitecture.allCases {
            let target = NativeLinuxTarget(architecture: architecture)
            let sdkRoot = native.nativeSDK(for: target)
            storage.append(
                StorageDeclaration(
                    id: "android-gfxstream-sdk-\(target.identifier)",
                    owner: descriptor.id,
                    producers: [
                        .task(TaskID(rawValue: "android-runtime.gfxstream.\(target.identifier)"))
                    ],
                    storageClass: .published,
                    root: sdkRoot.appending("android/gfxstream"),
                    safetyRoot: sdkRoot,
                    cleanupPolicy: .explicitClean,
                    retention: "the architecture-specific gfxstream SDK remains published"))
        }
        storage += platformStorage
        let component = try ComponentDefinition(
            descriptor: descriptor,
            tasks: tasks,
            entrypoints: entrypoints,
            storage: storage)
        return PreparedComponent(
            component: component,
            artifacts: Artifacts(
                gfxstream: gfxstreamArtifacts,
                activeAOSPGeneration: aosp.activeGeneration))
    }

    private static func aospProductSourceOverlays(
        root: FilePath
    ) -> [AOSPProductSourceOverlay] {
        [
            AOSPProductSourceOverlay(
                source: root.removingLastComponent().appending(
                    "ipc/transport/Sources/NucleusIPCTransportC"),
                relativeDestination: "native/ipc-transport"),
            AOSPProductSourceOverlay(
                source: root.appending(
                    "aosp/packages/apps/NucleusRuntimeBridge"),
                relativeDestination:
                    "packages/apps/NucleusRuntimeBridge"),
        ]
    }

    public static func verifyAOSPSourceLock(
        root: FilePath,
        environment: [String: String]
    ) throws -> TaskDeclaration {
        let launcher = try aospRepoLauncher(
            root: root,
            environment: environment)
        return try aospSourceLockArtifacts(
            root: root,
            environment: environment,
            launcher: launcher.executable
        ).task
    }

    private static func aospSourceLockArtifacts(
        root: FilePath,
        environment: [String: String],
        launcher: ArtifactReference<FileArtifact>
    ) throws -> SourceLockArtifacts {
        let lockPath = root.appending("aosp.lock.json")
        let report = root.appending(
            ".aosp-tools/source-lock-verification.json")
        let lock = try loadAOSPSourceLock(root: root)
        let specification = try lock.specification()
        var builder = TaskBuilder(
            id: AndroidRuntimeTaskIDs.aospSourceLock,
            component: component)
        builder.consume(launcher)
        let verification: ArtifactReference<JSONArtifact> = try builder.output(
            "verification",
            path: report,
            validation: .json)
        let task = builder.build(
            inputs: [
                .file(lockPath),
                .tool(.named("git")),
            ],
            locks: [.checkout("android-runtime-aosp-source-lock")],
            assessmentPolicy: .incremental,
            action:
                try AnyColliderAction(
                    VerifyAOSPSourceLockAction(
                        verification: AOSPSourceLockVerification(
                            specification: specification,
                            launcher: launcher.path,
                            report: report,
                            environment: environment)))
        )
        return SourceLockArtifacts(task: task, verification: verification)
    }

    public static func aospSourceTasks(
        root: FilePath,
        environment: [String: String]
    ) throws -> [TaskDeclaration] {
        try aospSourceArtifacts(
            root: root,
            environment: environment
        ).tasks
    }

    private static func aospContainerTasks(
        root: FilePath,
        cacheRoot: FilePath,
        dependencyImage: ArtifactReference<FileArtifact>,
        environment: [String: String]
    ) throws -> AOSPContainerArtifacts {
        let sourceRoot = root.appending("build-container")
        let buildEntrypoint = sourceRoot.appending("build-entrypoint.sh")
        let artifactEntrypoint = sourceRoot.appending(
            "artifact-entrypoint.sh")
        let buildContext = cacheRoot.appending("build-context")
        let artifactContext = cacheRoot.appending("artifact-context")
        let buildImageID = cacheRoot.appending("build-image-id")
        let artifactImageID = cacheRoot.appending("artifact-image-id")

        var buildBuilder = TaskBuilder(
            id: AndroidRuntimeTaskIDs.aospBuildTools,
            component: component)
        buildBuilder.consume(dependencyImage)
        let buildImage: ArtifactReference<FileArtifact> = try buildBuilder.output(
            "image-id",
            path: buildImageID,
            validation: .regularFile)
        let buildTask = buildBuilder.build(
            inputs: [.file(buildEntrypoint)],
            locks: [.checkout("android-runtime-aosp-build-image")],
            action: try AnyColliderAction(
                PrepareOCIEntrypointImageAction<AOSPBuildImageActionKind>(
                    baseImageID: dependencyImage.path,
                    entrypoint: buildEntrypoint,
                    entrypointDestination: "/usr/local/bin/nucleus-aosp-build",
                    generatedContext: buildContext,
                    preparation: OCIImagePreparation(
                        executionPlatform: .linuxARM64OCI,
                        context: buildContext,
                        containerFile: buildContext.appending("Containerfile"),
                        imageID: buildImageID,
                        imageName: "localhost/nucleus-aosp-build",
                        baseImageSource: .local,
                        localBaseImageID: dependencyImage.path,
                        environment: environment))))

        var artifactBuilder = TaskBuilder(
            id: AndroidRuntimeTaskIDs.aospArtifactTools,
            component: component)
        artifactBuilder.consume(dependencyImage)
        let artifactImage: ArtifactReference<FileArtifact> =
            try artifactBuilder.output(
                "image-id",
                path: artifactImageID,
                validation: .regularFile)
        let artifactTask = artifactBuilder.build(
            inputs: [.file(artifactEntrypoint)],
            locks: [.checkout("android-runtime-aosp-artifact-image")],
            action: try AnyColliderAction(
                PrepareOCIEntrypointImageAction<AOSPArtifactImageActionKind>(
                    baseImageID: dependencyImage.path,
                    entrypoint: artifactEntrypoint,
                    entrypointDestination:
                        "/usr/local/bin/nucleus-aosp-artifact",
                    generatedContext: artifactContext,
                    preparation: OCIImagePreparation(
                        executionPlatform: .linuxARM64OCI,
                        context: artifactContext,
                        containerFile: artifactContext.appending(
                            "Containerfile"),
                        imageID: artifactImageID,
                        imageName: "localhost/nucleus-aosp-artifact",
                        baseImageSource: .local,
                        localBaseImageID: dependencyImage.path,
                        environment: environment))))

        return AOSPContainerArtifacts(
            tasks: [buildTask, artifactTask],
            buildImage: buildImage,
            artifactImage: artifactImage,
            cacheRoot: cacheRoot)
    }

    private static func gfxstreamContainerTask(
        root: FilePath,
        cacheRoot: FilePath,
        dependencyImage: ArtifactReference<FileArtifact>,
        environment: [String: String]
    ) throws -> GfxstreamContainerArtifacts {
        let entrypoint = root.appending(
            "gfxstream-build-container/entrypoint.sh")
        let generatedContext = cacheRoot.appending("context")
        let imageID = cacheRoot.appending("image-id")
        var builder = TaskBuilder(
            id: AndroidRuntimeTaskIDs.gfxstreamTools,
            component: component)
        builder.consume(dependencyImage)
        let image: ArtifactReference<FileArtifact> = try builder.output(
            "image-id",
            path: imageID,
            validation: .regularFile)
        let task = builder.build(
            inputs: [.file(entrypoint)],
            locks: [.checkout("android-runtime-gfxstream-image")],
            action: try AnyColliderAction(
                PrepareOCIEntrypointImageAction<GfxstreamImageActionKind>(
                    baseImageID: dependencyImage.path,
                    entrypoint: entrypoint,
                    entrypointDestination:
                        "/usr/local/bin/nucleus-gfxstream-build",
                    generatedContext: generatedContext,
                    preparation: OCIImagePreparation(
                        executionPlatform: .linuxARM64OCI,
                        context: generatedContext,
                        containerFile: generatedContext.appending(
                            "Containerfile"),
                        imageID: imageID,
                        imageName: "localhost/nucleus-gfxstream-build",
                        baseImageSource: .local,
                        localBaseImageID: dependencyImage.path,
                        environment: environment))))
        return GfxstreamContainerArtifacts(
            task: task,
            image: image,
            cacheRoot: cacheRoot)
    }

    private static func aospSourceArtifacts(
        root: FilePath,
        sourceRoot: FilePath? = nil,
        environment: [String: String]
    ) throws -> SourceArtifacts {
        let launcher = try aospRepoLauncher(
            root: root,
            environment: environment)
        let verification = try aospSourceLockArtifacts(
            root: root,
            environment: environment,
            launcher: launcher.executable)
        let source = try aospSource(
            root: root,
            sourceRoot: sourceRoot ?? root.appending(".aosp-source"),
            environment: environment,
            launcher: launcher.executable,
            verification: verification.verification)
        return SourceArtifacts(
            tasks: [launcher.task, verification.task, source.task],
            provenance: source.provenance)
    }

    package static func aospImageTasks(
        root: FilePath,
        sourceRoot: FilePath? = nil,
        buildImage: ArtifactReference<FileArtifact>,
        artifactImage: ArtifactReference<FileArtifact>,
        environment: [String: String]
    ) throws -> AOSPImageArtifacts {
        let resolvedSourceRoot = sourceRoot ?? root.appending(".aosp-source")
        let source = try aospSourceArtifacts(
            root: root,
            sourceRoot: resolvedSourceRoot,
            environment: environment)
        let signing = try aospSigningIdentity(
            root: root,
            environment: environment)
        let product = try aospProductImageTasks(
            root: root,
            sourceRoot: resolvedSourceRoot,
            environment: environment,
            sourceProvenance: source.provenance,
            signing: signing,
            buildImage: buildImage,
            artifactImage: artifactImage)
        return AOSPImageArtifacts(
            tasks: source.tasks + [signing.task] + product.tasks,
            activeGeneration: product.activeGeneration)
    }

    private static func aospRepoLauncher(
        root: FilePath,
        environment _: [String: String]
    ) throws -> RepoLauncherArtifacts {
        let lock = try loadAOSPSourceLock(root: root)
        try lock.validate()
        guard let digest = ArtifactDigest(sha256Hex: lock.repo.launcherSHA256),
            let url = URL(string: lock.repo.launcherURL)
        else {
            throw AndroidRuntimeRecipeFailure.invalidAOSPSourceLock(
                "Repo launcher download specification is invalid")
        }
        let launcher = try aospRepoLauncherPath(root: root)
        let specification = try DownloadSpec(
            url: url,
            permittedRedirectOrigins: ["https://storage.googleapis.com"],
            expectedDigest: digest,
            maximumResponseSize: 2 * 1_024 * 1_024,
            acceptedMediaTypes: [
                "application/octet-stream",
                "text/plain",
            ])
        var builder = TaskBuilder(
            id: TaskID(rawValue: "android-runtime.aosp-repo-launcher"),
            component: component)
        let executable: ArtifactReference<FileArtifact> = try builder.output(
            "repo-launcher",
            path: launcher,
            validation: .regularFile)
        let task = builder.build(
            inputs: [
                .file(root.appending("aosp.lock.json"))
            ],
            locks: [.checkout("android-runtime-aosp-downloads")],
            action:
                try AnyColliderAction(
                    DownloadAOSPRepoLauncherAction(
                        specification: specification,
                        destination: launcher)))
        return RepoLauncherArtifacts(task: task, executable: executable)
    }

    private static func aospSource(
        root: FilePath,
        sourceRoot: FilePath,
        environment: [String: String],
        launcher: ArtifactReference<FileArtifact>,
        verification: ArtifactReference<JSONArtifact>
    ) throws -> SourceTaskArtifacts {
        let lock = try loadAOSPSourceLock(root: root)
        let specification = try lock.specification()
        let lockPath = root.appending("aosp.lock.json")
        let source = sourceRoot
        var builder = TaskBuilder(
            id: AndroidRuntimeTaskIDs.aospSource,
            component: component)
        builder.consume(verification)
        builder.consume(launcher)
        let _: ArtifactReference<FileArtifact> = try builder.output(
            "resolved-manifest",
            path: source.appending(".nucleus/resolved-manifest.xml"),
            validation: .regularFile)
        let provenance: ArtifactReference<JSONArtifact> = try builder.output(
            "provenance",
            path: source.appending(".nucleus/source-provenance.json"),
            validation: .json)
        let task = builder.build(
            inputs: [
                .file(lockPath),
                .tool(.named("git")),
                .tool(.named("python3")),
            ],
            locks: [.checkout("android-runtime-aosp-source")],
            action:
                try AnyColliderAction(
                    PrepareAOSPSourceAction(
                        preparation: AOSPSourcePreparation(
                            specification: specification,
                            launcher: launcher.path,
                            source: source,
                            syncJobs: 4,
                            retryFetches: 3,
                            environment: environment)))
        )
        return SourceTaskArtifacts(task: task, provenance: provenance)
    }

    private static func aospSigningIdentity(
        root: FilePath,
        environment: [String: String]
    ) throws -> SigningArtifacts {
        let signingIdentity = root.appending(
            ".aosp-signing/local-development")
        var builder = TaskBuilder(
            id: TaskID(rawValue: "android-runtime.aosp-signing-identity"),
            component: component)
        let identity: ArtifactReference<JSONArtifact> = try builder.output(
            "identity",
            path: signingIdentity.appending("signing-identity.json"),
            validation: .json)
        let directory: ArtifactReference<DirectoryArtifact> = try builder.output(
            "directory",
            path: signingIdentity,
            validation: .nonEmptyDirectory)
        let task = builder.build(
            inputs: [
                .string(
                    name: "subject",
                    value: aospSigningSubject),
                .tool(.named("openssl")),
            ],
            locks: [.checkout("android-runtime-aosp-signing")],
            action:
                try AnyColliderAction(
                    PrepareAOSPSigningIdentityAction(
                        preparation: AOSPSigningIdentityPreparation(
                            destination: signingIdentity,
                            subject: aospSigningSubject,
                            environment: environment))))
        return SigningArtifacts(
            task: task,
            identity: identity,
            directory: directory)
    }

    private struct PublishedAOSPArtifacts {
        let tasks: [TaskDeclaration]
        let activeGeneration: ArtifactReference<PathArtifact>
    }

    private static func aospProductImageTasks(
        root: FilePath,
        sourceRoot: FilePath,
        environment: [String: String],
        sourceProvenance: ArtifactReference<JSONArtifact>,
        signing: SigningArtifacts,
        buildImage: ArtifactReference<FileArtifact>,
        artifactImage: ArtifactReference<FileArtifact>
    ) throws -> PublishedAOSPArtifacts {
        let lockPath = root.appending("aosp-product.lock.json")
        let lock = try JSONDecoder().decode(
            AOSPProductLock.self,
            from: Data(contentsOf: URL(fileURLWithPath: lockPath.string)))
        try lock.validate()
        let source = sourceRoot
        let signingIdentity = root.appending(
            ".aosp-signing/local-development")
        let aospBuildRoot = aospBuildRoot(
            root: root,
            environment: environment)
        let productIdentity = Array(
            [
                lock.product,
                lock.release,
                lock.variant,
                lock.buildNumber,
                String(lock.buildTimestamp),
                String(lock.platformSDK),
                String(lock.vendorAPILevel),
            ].joined(separator: "\0").utf8)
        let generationID = [
            String(lock.buildTimestamp),
            lock.buildNumber,
            lock.release,
            lock.product,
            lock.variant,
            String(lock.platformSDK),
            String(lock.vendorAPILevel),
        ].joined(separator: "-")
        let buildRoot =
            aospBuildRoot
            .appending("generations")
            .appending(generationID)
        let active = aospBuildRoot.appending("current")
        let signed = buildRoot.appending("signed")
        let images = buildRoot.appending("images")
        let unsigned = buildRoot.appending(
            "unsigned/\(lock.product)-target_files.zip")
        let unsignedDigest = buildRoot.appending(
            "unsigned/\(lock.product)-target_files.zip.sha256")
        let staged = buildRoot.appending("staged")
        let stagedTargetFiles = staged.appending(
            "\(lock.product)-target_files.zip")
        let stagedImageArchive = staged.appending(
            "\(lock.product)-images.zip")
        let stagedImages = staged.appending("images")
        let stagedProvenance = staged.appending(
            "image-provenance.json")
        let build = AOSPProductBuild(
            productSource: root.appending(
                "aosp/device/nucleus/nucleus_x86_64"),
            source: source,
            sourceProvenance: sourceProvenance.path,
            artifactRoot: buildRoot,
            outputWorkspace: aospOutputWorkspace(apiLevel: lock.platformSDK),
            compilerCacheWorkspace: aospCompilerCacheWorkspace(
                apiLevel: lock.platformSDK),
            buildImageID: buildImage.path,
            artifactImageID: artifactImage.path,
            signingIdentity: signingIdentity,
            product: lock.product,
            release: lock.release,
            variant: lock.variant,
            buildNumber: lock.buildNumber,
            buildTimestamp: lock.buildTimestamp,
            buildJobs: lock.buildJobs,
            expectedPlatformSDK: lock.platformSDK,
            expectedVendorAPILevel: lock.vendorAPILevel,
            environment: environment,
            sourceOverlays: aospProductSourceOverlays(root: root))
        let requiredImages = aospRequiredProductImages
        var compileBuilder = TaskBuilder(
            id: TaskID(rawValue: "android-runtime.aosp-compile"),
            component: component)
        compileBuilder.consume(sourceProvenance)
        compileBuilder.consume(buildImage)
        let unsignedReference: ArtifactReference<FileArtifact> = try compileBuilder.output(
            "unsigned-target-files",
            path: unsigned,
            validation: .regularFile)
        let _: ArtifactReference<FileArtifact> = try compileBuilder.output(
            "unsigned-target-files-digest",
            path: unsignedDigest,
            validation: .regularFile)
        let compileResult: TaskResultReference<AOSPCompileResult> =
            try compileBuilder.result("compiled-output")
        let compileTask = compileBuilder.build(
            inputs: [
                .value(
                    name: "aosp-product-identity",
                    bytes: productIdentity),
                .sourceCheckout(
                    root.appending(
                        "aosp/device/nucleus/nucleus_x86_64")),
                .sourceCheckout(
                    root.removingLastComponent().appending(
                        "ipc/transport/Sources/NucleusIPCTransportC")),
                .sourceCheckout(
                    root.appending(
                        "aosp/packages/apps/NucleusRuntimeBridge")),
                .tool(.named("python3")),
            ],
            locks: [
                .checkout("android-runtime-aosp-source"),
                .checkout("android-runtime-aosp-build"),
            ],
            action:
                try AnyColliderAction(
                    CompileAOSPProductAction(build: build))
        )
        let compile = CompileArtifacts(
            task: compileTask,
            unsignedTargetFiles: unsignedReference,
            result: compileResult)
        var signBuilder = TaskBuilder(
            id: TaskID(rawValue: "android-runtime.aosp-sign"),
            component: component)
        signBuilder.consume(signing.identity)
        signBuilder.consume(signing.directory)
        signBuilder.consume(compile.unsignedTargetFiles)
        signBuilder.consume(compile.result)
        signBuilder.consume(artifactImage)
        let stagedTargetFilesReference: ArtifactReference<FileArtifact> =
            try signBuilder.output(
                "staged-target-files",
                path: stagedTargetFiles,
                validation: .regularFile)
        let sign = signBuilder.build(
            inputs: [
                .value(
                    name: "aosp-product-identity",
                    bytes: productIdentity),
                .tool(.named("openssl")),
            ],
            locks: [
                .checkout("android-runtime-aosp-source"),
                .checkout("android-runtime-aosp-build"),
            ],
            action:
                try AnyColliderAction(
                    SignAOSPProductAction(build: build))
        )
        var assembleBuilder = TaskBuilder(
            id: TaskID(rawValue: "android-runtime.aosp-assemble-images"),
            component: component)
        assembleBuilder.consume(stagedTargetFilesReference)
        assembleBuilder.consume(compile.result)
        assembleBuilder.consume(artifactImage)
        let stagedArchiveReference: ArtifactReference<FileArtifact> =
            try assembleBuilder.output(
                "image-archive",
                path: stagedImageArchive,
                validation: .regularFile)
        let stagedImageReferences: [ArtifactReference<FileArtifact>] =
            try requiredImages.map { image in
                try assembleBuilder.output(
                    OutputSlotID(rawValue: "image-\(image)"),
                    path: stagedImages.appending(image),
                    validation: .regularFile)
            }
        let assembleTask = assembleBuilder.build(
            inputs: [
                .value(
                    name: "aosp-product-identity",
                    bytes: productIdentity),
                .tool(.named("unzip")),
            ],
            locks: [
                .checkout("android-runtime-aosp-source"),
                .checkout("android-runtime-aosp-build"),
            ],
            action:
                try AnyColliderAction(
                    AssembleAOSPProductImagesAction(build: build)))
        let assemble = AssembleArtifacts(
            task: assembleTask,
            targetFiles: stagedTargetFilesReference,
            imageArchive: stagedArchiveReference,
            images: stagedImageReferences)
        var validateBuilder = TaskBuilder(
            id: TaskID(rawValue: "android-runtime.aosp-validate"),
            component: component)
        validateBuilder.consume(sourceProvenance)
        validateBuilder.consume(signing.identity)
        validateBuilder.consume(assemble.targetFiles)
        validateBuilder.consume(assemble.imageArchive)
        validateBuilder.consume(artifactImage)
        for image in assemble.images {
            validateBuilder.consume(image)
        }
        let stagedProvenanceReference: ArtifactReference<JSONArtifact> =
            try validateBuilder.output(
                "image-provenance",
                path: stagedProvenance,
                validation: .json)
        let validate = validateBuilder.build(
            inputs: [
                .value(
                    name: "aosp-product-identity",
                    bytes: productIdentity),
                .sourceCheckout(
                    root.appending(
                        "aosp/device/nucleus/nucleus_x86_64")),
                .sourceCheckout(
                    root.removingLastComponent().appending(
                        "ipc/transport/Sources/NucleusIPCTransportC")),
                .tool(.named("openssl")),
                .tool(.named("unzip")),
            ],
            locks: [
                .checkout("android-runtime-aosp-source"),
                .checkout("android-runtime-aosp-build"),
            ],
            action:
                try AnyColliderAction(
                    ValidateAOSPProductAction(build: build))
        )
        var publishBuilder = TaskBuilder(
            id: AndroidRuntimeTaskIDs.aospImage,
            component: component)
        publishBuilder.consume(stagedProvenanceReference)
        publishBuilder.consume(assemble.targetFiles)
        publishBuilder.consume(assemble.imageArchive)
        for image in assemble.images {
            publishBuilder.consume(image)
        }
        let _: ArtifactReference<JSONArtifact> = try publishBuilder.output(
            "image-provenance",
            path: signed.appending("image-provenance.json"),
            validation: .json)
        let _: ArtifactReference<FileArtifact> = try publishBuilder.output(
            "target-files",
            path: signed.appending("\(lock.product)-target_files.zip"),
            validation: .regularFile)
        let _: ArtifactReference<FileArtifact> = try publishBuilder.output(
            "image-archive",
            path: signed.appending("\(lock.product)-images.zip"),
            validation: .regularFile)
        let activeGeneration: ArtifactReference<PathArtifact> = try publishBuilder.output(
            "active-generation",
            path: active,
            validation: .symlinkTarget)
        for image in requiredImages {
            let _: ArtifactReference<FileArtifact> = try publishBuilder.output(
                OutputSlotID(rawValue: "image-\(image)"),
                path: images.appending(image),
                validation: .regularFile)
        }
        let publish = publishBuilder.build(
            inputs: [],
            locks: [.checkout("android-runtime-aosp-build")],
            action:
                try AnyColliderAction(
                    PublishAOSPProductAction(build: build))
        )
        return PublishedAOSPArtifacts(
            tasks: [compile.task, sign, assemble.task, validate, publish],
            activeGeneration: activeGeneration)
    }

    private static func loadAOSPSourceLock(
        root: FilePath
    ) throws -> AOSPSourceLock {
        try JSONDecoder().decode(
            AOSPSourceLock.self,
            from: Data(
                contentsOf: URL(
                    fileURLWithPath: root.appending("aosp.lock.json").string)))
    }

    private static func aospSourceRoot(
        root: FilePath,
        environment: [String: String]
    ) throws -> FilePath {
        guard let buildRoot = environment["NUCLEUS_BUILD_ROOT"], !buildRoot.isEmpty
        else {
            return root.appending(".aosp-source")
        }
        let lock = try loadAOSPSourceLock(root: root)
        try lock.validate()
        return FilePath(buildRoot)
            .appending("nucleus/aosp-source")
            .appending(lock.source.manifestCommit)
    }

    private static func aospBuildRoot(
        root: FilePath,
        environment: [String: String]
    ) -> FilePath {
        guard let buildRoot = environment["NUCLEUS_BUILD_ROOT"], !buildRoot.isEmpty
        else {
            return root.appending(".aosp-build")
        }
        return FilePath(buildRoot).appending("nucleus/aosp-build")
    }

    private static func aospRepoLauncherPath(
        root: FilePath
    ) throws -> FilePath {
        let lock = try loadAOSPSourceLock(root: root)
        try lock.validate()
        return root.appending(
            ".aosp-tools/repo-\(lock.repo.launcherVersion)")
    }

    package static func buildGfxstream(
        root: FilePath,
        repositoryRoot: FilePath,
        sdkRoot: FilePath,
        environment: [String: String],
        target: NativeLinuxTarget,
        image: ArtifactReference<FileArtifact>,
        builder: NativeOCIConfiguration
    ) throws -> GfxstreamArtifacts {
        let artifactRoot = sdkRoot.appending("android/gfxstream")
        let hostSource = repositoryRoot.appending("third-party/gfxstream")
        let guestSource = repositoryRoot.appending("third-party/mesa")
        let crossFile = root.appending("build-support/linux-x86_64.ini")
        let crossOption =
            target.architecture == .x86_64
            ? " --cross-file=/build-support/linux-x86_64.ini" : ""
        let hostBuild = "/build/host"
        let guestBuild = "/build/guest"
        let buildWorkspace = PersistentWorkspaceDeclaration(
            identity: PersistentWorkspaceIdentity(
                key: "android-gfxstream-intermediates",
                artifactTarget: target.artifactTarget,
                role: "build"),
            capacityBytes: 100 * 1_024 * 1_024 * 1_024,
            filesystem: .ext4,
            journal: .writeback64MiB)
        let compilerCacheWorkspace = PersistentWorkspaceDeclaration(
            identity: PersistentWorkspaceIdentity(
                key: "android-gfxstream-ccache",
                artifactTarget: target.artifactTarget,
                role: "compiler-cache"),
            capacityBytes: 50 * 1_024 * 1_024 * 1_024,
            filesystem: .ext4,
            journal: .writeback64MiB)
        var task = TaskBuilder(
            id: AndroidRuntimeTaskIDs.gfxstream(target),
            component: component)
        task.consume(image)
        task.consume(builder.swiftSDK)
        let hostBackend: ArtifactReference<FileArtifact> = try task.output(
            "host-backend",
            path: artifactRoot.appending("lib/libgfxstream_backend.a"),
            validation: .regularFile)
        let guestVulkanDriver: ArtifactReference<FileArtifact> = try task.output(
            "guest-vulkan-driver",
            path: artifactRoot.appending("lib/libvulkan_gfxstream.so"),
            validation: .regularFile)
        let declaration = task.build(
            inputs: [
                .sourceCheckout(hostSource),
                .sourceCheckout(guestSource),
            ] + (target.architecture == .x86_64 ? [.file(crossFile)] : []),
            locks: [
                .checkout("android-runtime-gfxstream-\(target.identifier)")
            ],
            assessmentPolicy: .incremental,
            action:
                try AnyColliderAction(
                    RunGfxstreamBuildAction(
                        artifactRoot: artifactRoot,
                        executions: [
                            try gfxstreamExecution(
                                root: root,
                                hostSource: hostSource,
                                guestSource: guestSource,
                                artifactRoot: artifactRoot,
                                buildWorkspace: buildWorkspace,
                                compilerCacheWorkspace: compilerCacheWorkspace,
                                target: target,
                                imageID: image.path,
                                builder: builder,
                                environment: environment,
                                command: [
                                    "bash", "-lc",
                                    "meson setup \(hostBuild) /gfxstream"
                                        + " -Dbuildtype=release -Ddefault_library=static"
                                        + " -Ddecoders=gles,vulkan,composer -Dgfxstream-build=host"
                                        + crossOption
                                        + " && meson compile -C \(hostBuild) gfxstream_backend"
                                        + " && mkdir -p /export/lib"
                                        + " && install -m 0644"
                                        + " \(hostBuild)/host/libgfxstream_backend.a"
                                        + " /export/lib/libgfxstream_backend.a",
                                ]),
                            try gfxstreamExecution(
                                root: root,
                                hostSource: hostSource,
                                guestSource: guestSource,
                                artifactRoot: artifactRoot,
                                buildWorkspace: buildWorkspace,
                                compilerCacheWorkspace: compilerCacheWorkspace,
                                target: target,
                                imageID: image.path,
                                builder: builder,
                                environment: environment,
                                command: [
                                    "bash", "-lc",
                                    "meson setup \(guestBuild) /mesa"
                                        + " -Dbuildtype=release -Dvulkan-drivers=gfxstream"
                                        + " -Dgallium-drivers=[] -Dplatforms=[] -Dglx=disabled"
                                        + " -Degl=disabled -Dgbm=disabled -Dgles1=disabled"
                                        + " -Dgles2=disabled -Dopengl=false -Dllvm=disabled"
                                        + " -Dshared-glapi=disabled -Dvalgrind=disabled"
                                        + " -Dlibunwind=disabled -Dbuild-tests=false"
                                        + " -Dvideo-codecs=[]"
                                        + crossOption
                                        + " && meson compile -C \(guestBuild) vulkan_gfxstream"
                                        + " gfxstream_vk_icd gfxstream_vk_devenv_icd"
                                        + " && mkdir -p /export/lib"
                                        + " && install -m 0755"
                                        + " \(guestBuild)/src/gfxstream/guest/vulkan/libvulkan_gfxstream.so"
                                        + " /export/lib/libvulkan_gfxstream.so",
                                ]),
                        ])))
        return GfxstreamArtifacts(
            task: declaration,
            hostBackend: hostBackend,
            guestVulkanDriver: guestVulkanDriver)
    }

}

private struct DownloadAOSPRepoLauncherAction: ColliderAction {
    static let kind: ActionKind = "android-runtime.download-aosp-repo-launcher"

    let identity: DownloadActionIdentity

    init(specification: DownloadSpec, destination: FilePath) {
        identity = DownloadActionIdentity(
            specification: specification,
            destination: destination)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            effects: [
                ActionEffect(.readWrite, scope: .output(identity.destination))
            ],
            networkAccess: .contentAddressed,
            executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        try await context.downloads.download(
            identity.specification,
            to: identity.destination)
    }

    func validateOutputs(using files: ActionFileSystem) throws {
        try identity.validateOutput(using: files)
    }
}

private func gfxstreamExecution(
    root: FilePath,
    hostSource: FilePath,
    guestSource: FilePath,
    artifactRoot: FilePath,
    buildWorkspace: PersistentWorkspaceDeclaration,
    compilerCacheWorkspace: PersistentWorkspaceDeclaration,
    target: NativeLinuxTarget,
    imageID: FilePath,
    builder: NativeOCIConfiguration,
    environment: [String: String],
    command: [String]
) throws -> OCIExecution {
    OCIExecution(
        executionPlatform: .linuxARM64OCI,
        artifactTarget: target.artifactTarget,
        imageID: imageID,
        hostname: "native-gfxstream-\(target.architecture.rawValue)",
        workingDirectory: "/build",
        hostWorkingDirectory: root,
        mounts: [
            OCIMount(source: hostSource, target: "/gfxstream", access: .readOnly),
            OCIMount(source: guestSource, target: "/mesa", access: .readOnly),
            OCIMount(source: artifactRoot, target: "/export", access: .readWrite),
            OCIMount(
                source: root.appending("build-support"),
                target: "/build-support",
                access: .readOnly),
            OCIMount(
                source: builder.swiftSDKRoot,
                target: "/swift-sdk",
                access: .readOnly),
        ],
        persistentWorkspaceMounts: [
            OCIPersistentWorkspaceMount(
                workspace: buildWorkspace,
                target: "/build",
                access: .readWrite),
            OCIPersistentWorkspaceMount(
                workspace: compilerCacheWorkspace,
                target: "/ccache",
                access: .readWrite),
        ],
        userPolicy: .builder,
        capabilityPolicy: .dropAll,
        privilegePolicy: .prohibitAcquisition,
        processFilesystemPolicy: .standard,
        intelBinaryTranslationPolicy: target.intelBinaryTranslationPolicy,
        resourceLimits: .parallelBuild,
        containerEnvironment: [
            "CC": "clang",
            "CCACHE_DIR": "/ccache",
            "CXX": "clang++",
            "CXXFLAGS": "-stdlib=libc++",
            "LDFLAGS": "-stdlib=libc++ -fuse-ld=lld",
            "LD_LIBRARY_PATH": target.containerRuntimeLibraryPath,
            "PKG_CONFIG_LIBDIR":
                "/usr/lib/\(target.gnuArchitecture)/pkgconfig:/usr/share/pkgconfig",
        ],
        command: command,
        environment: environment,
        output: .logged)
}

private struct RunGfxstreamBuildAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let artifactRoot: FilePath
        let pipeline: OCIExecutionPipelineIdentity

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: artifactRoot.string)
            encoder.append(tag: 2, nested: pipeline)
        }
    }

    static let kind: ActionKind = "android-runtime.build-gfxstream"

    let artifactRoot: FilePath
    let pipeline: OCIExecutionPipeline

    init(artifactRoot: FilePath, executions: [OCIExecution]) throws {
        self.artifactRoot = artifactRoot
        pipeline = try OCIExecutionPipeline(executions)
    }

    var identity: Identity {
        Identity(artifactRoot: artifactRoot, pipeline: pipeline.identity)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            effects: pipeline.requirements.effects + [
                ActionEffect(.readWrite, scope: .output(artifactRoot))
            ],
            lane: pipeline.requirements.lane,
            executionPlatform: pipeline.requirements.executionPlatform,
            artifactTarget: pipeline.requirements.artifactTarget)
    }

    var environment: [String: String] { pipeline.environment }

    func execute(in context: ActionContext) async throws {
        try context.files.remove(artifactRoot)
        try context.files.createDirectory(artifactRoot)
        try await pipeline.execute(in: context)
    }
}

private struct AOSPSourceLock: Decodable {
    struct Upstream: Decodable {
        let release: String
        let revision: String
        let manifestCommit: String
        let superprojectCommit: String
    }

    struct Source: Decodable {
        let manifestURL: String
        let manifestRevision: String
        let manifestCommit: String
        let defaultManifestSHA256: String
        let superprojectURL: String
        let superprojectRevision: String
        let superprojectCommit: String
    }

    struct Repo: Decodable {
        let launcherURL: String
        let launcherVersion: String
        let launcherSHA256: String
        let repositoryURL: String
        let revision: String
        let tagObject: String
        let commit: String
    }

    let upstream: Upstream
    let source: Source
    let repo: Repo

    func validate() throws {
        guard upstream.revision == "refs/tags/android-17.0.0_r1" else {
            throw AndroidRuntimeRecipeFailure.invalidAOSPSourceLock(
                "platform revision must be refs/tags/android-17.0.0_r1")
        }
        guard upstream.release == "Android 17.0.0 Release 1" else {
            throw AndroidRuntimeRecipeFailure.invalidAOSPSourceLock(
                "platform release must be Android 17.0.0 Release 1")
        }
        guard
            source.manifestRevision
                == "refs/heads/nucleus-android-17.0.0_r1",
            source.superprojectRevision
                == "refs/heads/nucleus-android-17.0.0_r1"
        else {
            throw AndroidRuntimeRecipeFailure.invalidAOSPSourceLock(
                "Nucleus source revisions must select the Android 17 branch")
        }
        guard
            source.manifestURL
                == "ssh://git@github.com/nucleus-os/platform_manifest.git",
            source.superprojectURL
                == "ssh://git@github.com/nucleus-os/platform_superproject.git",
            repo.launcherURL
                == "https://storage.googleapis.com/git-repo-downloads/repo",
            repo.repositoryURL
                == "https://gerrit.googlesource.com/git-repo"
        else {
            throw AndroidRuntimeRecipeFailure.invalidAOSPSourceLock(
                "source URLs do not match the approved upstreams")
        }
        for (name, value, count) in [
            ("upstream manifest commit", upstream.manifestCommit, 40),
            ("upstream superproject commit", upstream.superprojectCommit, 40),
            ("manifest commit", source.manifestCommit, 40),
            ("manifest digest", source.defaultManifestSHA256, 64),
            ("superproject commit", source.superprojectCommit, 40),
            ("Repo launcher digest", repo.launcherSHA256, 64),
            ("Repo tag object", repo.tagObject, 40),
            ("Repo commit", repo.commit, 40),
        ] {
            guard value.utf8.count == count,
                value.utf8.allSatisfy({ byte in
                    (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                        || (UInt8(ascii: "a")...UInt8(ascii: "f"))
                            .contains(byte)
                })
            else {
                throw AndroidRuntimeRecipeFailure.invalidAOSPSourceLock(
                    "\(name) must be \(count) lowercase hexadecimal digits")
            }
        }
        guard repo.revision == "refs/tags/v\(repo.launcherVersion)" else {
            throw AndroidRuntimeRecipeFailure.invalidAOSPSourceLock(
                "Repo revision and launcher version disagree")
        }
    }

    func specification() throws -> AOSPSourceSpecification {
        try validate()
        guard
            let defaultManifestDigest = ArtifactDigest(
                sha256Hex: source.defaultManifestSHA256),
            let launcherDigest = ArtifactDigest(
                sha256Hex: repo.launcherSHA256)
        else {
            throw AndroidRuntimeRecipeFailure.invalidAOSPSourceLock(
                "source digests are invalid")
        }
        return AOSPSourceSpecification(
            platform: AOSPPlatformSource(
                release: upstream.release,
                revision: upstream.revision,
                manifestURL: source.manifestURL,
                manifestRevision: source.manifestRevision,
                manifestCommit: source.manifestCommit,
                defaultManifestDigest: defaultManifestDigest,
                superprojectURL: source.superprojectURL,
                superprojectRevision: source.superprojectRevision,
                superprojectCommit: source.superprojectCommit),
            repo: AOSPRepoSource(
                launcherVersion: repo.launcherVersion,
                launcherDigest: launcherDigest,
                repositoryURL: repo.repositoryURL,
                revision: repo.revision,
                tagObject: repo.tagObject,
                commit: repo.commit))
    }
}

private struct AOSPProductLock: Decodable {
    let product: String
    let release: String
    let variant: String
    let buildNumber: String
    let buildTimestamp: UInt64
    let platformSDK: UInt32
    let vendorAPILevel: UInt32
    let buildJobs: UInt32

    func validate() throws {
        guard product == "nucleus_x86_64",
            release == "cp2a",
            variant == "user",
            buildNumber == "nucleus-android17-r1",
            buildTimestamp == 1_781_652_681,
            platformSDK == 37,
            vendorAPILevel == 202604,
            buildJobs > 0
        else {
            throw AndroidRuntimeRecipeFailure.invalidAOSPProductLock(
                "product identity does not match the Android 17 "
                    + "Nucleus build contract")
        }
    }
}

private let aospSigningSubject =
    "/C=US/O=Nucleus/OU=Android Development"

public enum AndroidRuntimeRecipeFailure: Error, CustomStringConvertible {
    case invalidAOSPProductLock(String)
    case invalidAOSPSourceLock(String)

    public var description: String {
        switch self {
        case .invalidAOSPProductLock(let detail):
            "invalid AOSP product lock: \(detail)"
        case .invalidAOSPSourceLock(let detail):
            "invalid AOSP source lock: \(detail)"
        }
    }
}
