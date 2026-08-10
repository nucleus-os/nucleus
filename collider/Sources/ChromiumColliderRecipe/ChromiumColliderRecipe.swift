import ColliderCore
import Foundation
import SystemPackage

private enum ChromiumBuildImageActionKind: OCIEntrypointImageActionKind {
    static let actionKind: ActionKind = "browser.prepare-build-image"
}

private enum ChromiumArtifactImageActionKind: OCIEntrypointImageActionKind {
    static let actionKind: ActionKind = "browser.prepare-artifact-image"
}

package enum ChromiumTaskIDs {
    package static let source = TaskID(rawValue: "browser.source")
    package static let builderDependencies = TaskID(
        rawValue: "browser.builder-dependencies")
    package static let buildTools = TaskID(rawValue: "browser.build-tools")
    package static let artifactTools = TaskID(
        rawValue: "browser.artifact-tools")
    package static let retention = TaskID(rawValue: "browser.retention")
    package static let install = TaskID(rawValue: "browser.install")

    package static func build(
        _ product: ChromiumProduct,
        _ target: ChromiumLinuxTarget
    ) -> TaskID {
        TaskID(
            rawValue:
                "browser.\(product.rawValue).\(target.architecture.rawValue).build")
    }

    package static func artifact(
        _ product: ChromiumProduct,
        _ target: ChromiumLinuxTarget
    ) -> TaskID {
        TaskID(
            rawValue:
                "browser.\(product.rawValue).\(target.architecture.rawValue).artifact")
    }

    package static func test(_ target: ChromiumLinuxTarget) -> TaskID {
        TaskID(rawValue: "browser.\(target.architecture.rawValue).test")
    }
}

enum ChromiumRetention {
    static let sourceRollbackGenerationCount: UInt32 = 0
    static let cefRollbackGenerationCount: UInt32 = 1
    static let browserRollbackGenerationCount: UInt32 = 1
    static let installationRollbackGenerationCount: UInt32 = 1
}

public struct ChromiumRecipeLayout: Hashable, Sendable {
    public let sourceID: String
    public let cacheRoot: FilePath
    public let installPrefix: FilePath
    public let jobs: Int

    public init(
        sourceID: String,
        cacheRoot: FilePath,
        installPrefix: FilePath,
        jobs: Int
    ) {
        self.sourceID = sourceID
        self.cacheRoot = cacheRoot
        self.installPrefix = installPrefix
        self.jobs = jobs
    }
}

public enum ChromiumColliderRecipe: ColliderComponent {
    public static let descriptor = ComponentDescriptor(
        id: ComponentID(rawValue: "browser"),
        canonicalName: "browser",
        directoryName: "chromium",
        aliases: ["chromium"])

    public static func makeComponent(
        in context: RecipeContext
    ) throws -> ComponentDefinition {
        let lockData = try Data(
            contentsOf: URL(
                fileURLWithPath: context.repositoryRoot.appending(
                    "chromium/source.lock.json"
                ).string))
        let lock = try JSONDecoder().decode(
            ChromiumSourceLock.self,
            from: lockData)
        try validateSourceLock(lock)
        let sourceID = String(
            ArtifactDigest.sha256(lockData).hexadecimal.prefix(24))
        let prefix =
            context.environment["PREFIX"]
            ?? context.environment["HOME"].map { FilePath($0).appending(".local").string }
            ?? "/tmp/nucleus-browser"
        let cacheRoot = context.cacheRoot.appending("nucleus/cef")
        let tasks = try tasks(
            workspaceRoot: context.repositoryRoot,
            environment: context.environment,
            layout: ChromiumRecipeLayout(
                sourceID: sourceID,
                cacheRoot: cacheRoot,
                installPrefix: FilePath(prefix),
                jobs: Int(context.environment["NUCLEUS_CHROMIUM_JOBS"] ?? "")
                    ?? 12))
        func producers(_ ids: TaskID...) -> Set<StorageProducer> {
            Set(ids.map(StorageProducer.task))
        }
        let retention = ChromiumTaskIDs.retention
        let installationRoot = FilePath(prefix).appending("lib/nucleus-browser")
        let buildTaskIDs = chromiumLinuxTargets.flatMap { target in
            ChromiumProduct.allCases.map { product in
                ChromiumTaskIDs.build(product, target)
            }
        }
        var storage: [StorageDeclaration] = [
            StorageDeclaration(
                id: "browser-source-generations",
                owner: descriptor.id,
                producers: producers(ChromiumTaskIDs.source, retention),
                storageClass: .generation,
                root: cacheRoot.appending("source-generations"),
                safetyRoot: cacheRoot,
                cleanupPolicy: .automaticRetention,
                activeGenerationLink: cacheRoot.appending("source-generations/current"),
                rollbackGenerationCount: ChromiumRetention.sourceRollbackGenerationCount,
                interruptedCandidateNaming: .contentIdentityCandidate,
                retention: "the active pinned Chromium source generation remains"),
            StorageDeclaration(
                id: "browser-build-metadata",
                owner: descriptor.id,
                producers: Set(
                    (buildTaskIDs + [retention]).map(StorageProducer.task)),
                storageClass: .incremental,
                root: cacheRoot.appending("build-metadata"),
                safetyRoot: cacheRoot,
                cleanupPolicy: .explicitClean,
                retention: "target build manifests remain reusable"),
            StorageDeclaration(
                id: "browser-depot-tools",
                owner: descriptor.id,
                producers: producers(
                    TaskID(rawValue: "browser.depot-tools"),
                    TaskID(rawValue: "browser.depot-tools-bootstrap")),
                storageClass: .cache,
                root: cacheRoot.appending("depot_tools"),
                safetyRoot: cacheRoot,
                cleanupPolicy: .explicitClean,
                retention: "the pinned depot_tools checkout remains reusable"),
            StorageDeclaration(
                id: "browser-builder-metadata",
                owner: descriptor.id,
                producers: producers(
                    ChromiumTaskIDs.builderDependencies,
                    ChromiumTaskIDs.buildTools,
                    ChromiumTaskIDs.artifactTools),
                storageClass: .cache,
                root: cacheRoot.appending("build-container"),
                safetyRoot: cacheRoot,
                cleanupPolicy: .explicitClean,
                retention:
                    "the Chromium build and artifact image metadata remains reusable"),
            StorageDeclaration(
                id: "browser-logs",
                owner: descriptor.id,
                producers: Set(buildTaskIDs.map(StorageProducer.task)),
                storageClass: .diagnostic,
                root: cacheRoot.appending("logs"),
                safetyRoot: cacheRoot,
                cleanupPolicy: .explicitClean,
                retention: "browser build diagnostics remain until explicit clean"),
            StorageDeclaration(
                id: "browser-locks",
                owner: descriptor.id,
                producers: Set(tasks.map { .task($0.id) }),
                storageClass: .incremental,
                root: cacheRoot.appending("locks"),
                safetyRoot: cacheRoot,
                cleanupPolicy: .protected,
                retention: "workflow lock identity remains with browser storage"),
            StorageDeclaration(
                id: "browser-installations",
                owner: descriptor.id,
                producers: producers(ChromiumTaskIDs.install),
                storageClass: .generation,
                root: installationRoot.appending("generations"),
                safetyRoot: installationRoot,
                cleanupPolicy: .automaticRetention,
                activeGenerationLink: installationRoot.appending("current"),
                rollbackGenerationCount:
                    ChromiumRetention.installationRollbackGenerationCount,
                retention: "the active browser installation and one rollback generation remain"),
        ]
        for target in chromiumLinuxTargets {
            let identifier = target.identifier
            let cefRoot = cacheRoot.appending("dist/\(identifier)")
            let browserRoot = cacheRoot.appending("browser-dist/\(identifier)")
            storage.append(
                StorageDeclaration(
                    id: "browser-cef-\(target.architecture.rawValue)-generations",
                    owner: descriptor.id,
                    producers: producers(
                        ChromiumTaskIDs.artifact(.cef, target), retention),
                    storageClass: .generation,
                    root: cefRoot.appending("releases"),
                    safetyRoot: cefRoot,
                    cleanupPolicy: .automaticRetention,
                    activeGenerationLink: cefRoot.appending("current-release"),
                    rollbackGenerationCount: ChromiumRetention.cefRollbackGenerationCount,
                    retention:
                        "the active CEF \(identifier) publication and one rollback generation remain"
                ))
            storage.append(
                StorageDeclaration(
                    id: "browser-product-\(target.architecture.rawValue)-generations",
                    owner: descriptor.id,
                    producers: producers(
                        ChromiumTaskIDs.artifact(.browser, target), retention),
                    storageClass: .generation,
                    root: browserRoot.appending("generations"),
                    safetyRoot: browserRoot,
                    cleanupPolicy: .automaticRetention,
                    activeGenerationLink: browserRoot.appending("current"),
                    rollbackGenerationCount: ChromiumRetention.browserRollbackGenerationCount,
                    retention:
                        "the active browser \(identifier) publication and one rollback generation remain"
                ))
        }
        return try ComponentDefinition(
            descriptor: descriptor,
            tasks: tasks,
            entrypoints: [
                ComponentEntrypoint(
                    id: .bootstrap,
                    roots: [ChromiumTaskIDs.source]),
                ComponentEntrypoint(id: .build, roots: [ChromiumTaskIDs.retention]),
                ComponentEntrypoint(
                    id: .testDefault,
                    roots: Set(
                        chromiumLinuxTargets.map(ChromiumTaskIDs.test))),
                ComponentEntrypoint(id: .install, roots: [ChromiumTaskIDs.install]),
            ],
            storage: storage)
    }

