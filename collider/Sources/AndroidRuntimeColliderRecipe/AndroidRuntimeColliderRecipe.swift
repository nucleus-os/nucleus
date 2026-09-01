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
    /// One pipeline per locked product, named for the architecture it targets.
    package static func aospImage(_ architecture: PlatformArchitecture) -> TaskID {
        TaskID(rawValue: "android-runtime.aosp-image.\(architecture.rawValue)")
    }

    package static func aospCompile(_ architecture: PlatformArchitecture) -> TaskID {
        TaskID(rawValue: "android-runtime.aosp-compile.\(architecture.rawValue)")
    }

    package static func aospSign(_ architecture: PlatformArchitecture) -> TaskID {
        TaskID(rawValue: "android-runtime.aosp-sign.\(architecture.rawValue)")
    }

    package static func aospAssembleImages(
        _ architecture: PlatformArchitecture
    ) -> TaskID {
        TaskID(
            rawValue: "android-runtime.aosp-assemble-images.\(architecture.rawValue)")
    }

    package static func aospValidate(_ architecture: PlatformArchitecture) -> TaskID {
        TaskID(rawValue: "android-runtime.aosp-validate.\(architecture.rawValue)")
    }

    /// One native-package input per locked product. Each is produced from its
    /// own architecture's generation, so no cohort packages another
    /// architecture's images.
    package static func packageInput(
        _ architecture: PlatformArchitecture
    ) -> TaskID {
        TaskID(rawValue: "android-runtime.package-input.\(architecture.rawValue)")
    }
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
        /// One native-package input per locked product, named by the cohort
        /// that consumes it rather than reached by path.
        package let packageInputs: [PlatformArchitecture: ArtifactReference]
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
        /// One active generation per locked product.
        package let activeGenerations: [PlatformArchitecture: ArtifactReference]
        /// The AVB identity every product signs with, consumed downstream as
        /// an artifact rather than reached by path.
        package let signingDirectory: ArtifactReference

        package var architectures: [PlatformArchitecture] {
            activeGenerations.keys.sorted { $0.rawValue < $1.rawValue }
        }
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
                roots: Set(
                    aosp.architectures.map { AndroidRuntimeTaskIDs.aospImage($0) })),
        ]
        var platformStorage: [StorageDeclaration] = []
        var packageInputRoots: Set<TaskID> = []
        var packageInputs: [PlatformArchitecture: ArtifactReference] = [:]
        for architecture in aosp.architectures {
            guard let generation = aosp.activeGenerations[architecture] else {
                throw AndroidRuntimeRecipeFailure.invalidAOSPProductLock(
                    "no product is locked for " + architecture.rawValue)
            }
            let linuxTarget = NativeLinuxTarget(architecture: architecture)
            let runtimeScratch = context.buildRoot.appending(
                "android-package-input/\(architecture.rawValue)")
            let output = context.artifactRoot.appending(
                "android-runtime/package-input/\(architecture.rawValue)")
            let packageInput = try packageInputTask(
                AndroidPackageInput(
                    architecture: architecture,
                    runtimeSwiftPM: try context.swiftPM(
                        .linux(architecture, configuration: .release)),
                    assemblerSwiftPM: try context.swiftPM(.linuxAssembler),
                    runtimeScratch: runtimeScratch,
                    targetLibraryRoots: NucleusLinuxABI.targetLibraryRoots(
                        triple: linuxTarget.targetTriple,
                        gnuArchitecture: linuxTarget.gnuArchitecture)
                        + [
                            // Wayland ships with the payload rather than with
                            // the Swift SDK, and the display host links it.
                            FilePath(
                                context.executionPath(
                                    native.nativeSDK(for: linuxTarget)
                                        .appending("wayland/lib")))
                        ],
                    aospGeneration: generation,
                    signingIdentity: aosp.signingDirectory,
                    output: output.appending("current"),
                    appArmorPolicy: root.appending(
                        "container/lxc-nucleus-android.apparmor"),
                    seccompPolicy: root.appending(
                        "container/nucleus-android.seccomp"),
                    placement: context.identityPathMap,
                    environment: context.environment),
                repositoryRoot: context.repositoryRoot)
            let package = packageInput.task
            packageInputs[architecture] = packageInput.artifact
            tasks.append(package)
            packageInputRoots.insert(package.id)
            platformStorage += [
                StorageDeclaration(
                    id: "android-package-input-scratch-\(architecture.rawValue)",
                    owner: descriptor.id,
                    producers: [.task(package.id)],
                    storageClass: .incremental,
                    root: runtimeScratch,
                    safetyRoot: runtimeScratch.removingLastComponent(),
                    retentionPolicy: .singleWorkingSet),
                StorageDeclaration(
                    id: "android-package-input-publication-\(architecture.rawValue)",
                    owner: descriptor.id,
                    producers: [.task(package.id)],
                    storageClass: .published,
                    root: output,
                    safetyRoot: output.removingLastComponent(),
                    retentionPolicy: .protected),
            ]
        }
        entrypoints.append(
            ComponentEntrypoint(
                id: AndroidRuntimeEntrypoints.packageInput,
                roots: packageInputRoots))
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
            // The object store and the state describing it are separate
            // declarations because they answer differently. One is seventy-three
            // gigabytes of Repo objects that host networking can rebuild
            // exactly; the other is two small files naming the revisions it was
            // built against. A single declaration over both could only carry
            // one residency, and rooting it at the parent made "a declared
            // output exists under this root" true of the object store on the
            // strength of a manifest file beside it.
            StorageDeclaration(
                id: "android-aosp-source-inputs",
                owner: descriptor.id,
                producers: [.task(AndroidRuntimeTaskIDs.aospSourceInputs)],
                // Source rather than cache. It is a partial-clone Repo tree,
                // and calling it a cache described how it is used rather than
                // what it holds -- which is why seventy-three gigabytes of it
                // sat outside every decision about materialized source.
                storageClass: .source,
                root: context.cacheRoot.appending(
                    "android-runtime/aosp-source-inputs/repository"),
                safetyRoot: context.cacheRoot.appending("android-runtime"),
                retentionPolicy: .singleWorkingSet,
                // Reconstructible, but not spare. The guest volume holds
                // working trees and per-project git directories and reaches
                // this store through a symlink rather than copying it, so
                // these objects stay load-bearing for as long as that volume
                // exists -- they are not a staging area that materialization
                // finishes with. What makes them on demand is that the locked
                // manifest names every one of them, so host networking
                // rebuilds the store exactly: collecting it costs a hydration
                // rather than a result.
                residency: .onDemand(
                    reconstructedBy: AndroidRuntimeTaskIDs.aospSourceInputs)),
            StorageDeclaration(
                id: "android-aosp-source-input-state",
                owner: descriptor.id,
                producers: [.task(AndroidRuntimeTaskIDs.aospSourceInputs)],
                storageClass: .incremental,
                root: context.cacheRoot.appending(
                    "android-runtime/aosp-source-inputs/locks"),
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
                producers: Set(
                    aosp.architectures.map {
                        StorageProducer.task(AndroidRuntimeTaskIDs.aospImage($0))
                    }),
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
        ]
        // Generations separate per product: each has its own active link, and
        // publishing one must not retire another architecture's.
        for architecture in aosp.architectures {
            let productRoot = aospBuildRoot.appending(architecture.rawValue)
            storage.append(
                StorageDeclaration(
                    id: "android-aosp-build-\(architecture.rawValue)",
                    owner: descriptor.id,
                    producers: Set(
                        [
                            AndroidRuntimeTaskIDs.aospCompile(architecture),
                            AndroidRuntimeTaskIDs.aospSign(architecture),
                            AndroidRuntimeTaskIDs.aospAssembleImages(architecture),
                            AndroidRuntimeTaskIDs.aospValidate(architecture),
                            AndroidRuntimeTaskIDs.aospImage(architecture),
                        ].map { StorageProducer.task($0) }),
                    storageClass: .generation,
                    root: productRoot.appending("generations"),
                    safetyRoot: productRoot,
                    retentionPolicy: .keepActiveAndRollback(
                        count: rollbackGenerationCount),
                    activeGenerationLink: productRoot.appending("current"),
                    generationNaming: .aospProduct,
                    interruptedCandidateNaming: nil))
        }
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
                packageInputs: packageInputs))
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
            activeGenerations: product.activeGenerations,
            signingDirectory: signing.directory)
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
        // The object store itself, and not only the two files describing it.
        //
        // It was declared as scratch, so nothing validated it: deleting
        // seventy-three gigabytes of Repo objects left this task clean, and the
        // materialization that mounts them read-only would have run against an
        // empty directory. A root nothing can observe as missing is a root
        // nothing can promise to rebuild, which is exactly what its on-demand
        // residency promises.
        //
        // Non-empty is the whole check. What the objects are is already
        // established by the locked revisions the hydration resolves against,
        // and digesting a tree this size to learn that it exists would cost
        // more than the hydration it guards.
        let _: ArtifactReference = try builder.output(
            "source-inputs",
            path: sourceInputs,
            validation: .nonEmptyDirectory)
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
        let activeGenerations: [PlatformArchitecture: ArtifactReference]
    }

    private struct ProductPipeline {
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
        var tasks: [TaskDeclaration] = []
        var activeGenerations: [PlatformArchitecture: ArtifactReference] = [:]
        for entry in lock.products {
            let published = try aospProductPipeline(
                entry: entry,
                root: root,
                identityRoot: identityRoot,
                sourceWorkspace: sourceWorkspace,
                sourceInputs: sourceInputs,
                aospBuildRoot: aospBuildRoot,
                environment: environment,
                sourceProvenance: sourceProvenance,
                signing: signing,
                buildTool: buildTool,
                artifactTool: artifactTool)
            tasks += published.tasks
            activeGenerations[entry.architecture] = published.activeGeneration
        }
        return PublishedAOSPArtifacts(
            tasks: tasks,
            activeGenerations: activeGenerations)
    }

    /// One product's pipeline, from compilation through publication.
    private static func aospProductPipeline(
        entry: AOSPProductEntry,
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
    ) throws -> ProductPipeline {
        let signingIdentity = identityRoot.appending(
            "android-runtime/aosp-signing/local-development")
        let productIdentity = Array(
            [
                entry.product,
                entry.release,
                entry.variant,
                entry.buildNumber,
                String(entry.buildTimestamp),
                String(entry.platformSDK),
                String(entry.vendorAPILevel),
            ].joined(separator: "\0").utf8)
        let generationID = [
            String(entry.buildTimestamp),
            entry.buildNumber,
            entry.release,
            entry.product,
            entry.variant,
            String(entry.platformSDK),
            String(entry.vendorAPILevel),
        ].joined(separator: "-")
        let productRoot = aospBuildRoot.appending(entry.architecture.rawValue)
        let buildRoot =
            productRoot
            .appending("generations")
            .appending(generationID)
        let active = productRoot.appending("current")
        let signed = buildRoot.appending("signed")
        let images = buildRoot.appending("images")
        let unsigned = buildRoot.appending(
            "unsigned/\(entry.product)-target_files.zip")
        let unsignedDigest = buildRoot.appending(
            "unsigned/\(entry.product)-target_files.zip.sha256")
        let staged = buildRoot.appending("staged")
        let stagedTargetFiles = staged.appending(
            "\(entry.product)-target_files.zip")
        let stagedImageArchive = staged.appending(
            "\(entry.product)-images.zip")
        let stagedImages = staged.appending("images")
        let stagedProvenance = staged.appending(
            "image-provenance.json")
        let build = AOSPProductBuild(
            architecture: entry.architecture,
            deviceSource: root.appending("aosp/device/nucleus"),
            sourceInputs: sourceInputs,
            sourceProvenance: sourceProvenance.path,
            artifactRoot: buildRoot,
            sourceWorkspace: sourceWorkspace,
            outputWorkspace: aospOutputWorkspace(apiLevel: entry.platformSDK),
            compilerCacheWorkspace: aospCompilerCacheWorkspace(
                apiLevel: entry.platformSDK),
            buildEntrypoint: buildTool,
            artifactEntrypoint: artifactTool,
            signingIdentity: signingIdentity,
            product: entry.product,
            release: entry.release,
            variant: entry.variant,
            buildNumber: entry.buildNumber,
            buildTimestamp: entry.buildTimestamp,
            buildJobs: entry.buildJobs,
            expectedPlatformSDK: entry.platformSDK,
            expectedVendorAPILevel: entry.vendorAPILevel,
            environment: environment,
            sourceOverlays: aospProductSourceOverlays(root: root))
        let requiredImages = aospRequiredProductImages
        var compileBuilder = TaskBuilder(
            id: AndroidRuntimeTaskIDs.aospCompile(entry.architecture),
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
                .sourceCheckout(root.appending("aosp/device/nucleus/common")),
                .sourceCheckout(
                    root.appending("aosp/device/nucleus/\(entry.product)")),
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
            id: AndroidRuntimeTaskIDs.aospSign(entry.architecture),
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
            id: AndroidRuntimeTaskIDs.aospAssembleImages(entry.architecture),
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
            id: AndroidRuntimeTaskIDs.aospValidate(entry.architecture),
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
                .sourceCheckout(root.appending("aosp/device/nucleus/common")),
                .sourceCheckout(
                    root.appending("aosp/device/nucleus/\(entry.product)")),
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
            id: AndroidRuntimeTaskIDs.aospImage(entry.architecture),
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
            path: signed.appending("\(entry.product)-target_files.zip"),
            validation: .regularFile)
        let _: ArtifactReference = try publishBuilder.output(
            "image-archive",
            path: signed.appending("\(entry.product)-images.zip"),
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
        return ProductPipeline(
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
        let hostBuild = MesonBuildDirectory(
            path: "/build/host",
            source: "/gfxstream",
            target: target,
            nativeToolchain: .nucleusSysroot,
            options: [
                "-Dbuildtype=release",
                "-Ddefault_library=static",
                "-Ddecoders=gles,vulkan,composer",
                "-Dgfxstream-build=host",
            ])
        let guestBuild = MesonBuildDirectory(
            path: "/build/guest",
            source: "/mesa",
            target: target,
            nativeToolchain: .nucleusSysroot,
            options: [
                "-Dbuildtype=release",
                "-Dvulkan-drivers=gfxstream",
                "-Dgallium-drivers=[]",
                "-Dplatforms=[]",
                "-Dglx=disabled",
                "-Degl=disabled",
                "-Dgbm=disabled",
                "-Dgles1=disabled",
                "-Dgles2=disabled",
                "-Dopengl=false",
                "-Dllvm=disabled",
                "-Dshared-glapi=disabled",
                "-Dvalgrind=disabled",
                "-Dlibunwind=disabled",
                "-Dbuild-tests=false",
                "-Dvideo-codecs=[]",
            ])
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
        task.consume(builder.nativeSysroot)
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
            ],
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
                                    hostBuild.setupScript + """

                                        meson compile -C \(hostBuild.path) gfxstream_backend
                                        mkdir -p /export/lib
                                        install -m 0644 \(hostBuild.path)/host/libgfxstream_backend.a /export/lib/libgfxstream_backend.a
                                        """,
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
                                    guestBuild.setupScript + """

                                        meson compile -C \(guestBuild.path) vulkan_gfxstream gfxstream_vk_icd gfxstream_vk_devenv_icd
                                        mkdir -p /export/lib
                                        install -m 0755 \(guestBuild.path)/src/gfxstream/guest/vulkan/libvulkan_gfxstream.so /export/lib/libvulkan_gfxstream.so
                                        """,
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
                "-nostdinc++ -isystem\(target.containerLibCXXIncludeRoot)",
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

private struct AOSPProductEntry: Decodable {
    let architecture: PlatformArchitecture
    let product: String
    let release: String
    let variant: String
    let buildNumber: String
    let buildTimestamp: UInt64
    let platformSDK: UInt32
    let vendorAPILevel: UInt32
    let buildJobs: UInt32

    /// One product per architecture, named for the architecture it targets.
    /// The guest is one device tree, so everything except the product name and
    /// the architecture is identical across entries.
    func validate() throws {
        guard product == "nucleus_\(architecture.rawValue)",
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

private struct AOSPProductLock: Decodable {
    let products: [AOSPProductEntry]

    /// One platform serves every product: the guest is one device tree, and
    /// validation rejects an entry that disagrees.
    var platformSDK: UInt32 { products.first?.platformSDK ?? 0 }

    func validate() throws {
        guard !products.isEmpty else {
            throw AndroidRuntimeRecipeFailure.invalidAOSPProductLock(
                "the product lock declares no product")
        }
        let architectures = products.map(\.architecture)
        guard Set(architectures).count == architectures.count else {
            throw AndroidRuntimeRecipeFailure.invalidAOSPProductLock(
                "one architecture declares more than one product")
        }
        for entry in products {
            try entry.validate()
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
