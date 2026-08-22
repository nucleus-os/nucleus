import ColliderCore
import Foundation
import NativeBuilderColliderRecipe
import SystemPackage

package enum AndroidRuntimeEntrypoints {
    package static let packageInput = ComponentEntrypointID(
        rawValue: "package.android-input")
}

package enum AndroidRuntimeTaskIDs {
    package static let aospSourceLock = TaskID(
        rawValue: "android-runtime.aosp-source-lock")
    package static let aospSource = TaskID(rawValue: "android-runtime.aosp-source")
    package static let aospSourceInputs = TaskID(
        rawValue: "android-runtime.aosp-source-inputs")
    package static let aospImage = TaskID(rawValue: "android-runtime.aosp-image")
    package static let apexManifestGenerate = TaskID(
        rawValue: "android-runtime.apex-manifest.generate")
    package static let apexManifestVerify = TaskID(
        rawValue: "android-runtime.apex-manifest.verify")
    package static func gfxstream(_ target: NativeLinuxTarget) -> TaskID {
        TaskID(rawValue: "android-runtime.gfxstream.\(target.identifier)")
    }
}

public enum AndroidRuntimeColliderRecipe: ColliderComponent {
    static let rollbackGenerationCount: UInt32 = 1

    package struct GfxstreamArtifacts: Sendable {
        package let task: TaskDeclaration
        package let hostBackend: ArtifactReference
        package let guestVulkanDriver: ArtifactReference
    }

    package struct Artifacts: Sendable {
        package let gfxstream: [NativeLinuxTarget: GfxstreamArtifacts]
        package let activeAOSPGeneration: ArtifactReference
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
        let verification: ArtifactReference
    }

    private struct RepoLauncherArtifacts {
        let task: TaskDeclaration
        let executable: ArtifactReference
    }

    private struct SourceInputArtifacts {
        let task: TaskDeclaration
        let sourceInputs: FilePath
        let resolvedManifest: ArtifactReference
        let provenance: ArtifactReference
    }

    private struct SourceArtifacts {
        let tasks: [TaskDeclaration]
        let provenance: ArtifactReference
        let workspace: PersistentWorkspaceDeclaration
        let sourceInputs: FilePath
    }

    private struct SourceTaskArtifacts {
        let task: TaskDeclaration
        let provenance: ArtifactReference
        let workspace: PersistentWorkspaceDeclaration
    }

    private struct SigningArtifacts {
        let task: TaskDeclaration
        let identity: ArtifactReference
        let directory: ArtifactReference
    }

    private struct CompileArtifacts {
        let task: TaskDeclaration
        let unsignedTargetFiles: ArtifactReference
    }

    private struct AOSPContainerArtifacts {
        let build: OCIMountedEntrypoint
        let artifact: OCIMountedEntrypoint
    }

    private struct GfxstreamContainerArtifacts {
        let tool: OCIMountedEntrypoint
    }

    private struct AssembleArtifacts {
        let task: TaskDeclaration
        let targetFiles: ArtifactReference
        let imageArchive: ArtifactReference
        let images: [ArtifactReference]
    }