    public static func tasks(
        workspaceRoot: FilePath,
        environment: [String: String],
        layout: ChromiumRecipeLayout
    ) throws -> [TaskDeclaration] {
        let chromium = workspaceRoot.appending("chromium")
        let sourceLockFile = chromium.appending("source.lock.json")
        let sourceLock = try JSONDecoder().decode(
            ChromiumSourceLock.self,
            from: Data(
                contentsOf: URL(
                    fileURLWithPath: sourceLockFile.string)))
        try validateSourceLock(sourceLock)
        var repositories: [String: ChromiumSourceRepository] = [:]
        for repository in sourceLock.repositories {
            guard
                repositories.updateValue(
                    repository,
                    forKey: repository.name
                ) == nil
            else {
                throw ChromiumRecipeFailure.invalidSourceLock
            }
        }
        guard let chromiumRepository = repositories["chromium"],
            let cefRepository = repositories["cef"],
            repositories["angle"] != nil,
            repositories["skia"] != nil,
            repositories["v8"] != nil,
            repositories["dawn"] != nil,
            repositories.count == 6
        else {
            throw ChromiumRecipeFailure.invalidSourceLock
        }
        let cache = layout.cacheRoot
        let sources = cache.appending("source-generations")
        let source = sources.appending(layout.sourceID)
        let chromiumSource = source.appending("chromium/src")
        let buildMetadata = cache.appending("build-metadata").appending(
            layout.sourceID)
        let depotTools = cache.appending("depot_tools")
        let builderContext = chromium.appending("build-container")
        let builderCache = cache.appending("build-container")
        let builderInputRoot = builderCache.appending("inputs")
        let generatedBuilderDependencyContext = builderCache.appending(
            "dependency-context")
        let generatedBuilderContext = builderCache.appending("build-context")
        let generatedArtifactContext = builderCache.appending(
            "artifact-context")
        let builderResolverOutput = builderCache.appending("apt-resolution")
        let builderResolverImageID = builderCache.appending("resolver-image-id")
        let builderDependencyImageID = builderCache.appending(
            "dependency-image-id")
        let buildImageID = builderCache.appending("build-image-id")
        let artifactImageID = builderCache.appending("artifact-image-id")
        let builderInputManifest = try ChromiumBuilderInputManifest.load(
            from: builderContext.appending("builder-inputs.json"))
        let childEnvironment = environment.merging([
            "NUCLEUS_CHROMIUM_ORCHESTRATED": "1",
            "NUCLEUS_CEF_BRANCH": sourceLock.cefBranch,
            "NUCLEUS_CEF_CHECKOUT": cefRepository.commit,
            "NUCLEUS_CEF_CHROMIUM_VERSION": sourceLock.chromiumVersion,
            "NUCLEUS_CHROMIUM_CHECKOUT": chromiumRepository.commit,
            "NUCLEUS_DEPOT_TOOLS_REVISION": sourceLock.depotTools.commit,
            "NUCLEUS_CEF_CACHE_ROOT": cache.string,
            "NUCLEUS_CEF_DEPOT_TOOLS": depotTools.string,
            "NUCLEUS_CHROMIUM_SOURCE_ID": layout.sourceID,
            "NUCLEUS_CHROMIUM_SOURCE_GENERATIONS": sources.string,
            "NUCLEUS_CHROMIUM_SOURCE_CURRENT": sources.appending(
                "current"
            ).string,
            "NUCLEUS_CEF_SRC_ROOT": source.string,
            "NUCLEUS_CHROMIUM_SRC_ROOT": chromiumSource.string,
            "NUCLEUS_CEF_LOG_DIR": cache.appending("logs").string,
            "NUCLEUS_CHROMIUM_JOBS": String(layout.jobs),
            "PREFIX": layout.installPrefix.string,
        ]) { _, required in required }
        let depotEnvironment = childEnvironment.merging([
            "PATH": depotTools.string + ":"
                + (childEnvironment["PATH"] ?? "/usr/bin:/bin")
        ]) { _, required in required }
        let sourceInputs: [ArtifactInput] = [
            .string(name: "source-id", value: layout.sourceID),
            .file(sourceLockFile),
            .file(chromium.appending("build-host-tools/cipd")),
        ]
        var depotToolsBuilder = TaskBuilder(
            id: TaskID(rawValue: "browser.depot-tools"),
            component: ComponentID(rawValue: "browser"))
        let _: ArtifactReference<FileArtifact> = try depotToolsBuilder.output(
            "head",
            path: depotTools.appending(".git/HEAD"),
            validation: .regularFile)
        let depotBootstrapExecutable: ArtifactReference<ExecutableArtifact> =
            try depotToolsBuilder.output(
                "bootstrap-executable",
                path: depotTools.appending("ensure_bootstrap"),
                validation: .executableFile)
        let depotToolsTask = depotToolsBuilder.build(
            inputs: [
                .string(
                    name: "depot-tools-revision",
                    value: sourceLock.depotTools.commit),
                .tool(.named("git")),
            ],
            locks: [.shared(cache.appending("locks/depot-tools.lock"))],
            assessmentPolicy: .always,
            action:
                try AnyColliderAction(
                    PrepareChromiumDepotToolsAction(
                        repository: depotTools,
                        remote: sourceLock.depotTools.remote,
                        commit: sourceLock.depotTools.commit,
                        environment: childEnvironment)))
        var bootstrapBuilder = TaskBuilder(
            id: TaskID(rawValue: "browser.depot-tools-bootstrap"),
            component: ComponentID(rawValue: "browser"))
        bootstrapBuilder.consume(depotBootstrapExecutable)
        let bootstrapMarker: ArtifactReference<FileArtifact> = try bootstrapBuilder.output(
            "python-relative-directory",
            path: depotTools.appending("python3_bin_reldir.txt"),
            validation: .regularFile)
        let depotBootstrap = bootstrapBuilder.build(
            locks: [.shared(cache.appending("locks/depot-tools.lock"))],
            action:
                try AnyColliderAction(
                    BootstrapChromiumDepotToolsAction(
                        executable: depotBootstrapExecutable.path,
                        repository: depotTools,
                        environment: depotEnvironment)))
        let sourcePreparation = ChromiumSourcePreparation(
            sourceID: layout.sourceID,
            sourceRoot: source,
            sourceGenerations: sources,
            current: sources.appending("current"),
            depotTools: depotTools,
            linuxHostCIPDAdapter: chromium.appending("build-host-tools/cipd"),
            sourceLockFile: sourceLockFile,
            sourceLock: sourceLock,
            environment: childEnvironment)
        var sourceBuilder = TaskBuilder(
            id: ChromiumTaskIDs.source,
            component: ComponentID(rawValue: "browser"))
        sourceBuilder.consume(bootstrapMarker)
        let sourceProvenance: ArtifactReference<JSONArtifact> = try sourceBuilder.output(
            "provenance",
            path: source.appending("source-provenance.json"),
            validation: .json)
        let sourceTask = sourceBuilder.build(
            inputs: sourceInputs,
            locks: [
                .shared(cache.appending("locks/source.lock"))
            ],
            action:
                try AnyColliderAction(
                    PrepareChromiumSourceAction(
                        preparation: sourcePreparation)))
        var dependencyImageBuilder = TaskBuilder(
            id: ChromiumTaskIDs.builderDependencies,
            component: ComponentID(rawValue: "browser"))
        let dependencyImage: ArtifactReference<FileArtifact> =
            try dependencyImageBuilder.output(
                "image-id",
                path: builderDependencyImageID,
                validation: .regularFile)
        let builderDependencyTask = dependencyImageBuilder.build(
            inputs: chromiumBuilderDependencyInputs(
                sourceContext: builderContext),
            locks: [.shared(cache.appending("locks/builder.lock"))],
            action:
                try AnyColliderAction(
                    PrepareChromiumBuilderDependencyImageAction(
                        sourceContext: builderContext,
                        inputRoot: builderInputRoot,
                        generatedContext: generatedBuilderDependencyContext,
                        resolverOutput: builderResolverOutput,
                        ubuntuSnapshot: builderInputManifest.ubuntuSnapshot,
                        ubuntuSuites: builderInputManifest.aptRepositories.map(\.suite),
                        initialDownloads: builderInputManifest.downloads(
                            root: builderInputRoot),
                        resolverPreparation: OCIImagePreparation(
                            executionPlatform: .linuxARM64OCI,
                            context: builderContext,
                            containerFile: builderContext.appending(
                                "Resolver.Containerfile"),
                            imageID: builderResolverImageID,
                            imageName: "localhost/nucleus-chromium-apt-resolver",
                            environment: childEnvironment),
                        dependencyPreparation: OCIImagePreparation(
                            executionPlatform: .linuxARM64OCI,
                            context: generatedBuilderDependencyContext,
                            containerFile: generatedBuilderDependencyContext.appending(
                                "Containerfile"),
                            imageID: builderDependencyImageID,
                            imageName:
                                "localhost/nucleus-chromium-build-dependencies",
                            environment: childEnvironment))))
        var buildImageBuilder = TaskBuilder(
            id: ChromiumTaskIDs.buildTools,
            component: ComponentID(rawValue: "browser"))
        buildImageBuilder.consume(dependencyImage)
        let buildImage: ArtifactReference<FileArtifact> =
            try buildImageBuilder.output(
                "image-id",
                path: buildImageID,
                validation: .regularFile)
        let buildImageTask = buildImageBuilder.build(
            inputs: [.file(builderContext.appending("build-entrypoint.sh"))],
            locks: [.shared(cache.appending("locks/builder.lock"))],
            action:
                try AnyColliderAction(
                    PrepareOCIEntrypointImageAction<ChromiumBuildImageActionKind>(
                        baseImageID: builderDependencyImageID,
                        entrypoint: builderContext.appending(
                            "build-entrypoint.sh"),
                        entrypointDestination:
                            "/usr/local/bin/nucleus-chromium-build",
                        generatedContext: generatedBuilderContext,
                        preparation: OCIImagePreparation(
                            executionPlatform: .linuxARM64OCI,
                            context: generatedBuilderContext,
                            containerFile: generatedBuilderContext.appending(
                                "Containerfile"),
                            imageID: buildImageID,
                            imageName: "localhost/nucleus-chromium-build",
                            baseImageSource: .local,
                            localBaseImageID: builderDependencyImageID,
                            environment: childEnvironment))))
        var artifactImageBuilder = TaskBuilder(
            id: ChromiumTaskIDs.artifactTools,
            component: ComponentID(rawValue: "browser"))
        artifactImageBuilder.consume(dependencyImage)
        let artifactImage: ArtifactReference<FileArtifact> =
            try artifactImageBuilder.output(
                "image-id",
                path: artifactImageID,
                validation: .regularFile)
        let artifactImageTask = artifactImageBuilder.build(
            inputs: [.file(builderContext.appending("artifact-entrypoint.sh"))],
            locks: [.shared(cache.appending("locks/builder.lock"))],
            action:
                try AnyColliderAction(
                    PrepareOCIEntrypointImageAction<ChromiumArtifactImageActionKind>(
                        baseImageID: builderDependencyImageID,
                        entrypoint: builderContext.appending(
                            "artifact-entrypoint.sh"),
                        entrypointDestination:
                            "/usr/local/bin/nucleus-chromium-artifact",
                        generatedContext: generatedArtifactContext,
                        preparation: OCIImagePreparation(
                            executionPlatform: .linuxARM64OCI,
                            context: generatedArtifactContext,
                            containerFile: generatedArtifactContext.appending(
                                "Containerfile"),
                            imageID: artifactImageID,
                            imageName: "localhost/nucleus-chromium-artifact",
                            baseImageSource: .local,
                            localBaseImageID: builderDependencyImageID,
                            environment: childEnvironment))))
        var buildTasks: [TaskDeclaration] = []
        var artifactTasks: [TaskDeclaration] = []
        var publications: [ArtifactReference<PathArtifact>] = []
        var browserPublications: [ChromiumLinuxTarget: ArtifactReference<PathArtifact>] = [:]
        var browserManifests: [ChromiumLinuxTarget: ArtifactReference<JSONArtifact>] = [:]
        var browserWorkspaces: [ChromiumLinuxTarget: PersistentWorkspaceDeclaration] = [:]

        for product in ChromiumProduct.allCases {
            for target in chromiumLinuxTargets {
                let metadata = buildMetadata.appending(
                    "\(target.identifier)/\(product.rawValue)")
                let manifest = metadata.appending("build-manifest.json")
                let sourceWorkspace = chromiumSourceWorkspace(target: target)
                let outputWorkspace = chromiumOutputWorkspace(
                    product: product,
                    target: target)
                let compilerCacheWorkspace = chromiumCompilerCacheWorkspace(
                    product: product,
                    target: target)
                let productEnvironment = childEnvironment.merging([
                    "NUCLEUS_CHROMIUM_TARGET_ARCHITECTURE":
                        target.architecture.rawValue,
                    "CCACHE_DIR": "/ccache",
                    "CCACHE_MAXSIZE": "30G",
                    "CCACHE_COMPILERCHECK": "content",
                ]) { _, required in required }
                let productBuild = ChromiumProductBuild(
                    product: product,
                    target: target,
                    sourceRoot: source,
                    buildManifest: manifest,
                    inputRoot: metadata.appending("inputs"),
                    sourceWorkspace: sourceWorkspace,
                    outputWorkspace: outputWorkspace,
                    compilerCacheWorkspace: compilerCacheWorkspace,
                    containerImageID: buildImageID,
                    gnArguments: chromiumGNArguments(
                        product: product,
                        target: target),
                    targets: product == .cef
                        ? ["libcef", "chrome_sandbox"]
                        : ["chrome", "chrome_sandbox"],
                    jobs: UInt32(layout.jobs),
                    environment: productEnvironment)
                var buildBuilder = TaskBuilder(
                    id: ChromiumTaskIDs.build(product, target),
                    component: ComponentID(rawValue: "browser"))
                buildBuilder.consume(sourceProvenance)
                buildBuilder.consume(buildImage)
                let buildArtifact: ArtifactReference<JSONArtifact> =
                    try buildBuilder.output(
                        "build-manifest",
                        path: manifest,
                        validation: .json)
                buildTasks.append(
                    buildBuilder.build(
                        locks: [
                            .shared(
                                cache.appending(
                                    "locks/\(product.rawValue)-"
                                        + "\(target.architecture.rawValue)-build.lock"
                                ))
                        ],
                        action:
                            try AnyColliderAction(
                                BuildChromiumProductAction(
                                    build: productBuild))))

                let distributionRoot = cache.appending(
                    product == .cef
                        ? "dist/\(target.identifier)"
                        : "browser-dist/\(target.identifier)")
                var artifactBuilder = TaskBuilder(
                    id: ChromiumTaskIDs.artifact(product, target),
                    component: ComponentID(rawValue: "browser"))
                artifactBuilder.consume(sourceProvenance)
                artifactBuilder.consume(buildArtifact)
                artifactBuilder.consume(artifactImage)
                let publication: ArtifactReference<PathArtifact> =
                    try artifactBuilder.output(
                        "publication",
                        path: distributionRoot.appending("current"),
                        validation: .symlinkTarget)
                let publicationLock = cache.appending(
                    "locks/\(product.rawValue)-"
                        + "\(target.architecture.rawValue)-publication.lock")
                let artifactAction: AnyColliderAction
                switch product {
                case .cef:
                    artifactAction = try AnyColliderAction(
                        AssembleCEFArtifactAction(
                            assembly: CEFArtifactAssembly(
                                target: target,
                                chromiumSource: chromiumSource,
                                buildManifest: manifest,
                                sourceWorkspace: sourceWorkspace,
                                outputWorkspace: outputWorkspace,
                                artifactImageID: artifactImageID,
                                distributionRoot: distributionRoot,
                                cefCheckout: cefRepository.commit,
                                chromiumVersion: sourceLock.chromiumVersion,
                                environment: productEnvironment)))
                case .browser:
                    artifactAction = try AnyColliderAction(
                        AssembleBrowserArtifactAction(
                            assembly: BrowserArtifactAssembly(
                                target: target,
                                chromiumSource: chromiumSource,
                                buildManifest: manifest,
                                sourceWorkspace: sourceWorkspace,
                                outputWorkspace: outputWorkspace,
                                artifactImageID: artifactImageID,
                                distributionRoot: distributionRoot,
                                launcher: chromium.appending(
                                    "launcher/nucleus-browser"),
                                desktopTemplate: chromium.appending(
                                    "share/applications/"
                                        + "dev.nucleus.Browser.desktop.in"),
                                environment: productEnvironment)))
                    browserPublications[target] = publication
                    browserManifests[target] = buildArtifact
                    browserWorkspaces[target] = outputWorkspace
                }
                artifactTasks.append(
                    artifactBuilder.build(
                        inputs: product == .browser
                            ? [
                                .file(
                                    chromium.appending(
                                        "launcher/nucleus-browser")),
                                .file(
                                    chromium.appending(
                                        "share/applications/"
                                            + "dev.nucleus.Browser.desktop.in")),
                            ] : [],
                        locks: [.shared(publicationLock)],
                        action: artifactAction))
                publications.append(publication)
            }
        }
        var retentionBuilder = TaskBuilder(
            id: ChromiumTaskIDs.retention,
            component: ComponentID(rawValue: "browser"))
        for publication in publications {
            retentionBuilder.consume(publication)
        }
        var retentionRules = [
            DirectoryRetentionRule(
                root: sources,
                current: sources.appending("current"),
                retain: ChromiumRetention.sourceRollbackGenerationCount,
                naming: .contentIdentity),
            DirectoryRetentionRule(
                root: sources,
                retain: 0,
                naming: .contentIdentityCandidate),
        ]
        for target in chromiumLinuxTargets {
            let cefDistribution = cache.appending("dist/\(target.identifier)")
            let browserDistribution = cache.appending(
                "browser-dist/\(target.identifier)")
            retentionRules += [
                DirectoryRetentionRule(
                    root: cefDistribution.appending("releases"),
                    current: cefDistribution.appending("current-release"),
                    retain: ChromiumRetention.cefRollbackGenerationCount,
                    naming: .contentIdentity),
                DirectoryRetentionRule(
                    root: cefDistribution.appending("releases"),
                    retain: 0,
                    naming: .contentIdentityCandidate),
                DirectoryRetentionRule(
                    root: browserDistribution.appending("generations"),
                    current: browserDistribution.appending("current"),
                    retain: ChromiumRetention.browserRollbackGenerationCount,
                    naming: .contentIdentity),
                DirectoryRetentionRule(
                    root: browserDistribution.appending("generations"),
                    retain: 0,
                    naming: .contentIdentityCandidate),
            ]
        }
        let retention = retentionBuilder.build(
            locks: [
                .shared(cache.appending("locks/cache-retention.lock")),
                .shared(cache.appending("locks/source.lock")),
            ],
            assessmentPolicy: .always,
            action:
                try AnyColliderAction(
                    PruneChromiumCacheAction(
                        plan: DirectoryRetentionPlan(
                            safetyRoot: cache,
                            rules: retentionRules))))
        var testTasks: [TaskDeclaration] = []
        for target in chromiumLinuxTargets {
            let publication = try required(browserPublications[target])
            let manifest = try required(browserManifests[target])
            let workspace = try required(browserWorkspaces[target])
            var testBuilder = TaskBuilder(
                id: ChromiumTaskIDs.test(target),
                component: ComponentID(rawValue: "browser"))
            testBuilder.consume(publication)
            testBuilder.consume(manifest)
            testBuilder.consume(buildImage)
            testTasks.append(
                testBuilder.build(
                    assessmentPolicy: .always,
                    action:
                        try AnyColliderAction(
                            RunChromiumTestsAction(
                                executions: [
                                    chromiumBuildExecution(
                                        target: target,
                                        imageID: buildImageID,
                                        source: source,
                                        inputRoot: manifest.path
                                            .removingLastComponent()
                                            .appending("inputs"),
                                        sourceWorkspace:
                                            chromiumSourceWorkspace(
                                                target: target),
                                        outputWorkspace: workspace,
                                        compilerCacheWorkspace:
                                            chromiumCompilerCacheWorkspace(
                                                product: .browser,
                                                target: target),
                                        jobs: layout.jobs,
                                        targets: [],
                                        command: [
                                            "test-ozone",
                                            String(layout.jobs),
                                            target.architecture.rawValue,
                                        ],
                                        environment: childEnvironment)
                                ]))))
        }
        let installTarget = ChromiumLinuxTarget(architecture: .x86_64)
        let browserPublication = try required(
            browserPublications[installTarget])
        let browserDistribution = cache.appending(
            "browser-dist/\(installTarget.identifier)")
        var installBuilder = TaskBuilder(
            id: ChromiumTaskIDs.install,
            component: ComponentID(rawValue: "browser"))
        installBuilder.consume(browserPublication)
        let install = installBuilder.build(
            locks: [
                .shared(
                    cache.appending(
                        "locks/browser-\(installTarget.architecture.rawValue)-publication.lock"
                    ))
            ],
            assessmentPolicy: .always,
            action:
                try AnyColliderAction(
                    InstallBrowserAction(
                        installation: BrowserInstallation(
                            distributionRoot: browserDistribution,
                            prefix: layout.installPrefix,
                            environment: childEnvironment))))
        return [
            depotToolsTask, depotBootstrap,
            sourceTask, builderDependencyTask, buildImageTask, artifactImageTask,
        ] + buildTasks + artifactTasks + [retention] + testTasks + [install]
    }

