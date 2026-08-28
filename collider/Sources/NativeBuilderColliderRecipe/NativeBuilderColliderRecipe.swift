import ColliderCore
import Foundation
import SystemPackage

package enum NativeBuilderTaskIDs {
    package static let swiftBuildRegressionTest = TaskID(
        rawValue: "native.swiftbuild-regression-test")
    package static let swiftPMRegressionTest = TaskID(
        rawValue: "native.swiftpm-regression-test")
    package static let swiftPMOverlayBuild = TaskID(
        rawValue: "native.swiftpm-overlay-build")
    package static func packageRootView(_ identifier: String) -> TaskID {
        TaskID(rawValue: "native.package-root-view.\(identifier)")
    }
    package static let swiftPMOverlayArtifact = TaskID(
        rawValue: "native.swiftpm-overlay-artifact")
    package static let dependencies = TaskID(rawValue: "native.builder-dependencies")
}

package struct NativeBuilderArtifacts: Sendable {
    package let component: ComponentDefinition
    package let configuration: NativeOCIBaseConfiguration
    /// The package-root view each Swift build lane mounts, by request
    /// identifier. A build's package root is a projection of what its manifest
    /// declares rather than the checkout it sits in.
    package let packageRootViews: [String: ArtifactReference]
}

public enum NativeBuilderColliderRecipe {
    public static let descriptor = ComponentDescriptor(
        id: ComponentID(rawValue: "native"),
        canonicalName: "native-builder",
        directoryName: "collider/images/native-builder")