    package struct AOSPImageArtifacts: Sendable {
        package let tasks: [TaskDeclaration]
        package let activeGeneration: ArtifactReference
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
        let protobuf = try apexManifestProtobufTasks(
            root: root,
            packageRoot: context.repositoryRoot,
            buildRoot: context.buildRoot,
            environment: context.environment,
            swiftPM: try context.swiftPM(.hostDebug))
        let aospBuildRoot = context.artifactRoot.appending("android-runtime/aosp")
        let aospContainers = aospContainerArtifacts(
            root: root,
            image: native.builder.image)
        let aosp = try aospImageTasks(
            root: root,
            sourceInputRoot: context.cacheRoot.appending(
                "android-runtime/aosp-source-inputs"),
            toolsRoot: context.cacheRoot.appending("android-runtime/aosp-tools"),
            identityRoot: context.identityRoot,
            artifactRoot: aospBuildRoot,
            buildTool: aospContainers.build,
            artifactTool: aospContainers.artifact,
            assemblerSwiftPM: try context.swiftPM(.linuxAssembler),
            placement: context.identityPathMap,
            environment: context.environment)
        let gfxstreamContainer = gfxstreamContainerArtifacts(
            root: root,
            image: native.builder.image)
        var tasks = aosp.tasks + [protobuf.generation, protobuf.verification]
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
                tool: gfxstreamContainer.tool,
                builder: native.builder)
            tasks.append(artifacts.task)
            gfxstreamRoots.insert(artifacts.task.id)
            gfxstreamArtifacts[target] = artifacts
        }
        var entrypoints = [
            ComponentEntrypoint(id: .bootstrap, roots: gfxstreamRoots),
            ComponentEntrypoint(
                id: .generate,
                roots: [protobuf.generation.id]),
            ComponentEntrypoint(
                id: ComponentEntrypointID.verifyGeneratedSources,
                roots: [protobuf.verification.id]),
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
        if let configuration = try context.configurationIfPresent(
            AndroidPackageInputConfiguration.self,
            for: descriptor.id)
        {
            let package = try packageInputTask(
                configuration: configuration,
                repositoryRoot: context.repositoryRoot,
                managedAOSPGeneration: aosp.activeGeneration)
            tasks.append(package)
            entrypoints.append(
                ComponentEntrypoint(
                    id: AndroidRuntimeEntrypoints.packageInput,
                    roots: [package.id]))
            platformStorage = [
                StorageDeclaration(
                    id: "android-package-input-scratch",
                    owner: descriptor.id,
                    producers: [.task(package.id)],
                    storageClass: .incremental,
                    root: configuration.runtimeScratch,
                    safetyRoot: configuration.runtimeScratch.removingLastComponent(),
                    retentionPolicy: .singleWorkingSet),
                StorageDeclaration(
                    id: "android-package-input-publication",
                    owner: descriptor.id,
                    producers: [.task(package.id)],
                    storageClass: .published,
                    root: configuration.output,
                    safetyRoot: configuration.output,
                    retentionPolicy: .protected),
            ]
        }
        let aospProductProducers = Set(
            [
                "android-runtime.aosp-compile",
                "android-runtime.aosp-sign",
                "android-runtime.aosp-assemble-images",
                "android-runtime.aosp-validate",
                AndroidRuntimeTaskIDs.aospImage.rawValue,
            ].map { StorageProducer.task(TaskID(rawValue: $0)) })
        var storage = [
            // What generation produces. The committed copy beside the sources
            // is authored state no task declares itself the producer of.
            StorageDeclaration(
                id: "android-apex-manifest-generated-source",
                owner: descriptor.id,
                producers: [.task(protobuf.generation.id)],
                storageClass: .published,
                root: protobuf.generatedSource.removingLastComponent(),
                safetyRoot: context.buildRoot,
                retentionPolicy: .singleWorkingSet),
            StorageDeclaration(
                id: "android-apex-manifest-generation-state",
                owner: descriptor.id,
                producers: [.task(protobuf.generation.id)],
                storageClass: .cache,
                root: protobuf.verificationRoot,
                safetyRoot: context.buildRoot,
                retentionPolicy: .singleWorkingSet),
            StorageDeclaration(
                id: "android-aosp-source-inputs",
                owner: descriptor.id,
                producers: [.task(AndroidRuntimeTaskIDs.aospSourceInputs)],
                storageClass: .cache,
                root: context.cacheRoot.appending(
                    "android-runtime/aosp-source-inputs"),
                safetyRoot: context.cacheRoot.appending("android-runtime"),
                retentionPolicy: .singleWorkingSet),
            StorageDeclaration(
                id: "android-aosp-signing-identity",
                owner: descriptor.id,
                producers: [
                    .task(TaskID(rawValue: "android-runtime.aosp-signing-identity"))
                ],
                storageClass: .identity,
                root: context.identityRoot.appending("android-runtime/aosp-signing"),
                safetyRoot: context.identityRoot.appending("android-runtime"),
                retentionPolicy: .protected),
            StorageDeclaration(
                id: "android-aosp-tools",
                owner: descriptor.id,
                producers: [
                    .task(AndroidRuntimeTaskIDs.aospSourceLock),
                    .task(TaskID(rawValue: "android-runtime.aosp-repo-launcher")),
                ],
                storageClass: .cache,
                root: context.cacheRoot.appending("android-runtime/aosp-tools"),
                safetyRoot: context.cacheRoot.appending("android-runtime"),
                retentionPolicy: .singleWorkingSet),
            StorageDeclaration(
                id: "android-aosp-artifact-root",
                owner: descriptor.id,
                producers: [.task(AndroidRuntimeTaskIDs.aospImage)],
                storageClass: .published,
                root: aospBuildRoot,
                safetyRoot: aospBuildRoot.removingLastComponent(),
                retentionPolicy: .protected),
            StorageDeclaration(
                id: "android-aosp-source-state",
                owner: descriptor.id,
                producers: [.task(AndroidRuntimeTaskIDs.aospSource)],
                storageClass: .incremental,
                root: aospBuildRoot.appending("source-state"),
                safetyRoot: aospBuildRoot,
                retentionPolicy: .singleWorkingSet),
            StorageDeclaration(
                id: "android-aosp-build",
                owner: descriptor.id,
                producers: aospProductProducers,
                storageClass: .generation,
                root: aospBuildRoot.appending("generations"),
                safetyRoot: aospBuildRoot,
                retentionPolicy: .keepActiveAndRollback(count: rollbackGenerationCount),
                activeGenerationLink: aospBuildRoot.appending("current"),
                generationNaming: .aospProduct,
                interruptedCandidateNaming: nil),
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
                    retentionPolicy: .singleWorkingSet))
        }
        storage += platformStorage
        let component = try ComponentDefinition(
            descriptor: descriptor,
            tasks: tasks,
            entrypoints: entrypoints,
            storage: storage,
            generatedSources: protobuf.mappings)
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
                relativeDestination: "common/native/ipc-transport"),
            AOSPProductSourceOverlay(
                source: root.appending(
                    "aosp/packages/apps/NucleusRuntimeBridge"),
                relativeDestination:
                    "common/packages/apps/NucleusRuntimeBridge"),
        ]
    }

    public static func verifyAOSPSourceLock(
        root: FilePath,
        toolsRoot: FilePath,
        environment: [String: String]
    ) throws -> TaskDeclaration {
        let launcher = try aospRepoLauncher(
            root: root,
            toolsRoot: toolsRoot,
            environment: environment)
        return try aospSourceLockArtifacts(
            root: root,
            toolsRoot: toolsRoot,
            environment: environment,
            launcher: launcher.executable
        ).task
    }

    private static func aospSourceLockArtifacts(
        root: FilePath,
        toolsRoot: FilePath,
        environment: [String: String],
        launcher: ArtifactReference
    ) throws -> SourceLockArtifacts {
        let lockPath = root.appending("aosp.lock.json")
        let report = toolsRoot.appending("source-lock-verification.json")
        let lock = try loadAOSPSourceLock(root: root)
        let specification = try lock.specification()
        var builder = TaskBuilder(
            id: AndroidRuntimeTaskIDs.aospSourceLock,
            component: component)
        builder.consume(launcher)
        let verification: ArtifactReference = try builder.output(
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

    private static func aospContainerArtifacts(
        root: FilePath,
        image: ArtifactReference
    ) -> AOSPContainerArtifacts {
        let sourceRoot = root.appending("build-container")
        return AOSPContainerArtifacts(
            build: OCIMountedEntrypoint(
                image: image,
                executable: sourceRoot.appending("build-entrypoint.sh"),
                containerDirectory: "/collider-entrypoints/aosp-build"),
            artifact: OCIMountedEntrypoint(
                image: image,
                executable: sourceRoot.appending("artifact-entrypoint.sh"),
                containerDirectory: "/collider-entrypoints/aosp-artifact"))
    }

    private static func gfxstreamContainerArtifacts(
        root: FilePath,
        image: ArtifactReference
    ) -> GfxstreamContainerArtifacts {
        return GfxstreamContainerArtifacts(
            tool: OCIMountedEntrypoint(
                image: image,
                executable: root.appending(
                    "gfxstream-build-container/entrypoint.sh"),
                containerDirectory: "/collider-entrypoints/gfxstream"))
    }

    private static func aospSourceArtifacts(
        root: FilePath,
        toolsRoot: FilePath,
        sourceInputRoot: FilePath,
        sourceStateRoot: FilePath,
        buildTool: OCIMountedEntrypoint,
        apiLevel: UInt32,
        environment: [String: String]
    ) throws -> SourceArtifacts {
        let launcher = try aospRepoLauncher(
            root: root,
            toolsRoot: toolsRoot,
            environment: environment)
        let verification = try aospSourceLockArtifacts(
            root: root,
            toolsRoot: toolsRoot,
            environment: environment,
            launcher: launcher.executable)
        let inputs = try aospSourceInputs(
            root: root,
            sourceInputRoot: sourceInputRoot,
            environment: environment,
            launcher: launcher.executable,
            verification: verification.verification)
        let source = try aospSource(
            root: root,
            sourceStateRoot: sourceStateRoot,
            sourceWorkspace: aospSourceWorkspace(apiLevel: apiLevel),
            sourceInputs: inputs,
            buildTool: buildTool,
            environment: environment,
            launcher: launcher.executable)
        return SourceArtifacts(
            tasks: [launcher.task, verification.task, inputs.task, source.task],
            provenance: source.provenance,
            workspace: source.workspace,
            sourceInputs: inputs.sourceInputs)
    }

    package static func aospImageTasks(
        root: FilePath,
        sourceInputRoot: FilePath,
        toolsRoot: FilePath,
        identityRoot: FilePath,
        artifactRoot: FilePath,
        buildTool: OCIMountedEntrypoint,
        artifactTool: OCIMountedEntrypoint,
        assemblerSwiftPM: SwiftPMInvocation,
        placement: IdentityPathMap,
        environment: [String: String]
    ) throws -> AOSPImageArtifacts {
        let productLock = try JSONDecoder().decode(
            AOSPProductLock.self,
            from: Data(
                contentsOf: URL(
                    fileURLWithPath: root.appending("aosp-product.lock.json").string)))
        try productLock.validate()
        let source = try aospSourceArtifacts(
            root: root,
            toolsRoot: toolsRoot,
            sourceInputRoot: sourceInputRoot,
            sourceStateRoot: artifactRoot.appending("source-state"),
            buildTool: buildTool,
            apiLevel: productLock.platformSDK,
            environment: environment)
        let signing = try aospSigningIdentity(
            identityRoot: identityRoot,
            assemblerSwiftPM: assemblerSwiftPM,
            placement: placement,
            environment: environment)
        let product = try aospProductImageTasks(
            root: root,
            identityRoot: identityRoot,
            sourceWorkspace: source.workspace,
            sourceInputs: source.sourceInputs,
            aospBuildRoot: artifactRoot,
            environment: environment,
            sourceProvenance: source.provenance,
            signing: signing,
            buildTool: buildTool,
            artifactTool: artifactTool)
        return AOSPImageArtifacts(
            tasks: source.tasks + [signing.task] + product.tasks,
            activeGeneration: product.activeGeneration)
    }

    private static func aospRepoLauncher(
        root: FilePath,
        toolsRoot: FilePath,
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
        let launcher = try aospRepoLauncherPath(root: root, toolsRoot: toolsRoot)
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
        let executable: ArtifactReference = try builder.output(
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

    private static func aospSourceInputs(
        root: FilePath,
        sourceInputRoot: FilePath,
        environment: [String: String],
        launcher: ArtifactReference,
        verification: ArtifactReference
    ) throws -> SourceInputArtifacts {
        let lock = try loadAOSPSourceLock(root: root)
        let specification = try lock.specification()
        let lockPath = root.appending("aosp.lock.json")
        let sourceInputs = sourceInputRoot.appending("repository")
        let hydrationScript = root.appending(
            "build-support/hydrate-aosp-source-inputs.sh")
        let state = sourceInputRoot.appending(
            "locks/\(specification.platform.manifestCommit)")
        var builder = TaskBuilder(
            id: AndroidRuntimeTaskIDs.aospSourceInputs,
            component: component)
        builder.consume(verification)
        builder.consume(launcher)
        let resolvedManifest: ArtifactReference = try builder.output(
            "resolved-manifest",
            path: state.appending("resolved-manifest.xml"),
            validation: .regularFile)
        let provenance: ArtifactReference = try builder.output(
            "provenance",
            path: state.appending("source-provenance.json"),
            validation: .json)
        let task = builder.build(
            inputs: [
                .file(lockPath),
                .file(hydrationScript),
                .tool(.named("bash")),
                .tool(.named("git")),
                .tool(.named("python3")),
            ],
            locks: [.checkout("android-runtime-aosp-source-inputs")],
            action:
                try AnyColliderAction(
                    PrepareAOSPSourceInputsAction(
                        preparation: AOSPSourceInputPreparation(
                            specification: specification,
                            launcher: launcher.path,
                            sourceInputs: sourceInputs,
                            hydrationScript: hydrationScript,
                            resolvedManifest: resolvedManifest.path,
                            provenance: provenance.path,
                            syncJobs: 4,
                            retryFetches: 3,
                            environment: environment)))
        )
        return SourceInputArtifacts(
            task: task,
            sourceInputs: sourceInputs,
            resolvedManifest: resolvedManifest,
            provenance: provenance)
    }

    private static func aospSource(
        root: FilePath,
        sourceStateRoot: FilePath,
        sourceWorkspace: PersistentWorkspaceDeclaration,
        sourceInputs: SourceInputArtifacts,
        buildTool: OCIMountedEntrypoint,
        environment: [String: String],
        launcher: ArtifactReference
    ) throws -> SourceTaskArtifacts {
        let specification = try loadAOSPSourceLock(root: root).specification()
        let state = sourceStateRoot.appending(specification.platform.manifestCommit)
        var builder = TaskBuilder(
            id: AndroidRuntimeTaskIDs.aospSource,
            component: component)
        builder.consume(sourceInputs.resolvedManifest)
        builder.consume(sourceInputs.provenance)
        builder.consume(launcher)
        builder.consume(buildTool.image)
        let _: ArtifactReference = try builder.output(
            "resolved-manifest",
            path: state.appending("resolved-manifest.xml"),
            validation: .regularFile)
        let provenance: ArtifactReference = try builder.output(
            "provenance",
            path: state.appending("source-provenance.json"),
            validation: .json)
        let task = builder.build(
            inputs: [
                .file(root.appending("aosp.lock.json")),
                .file(root.appending("build-container/materialize-source.sh")),
                buildTool.input,
            ],
            locks: [.checkout("android-runtime-aosp-source")],
            assessmentPolicy: .incremental,
            action: try AnyColliderAction(
                MaterializeAOSPSourceAction(
                    materialization: AOSPSourceMaterialization(
                        specification: specification,
                        launcher: launcher.path,
                        sourceInputs: sourceInputs.sourceInputs,
                        resolvedManifest: sourceInputs.resolvedManifest.path,
                        provenance: sourceInputs.provenance.path,
                        exportedResolvedManifest: state.appending(
                            "resolved-manifest.xml"),
                        exportedProvenance: provenance.path,
                        script: root.appending("build-container/materialize-source.sh"),
                        entrypoint: buildTool,
                        sourceWorkspace: sourceWorkspace,
                        syncJobs: 24,
                        environment: environment))))
        return SourceTaskArtifacts(
            task: task,
            provenance: provenance,
            workspace: sourceWorkspace)
    }

    private static func aospSigningIdentity(
        identityRoot: FilePath,
        assemblerSwiftPM: SwiftPMInvocation,
        placement: IdentityPathMap,
        environment: [String: String]
    ) throws -> SigningArtifacts {
        // Each account generates and owns its own local-development identity in
        // its declared storage. Nothing signs with another account's private
        // keys, and no account needs read access to another's.
        let signingIdentity = identityRoot.appending(
            "android-runtime/aosp-signing/local-development")
        var builder = TaskBuilder(
            id: TaskID(rawValue: "android-runtime.aosp-signing-identity"),
            component: component)
        let identity: ArtifactReference = try builder.output(
            "identity",
            path: signingIdentity.appending("signing-identity.json"),
            validation: .json)
        let directory: ArtifactReference = try builder.output(
            "directory",
            path: signingIdentity,
            validation: .nonEmptyDirectory)
        let tool = "nucleus-android-assembler"
        let task = builder.build(
            swiftProducts: [
                assemblerSwiftPM.product(
                    package: "collider-cli",
                    product: tool,
                    packageRoot: assemblerSwiftPM.context.packageRoot,
                    environment: environment,
                    expectedOutputs: [
                        PathPostcondition(
                            path: assemblerSwiftPM.executable(tool),
                            validation: .executableFile)
                    ])
            ],
            inputs: [
                .string(
                    name: "subject",
                    value: aospSigningSubject),
                assemblerSwiftPM.identityInput,
            ],
            locks: [.checkout("android-runtime-aosp-signing")],
            action:
                try AnyColliderAction(
                    PublishAOSPSigningIdentityAction(
                        preparation: AOSPSigningIdentityPreparation(
                            destination: signingIdentity,
                            subject: aospSigningSubject,
                            environment: environment),
                        assemblerSwiftPM: assemblerSwiftPM,
                        placement: placement)))
        return SigningArtifacts(
            task: task,
            identity: identity,
            directory: directory)
    }

    private struct PublishedAOSPArtifacts {
        let tasks: [TaskDeclaration]
        let activeGeneration: ArtifactReference
    }

    private static func aospProductImageTasks(
        root: FilePath,
        identityRoot: FilePath,
        sourceWorkspace: PersistentWorkspaceDeclaration,
        sourceInputs: FilePath,
        aospBuildRoot: FilePath,
        environment: [String: String],
        sourceProvenance: ArtifactReference,
        signing: SigningArtifacts,
        buildTool: OCIMountedEntrypoint,
        artifactTool: OCIMountedEntrypoint
    ) throws -> PublishedAOSPArtifacts {
        let lockPath = root.appending("aosp-product.lock.json")
        let lock = try JSONDecoder().decode(
            AOSPProductLock.self,
            from: Data(contentsOf: URL(fileURLWithPath: lockPath.string)))
        try lock.validate()
        let signingIdentity = identityRoot.appending(
            "android-runtime/aosp-signing/local-development")
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
            deviceSource: root.appending("aosp/device/nucleus"),
            sourceInputs: sourceInputs,
            sourceProvenance: sourceProvenance.path,
            artifactRoot: buildRoot,
            sourceWorkspace: sourceWorkspace,
            outputWorkspace: aospOutputWorkspace(apiLevel: lock.platformSDK),
            compilerCacheWorkspace: aospCompilerCacheWorkspace(
                apiLevel: lock.platformSDK),
            buildEntrypoint: buildTool,
            artifactEntrypoint: artifactTool,
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
        compileBuilder.consume(buildTool.image)
        let unsignedReference: ArtifactReference = try compileBuilder.output(
            "unsigned-target-files",
            path: unsigned,
            validation: .regularFile)
        let _: ArtifactReference = try compileBuilder.output(
            "unsigned-target-files-digest",
            path: unsignedDigest,
            validation: .regularFile)
        let compileTask = compileBuilder.build(
            inputs: [
                .value(
                    name: "aosp-product-identity",
                    bytes: productIdentity),
                .sourceCheckout(root.appending("aosp/device/nucleus")),
                .sourceCheckout(
                    root.removingLastComponent().appending(
                        "ipc/transport/Sources/NucleusIPCTransportC")),
                .sourceCheckout(
                    root.appending(
                        "aosp/packages/apps/NucleusRuntimeBridge")),
                .tool(.named("python3")),
                buildTool.input,
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
            unsignedTargetFiles: unsignedReference)
        var signBuilder = TaskBuilder(
            id: TaskID(rawValue: "android-runtime.aosp-sign"),
            component: component)
        signBuilder.consume(signing.identity)
        signBuilder.consume(signing.directory)
        signBuilder.consume(compile.unsignedTargetFiles)
        signBuilder.consume(artifactTool.image)
        let stagedTargetFilesReference: ArtifactReference =
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
                artifactTool.input,
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
        assembleBuilder.consume(artifactTool.image)
        let stagedArchiveReference: ArtifactReference =
            try assembleBuilder.output(
                "image-archive",
                path: stagedImageArchive,
                validation: .regularFile)
        let stagedImageReferences: [ArtifactReference] =
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
                artifactTool.input,
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
        validateBuilder.consume(artifactTool.image)
        for image in assemble.images {
            validateBuilder.consume(image)
        }
        let stagedProvenanceReference: ArtifactReference =
            try validateBuilder.output(
                "image-provenance",
                path: stagedProvenance,
                validation: .json)
        let validate = validateBuilder.build(
            inputs: [
                .value(
                    name: "aosp-product-identity",
                    bytes: productIdentity),
                .sourceCheckout(root.appending("aosp/device/nucleus")),
                .sourceCheckout(
                    root.removingLastComponent().appending(
                        "ipc/transport/Sources/NucleusIPCTransportC")),
                .tool(.named("openssl")),
                .tool(.named("unzip")),
                artifactTool.input,
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
        let _: ArtifactReference = try publishBuilder.output(
            "image-provenance",
            path: signed.appending("image-provenance.json"),
            validation: .json)
        let _: ArtifactReference = try publishBuilder.output(
            "target-files",
            path: signed.appending("\(lock.product)-target_files.zip"),
            validation: .regularFile)
        let _: ArtifactReference = try publishBuilder.output(
            "image-archive",
            path: signed.appending("\(lock.product)-images.zip"),
            validation: .regularFile)
        let activeGeneration: ArtifactReference = try publishBuilder.output(
            "active-generation",
            path: active,
            validation: .symlinkTarget)
        for image in requiredImages {
            let _: ArtifactReference = try publishBuilder.output(
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

    private static func aospRepoLauncherPath(
        root: FilePath,
        toolsRoot: FilePath
    ) throws -> FilePath {
        let lock = try loadAOSPSourceLock(root: root)
        try lock.validate()
        return toolsRoot.appending("repo-\(lock.repo.launcherVersion)")
    }

    package static func buildGfxstream(
        root: FilePath,
        repositoryRoot: FilePath,
        sdkRoot: FilePath,
        environment: [String: String],
        target: NativeLinuxTarget,
        tool: OCIMountedEntrypoint,
        builder: NativeOCIConfiguration
    ) throws -> GfxstreamArtifacts {
        let artifactRoot = sdkRoot.appending("android/gfxstream")
        let hostSource = repositoryRoot.appending("third-party/gfxstream")
        let guestSource = repositoryRoot.appending("third-party/mesa")
        let crossFile = root.appending("build-support/linux-x86_64.ini")
        let crossOption =
            target.architecture == .x86_64
            ? " --cross-file=/build-support/linux-x86_64.ini" : ""
        let targetCXXOptions =
            " -Dcpp_args=\"['-stdlib=libc++','-nostdinc++','-isystem"
            + target.containerLibCXXIncludeRoot
            + "']\" -Dc_link_args=\"['-fuse-ld=lld','-L"
            + target.containerLibCXXLibraryRoot
            + "']\" -Dcpp_link_args=\"['-stdlib=libc++','-fuse-ld=lld','-L"
            + target.containerLibCXXLibraryRoot
            + "']\""
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
            journal: .writeback64MiB,
            retentionPolicy: .toolManagedLimit(maximumBytes: 50 * 1_024 * 1_024 * 1_024))
        var task = TaskBuilder(
            id: AndroidRuntimeTaskIDs.gfxstream(target),
            component: component)
        task.consume(tool.image)
        task.consume(builder.swiftSDK)
        let hostBackend: ArtifactReference = try task.output(
            "host-backend",
            path: artifactRoot.appending("lib/libgfxstream_backend.a"),
            validation: .regularFile)
        let guestVulkanDriver: ArtifactReference = try task.output(
            "guest-vulkan-driver",
            path: artifactRoot.appending("lib/libvulkan_gfxstream.so"),
            validation: .regularFile)
        let declaration = task.build(
            inputs: [
                .sourceCheckout(hostSource),
                .sourceCheckout(guestSource),
                tool.input,
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
                                tool: tool,
                                builder: builder,
                                environment: environment,
                                command: [
                                    "bash", "-lc",
                                    "meson_mode=; test ! -f"
                                        + " \(hostBuild)/meson-private/coredata.dat"
                                        + " || meson_mode=--reconfigure;"
                                        + " meson setup $meson_mode \(hostBuild) /gfxstream"
                                        + " -Dbuildtype=release -Ddefault_library=static"
                                        + " -Ddecoders=gles,vulkan,composer -Dgfxstream-build=host"
                                        + crossOption
                                        + targetCXXOptions
                                        + " || { status=$?; cat"
                                        + " \(hostBuild)/meson-logs/meson-log.txt; exit $status; };"
                                        + " meson compile -C \(hostBuild) gfxstream_backend"
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
                                tool: tool,
                                builder: builder,
                                environment: environment,
                                command: [
                                    "bash", "-lc",
                                    "meson_mode=; test ! -f"
                                        + " \(guestBuild)/meson-private/coredata.dat"
                                        + " || meson_mode=--reconfigure;"
                                        + " meson setup $meson_mode \(guestBuild) /mesa"
                                        + " -Dbuildtype=release -Dvulkan-drivers=gfxstream"
                                        + " -Dgallium-drivers=[] -Dplatforms=[] -Dglx=disabled"
                                        + " -Degl=disabled -Dgbm=disabled -Dgles1=disabled"
                                        + " -Dgles2=disabled -Dopengl=false -Dllvm=disabled"
                                        + " -Dshared-glapi=disabled -Dvalgrind=disabled"
                                        + " -Dlibunwind=disabled -Dbuild-tests=false"
                                        + " -Dvideo-codecs=[]"
                                        + crossOption
                                        + targetCXXOptions
                                        + " || { status=$?; cat"
                                        + " \(guestBuild)/meson-logs/meson-log.txt; exit $status; };"
                                        + " meson compile -C \(guestBuild) vulkan_gfxstream"
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
    tool: OCIMountedEntrypoint,
    builder: NativeOCIConfiguration,
    environment: [String: String],
    command: [String]
) throws -> OCIExecution {
    OCIExecution(
        executionPlatform: .linuxARM64OCI,
        artifactTarget: target.artifactTarget,
        imageID: tool.image.path,
        hostname: "native-gfxstream-\(target.architecture.rawValue)",
        workingDirectory: "/build",
        hostWorkingDirectory: root,
        mounts: [
            tool.mount,
            OCIMount(source: hostSource, target: "/gfxstream", access: .readOnly),
            OCIMount(source: guestSource, target: "/mesa", access: .readOnly),
            OCIMount(boundedExport: artifactRoot, target: "/export"),
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
        resourceLimits: .parallelBuild,
        containerEnvironment: [
            "CC": "/usr/bin/clang",
            "CCACHE_DIR": "/ccache",
            "CXX": "/usr/bin/clang++",
            "CXXFLAGS":
                "-stdlib=libc++ -nostdinc++ -isystem\(target.containerLibCXXIncludeRoot)",
            "LDFLAGS": "-stdlib=libc++ -fuse-ld=lld -L\(target.containerLibCXXLibraryRoot)",
            "LD_LIBRARY_PATH":
                "/opt/swift/usr/lib/swift/linux:/opt/swift-compat/arm64",
            "PKG_CONFIG_LIBDIR":
                "/usr/lib/\(target.gnuArchitecture)/pkgconfig:/usr/share/pkgconfig",
        ],
        imageEntrypointOverride: tool.containerPath,
        command: command,
        environment: environment,
        output: .logged)
}

private struct RunGfxstreamBuildAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let artifactRoot: FilePath
        let pipeline: OCIExecutionPipelineIdentity

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: artifactRoot)
            encoder.append(nested: pipeline)
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
        pipeline.requirements
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
        // Read-only acquisition over HTTPS. Every Nucleus project is public,
        // and the identity that acquires them holds no credentials, so an
        // authenticated transport would require provisioning one for nothing.
        guard
            source.manifestURL
                == "https://github.com/nucleus-os/platform_manifest.git",
            source.superprojectURL
                == "https://github.com/nucleus-os/platform_superproject.git",
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