    private static func validateSourceLock(
        _ sourceLock: ChromiumSourceLock
    ) throws {
        let expected:
            [String: (
                path: String,
                remote: String,
                upstream: String
            )] = [
                "chromium": (
                    "chromium/src",
                    "https://github.com/nucleus-os/chromium.git",
                    "https://chromium.googlesource.com/chromium/src.git"
                ),
                "cef": (
                    "chromium/src/cef",
                    "https://github.com/nucleus-os/cef.git",
                    "https://github.com/chromiumembedded/cef.git"
                ),
                "angle": (
                    "chromium/src/third_party/angle",
                    "https://github.com/nucleus-os/angle.git",
                    "https://chromium.googlesource.com/angle/angle.git"
                ),
                "skia": (
                    "chromium/src/third_party/skia",
                    "https://github.com/nucleus-os/skia.git",
                    "https://skia.googlesource.com/skia.git"
                ),
                "v8": (
                    "chromium/src/v8",
                    "https://github.com/nucleus-os/v8.git",
                    "https://chromium.googlesource.com/v8/v8.git"
                ),
                "dawn": (
                    "chromium/src/third_party/dawn",
                    "https://github.com/nucleus-os/dawn.git",
                    "https://dawn.googlesource.com/dawn.git"
                ),
            ]
        guard sourceLock.repositories.count == expected.count,
            sourceLock.cefBranch.allSatisfy(\.isNumber),
            !sourceLock.cefBranch.isEmpty,
            sourceLock.chromiumVersion.split(separator: ".").count == 4,
            sourceLock.buildHostPlatform == "linux-x86_64",
            sourceLock.devtoolsRollupPlatform == "linux-x64-gnu",
            sourceLock.depotTools.remote
                == "https://chromium.googlesource.com/chromium/tools/depot_tools.git",
            isGitObjectID(sourceLock.depotTools.commit)
        else {
            throw ChromiumRecipeFailure.invalidSourceLock
        }
        for repository in sourceLock.repositories {
            guard let requirement = expected[repository.name],
                repository.checkoutPath == requirement.path,
                repository.remote == requirement.remote,
                repository.upstreamRemote == requirement.upstream,
                isGitObjectID(repository.upstreamCommit),
                isGitObjectID(repository.commit),
                isGitObjectID(repository.tree)
            else {
                throw ChromiumRecipeFailure.invalidSourceLock
            }
        }
    }