    package static func prepare(
        repositoryRoot: FilePath,
        context sourceContext: FilePath,
        cacheRoot: FilePath,
        ccache: FilePath,
        environment: [String: String],
        identityPathMap: IdentityPathMap,
        packageRootViews packageRootViewRequests: [PackageRootViewRequest] = []
    ) throws -> NativeBuilderArtifacts {
        let inputRoot = cacheRoot.appending("inputs")
        let dependencyContext = cacheRoot.appending("dependency-context")
        let resolverOutput = cacheRoot.appending("apt-resolution")
        let resolverImageID = cacheRoot.appending("resolver-image-id")
        let dependencyImageID = cacheRoot.appending("dependency-image-id")
        let overlayRoot = cacheRoot.appending("swiftpm-overlay/artifact")
        let swiftPMSource = repositoryRoot.appending(
            "swift-sdk/source/swift-package-manager")
        let swiftBuildSource = repositoryRoot.appending(
            "swift-sdk/source/swift-build")
        // The overlay lane compiles pinned SwiftPM against pinned SwiftBuild,
        // and every task in it declares exactly these two checkouts. Each is a
        // gitlink whose `.git` is a directory in place rather than a file
        // pointing into the superproject, so the assembly step's revision and
        // cleanliness checks resolve inside the subtree and no part of this
        // lane reaches the checkout root.
        let overlaySourceMounts = [swiftPMSource, swiftBuildSource].map {
            OCIMount(
                source: $0,
                target: identityPathMap.executionPath($0),
                access: .readOnly)
        }
        let manifest = try NativeBuilderInputManifest.load(
            from: sourceContext.appending("native-builder-inputs.json"))
        let overlayManifest = try SwiftPMOverlayInputManifest.load(
            from: sourceContext.appending("swiftpm-overlay-inputs.json"))
        guard
            let swiftCompilerArchive = manifest.archives.first(where: {
                $0.name == "swift-arm64.tar.gz"
            })
        else {
            throw NativeBuilderInputFailure.invalidManifest
        }
        let downloads = try manifest.downloads(root: inputRoot)
        let resolverPreparation = OCIImagePreparation(
            executionPlatform: .linuxARM64OCI,
            context: sourceContext,
            containerFile: sourceContext.appending("Resolver.Containerfile"),
            imageID: resolverImageID,
            imageName: "localhost/nucleus-apt-resolver",
            environment: environment)
        let dependencyPreparation = OCIImagePreparation(
            executionPlatform: .linuxARM64OCI,
            context: dependencyContext,
            containerFile: dependencyContext.appending("Containerfile"),
            imageID: dependencyImageID,
            imageName: "localhost/nucleus-linux-build-dependencies",
            environment: environment)

        var dependencyBuilder = TaskBuilder(
            id: NativeBuilderTaskIDs.dependencies,
            component: descriptor.id)
        let dependencyImage: ArtifactReference =
            try dependencyBuilder.output(
                "image-id",
                path: dependencyImageID,
                validation: .regularFile)
        let dependencyTask = dependencyBuilder.build(
            inputs: nativeBuilderDependencyInputs(sourceContext: sourceContext),
            postconditions: [
                PathPostcondition(path: ccache, validation: .exists)
            ],
            locks: [.checkout("native-builder-image")],
            assessmentPolicy: .incremental,
            action:
                try AnyColliderAction(
                    PrepareNativeBuilderDependencyImageAction(
                        sourceContext: sourceContext,
                        inputRoot: inputRoot,
                        generatedContext: dependencyContext,
                        resolverOutput: resolverOutput,
                        ccache: ccache,
                        ubuntuSnapshot: manifest.ubuntuSnapshot,
                        ubuntuSuites: manifest.aptRepositories.map(\.suite),
                        initialDownloads: downloads,
                        resolverPreparation: resolverPreparation,
                        dependencyPreparation: dependencyPreparation)))

        let swiftBuildInvocation = SwiftPMInvocation(
            context: SwiftBuildContext(
                packageRoot: swiftBuildSource,
                buildSystem: .native,
                configuration: .debug,
                target: .host(identity: "aarch64-unknown-linux-gnu"),
                toolchainIdentity: "swift-6.4-swiftbuild-"
                    + overlayManifest.swiftBuildRevision,
                maximumParallelism: SwiftBuildContext.concurrentOCIMaximumParallelism,
                execution: .oci(
                    SwiftPMOCIExecution(
                        executionPlatform: .linuxARM64OCI,
                        artifactTarget: .linuxARM64,
                        image: dependencyImage,
                        hostname: "nucleus-swiftbuild-regression",
                        hostWorkingDirectory: swiftBuildSource,
                        mounts: [
                            OCIMount(
                                source: swiftBuildSource,
                                target: identityPathMap.executionPath(swiftBuildSource),
                                access: .readOnly)
                        ],
                        buildWorkspace: PersistentWorkspaceDeclaration(
                            identity: PersistentWorkspaceIdentity(
                                key: "nucleus-swiftbuild-tests",
                                artifactTarget: .linuxARM64,
                                role: "build"),
                            capacityBytes: 50 * 1_024 * 1_024 * 1_024,
                            filesystem: .ext4,
                            journal: .writeback64MiB),
                        hostDependencyCache: cacheRoot.appending(
                            "swiftbuild-regression/dependency-cache"),
                        resourceLimits: .parallelBuild,
                        containerEnvironment: [
                            "HOME": "/home/nucleus-build",
                            "LD_LIBRARY_PATH": "/opt/swift/usr/lib/swift/linux:"
                                + "/opt/swift-compat/arm64",
                            "NUCLEUS_SWIFTPM_RETAIN_CONTEXTS": "1",
                        ],
                        commandPrefix: ["swiftpm"])),
                identityPathMap: identityPathMap),
            scratchPath: cacheRoot.appending("swiftbuild-regression/scratch"),
            dependencyLock: swiftBuildSource.appending("Package.resolved"))
        let swiftBuildRegression = swiftBuildInvocation.testProduct(
            package: "SwiftBuild",
            testProduct: "SwiftBuildPackageTests",
            packageRoot: swiftBuildSource,
            environment: environment,
            arguments: [
                "--filter",
                "HostBuildToolTaskConstructionTests."
                    + "hostToolUsesHostSDKWhenDestinationIsAlsoLinux",
            ])
        let swiftBuildRegressionTask = TaskBuilder(
            id: NativeBuilderTaskIDs.swiftBuildRegressionTest,
            component: descriptor.id
        ).build(
            swiftTests: [swiftBuildRegression],
            inputs: [
                .sourceCheckout(swiftBuildSource),
                swiftBuildInvocation.identityInput,
            ],
            locks: [.checkout("native-swiftbuild-regression-test")])

        let swiftPMInvocation = SwiftPMInvocation(
            context: SwiftBuildContext(
                packageRoot: swiftPMSource,
                buildSystem: .native,
                configuration: .release,
                target: .host(identity: "aarch64-unknown-linux-gnu"),
                toolchainIdentity: "swift-6.4-"
                    + overlayManifest.swiftPackageManagerRevision,
                maximumParallelism: SwiftBuildContext.concurrentOCIMaximumParallelism,
                execution: .oci(
                    SwiftPMOCIExecution(
                        executionPlatform: .linuxARM64OCI,
                        artifactTarget: .linuxARM64,
                        image: dependencyImage,
                        hostname: "nucleus-swiftpm-overlay",
                        hostWorkingDirectory: swiftPMSource,
                        mounts: overlaySourceMounts,
                        buildWorkspace: PersistentWorkspaceDeclaration(
                            identity: PersistentWorkspaceIdentity(
                                key: "nucleus-swiftpm-overlay",
                                artifactTarget: .linuxARM64,
                                role: "build"),
                            capacityBytes: 50 * 1_024 * 1_024 * 1_024,
                            filesystem: .ext4,
                            journal: .writeback64MiB),
                        hostDependencyCache: cacheRoot.appending(
                            "swiftpm-overlay/dependency-cache"),
                        resourceLimits: .parallelBuild,
                        containerEnvironment: [
                            "HOME": "/home/nucleus-build",
                            "LD_LIBRARY_PATH": "/opt/swift/usr/lib/swift/linux:"
                                + "/opt/swift-compat/arm64",
                            "NUCLEUS_SWIFTPM_RETAIN_CONTEXTS": "1",
                        ],
                        commandPrefix: ["swiftpm"])),
                identityPathMap: identityPathMap),
            scratchPath: cacheRoot.appending("swiftpm-overlay/scratch"),
            dependencyLock: swiftPMSource.appending("Package.resolved"))
        let swiftPMRegression = swiftPMInvocation.testProduct(
            package: "SwiftPM",
            testProduct: "SwiftPMPackageTests",
            packageRoot: swiftPMSource,
            environment: environment,
            arguments: [
                "--filter",
                "SwiftBuildSystemTests.commandLineFlagsAreDestinationOnly",
            ])
        let swiftPMRegressionTask = TaskBuilder(
            id: NativeBuilderTaskIDs.swiftPMRegressionTest,
            component: descriptor.id
        ).build(
            swiftTests: [swiftPMRegression],
            inputs: [
                .sourceCheckout(swiftPMSource),
                .sourceCheckout(swiftBuildSource),
                swiftPMInvocation.identityInput,
            ],
            locks: [.checkout("native-swiftpm-regression-test")]
        ).addingDependencies([swiftBuildRegressionTask.id])

        let swiftPMProduct = swiftPMInvocation.product(
            package: "SwiftPM",
            product: "swift-package-manager",
            packageRoot: swiftPMSource,
            environment: environment)
        var overlayBuildBuilder = TaskBuilder(
            id: NativeBuilderTaskIDs.swiftPMOverlayBuild,
            component: descriptor.id)
        let swiftPMExecutable = try overlayBuildBuilder.executableOutput(
            "swift-package-manager",
            path: swiftPMInvocation.executable("swift-package-manager"))
        let overlayBuildTask = overlayBuildBuilder.build(
            swiftProducts: [swiftPMProduct],
            inputs: [
                .sourceCheckout(swiftPMSource),
                .sourceCheckout(swiftBuildSource),
                swiftPMInvocation.identityInput,
            ],
            locks: [.checkout("native-swiftpm-overlay-build")]
        ).addingDependencies([swiftPMRegressionTask.id])

        var overlayArtifactBuilder = TaskBuilder(
            id: NativeBuilderTaskIDs.swiftPMOverlayArtifact,
            component: descriptor.id)
        overlayArtifactBuilder.consume(swiftPMExecutable)
        overlayArtifactBuilder.consume(dependencyImage)
        let overlayArtifact: ArtifactReference = try overlayArtifactBuilder.output(
            "root",
            path: overlayRoot,
            validation: .nonEmptyDirectory)
        let overlayArtifactTask = overlayArtifactBuilder.build(
            inputs: [
                .file(sourceContext.appending("swiftpm-overlay-inputs.json")),
                .file(sourceContext.appending("assemble-swiftpm-overlay.sh")),
                .sourceCheckout(swiftPMSource),
                .sourceCheckout(swiftBuildSource),
            ],
            locks: [.checkout("native-swiftpm-overlay-artifact")],
            action: try AnyColliderAction(
                AssembleSwiftPMOverlayAction(
                    image: dependencyImage,
                    sourceMounts: overlaySourceMounts,
                    products: swiftPMInvocation.productsDirectory,
                    outputRoot: overlayRoot,
                    assemblyScript: sourceContext.appending(
                        "assemble-swiftpm-overlay.sh"),
                    swiftPMSource: swiftPMSource,
                    swiftBuildSource: swiftBuildSource,
                    inputs: overlayManifest,
                    swiftCompilerArchiveSHA256: swiftCompilerArchive.sha256,
                    identityPathMap: identityPathMap,
                    environment: environment)))

        let packageRootViewRoot =
            packageRootViewRequests.first?.view.removingLastComponent()
            ?? cacheRoot.appending("package-root-views")
        var packageRootViewTasks: [TaskDeclaration] = []
        var packageRootViews: [String: ArtifactReference] = [:]
        for request in packageRootViewRequests.sorted(by: {
            $0.identifier < $1.identifier
        }) {
            var builder = TaskBuilder(
                id: NativeBuilderTaskIDs.packageRootView(request.identifier),
                component: descriptor.id)
            let view: ArtifactReference = try builder.output(
                "view",
                path: request.view,
                validation: .nonEmptyDirectory)
            packageRootViews[request.identifier] = view
            packageRootViewTasks.append(
                builder.build(
                    inputs: request.files.map { .file($0) },
                    locks: [.checkout("native-package-root-view-\(request.identifier)")],
                    action: try AnyColliderAction(
                        MaterializePackageRootViewAction(request: request))))
        }

        let configuration = NativeOCIBaseConfiguration(
            image: dependencyImage,
            swiftPMOverlay: overlayArtifact,
            ccache: ccache,
            environment: environment,
            swiftPMOverlayRevision:
                overlayManifest.swiftPackageManagerRevision)
        return NativeBuilderArtifacts(
            component: try ComponentDefinition(
                descriptor: descriptor,
                tasks: [
                    dependencyTask,
                    swiftBuildRegressionTask,
                    swiftPMRegressionTask,
                    overlayBuildTask,
                    overlayArtifactTask,
                ] + packageRootViewTasks,
                entrypoints: [
                    ComponentEntrypoint(
                        id: .bootstrap,
                        roots: [dependencyTask.id, overlayArtifactTask.id])
                ],
                storage: [
                    StorageDeclaration(
                        id: "native-builder-metadata",
                        owner: descriptor.id,
                        producers: [
                            .task(dependencyTask.id),
                            .task(swiftBuildRegressionTask.id),
                            .task(swiftPMRegressionTask.id),
                            .task(overlayBuildTask.id),
                            .task(overlayArtifactTask.id),
                        ],
                        storageClass: .cache,
                        root: cacheRoot,
                        safetyRoot: cacheRoot.removingLastComponent(),
                        retentionPolicy: .singleWorkingSet),
                    StorageDeclaration(
                        id: "native-builder-package-root-views",
                        owner: descriptor.id,
                        producers: Set(packageRootViewTasks.map { StorageProducer.task($0.id) }),
                        storageClass: .cache,
                        root: packageRootViewRoot,
                        safetyRoot: packageRootViewRoot.removingLastComponent(),
                        retentionPolicy: .singleWorkingSet),
                    StorageDeclaration(
                        id: "native-builder-ccache",
                        owner: descriptor.id,
                        producers: [.task(dependencyTask.id)],
                        storageClass: .cache,
                        root: ccache,
                        safetyRoot: ccache.removingLastComponent(),
                        retentionPolicy: .toolManagedLimit(
                            maximumBytes: 50 * 1_024 * 1_024 * 1_024)),
                ]),
            configuration: configuration,
            packageRootViews: packageRootViews)
    }
}

private struct AssembleSwiftPMOverlayAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let execution: OCIExecution

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(nested: OCIExecutionActionIdentity(execution))
        }
    }

    static let kind: ActionKind = "native.assemble-swiftpm-overlay"

    private let execution: OCIExecution
    private let pipeline: OCIExecutionPipeline
    private let outputRoot: FilePath
    private let pinnedSources: [(source: FilePath, revision: String)]

    var identity: Identity { Identity(execution: execution) }
    var requirements: ActionRequirements { pipeline.requirements }

    init(
        image: ArtifactReference,
        sourceMounts: [OCIMount],
        products: FilePath,
        outputRoot: FilePath,
        assemblyScript: FilePath,
        swiftPMSource: FilePath,
        swiftBuildSource: FilePath,
        inputs: SwiftPMOverlayInputManifest,
        swiftCompilerArchiveSHA256: String,
        identityPathMap: IdentityPathMap,
        environment: [String: String]
    ) throws {
        self.outputRoot = outputRoot
        pinnedSources = [
            (swiftPMSource, inputs.swiftPackageManagerRevision),
            (swiftBuildSource, inputs.swiftBuildRevision),
        ]
        let entrypoint = OCIMountedEntrypoint(
            image: image,
            executable: assemblyScript,
            containerDirectory: "/collider-entrypoints/swiftpm-overlay")
        execution = OCIExecution(
            executionPlatform: .linuxARM64OCI,
            artifactTarget: .linuxARM64,
            imageID: image.path,
            hostname: "nucleus-swiftpm-overlay-artifact",
            workingDirectory: identityPathMap.executionPath(swiftPMSource),
            hostWorkingDirectory: swiftPMSource,
            mounts: sourceMounts + [
                OCIMount(
                    source: products,
                    target: identityPathMap.executionPath(products),
                    access: .readOnly),
                OCIMount(
                    boundedExport: outputRoot,
                    target: identityPathMap.executionPath(outputRoot)),
                entrypoint.mount,
            ],
            userPolicy: .builder,
            capabilityPolicy: .dropAll,
            privilegePolicy: .prohibitAcquisition,
            processFilesystemPolicy: .standard,
            resourceLimits: .build,
            containerEnvironment: [
                "HOME": "/home/nucleus-build",
                "LD_LIBRARY_PATH": "/opt/swift/usr/lib/swift/linux:"
                    + "/opt/swift-compat/arm64",
                "NUCLEUS_SWIFTPM_OVERLAY_OUTPUT": identityPathMap.executionPath(outputRoot),
                "NUCLEUS_SWIFTPM_OVERLAY_PRODUCTS": identityPathMap.executionPath(products),
                "NUCLEUS_SWIFTPM_REVISION": inputs.swiftPackageManagerRevision,
                "NUCLEUS_SWIFTBUILD_REVISION": inputs.swiftBuildRevision,
                "NUCLEUS_SWIFT_COMPILER_ARCHIVE_SHA256":
                    swiftCompilerArchiveSHA256,
                "SOURCE_DATE_EPOCH": String(inputs.sourceDateEpoch),
            ],
            imageEntrypointOverride: entrypoint.containerPath,
            command: ["assemble"],
            environment: environment,
            output: .logged)
        pipeline = try OCIExecutionPipeline([execution])
    }

    func execute(in context: ActionContext) async throws {
        for pinned in pinnedSources {
            try await verify(pinned.source, isAt: pinned.revision, in: context)
        }
        try context.files.createDirectory(outputRoot)
        try await context.containers.run(execution)
    }

    /// Asserts a pinned source is the revision the overlay claims and carries
    /// no modification.
    ///
    /// Source identity establishes that the tree did not change, not that it is
    /// the revision the manifest names, so nothing else states this. It runs
    /// here rather than inside the assembly step because only the submodule
    /// subtree crosses into that container, while a gitlink's `.git` is a file
    /// naming a directory in the superproject wherever the checkout was made by
    /// cloning with submodules. Asking git there answers only for a checkout
    /// whose repository happens to sit in place, which the authoritative one
    /// does and a work tree created by cloning does not; the host holds the
    /// whole repository either way.
    private func verify(
        _ source: FilePath,
        isAt revision: String,
        in context: ActionContext
    ) async throws {
        let head = try await git(["rev-parse", "HEAD"], in: source, context: context)
        guard head == revision else {
            throw SwiftPMOverlaySourceFailure.unexpectedRevision(
                source: source, expected: revision, actual: head)
        }
        let modifications = try await git(
            ["status", "--porcelain"], in: source, context: context)
        guard modifications.isEmpty else {
            throw SwiftPMOverlaySourceFailure.modified(source: source)
        }
    }

    private func git(
        _ arguments: [String],
        in source: FilePath,
        context: ActionContext
    ) async throws -> String {
        let result = try await context.commands.execute(
            CommandSpec(
                executable: .named("git"),
                arguments: ["-C", source.string] + arguments,
                workingDirectory: source,
                environment: execution.environment,
                output: .captured(limit: 1 << 20)))
        guard result.status == 0 else {
            throw SwiftPMOverlaySourceFailure.notAGitCheckout(source)
        }
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum SwiftPMOverlaySourceFailure: Error, CustomStringConvertible {
    case notAGitCheckout(FilePath)
    case unexpectedRevision(source: FilePath, expected: String, actual: String)
    case modified(source: FilePath)

    var description: String {
        switch self {
        case .notAGitCheckout(let source):
            return "pinned overlay source is not a readable git checkout: \(source)"
        case .unexpectedRevision(let source, let expected, let actual):
            return
                "pinned overlay source \(source) is at \(actual), "
                + "and the overlay manifest names \(expected)"
        case .modified(let source):
            return "pinned overlay source has uncommitted modifications: \(source)"
        }
    }
}

private func nativeBuilderDependencyInputs(
    sourceContext: FilePath
) -> [ArtifactInput] {
    [
        "Dependencies.Containerfile",
        "entrypoint.sh",
        "Resolver.Containerfile",
        "apt-extract-packages.txt",
        "apt-install-packages.txt",
        "native-builder-inputs.json",
        "resolve-apt-packages.sh",
    ].map { .file(sourceContext.appending($0)) }
}

private struct PrepareNativeBuilderDependencyImageAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let sourceContext: FilePath
        let inputRoot: FilePath
        let generatedContext: FilePath
        let resolverOutput: FilePath
        let cache: FilePath
        let ubuntuSnapshot: String
        let ubuntuSuites: [String]
        let resolverPreparation: OCIImagePreparation
        let dependencyPreparation: OCIImagePreparation

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: sourceContext)
            encoder.append(path: inputRoot)
            encoder.append(path: generatedContext)
            encoder.append(path: resolverOutput)
            encoder.append(path: cache)
            encoder.append(ubuntuSnapshot)
            encoder.append(ubuntuSuites.joined(separator: "\n"))
            encoder.append(nested: OCIImagePreparationActionIdentity(resolverPreparation))
            encoder.append(nested: OCIImagePreparationActionIdentity(dependencyPreparation))
        }
    }

    static let kind: ActionKind = "native.prepare-builder-dependency-image"

    let sourceContext: FilePath
    let inputRoot: FilePath
    let generatedContext: FilePath
    let resolverOutput: FilePath
    let ccache: FilePath
    let ubuntuSnapshot: String
    let ubuntuSuites: [String]
    let initialDownloads: [NativeBuilderDownload]
    let resolverPreparation: OCIImagePreparation
    let dependencyPreparation: OCIImagePreparation

    var identity: Identity {
        Identity(
            sourceContext: sourceContext,
            inputRoot: inputRoot,
            generatedContext: generatedContext,
            resolverOutput: resolverOutput,
            cache: ccache,
            ubuntuSnapshot: ubuntuSnapshot,
            ubuntuSuites: ubuntuSuites,
            resolverPreparation: resolverPreparation,
            dependencyPreparation: dependencyPreparation)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            effects: [
                // The resolver mounts this context whole and both image
                // preparations build from it, so the directory is what this
                // reaches rather than the files it reads out of it.
                ActionEffect(.read, scope: .input(sourceContext)),
                ActionEffect(.readWrite, scope: .scratch(inputRoot)),
                ActionEffect(.readWrite, scope: .scratch(generatedContext)),
                ActionEffect(
                    .readWrite,
                    scope: .scratch(candidateContext)),
                ActionEffect(.readWrite, scope: .scratch(resolverOutput)),
                ActionEffect(
                    .readWrite,
                    scope: .scratch(resolverPreparation.imageID)),
                ActionEffect(.readWrite, scope: .scratch(ccache)),
                ActionEffect(
                    .readWrite,
                    scope: .output(dependencyPreparation.imageID)),
            ],
            lane: .hostExclusive,
            networkAccess: .contentAddressed,
            executionPlatform: .linuxARM64OCI)
    }

    var environment: [String: String] { dependencyPreparation.environment }
    var imagePreparations: [OCIImagePreparation] {
        [resolverPreparation, dependencyPreparation]
    }

    func execute(in context: ActionContext) async throws {
        try context.files.createDirectory(ccache)
        try context.files.createDirectory(inputRoot)
        try await download(initialDownloads, in: context)
        let indexDownloads = try nativeBuilderAPTIndexDownloads(
            releases: initialDownloads,
            root: inputRoot,
            files: context.files)
        try await download(indexDownloads, in: context)

        try await context.containers.prepareImage(resolverPreparation)
        try context.files.remove(resolverOutput)
        try context.files.createDirectory(resolverOutput)
        try await context.containers.run(resolverExecution())

        let closurePath = resolverOutput.appending("packages.tsv")
        let closure = try String(
            decoding: context.files.read(closurePath),
            as: UTF8.self)
        let packageDownloads = try nativeBuilderPackageDownloads(
            manifest: closure,
            root: inputRoot)
        try await download(packageDownloads, in: context)
        try assembleContext(
            downloads: initialDownloads + indexDownloads + packageDownloads,
            files: context.files)
        try await context.containers.prepareImage(dependencyPreparation)
    }

    private func resolverExecution() -> OCIExecution {
        OCIExecution(
            executionPlatform: .linuxARM64OCI,
            artifactTarget: .linuxARM64,
            imageID: resolverPreparation.imageID,
            hostname: "native-apt-resolver",
            workingDirectory: "/",
            hostWorkingDirectory: sourceContext,
            mounts: [
                OCIMount(
                    source: sourceContext,
                    target: "/input",
                    access: .readOnly),
                OCIMount(
                    source: inputRoot.appending("indexes"),
                    target: "/indexes",
                    access: .readOnly),
                OCIMount(
                    boundedExport: resolverOutput,
                    target: "/output"),
            ],
            userPolicy: OCIUserPolicy(userID: 0, groupID: 0),
            capabilityPolicy: .dropAll,
            privilegePolicy: .prohibitAcquisition,
            processFilesystemPolicy: .standard,
            resourceLimits: OCIResourceLimits(
                cpuCount: 2,
                memoryBytes: 4 * 1_024 * 1_024 * 1_024,
                processCount: 1_024),
            containerEnvironment: [
                "LANG": "C.UTF-8",
                "LC_ALL": "C.UTF-8",
                "NUCLEUS_UBUNTU_SNAPSHOT": ubuntuSnapshot,
                "NUCLEUS_UBUNTU_SUITES": ubuntuSuites.joined(separator: " "),
            ],
            command: ["/usr/local/bin/resolve-nucleus-apt-packages"],
            environment: environment,
            output: .logged)
    }

    private func download(
        _ downloads: [NativeBuilderDownload],
        in context: ActionContext
    ) async throws {
        var iterator = downloads.makeIterator()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<min(12, downloads.count) {
                guard let download = iterator.next() else { break }
                group.addTask {
                    try await context.downloads.download(
                        download.identity.specification,
                        to: download.identity.destination)
                }
            }
            while try await group.next() != nil {
                guard let download = iterator.next() else { continue }
                group.addTask {
                    try await context.downloads.download(
                        download.identity.specification,
                        to: download.identity.destination)
                }
            }
        }
    }

    private func assembleContext(
        downloads: [NativeBuilderDownload],
        files: ActionFileSystem
    ) throws {
        let candidate = candidateContext
        try files.remove(candidate)
        try files.createDirectory(candidate)
        try files.copy(
            from: sourceContext.appending("Dependencies.Containerfile"),
            to: candidate.appending("Containerfile"))
        try files.copy(
            from: sourceContext.appending("entrypoint.sh"),
            to: candidate.appending("entrypoint.sh"))
        for download in downloads {
            let destination: FilePath
            switch download.placement {
            case .archive(let name):
                destination = candidate.appending("inputs/archives/\(name)")
            case .aptRelease:
                continue
            case .aptIndex:
                continue
            case .aptPackage(let role, let digest):
                destination = candidate.appending(
                    "inputs/apt/\(role)/\(digest).deb")
            }
            try files.createDirectory(destination.removingLastComponent())
            try files.copy(
                from: download.identity.destination,
                to: destination)
        }
        try files.remove(generatedContext)
        try files.move(from: candidate, to: generatedContext)
    }

    private var candidateContext: FilePath {
        generatedContext.removingLastComponent().appending(
            "\(generatedContext.lastComponent?.string ?? "dependency-context").candidate")
    }
}