    private static func isGitObjectID(_ value: String) -> Bool {
        value.utf8.count == 40
            && value.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
            }
    }
}

private func chromiumBuilderDependencyInputs(
    sourceContext: FilePath
) -> [ArtifactInput] {
    [
        "Dependencies.Containerfile",
        "Resolver.Containerfile",
        "builder-inputs.json",
        "packages.txt",
        "resolve-apt-packages.sh",
    ].map { .file(sourceContext.appending($0)) }
}

private struct PrepareChromiumBuilderDependencyImageAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let sourceContext: FilePath
        let inputRoot: FilePath
        let generatedContext: FilePath
        let resolverOutput: FilePath
        let ubuntuSnapshot: String
        let ubuntuSuites: [String]
        let resolverPreparation: OCIImagePreparation
        let dependencyPreparation: OCIImagePreparation

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: sourceContext.string)
            encoder.append(tag: 2, string: inputRoot.string)
            encoder.append(tag: 3, string: generatedContext.string)
            encoder.append(tag: 4, string: resolverOutput.string)
            encoder.append(tag: 7, string: ubuntuSnapshot)
            encoder.append(tag: 8, string: ubuntuSuites.joined(separator: "\n"))
            encoder.append(
                tag: 5,
                nested: OCIImagePreparationActionIdentity(resolverPreparation))
            encoder.append(
                tag: 6,
                nested: OCIImagePreparationActionIdentity(dependencyPreparation))
        }
    }

    static let kind: ActionKind = "browser.prepare-builder-dependency-image"

    let sourceContext: FilePath
    let inputRoot: FilePath
    let generatedContext: FilePath
    let resolverOutput: FilePath
    let ubuntuSnapshot: String
    let ubuntuSuites: [String]
    let initialDownloads: [ChromiumBuilderDownload]
    let resolverPreparation: OCIImagePreparation
    let dependencyPreparation: OCIImagePreparation

    var identity: Identity {
        Identity(
            sourceContext: sourceContext,
            inputRoot: inputRoot,
            generatedContext: generatedContext,
            resolverOutput: resolverOutput,
            ubuntuSnapshot: ubuntuSnapshot,
            ubuntuSuites: ubuntuSuites,
            resolverPreparation: resolverPreparation,
            dependencyPreparation: dependencyPreparation)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            effects: [
                ActionEffect(
                    .read,
                    scope: .input(
                        sourceContext.appending("Dependencies.Containerfile"))),
                ActionEffect(
                    .read,
                    scope: .input(
                        sourceContext.appending("Resolver.Containerfile"))),
                ActionEffect(
                    .read,
                    scope: .input(
                        sourceContext.appending("builder-inputs.json"))),
                ActionEffect(
                    .read,
                    scope: .input(sourceContext.appending("packages.txt"))),
                ActionEffect(
                    .read,
                    scope: .input(
                        sourceContext.appending("resolve-apt-packages.sh"))),
                ActionEffect(.readWrite, scope: .scratch(inputRoot)),
                ActionEffect(.readWrite, scope: .scratch(generatedContext)),
                ActionEffect(.readWrite, scope: .scratch(candidateContext)),
                ActionEffect(.readWrite, scope: .scratch(resolverOutput)),
                ActionEffect(
                    .readWrite,
                    scope: .scratch(resolverPreparation.imageID)),
                ActionEffect(
                    .readWrite,
                    scope: .output(dependencyPreparation.imageID)),
            ],
            lane: .hostExclusive,
            networkAccess: .contentAddressed,
            executionPlatform: .linuxARM64OCI)
    }

    var environment: [String: String] { dependencyPreparation.environment }

    func execute(in context: ActionContext) async throws {
        try context.files.createDirectory(inputRoot)
        try await download(initialDownloads, in: context)
        let indexDownloads = try chromiumBuilderAPTIndexDownloads(
            releases: initialDownloads,
            root: inputRoot,
            files: context.files)
        try await download(indexDownloads, in: context)

        try await context.containers.prepareImage(resolverPreparation)
        try context.files.remove(resolverOutput)
        try context.files.createDirectory(resolverOutput)
        try await context.containers.run(resolverExecution())

        let closure = try String(
            decoding: context.files.read(
                resolverOutput.appending("packages.tsv")),
            as: UTF8.self)
        let packageDownloads = try chromiumBuilderPackageDownloads(
            manifest: closure,
            root: inputRoot)
        try await download(packageDownloads, in: context)
        try assembleContext(
            packageDownloads: packageDownloads,
            files: context.files)
        try await context.containers.prepareImage(dependencyPreparation)
    }

    private func resolverExecution() -> OCIExecution {
        OCIExecution(
            executionPlatform: .linuxARM64OCI,
            artifactTarget: .linuxARM64,
            imageID: resolverPreparation.imageID,
            hostname: "chromium-apt-resolver",
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
                    source: resolverOutput,
                    target: "/output",
                    access: .readWrite),
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
            command: ["/usr/local/bin/resolve-chromium-apt-packages"],
            environment: environment,
            output: .logged)
    }

    private func download(
        _ downloads: [ChromiumBuilderDownload],
        in context: ActionContext
    ) async throws {
        var iterator = downloads.makeIterator()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<min(12, downloads.count) {
                guard let download = iterator.next() else { break }
                group.addTask {
                    try await context.downloads.download(
                        download.specification,
                        to: download.destination)
                }
            }
            while try await group.next() != nil {
                guard let download = iterator.next() else { continue }
                group.addTask {
                    try await context.downloads.download(
                        download.specification,
                        to: download.destination)
                }
            }
        }
    }

    private func assembleContext(
        packageDownloads: [ChromiumBuilderDownload],
        files: ActionFileSystem
    ) throws {
        try files.remove(candidateContext)
        try files.createDirectory(candidateContext)
        try files.copy(
            from: sourceContext.appending("Dependencies.Containerfile"),
            to: candidateContext.appending("Containerfile"))
        for download in packageDownloads {
            guard case .aptPackage(let digest) = download.placement else { continue }
            let destination = candidateContext.appending(
                "inputs/apt/install/\(digest).deb")
            try files.createDirectory(destination.removingLastComponent())
            try files.copy(from: download.destination, to: destination)
        }
        try files.remove(generatedContext)
        try files.move(from: candidateContext, to: generatedContext)
    }

    private var candidateContext: FilePath {
        generatedContext.removingLastComponent().appending(
            "\(generatedContext.lastComponent?.string ?? "dependency-context").candidate")
    }
}

private struct RunChromiumTestsAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let pipeline: OCIExecutionPipelineIdentity

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, nested: pipeline)
        }
    }

    static let kind: ActionKind = "browser.run-tests"

    let pipeline: OCIExecutionPipeline

    init(executions: [OCIExecution]) throws {
        pipeline = try OCIExecutionPipeline(executions)
    }

    var identity: Identity {
        Identity(pipeline: pipeline.identity)
    }

    var requirements: ActionRequirements { pipeline.requirements }

    var environment: [String: String] { pipeline.environment }

    func execute(in context: ActionContext) async throws {
        try await pipeline.execute(in: context)
    }
}

package struct PrepareChromiumDepotToolsAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        let repository: FilePath
        let remote: String
        let commit: String

        package func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: repository.string)
            encoder.append(tag: 2, string: remote)
            encoder.append(tag: 3, string: commit)
        }
    }

    package static let kind: ActionKind = "browser.prepare-depot-tools"

    let repository: FilePath
    let remote: String
    let commit: String
    package let environment: [String: String]

    package init(
        repository: FilePath,
        remote: String,
        commit: String,
        environment: [String: String]
    ) {
        self.repository = repository
        self.remote = remote
        self.commit = commit
        self.environment = environment
    }

    package var identity: Identity {
        Identity(repository: repository, remote: remote, commit: commit)
    }

    package var requirements: ActionRequirements {
        return ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "git",
                    executable: .named("git"),
                    role: .operational)
            ],
            effects: [
                ActionEffect(
                    .readWrite,
                    scope: .checkout(repository.removingLastComponent()))
            ],
            executionPlatform: .macOSARM64Native)
    }

    package func execute(in context: ActionContext) async throws {
        let gitMetadata = repository.appending(".git")
        if try context.files.metadata(for: gitMetadata) == nil {
            guard try context.files.metadata(for: repository) == nil else {
                throw ChromiumDepotToolsFailure.nonGitCheckout(repository)
            }
            try context.files.createDirectory(repository.removingLastComponent())
            try await requireSuccess(
                ["init", repository.string],
                workingDirectory: repository.removingLastComponent(),
                context: context)
            try await requireSuccess(
                ["-C", repository.string, "remote", "add", "origin", remote],
                workingDirectory: repository,
                context: context)
        } else {
            try await requireTrackedCheckoutIsClean(context)
            try await requireSuccess(
                ["-C", repository.string, "remote", "set-url", "origin", remote],
                workingDirectory: repository,
                context: context)
        }

        let object = try await git(
            ["-C", repository.string, "cat-file", "-e", "\(commit)^{commit}"],
            workingDirectory: repository,
            context: context)
        if object.status != 0 {
            try await requireSuccess(
                ["-C", repository.string, "fetch", "--no-tags", "--depth=1", "origin", commit],
                workingDirectory: repository,
                context: context)
        }
        try await requireSuccess(
            ["-C", repository.string, "checkout", "--detach", "--force", commit],
            workingDirectory: repository,
            context: context)
        let resolved = try await git(
            ["-C", repository.string, "rev-parse", "HEAD^{commit}"],
            workingDirectory: repository,
            context: context)
        guard resolved.status == 0,
            resolved.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                == commit
        else {
            throw ChromiumDepotToolsFailure.wrongCommit(
                expected: commit,
                actual: resolved.standardOutput)
        }
        try await requireTrackedCheckoutIsClean(context)
    }

    private func requireTrackedCheckoutIsClean(
        _ context: ActionContext
    ) async throws {
        let status = try await git(
            ["-C", repository.string, "status", "--porcelain", "--untracked-files=no"],
            workingDirectory: repository,
            context: context)
        guard status.status == 0, status.standardOutput.isEmpty else {
            throw ChromiumDepotToolsFailure.trackedModifications(repository)
        }
    }

    private func requireSuccess(
        _ arguments: [String],
        workingDirectory: FilePath,
        context: ActionContext
    ) async throws {
        let result = try await git(
            arguments,
            workingDirectory: workingDirectory,
            context: context)
        guard result.succeeded else {
            throw result.executionFailure(reason: "depot_tools git command failed")
        }
    }

    private func git(
        _ arguments: [String],
        workingDirectory: FilePath,
        context: ActionContext
    ) async throws -> CommandResult {
        try await context.commands.execute(
            CommandSpec(
                executable: .named("git"),
                arguments: arguments,
                workingDirectory: workingDirectory,
                environment: environment,
                output: .captured(limit: 4 * 1_024 * 1_024)))
    }
}

private enum ChromiumDepotToolsFailure: Error {
    case nonGitCheckout(FilePath)
    case trackedModifications(FilePath)
    case wrongCommit(expected: String, actual: String)
}

private struct PruneChromiumCacheAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let plan: DirectoryRetentionPlan

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: plan.safetyRoot.string)
            encoder.append(
                tag: 2,
                string: plan.rules.map {
                    [
                        $0.root.string,
                        $0.current?.string ?? "",
                        String($0.retain),
                        $0.naming.rawValue,
                    ].joined(separator: "\u{0}")
                }.joined(separator: "\u{1}"))
        }
    }

    static let kind: ActionKind = "browser.prune-cache"

    let plan: DirectoryRetentionPlan

    var identity: Identity { Identity(plan: plan) }

    var requirements: ActionRequirements {
        var effects: [ActionEffect] = []
        for rule in plan.rules {
            let effect = ActionEffect(.readWrite, scope: .scratch(rule.root))
            if !effects.contains(effect) { effects.append(effect) }
        }
        return ActionRequirements(
            effects: effects,
            executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        try context.files.pruneDirectories(plan)
    }
}

private struct BootstrapChromiumDepotToolsAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let executable: FilePath
        let repository: FilePath

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: executable.string)
            encoder.append(tag: 2, string: repository.string)
        }
    }

    static let kind: ActionKind = "browser.bootstrap-depot-tools"

    let executable: FilePath
    let repository: FilePath
    let environment: [String: String]

    var identity: Identity {
        Identity(executable: executable, repository: repository)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "ensure-bootstrap",
                    executable: .taskOutput(executable),
                    role: .operational)
            ],
            effects: [
                ActionEffect(.readWrite, scope: .checkout(repository))
            ],
            executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        let result = try await context.commands.execute(
            CommandSpec(
                executable: .taskOutput(executable),
                arguments: [],
                workingDirectory: repository,
                environment: environment))
        guard result.succeeded else {
            throw result.executionFailure(reason: "Chromium bootstrap failed")
        }
    }
}

private func chromiumBuildExecution(
    target: ChromiumLinuxTarget,
    imageID: FilePath,
    source: FilePath,
    inputRoot: FilePath,
    sourceWorkspace: PersistentWorkspaceDeclaration,
    outputWorkspace: PersistentWorkspaceDeclaration,
    compilerCacheWorkspace: PersistentWorkspaceDeclaration,
    jobs: Int,
    targets: [String],
    command: [String]? = nil,
    environment: [String: String]
) -> OCIExecution {
    OCIExecution(
        executionPlatform: .linuxARM64OCI,
        artifactTarget: target.artifactTarget,
        imageID: imageID,
        hostname: "chromium-build",
        workingDirectory: "/source/chromium/src",
        hostWorkingDirectory: source.appending("chromium/src"),
        mounts: [
            OCIMount(
                source: inputRoot,
                target: "/inputs",
                access: .readOnly)
        ],
        persistentWorkspaceMounts: [
            OCIPersistentWorkspaceMount(
                workspace: sourceWorkspace,
                target: "/source",
                access: .readOnly),
            OCIPersistentWorkspaceMount(
                workspace: outputWorkspace,
                target: "/build",
                access: .readWrite),
            OCIPersistentWorkspaceMount(
                workspace: compilerCacheWorkspace,
                target: "/ccache",
                access: .readWrite),
        ],
        temporaryDirectory: inputRoot.removingLastComponent().appending(
            ".temporary"),
        userPolicy: .builder,
        capabilityPolicy: .dropAll,
        privilegePolicy: .prohibitAcquisition,
        processFilesystemPolicy: .standard,
        intelBinaryTranslationPolicy: .required,
        resourceLimits: .parallelBuild,
        containerEnvironment: [
            "DEPOT_TOOLS_UPDATE": "0",
            "HOME": "/tmp/nucleus-home",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PYTHONDONTWRITEBYTECODE": "1",
            "TZ": "UTC",
            "CCACHE_DIR": "/ccache",
            "CCACHE_MAXSIZE": "30G",
            "CCACHE_COMPILERCHECK": "content",
        ],
        command: command ?? ["build", String(jobs)] + targets,
        environment: environment,
        output: .logged)
}

private enum ChromiumRecipeFailure: Error {
    case invalidSourceLock
}

private func required<Value>(_ value: Value?) throws -> Value {
    guard let value else { throw ChromiumRecipeFailure.invalidSourceLock }
    return value
}

package func chromiumGNArguments(
    product: ChromiumProduct,
    target: ChromiumLinuxTarget
) -> String {
    let base = product == .cef ? cefGNArguments : browserGNArguments
    return
        base
        .replacingOccurrences(of: #"cc_wrapper="""#, with: #"cc_wrapper="ccache""#)
        .replacingOccurrences(
            of: #"target_cpu="x64""#,
            with: #"target_cpu="\#(target.gnCPU)""#
        )
        .replacingOccurrences(
            of: "chrome_pgo_phase=2",
            with: target.architecture == .x86_64
                ? "chrome_pgo_phase=2"
                : "chrome_pgo_phase=0")
}

private let cefGNArguments =
    #"angle_enable_swiftshader=false blink_heap_inside_shared_library=true cc_wrapper="" chrome_pgo_phase=2 clang_base_path="//third_party/llvm-build/Linux_x64" clang_use_chrome_plugins=false dcheck_always_on=false disable_fieldtrial_testing_config=true enable_background_mode=false enable_backup_ref_ptr_support=false enable_downgrade_processing=false enable_expensive_dchecks=false enable_linux_installer=false enable_precompiled_headers=false enable_resource_allowlist_generation=false enable_swiftshader=false enable_swiftshader_vulkan=false enable_widevine=true ffmpeg_branding="Chrome" forbid_non_component_debug_builds=false is_component_build=false is_debug=false is_official_build=true optimize_webui=true ozone_platform="wayland" ozone_platform_wayland=true ozone_platform_x11=false proprietary_codecs=true symbol_level=0 target_cpu="x64" thin_lto_enable_optimizations=true treat_warnings_as_errors=false use_allocator_shim=false use_dbus=true use_lld=true use_mold=false use_partition_alloc_as_malloc=false use_qt5=false use_qt6=false use_siso=true use_sysroot=true use_thin_lto=true use_unified_system_module=false"#

private let browserGNArguments =
    #"proprietary_codecs=true ffmpeg_branding="Chrome" is_chrome_branded=false enable_cef=false use_dbus=true enable_widevine=true is_official_build=true is_component_build=false symbol_level=0 dcheck_always_on=false enable_expensive_dchecks=false chrome_pgo_phase=2 use_thin_lto=true thin_lto_enable_optimizations=true use_mold=false use_lld=true use_siso=true cc_wrapper="" use_allocator_shim=true use_partition_alloc_as_malloc=true enable_backup_ref_ptr_support=true enable_swiftshader=false enable_swiftshader_vulkan=false angle_enable_swiftshader=false treat_warnings_as_errors=false clang_base_path="//third_party/llvm-build/Linux_x64" clang_use_chrome_plugins=false ozone_platform="wayland" ozone_platform_wayland=true ozone_platform_x11=false use_sysroot=true target_cpu="x64""#
