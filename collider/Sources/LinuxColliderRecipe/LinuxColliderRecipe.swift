import ChromiumColliderRecipe
import ColliderCore
import LinuxPackageContracts
import NativeBuilderColliderRecipe
import ShellColliderRecipe
import SystemPackage

package enum LinuxEntrypoints {
    package static let packageRuntime = ComponentEntrypointID(
        rawValue: "package.linux-runtime")
    package static let runtimeArtifact = ComponentEntrypointID(
        rawValue: "artifact.runtime")
    package static let testGPUHeadless = ComponentEntrypointID(
        rawValue: "test.gpu-headless")
}

package enum LinuxTaskIDs {
    package static let packageSourceSnapshot = TaskID(
        rawValue: "linux.package-source-snapshot")

    package static func build(_ architecture: PlatformArchitecture) -> TaskID {
        TaskID(rawValue: "linux.\(architecture.rawValue).build")
    }

    package static func test(_ architecture: PlatformArchitecture) -> TaskID {
        TaskID(rawValue: "linux.\(architecture.rawValue).test")
    }

    package static func testLoader(_ architecture: PlatformArchitecture) -> TaskID {
        TaskID(rawValue: "linux.\(architecture.rawValue).test-loader")
    }

    package static func testGPUHeadless(_ architecture: PlatformArchitecture) -> TaskID {
        TaskID(rawValue: "linux.\(architecture.rawValue).test-gpu-headless")
    }

    package static func runtimeArtifact(
        _ architecture: PlatformArchitecture
    ) -> TaskID {
        TaskID(rawValue: "linux.\(architecture.rawValue).runtime-artifact")
    }

    package static func packageCohort(
        _ architecture: PlatformArchitecture
    ) -> TaskID {
        TaskID(rawValue: "linux.\(architecture.rawValue).package-cohort")
    }

    package static func packagePayload(
        _ architecture: PlatformArchitecture,
        _ package: LinuxNativePackageName
    ) -> TaskID {
        TaskID(
            rawValue:
                "linux.\(architecture.rawValue).package-payload.\(package.rawValue)")
    }

    package static func packageControlPayloads(
        _ architecture: PlatformArchitecture
    ) -> TaskID {
        TaskID(
            rawValue:
                "linux.\(architecture.rawValue).package-control-payloads")
    }

    package static func packageAdapter(
        _ architecture: PlatformArchitecture,
        _ family: LinuxDistributionFamily,
        _ package: LinuxNativePackageName
    ) -> TaskID {
        TaskID(
            rawValue:
                "linux.\(architecture.rawValue).package-adapter."
                + "\(family.rawValue).\(package.rawValue)")
    }

    package static func packageControlAdapters(
        _ architecture: PlatformArchitecture
    ) -> TaskID {
        TaskID(
            rawValue:
                "linux.\(architecture.rawValue).package-control-adapters")
    }

    package static func payloadProducer(
        _ architecture: PlatformArchitecture,
        _ package: LinuxNativePackageName
    ) -> TaskID {
        package.isControlOnly
            ? packageControlPayloads(architecture)
            : packagePayload(architecture, package)
    }

    package static func adapterProducer(
        _ architecture: PlatformArchitecture,
        _ family: LinuxDistributionFamily,
        _ package: LinuxNativePackageName
    ) -> TaskID {
        package.isControlOnly
            ? packageControlAdapters(architecture)
            : packageAdapter(architecture, family, package)
    }

    package static func packageProductPublication(
        _ architecture: PlatformArchitecture
    ) -> TaskID {
        TaskID(
            rawValue:
                "linux.\(architecture.rawValue).package-product-publication")
    }

    package static func packageLifecycleQualification(
        _ architecture: PlatformArchitecture
    ) -> TaskID {
        TaskID(
            rawValue:
                "linux.\(architecture.rawValue).package-lifecycle-qualification")
    }

    package static let packageStorageRetention = TaskID(
        rawValue: "linux.package-storage-retention")
}

private let linuxSwiftPMExecutionLock = TaskLock.checkout(
    "linux-swiftpm-execution")

package struct LinuxRuntimeArtifactLane: Sendable {
    package let runtimeSwiftPM: SwiftPMInvocation
    package let artifactRoot: FilePath
    package let packageRoot: FilePath
    package let packageWorkRoot: FilePath
    package let productPublicationRoot: FilePath
    package let qualificationRoot: FilePath

    package init(
        runtimeSwiftPM: SwiftPMInvocation,
        artifactRoot: FilePath,
        packageRoot: FilePath,
        packageWorkRoot: FilePath,
        productPublicationRoot: FilePath,
        qualificationRoot: FilePath
    ) {
        self.runtimeSwiftPM = runtimeSwiftPM
        self.artifactRoot = artifactRoot
        self.packageRoot = packageRoot
        self.packageWorkRoot = packageWorkRoot
        self.productPublicationRoot = productPublicationRoot
        self.qualificationRoot = qualificationRoot
    }
}

package struct LinuxRuntimeArtifactConfiguration: RecipeConfiguration {
    package let lanes: [PlatformArchitecture: LinuxRuntimeArtifactLane]
    package let browserPackageInputs: [PlatformArchitecture: ChromiumColliderRecipe.PackageInput]
    /// One produced package input per architecture. There is no default: an
    /// architecture whose Android input no task produces is not packaged.
    package let androidPackageInputs: [PlatformArchitecture: ArtifactReference]
    package let assemblerSwiftPM: SwiftPMInvocation
    package let packageSourceSnapshotRoot: FilePath
    package let productStoreRoot: FilePath
    package let sessionPackage: FilePath
    /// Where declared placement roots put every path these executions name.
    package let placement: IdentityPathMap
    package let environment: [String: String]

    package init(
        lanes: [PlatformArchitecture: LinuxRuntimeArtifactLane],
        browserPackageInputs:
            [PlatformArchitecture: ChromiumColliderRecipe.PackageInput],
        androidPackageInputs: [PlatformArchitecture: ArtifactReference],
        assemblerSwiftPM: SwiftPMInvocation,
        packageSourceSnapshotRoot: FilePath,
        productStoreRoot: FilePath,
        sessionPackage: FilePath,
        placement: IdentityPathMap,
        environment: [String: String]
    ) {
        self.lanes = lanes
        self.browserPackageInputs = browserPackageInputs
        self.androidPackageInputs = androidPackageInputs
        self.assemblerSwiftPM = assemblerSwiftPM
        self.packageSourceSnapshotRoot = packageSourceSnapshotRoot
        self.productStoreRoot = productStoreRoot
        self.sessionPackage = sessionPackage
        self.placement = placement
        self.environment = environment
    }
}

public enum LinuxColliderRecipe: ColliderComponent {
    static let rollbackGenerationCount: UInt32 = 1

    public static let descriptor = ComponentDescriptor(
        id: ComponentID(rawValue: "linux"),
        canonicalName: "linux",
        directoryName: ".")

    public static func makeComponent(
        in context: RecipeContext
    ) throws -> ComponentDefinition {
        let native = try context.configuration(
            NativeBuilderGraphConfiguration.self,
            for: NativeBuilderColliderRecipe.descriptor.id)
        let runtimeArtifact = try context.configuration(
            LinuxRuntimeArtifactConfiguration.self,
            for: descriptor.id)
        var tasks: [TaskDeclaration] = []
        var buildRoots: Set<TaskID> = []
        var testRoots: Set<TaskID> = []
        var loaderRoots: Set<TaskID> = []
        var headlessRoots: Set<TaskID> = []
        var runtimeArtifactTasks: Set<TaskID> = []
        var packageTasks: Set<TaskID> = []
        var packagePublications: [PreparedNativePackages] = []
        var packageQualifications: [PreparedPackageQualification] = []
        let packageSourceSnapshot = try packageSourceSnapshotTask(
            configuration: runtimeArtifact)
        tasks.append(packageSourceSnapshot.task)
        for architecture in PlatformArchitecture.allCases {
            let target = NativeLinuxTarget(architecture: architecture)
            tasks += try architectureLane(
                architecture: architecture,
                root: context.repositoryRoot,
                environment: context.environment,
                swiftPM: try context.swiftPM(.linux(architecture)),
                targetArtifacts: try native.artifacts(for: target))
            buildRoots.insert(LinuxTaskIDs.build(architecture))
            if architecture == .arm64 {
                testRoots.insert(LinuxTaskIDs.test(architecture))
                loaderRoots.insert(LinuxTaskIDs.testLoader(architecture))
                headlessRoots.insert(LinuxTaskIDs.testGPUHeadless(architecture))
            }
            guard let lane = runtimeArtifact.lanes[architecture] else {
                throw LinuxRuntimeArtifactFailure.missingArchitecture(architecture)
            }
            let artifact = try runtimeArtifactTask(
                architecture: architecture,
                lane: lane,
                configuration: runtimeArtifact,
                targetArtifacts: try native.artifacts(for: target))
            tasks.append(artifact.task)
            runtimeArtifactTasks.insert(artifact.task.id)
            guard let browser = runtimeArtifact.browserPackageInputs[architecture]
            else {
                throw LinuxRuntimeArtifactFailure.missingBrowser(architecture)
            }
            guard
                let androidPackageInput =
                    runtimeArtifact.androidPackageInputs[architecture]
            else {
                throw LinuxRuntimeArtifactFailure.missingAndroidPackageInput(
                    architecture)
            }
            var payloads: [PreparedNativePackagePayload] = []
            for package in LinuxNativePackageName.allCases
            where !package.isControlOnly {
                let payload = try packagePayloadTask(
                    architecture: architecture,
                    package: package,
                    lane: lane,
                    runtime: artifact,
                    browser: browser,
                    androidPackageInput: androidPackageInput,
                    configuration: runtimeArtifact)
                tasks.append(payload.task)
                payloads.append(payload)
            }
            let controlPayloads = try packageControlPayloadsTask(
                architecture: architecture,
                lane: lane,
                runtime: artifact,
                browser: browser,
                configuration: runtimeArtifact)
            tasks.append(controlPayloads.task)
            payloads += controlPayloads.payloads
            var adapters: [PreparedNativePackageAdapter] = []
            for family in LinuxDistributionFamily.allCases {
                for payload in payloads where !payload.package.isControlOnly {
                    let adapter = try packageAdapterTask(
                        architecture: architecture,
                        family: family,
                        payload: payload,
                        lane: lane,
                        runtime: artifact,
                        browser: browser,
                        configuration: runtimeArtifact)
                    tasks.append(adapter.task)
                    adapters.append(adapter)
                }
            }
            let controlAdapters = try packageControlAdaptersTask(
                architecture: architecture,
                payloads: controlPayloads.payloads,
                lane: lane,
                runtime: artifact,
                browser: browser,
                configuration: runtimeArtifact)
            tasks.append(controlAdapters.task)
            adapters += controlAdapters.adapters
            let nativePackages = try packageTask(
                architecture: architecture,
                lane: lane,
                runtime: artifact,
                browser: browser,
                adapters: adapters,
                sourceSnapshot: packageSourceSnapshot.snapshot,
                configuration: runtimeArtifact)
            tasks.append(nativePackages.task)
            packagePublications.append(nativePackages)
            let productPublication = try packageProductPublicationTask(
                architecture: architecture,
                lane: lane,
                packages: nativePackages,
                configuration: runtimeArtifact)
            tasks.append(productPublication.task)
            let qualification = try packageQualificationTask(
                architecture: architecture,
                lane: lane,
                packages: nativePackages,
                productPublication: productPublication,
                configuration: runtimeArtifact)
            tasks.append(qualification.task)
            packageQualifications.append(qualification)
        }
        let packageStorageRetention = try packageStorageRetentionTask(
            publications: packagePublications,
            qualifications: packageQualifications,
            configuration: runtimeArtifact)
        tasks.append(packageStorageRetention)
        packageTasks.insert(packageStorageRetention.id)
        var storage: [StorageDeclaration] = []
        storage.append(
            StorageDeclaration(
                id: "linux-package-source-snapshot",
                owner: descriptor.id,
                producers: [.task(LinuxTaskIDs.packageSourceSnapshot)],
                storageClass: .cache,
                root: runtimeArtifact.packageSourceSnapshotRoot,
                safetyRoot: runtimeArtifact.packageSourceSnapshotRoot
                    .removingLastComponent(),
                retentionPolicy: .singleWorkingSet))
        storage.append(
            StorageDeclaration(
                id: "product-artifact-store",
                owner: descriptor.id,
                producers: Set(
                    PlatformArchitecture.allCases.map {
                        StorageProducer.task(
                            LinuxTaskIDs.packageProductPublication($0))
                    } + [.task(LinuxTaskIDs.packageStorageRetention)]),
                storageClass: .published,
                root: runtimeArtifact.productStoreRoot,
                safetyRoot: runtimeArtifact.productStoreRoot.removingLastComponent(),
                retentionPolicy: .protected))
        for architecture in PlatformArchitecture.allCases {
            guard let lane = runtimeArtifact.lanes[architecture] else {
                throw LinuxRuntimeArtifactFailure.missingArchitecture(architecture)
            }
            let task = LinuxTaskIDs.runtimeArtifact(architecture)
            let packageTask = LinuxTaskIDs.packageCohort(architecture)
            let productPublicationTask =
                LinuxTaskIDs.packageProductPublication(architecture)
            let payloadPackages = LinuxNativePackageName.allCases
            let payloadProducers = Set(
                payloadPackages.map {
                    StorageProducer.task(
                        LinuxTaskIDs.payloadProducer(architecture, $0))
                }
                    + payloadPackages.flatMap { package in
                        LinuxDistributionFamily.allCases.map { family in
                            StorageProducer.task(
                                LinuxTaskIDs.adapterProducer(
                                    architecture,
                                    family,
                                    package))
                        }
                    })
            storage += [
                StorageDeclaration(
                    id: "linux-\(architecture.rawValue)-native-package-work",
                    owner: descriptor.id,
                    producers: payloadProducers,
                    storageClass: .published,
                    root: lane.packageWorkRoot,
                    safetyRoot: lane.packageWorkRoot.removingLastComponent(),
                    retentionPolicy: .protected),
                StorageDeclaration(
                    id: "linux-\(architecture.rawValue)-runtime-artifact-root",
                    owner: descriptor.id,
                    producers: [.task(task)],
                    storageClass: .published,
                    root: lane.artifactRoot,
                    safetyRoot: lane.artifactRoot.removingLastComponent(),
                    retentionPolicy: .protected),
                StorageDeclaration(
                    id: "linux-\(architecture.rawValue)-runtime-generations",
                    owner: descriptor.id,
                    producers: [.task(task)],
                    storageClass: .generation,
                    root: lane.artifactRoot.appending("generations"),
                    safetyRoot: lane.artifactRoot,
                    retentionPolicy: .keepActiveAndRollback(
                        count: rollbackGenerationCount),
                    activeGenerationLink: lane.artifactRoot.appending("current"),
                    generationNaming: .contentIdentity,
                    interruptedCandidateNaming: nil),
                StorageDeclaration(
                    id: "linux-\(architecture.rawValue)-package-manifest-generations",
                    owner: descriptor.id,
                    producers: [.task(task)],
                    storageClass: .generation,
                    root: lane.artifactRoot.appending("package-manifests"),
                    safetyRoot: lane.artifactRoot,
                    retentionPolicy: .keepActiveAndRollback(
                        count: rollbackGenerationCount),
                    activeGenerationLink: lane.artifactRoot.appending(
                        "package-manifests/current"),
                    generationNaming: .contentIdentity,
                    interruptedCandidateNaming: nil),
                StorageDeclaration(
                    id: "linux-\(architecture.rawValue)-native-package-root",
                    owner: descriptor.id,
                    producers: [
                        .task(packageTask),
                        .task(LinuxTaskIDs.packageStorageRetention),
                    ],
                    storageClass: .published,
                    root: lane.packageRoot,
                    safetyRoot: lane.packageRoot.removingLastComponent(),
                    retentionPolicy: .protected),
                StorageDeclaration(
                    id: "linux-\(architecture.rawValue)-native-package-generations",
                    owner: descriptor.id,
                    producers: [
                        .task(packageTask),
                        .task(LinuxTaskIDs.packageStorageRetention),
                    ],
                    storageClass: .generation,
                    root: lane.packageRoot.appending("generations"),
                    safetyRoot: lane.packageRoot,
                    retentionPolicy: .keepActiveAndRollback(
                        count: rollbackGenerationCount),
                    activeGenerationLink: lane.packageRoot.appending("current"),
                    generationNaming: .artifactDigestDirectory,
                    interruptedCandidateNaming: DirectoryNamePattern(
                        rawValue: #"^\.candidate$"#)),
                StorageDeclaration(
                    id:
                        "linux-\(architecture.rawValue)-package-product-publication",
                    owner: descriptor.id,
                    producers: [.task(productPublicationTask)],
                    storageClass: .published,
                    root: lane.productPublicationRoot,
                    safetyRoot: lane.productPublicationRoot.removingLastComponent(),
                    retentionPolicy: .singleWorkingSet),
                StorageDeclaration(
                    id:
                        "linux-\(architecture.rawValue)-native-package-qualification",
                    owner: descriptor.id,
                    producers: [
                        .task(
                            LinuxTaskIDs.packageLifecycleQualification(
                                architecture))
                    ],
                    storageClass: .published,
                    root: lane.qualificationRoot,
                    safetyRoot: lane.qualificationRoot.removingLastComponent(),
                    retentionPolicy: .singleWorkingSet),
            ]
            storage += payloadPackages.map { package in
                let root = lane.packageWorkRoot.appending(
                    "payloads/\(package.rawValue)")
                return StorageDeclaration(
                    id:
                        "linux-\(architecture.rawValue)-native-package-payload-"
                        + package.rawValue,
                    owner: descriptor.id,
                    producers: [
                        .task(LinuxTaskIDs.payloadProducer(architecture, package))
                    ],
                    storageClass: .generation,
                    root: root.appending("generations"),
                    safetyRoot: root,
                    retentionPolicy: .keepActiveAndRollback(count: 0),
                    activeGenerationLink: root.appending("current"),
                    generationNaming: .artifactDigestDirectory,
                    interruptedCandidateNaming: DirectoryNamePattern(
                        rawValue: #"^\.candidate$"#))
            }
            storage += payloadPackages.flatMap { package in
                LinuxDistributionFamily.allCases.map { family in
                    let root = lane.packageWorkRoot.appending(
                        "adapters/\(family.rawValue)/\(package.rawValue)")
                    return StorageDeclaration(
                        id:
                            "linux-\(architecture.rawValue)-native-package-adapter-"
                            + "\(family.rawValue)-\(package.rawValue)",
                        owner: descriptor.id,
                        producers: [
                            .task(
                                LinuxTaskIDs.adapterProducer(
                                    architecture,
                                    family,
                                    package))
                        ],
                        storageClass: .generation,
                        root: root.appending("generations"),
                        safetyRoot: root,
                        retentionPolicy: .keepActiveAndRollback(count: 0),
                        activeGenerationLink: root.appending("current"),
                        generationNaming: .artifactDigestDirectory,
                        interruptedCandidateNaming: DirectoryNamePattern(
                            rawValue: #"^\.candidate$"#))
                }
            }
        }
        return try ComponentDefinition(
            descriptor: descriptor,
            tasks: tasks,
            entrypoints: [
                ComponentEntrypoint(id: .build, roots: buildRoots),
                ComponentEntrypoint(id: .testDefault, roots: testRoots),
                ComponentEntrypoint(
                    id: LinuxEntrypoints.runtimeArtifact,
                    roots: runtimeArtifactTasks),
                ComponentEntrypoint(
                    id: LinuxEntrypoints.packageRuntime,
                    roots: packageTasks),
                ComponentEntrypoint(
                    id: LinuxEntrypoints.testGPUHeadless,
                    roots: headlessRoots),
                ComponentEntrypoint(
                    id: ComponentEntrypointID(rawValue: "test.loader"),
                    roots: loaderRoots),
            ],
            storage: storage)
    }

    private struct PreparedRuntimeArtifact {
        let task: TaskDeclaration
        let runtime: ArtifactReference
        let packageManifests: ArtifactReference
    }

    private struct PreparedPackageSourceSnapshot {
        let task: TaskDeclaration
        let snapshot: ArtifactReference
    }

    private struct PreparedNativePackages {
        let task: TaskDeclaration
        let publication: ArtifactReference
    }

    private struct PreparedNativePackagePayload {
        let package: LinuxNativePackageName
        let task: TaskDeclaration
        let payload: ArtifactReference
    }

    private struct PreparedControlPayloads {
        let task: TaskDeclaration
        let payloads: [PreparedNativePackagePayload]
    }

    private struct PreparedNativePackageAdapter {
        let family: LinuxDistributionFamily
        let package: LinuxNativePackageName
        let task: TaskDeclaration
        let publication: ArtifactReference
    }

    private struct PreparedControlAdapters {
        let task: TaskDeclaration
        let adapters: [PreparedNativePackageAdapter]
    }

    private struct PreparedPublishedNativePackages {
        let task: TaskDeclaration
        let receipt: ArtifactReference
    }

    private struct PreparedPackageQualification {
        let task: TaskDeclaration
        let report: ArtifactReference
    }

    private static func packageSourceSnapshotTask(
        configuration: LinuxRuntimeArtifactConfiguration
    ) throws -> PreparedPackageSourceSnapshot {
        let repositoryRoot = configuration.assemblerSwiftPM.context.packageRoot
            .removingLastComponent()
        let sourcePaths = configuration.assemblerSwiftPM.sourceGraph.sourcePaths(
            forProduct: "nucleus-linux-assembler")
        let output = configuration.packageSourceSnapshotRoot.appending(
            "source-snapshot.json")
        var builder = TaskBuilder(
            id: LinuxTaskIDs.packageSourceSnapshot,
            component: descriptor.id)
        let snapshot: ArtifactReference = try builder.output(
            "source-snapshot",
            path: output,
            validation: .regularFile)
        let task = builder.build(
            inputs: [
                .sourceCheckoutClosure(sourcePaths),
                .environment(
                    name: "NUCLEUS_PRODUCT_SOURCE_AUTHORITY",
                    value: configuration.environment[
                        "NUCLEUS_PRODUCT_SOURCE_AUTHORITY"]),
                .environment(
                    name: "NUCLEUS_PRODUCT_SOURCE_COMMIT",
                    value: configuration.environment[
                        "NUCLEUS_PRODUCT_SOURCE_COMMIT"]),
                .environment(
                    name: "NUCLEUS_PRODUCT_SOURCE_REF",
                    value: configuration.environment[
                        "NUCLEUS_PRODUCT_SOURCE_REF"]),
            ],
            locks: [
                .shared(
                    configuration.packageSourceSnapshotRoot.appending(
                        ".publish.lock"))
            ],
            assessmentPolicy: .incremental,
            action: try AnyColliderAction(
                CaptureLinuxPackageSourceSnapshotAction(
                    repositoryRoot: repositoryRoot,
                    sourcePaths: sourcePaths,
                    output: output,
                    sourceAuthority: configuration.environment[
                        "NUCLEUS_PRODUCT_SOURCE_AUTHORITY"],
                    assertedCommit: configuration.environment[
                        "NUCLEUS_PRODUCT_SOURCE_COMMIT"],
                    assertedBranch: configuration.environment[
                        "NUCLEUS_PRODUCT_SOURCE_REF"])))
        return PreparedPackageSourceSnapshot(task: task, snapshot: snapshot)
    }

    private static func runtimeArtifactTask(
        architecture: PlatformArchitecture,
        lane: LinuxRuntimeArtifactLane,
        configuration: LinuxRuntimeArtifactConfiguration,
        targetArtifacts: ArtifactReferenceSet
    ) throws -> PreparedRuntimeArtifact {
        let products = [
            "NucleusCompositor",
            "NucleusSessionSupervisor",
            "NucleusConfigService",
            "NucleusControlService",
            "NucleusShell",
            "NucleusShellPamHelper",
            "nucleus",
        ]
        let runtimeRequirements = products.map { product in
            lane.runtimeSwiftPM.product(
                package: "nucleus",
                product: product,
                packageRoot: lane.runtimeSwiftPM.context.packageRoot,
                environment: configuration.environment,
                expectedOutputs: [
                    PathPostcondition(
                        path: lane.runtimeSwiftPM.executable(product),
                        validation: .executableFile)
                ])
        }
        let runtimePublisher = configuration.assemblerSwiftPM.product(
            package: "collider-cli",
            product: "nucleus-linux-runtime-publisher",
            packageRoot: configuration.assemblerSwiftPM.context.packageRoot,
            environment: configuration.environment,
            expectedOutputs: [
                PathPostcondition(
                    path: configuration.assemblerSwiftPM.executable(
                        "nucleus-linux-runtime-publisher"),
                    validation: .executableFile)
            ])
        let generations = lane.artifactRoot.appending("generations")
        let packageManifests = lane.artifactRoot.appending(
            "package-manifests")
        var builder = TaskBuilder(
            id: LinuxTaskIDs.runtimeArtifact(architecture),
            component: descriptor.id)
        builder.consume(targetArtifacts)
        guard
            case .oci(let runtimeOCI) =
                lane.runtimeSwiftPM.context.execution
        else {
            throw LinuxRuntimeArtifactFailure.requiresOCI
        }
        builder.consume(runtimeOCI.image)
        let runtime: ArtifactReference = try builder.output(
            "runtime",
            path: lane.artifactRoot.appending("current"),
            validation: .symlinkTarget)
        let packageManifestOutput: ArtifactReference = try builder.output(
            "package-manifests",
            path: packageManifests.appending("current"),
            validation: .symlinkTarget)
        let task = builder.build(
            swiftProducts: runtimeRequirements + [runtimePublisher],
            inputs: RuntimeHostIntegration.sourceFiles.map {
                .file(configuration.sessionPackage.appending($0))
            } + [
                lane.runtimeSwiftPM.identityInput,
                configuration.assemblerSwiftPM.identityInput,
            ],
            locks: [
                .shared(lane.artifactRoot.appending(".publish.lock"))
            ],
            action: try AnyColliderAction(
                PublishLinuxRuntimeArtifactAction(
                    runtimeSwiftPM: lane.runtimeSwiftPM,
                    assemblerSwiftPM: configuration.assemblerSwiftPM,
                    architecture: architecture,
                    artifactRoot: lane.artifactRoot,
                    generationsRoot: generations,
                    packageManifestsRoot: packageManifests,
                    rollbackGenerationCount: rollbackGenerationCount,
                    sessionPackage: configuration.sessionPackage,
                    placement: configuration.placement,
                    environment: configuration.environment)))
        return PreparedRuntimeArtifact(
            task: task,
            runtime: runtime,
            packageManifests: packageManifestOutput)
    }

    private static func packageTask(
        architecture: PlatformArchitecture,
        lane: LinuxRuntimeArtifactLane,
        runtime: PreparedRuntimeArtifact,
        browser: ChromiumColliderRecipe.PackageInput,
        adapters: [PreparedNativePackageAdapter],
        sourceSnapshot: ArtifactReference,
        configuration: LinuxRuntimeArtifactConfiguration
    ) throws -> PreparedNativePackages {
        let assembler = configuration.assemblerSwiftPM.product(
            package: "collider-cli",
            product: "nucleus-linux-assembler",
            packageRoot: configuration.assemblerSwiftPM.context.packageRoot,
            environment: configuration.environment,
            expectedOutputs: [
                PathPostcondition(
                    path: configuration.assemblerSwiftPM.executable(
                        "nucleus-linux-assembler"),
                    validation: .executableFile)
            ])
        guard
            case .oci(let assemblerOCI) =
                configuration.assemblerSwiftPM.context.execution
        else {
            throw LinuxRuntimeArtifactFailure.requiresOCI
        }
        var builder = TaskBuilder(
            id: LinuxTaskIDs.packageCohort(architecture),
            component: descriptor.id)
        builder.consume(runtime.runtime)
        builder.consume(runtime.packageManifests)
        builder.consume(browser.reference)
        builder.consume(browser.payloadReference)
        for adapter in adapters {
            builder.consume(adapter.publication)
        }
        builder.consume(sourceSnapshot)
        builder.consume(assemblerOCI.image)
        let publication: ArtifactReference = try builder.output(
            "native-packages",
            path: lane.packageRoot.appending("current"),
            validation: .symlinkTarget)
        let task = builder.build(
            swiftProducts: [assembler],
            inputs: [
                configuration.assemblerSwiftPM.identityInput,
                .environment(
                    name: "NUCLEUS_PRODUCT_PRODUCER_TRUST_DOMAIN",
                    value: configuration.environment[
                        "NUCLEUS_PRODUCT_PRODUCER_TRUST_DOMAIN"]),
            ],
            locks: [
                .shared(lane.packageRoot.appending(".publish.lock"))
            ],
            assessmentPolicy: .incremental,
            action: try AnyColliderAction(
                PackageLinuxRuntimeCohortAction(
                    architecture: architecture,
                    sourceSnapshot: sourceSnapshot.path,
                    runtimeArtifactRoot: lane.artifactRoot,
                    browser: browser,
                    adapterRoot: lane.packageWorkRoot.appending("adapters"),
                    assemblerSwiftPM: configuration.assemblerSwiftPM,
                    outputRoot: lane.packageRoot,
                    producingTask: LinuxTaskIDs.packageCohort(architecture),
                    producerRunner: .current,
                    placement: configuration.placement,
                    environment: configuration.environment)))
        return PreparedNativePackages(task: task, publication: publication)
    }

    private static func packagePayloadTask(
        architecture: PlatformArchitecture,
        package: LinuxNativePackageName,
        lane: LinuxRuntimeArtifactLane,
        runtime: PreparedRuntimeArtifact,
        browser: ChromiumColliderRecipe.PackageInput,
        androidPackageInput: ArtifactReference,
        configuration: LinuxRuntimeArtifactConfiguration
    ) throws -> PreparedNativePackagePayload {
        let assembler = configuration.assemblerSwiftPM.product(
            package: "collider-cli",
            product: "nucleus-linux-assembler",
            packageRoot: configuration.assemblerSwiftPM.context.packageRoot,
            environment: configuration.environment,
            expectedOutputs: [
                PathPostcondition(
                    path: configuration.assemblerSwiftPM.executable(
                        "nucleus-linux-assembler"),
                    validation: .executableFile)
            ])
        let outputRoot = lane.packageWorkRoot.appending(
            "payloads/\(package.rawValue)")
        var builder = TaskBuilder(
            id: LinuxTaskIDs.packagePayload(architecture, package),
            component: descriptor.id)
        builder.consume(runtime.runtime)
        builder.consume(runtime.packageManifests)
        builder.consume(browser.reference)
        builder.consume(browser.payloadReference)
        if package == .androidPackage {
            builder.consume(androidPackageInput)
        }
        let payload: ArtifactReference = try builder.output(
            "payload",
            path: outputRoot.appending("current"),
            validation: .symlinkTarget)
        let task = builder.build(
            swiftProducts: [assembler],
            inputs: [configuration.assemblerSwiftPM.identityInput],
            locks: [.shared(outputRoot.appending(".publish.lock"))],
            assessmentPolicy: .incremental,
            action: try AnyColliderAction(
                PackageLinuxRuntimePayloadAction(
                    architecture: architecture,
                    package: package,
                    runtimeArtifactRoot: lane.artifactRoot,
                    browser: browser,
                    androidPackageInputRoot:
                        package == .androidPackage
                        ? androidPackageInput.path : nil,
                    assemblerSwiftPM: configuration.assemblerSwiftPM,
                    outputRoot: outputRoot,
                    placement: configuration.placement,
                    environment: configuration.environment)))
        return PreparedNativePackagePayload(
            package: package,
            task: task,
            payload: payload)
    }

    private static func packageControlPayloadsTask(
        architecture: PlatformArchitecture,
        lane: LinuxRuntimeArtifactLane,
        runtime: PreparedRuntimeArtifact,
        browser: ChromiumColliderRecipe.PackageInput,
        configuration: LinuxRuntimeArtifactConfiguration
    ) throws -> PreparedControlPayloads {
        let assembler = configuration.assemblerSwiftPM.product(
            package: "collider-cli",
            product: "nucleus-linux-assembler",
            packageRoot: configuration.assemblerSwiftPM.context.packageRoot,
            environment: configuration.environment,
            expectedOutputs: [
                PathPostcondition(
                    path: configuration.assemblerSwiftPM.executable(
                        "nucleus-linux-assembler"),
                    validation: .executableFile)
            ])
        let payloadRoot = lane.packageWorkRoot.appending("payloads")
        var builder = TaskBuilder(
            id: LinuxTaskIDs.packageControlPayloads(architecture),
            component: descriptor.id)
        builder.consume(runtime.runtime)
        builder.consume(runtime.packageManifests)
        builder.consume(browser.reference)
        builder.consume(browser.payloadReference)
        var publications:
            [(
                package: LinuxNativePackageName, payload: ArtifactReference
            )] = []
        for package in LinuxNativePackageName.controlOnly {
            let payload = try builder.output(
                OutputSlotID(rawValue: "payload-\(package.rawValue)"),
                path: payloadRoot.appending("\(package.rawValue)/current"),
                validation: .symlinkTarget)
            publications.append((package, payload))
        }
        let task = builder.build(
            swiftProducts: [assembler],
            inputs: [configuration.assemblerSwiftPM.identityInput],
            locks: LinuxNativePackageName.controlOnly.map {
                .shared(
                    payloadRoot.appending("\($0.rawValue)/.publish.lock"))
            },
            assessmentPolicy: .incremental,
            action: try AnyColliderAction(
                PackageLinuxControlPayloadsAction(
                    architecture: architecture,
                    runtimeArtifactRoot: lane.artifactRoot,
                    browser: browser,
                    assemblerSwiftPM: configuration.assemblerSwiftPM,
                    payloadRoot: payloadRoot,
                    placement: configuration.placement,
                    environment: configuration.environment)))
        return PreparedControlPayloads(
            task: task,
            payloads: publications.map {
                PreparedNativePackagePayload(
                    package: $0.package,
                    task: task,
                    payload: $0.payload)
            })
    }

    private static func packageAdapterTask(
        architecture: PlatformArchitecture,
        family: LinuxDistributionFamily,
        payload: PreparedNativePackagePayload,
        lane: LinuxRuntimeArtifactLane,
        runtime: PreparedRuntimeArtifact,
        browser: ChromiumColliderRecipe.PackageInput,
        configuration: LinuxRuntimeArtifactConfiguration
    ) throws -> PreparedNativePackageAdapter {
        let assembler = configuration.assemblerSwiftPM.product(
            package: "collider-cli",
            product: "nucleus-linux-assembler",
            packageRoot: configuration.assemblerSwiftPM.context.packageRoot,
            environment: configuration.environment,
            expectedOutputs: [
                PathPostcondition(
                    path: configuration.assemblerSwiftPM.executable(
                        "nucleus-linux-assembler"),
                    validation: .executableFile)
            ])
        let outputRoot = lane.packageWorkRoot.appending(
            "adapters/\(family.rawValue)/\(payload.package.rawValue)")
        let payloadRoot = lane.packageWorkRoot.appending(
            "payloads/\(payload.package.rawValue)")
        var builder = TaskBuilder(
            id: LinuxTaskIDs.packageAdapter(
                architecture,
                family,
                payload.package),
            component: descriptor.id)
        builder.consume(payload.payload)
        builder.consume(runtime.runtime)
        builder.consume(runtime.packageManifests)
        builder.consume(browser.reference)
        builder.consume(browser.payloadReference)
        let publication: ArtifactReference = try builder.output(
            "adapter",
            path: outputRoot.appending("current"),
            validation: .symlinkTarget)
        let task = builder.build(
            swiftProducts: [assembler],
            inputs: [configuration.assemblerSwiftPM.identityInput],
            locks: [.shared(outputRoot.appending(".publish.lock"))],
            assessmentPolicy: .incremental,
            action: try AnyColliderAction(
                PackageLinuxRuntimeAdapterAction(
                    architecture: architecture,
                    family: family,
                    package: payload.package,
                    runtimeArtifactRoot: lane.artifactRoot,
                    browser: browser,
                    payloadPublicationRoot: payloadRoot,
                    assemblerSwiftPM: configuration.assemblerSwiftPM,
                    outputRoot: outputRoot,
                    placement: configuration.placement,
                    environment: configuration.environment)))
        return PreparedNativePackageAdapter(
            family: family,
            package: payload.package,
            task: task,
            publication: publication)
    }

    private static func packageControlAdaptersTask(
        architecture: PlatformArchitecture,
        payloads: [PreparedNativePackagePayload],
        lane: LinuxRuntimeArtifactLane,
        runtime: PreparedRuntimeArtifact,
        browser: ChromiumColliderRecipe.PackageInput,
        configuration: LinuxRuntimeArtifactConfiguration
    ) throws -> PreparedControlAdapters {
        let assembler = configuration.assemblerSwiftPM.product(
            package: "collider-cli",
            product: "nucleus-linux-assembler",
            packageRoot: configuration.assemblerSwiftPM.context.packageRoot,
            environment: configuration.environment,
            expectedOutputs: [
                PathPostcondition(
                    path: configuration.assemblerSwiftPM.executable(
                        "nucleus-linux-assembler"),
                    validation: .executableFile)
            ])
        let adapterRoot = lane.packageWorkRoot.appending("adapters")
        var builder = TaskBuilder(
            id: LinuxTaskIDs.packageControlAdapters(architecture),
            component: descriptor.id)
        for payload in payloads {
            builder.consume(payload.payload)
        }
        builder.consume(runtime.runtime)
        builder.consume(runtime.packageManifests)
        builder.consume(browser.reference)
        builder.consume(browser.payloadReference)
        var publications:
            [(
                family: LinuxDistributionFamily,
                package: LinuxNativePackageName,
                publication: ArtifactReference
            )] = []
        for family in LinuxDistributionFamily.allCases {
            for package in LinuxNativePackageName.controlOnly {
                let publication = try builder.output(
                    OutputSlotID(
                        rawValue: "adapter-\(family.rawValue)-\(package.rawValue)"),
                    path: adapterRoot.appending(
                        "\(family.rawValue)/\(package.rawValue)/current"),
                    validation: .symlinkTarget)
                publications.append((family, package, publication))
            }
        }
        let task = builder.build(
            swiftProducts: [assembler],
            inputs: [configuration.assemblerSwiftPM.identityInput],
            locks: publications.map {
                .shared(
                    $0.publication.path.removingLastComponent().appending(
                        ".publish.lock"))
            },
            assessmentPolicy: .incremental,
            action: try AnyColliderAction(
                PackageLinuxControlAdaptersAction(
                    architecture: architecture,
                    runtimeArtifactRoot: lane.artifactRoot,
                    browser: browser,
                    payloadRoot: lane.packageWorkRoot.appending("payloads"),
                    assemblerSwiftPM: configuration.assemblerSwiftPM,
                    outputRoot: adapterRoot,
                    placement: configuration.placement,
                    environment: configuration.environment)))
        return PreparedControlAdapters(
            task: task,
            adapters: publications.map {
                PreparedNativePackageAdapter(
                    family: $0.family,
                    package: $0.package,
                    task: task,
                    publication: $0.publication)
            })
    }

    private static func packageProductPublicationTask(
        architecture: PlatformArchitecture,
        lane: LinuxRuntimeArtifactLane,
        packages: PreparedNativePackages,
        configuration: LinuxRuntimeArtifactConfiguration
    ) throws -> PreparedPublishedNativePackages {
        var builder = TaskBuilder(
            id: LinuxTaskIDs.packageProductPublication(architecture),
            component: descriptor.id)
        builder.consume(packages.publication)
        let receipt: ArtifactReference = try builder.output(
            "package-product-publication-receipt",
            path: lane.productPublicationRoot.appending("receipt.json"),
            validation: .regularFile)
        let task = builder.build(
            locks: [
                .shared(
                    lane.productPublicationRoot.appending(".publish.lock")),
                .shared(
                    configuration.productStoreRoot.appending(".publish.lock")),
            ],
            assessmentPolicy: .incremental,
            action: try AnyColliderAction(
                PublishLinuxRuntimePackageProductsAction(
                    architecture: architecture,
                    packagePublicationRoot: lane.packageRoot,
                    productStoreRoot: configuration.productStoreRoot,
                    receiptRoot: lane.productPublicationRoot)))
        return PreparedPublishedNativePackages(task: task, receipt: receipt)
    }

    private static func packageQualificationTask(
        architecture: PlatformArchitecture,
        lane: LinuxRuntimeArtifactLane,
        packages: PreparedNativePackages,
        productPublication: PreparedPublishedNativePackages,
        configuration: LinuxRuntimeArtifactConfiguration
    ) throws -> PreparedPackageQualification {
        let qualifier = configuration.assemblerSwiftPM.product(
            package: "collider-cli",
            product: "nucleus-linux-package-qualifier",
            packageRoot: configuration.assemblerSwiftPM.context.packageRoot,
            environment: configuration.environment,
            expectedOutputs: [
                PathPostcondition(
                    path: configuration.assemblerSwiftPM.executable(
                        "nucleus-linux-package-qualifier"),
                    validation: .executableFile)
            ])
        guard
            case .oci(let assemblerOCI) =
                configuration.assemblerSwiftPM.context.execution
        else {
            throw LinuxRuntimeArtifactFailure.requiresOCI
        }
        var builder = TaskBuilder(
            id: LinuxTaskIDs.packageLifecycleQualification(architecture),
            component: descriptor.id)
        builder.consume(packages.publication)
        builder.consume(productPublication.receipt)
        builder.consume(assemblerOCI.image)
        let report: ArtifactReference = try builder.output(
            "package-lifecycle-qualification",
            path: lane.qualificationRoot,
            validation: .nonEmptyDirectory)
        let task = builder.build(
            swiftProducts: [qualifier],
            inputs: [configuration.assemblerSwiftPM.identityInput],
            locks: [
                .shared(lane.qualificationRoot.appending(".publish.lock"))
            ],
            assessmentPolicy: .incremental,
            action: try AnyColliderAction(
                QualifyLinuxRuntimePackagesAction(
                    architecture: architecture,
                    packagePublicationRoot: lane.packageRoot,
                    productStoreRoot: configuration.productStoreRoot,
                    productStoreReceipt: productPublication.receipt.path,
                    assemblerSwiftPM: configuration.assemblerSwiftPM,
                    qualificationRoot: lane.qualificationRoot,
                    placement: configuration.placement,
                    environment: configuration.environment)))
        return PreparedPackageQualification(task: task, report: report)
    }

    private static func packageStorageRetentionTask(
        publications: [PreparedNativePackages],
        qualifications: [PreparedPackageQualification],
        configuration: LinuxRuntimeArtifactConfiguration
    ) throws -> TaskDeclaration {
        var builder = TaskBuilder(
            id: LinuxTaskIDs.packageStorageRetention,
            component: descriptor.id)
        for publication in publications {
            builder.consume(publication.publication)
        }
        for qualification in qualifications {
            builder.consume(qualification.report)
        }
        let lanes = try PlatformArchitecture.allCases.map { architecture in
            guard let lane = configuration.lanes[architecture] else {
                throw LinuxRuntimeArtifactFailure.missingArchitecture(architecture)
            }
            return LinuxPackageStorageRetentionLane(
                architecture: architecture,
                packageRoot: lane.packageRoot)
        }
        return builder.build(
            locks: lanes.map {
                .shared($0.packageRoot.appending(".publish.lock"))
            } + [
                .shared(configuration.productStoreRoot.appending(".publish.lock"))
            ],
            assessmentPolicy: .always,
            action: try AnyColliderAction(
                LinuxPackageStorageRetentionAction(
                    lanes: lanes,
                    productStoreRoot: configuration.productStoreRoot,
                    rollbackGenerationCount: rollbackGenerationCount)))
    }

    package static func architectureLane(
        architecture: PlatformArchitecture,
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation,
        targetArtifacts: ArtifactReferenceSet
    ) throws -> [TaskDeclaration] {
        let buildID = LinuxTaskIDs.build(architecture)
        let buildRequirement = swiftPM.product(
            package: "nucleus",
            product: "NucleusSessionSupervisor",
            packageRoot: root,
            environment: environment)
        let sharedInputs: [ArtifactInput] = [
            swiftPM.identityInput
        ]
        var buildBuilder = TaskBuilder(
            id: buildID,
            component: ComponentID(rawValue: "linux"))
        buildBuilder.consume(targetArtifacts)
        let build = buildBuilder.build(
            swiftProducts: [buildRequirement],
            inputs: sharedInputs,
            postconditions: [swiftPM.postcondition],
            locks: [linuxSwiftPMExecutionLock],
            assessmentPolicy: .incremental)
        guard architecture == .arm64 else { return [build] }

        let testRequirement = swiftPM.testProduct(
            package: "nucleus",
            testProduct: "NucleusLinuxPlatformPackageTests",
            packageRoot: root,
            environment: environment,
            arguments: [
                "--parallel", "--num-workers",
                String(SwiftBuildContext.concurrentOCIMaximumParallelism),
                "--skip",
                "gpu(DRM|Loader|Headless)_",
            ])
        let loaderRequirement = swiftPM.testProduct(
            package: "nucleus",
            testProduct: "NucleusLinuxPlatformPackageTests",
            packageRoot: root,
            environment: environment,
            arguments: ["--filter", "gpuLoader_"])
        let headlessRequirement = swiftPM.testProduct(
            package: "nucleus",
            testProduct: "NucleusLinuxPlatformPackageTests",
            packageRoot: root,
            environment: environment,
            arguments: ["--filter", "gpuHeadless_"])
        var testBuilder = TaskBuilder(
            id: LinuxTaskIDs.test(architecture),
            component: ComponentID(rawValue: "linux"))
        testBuilder.consume(targetArtifacts)
        let test = testBuilder.build(
            swiftTests: [testRequirement],
            inputs: sharedInputs,
            postconditions: [swiftPM.postcondition],
            locks: [linuxSwiftPMExecutionLock],
            assessmentPolicy: .always)
        return [
            build,
            test,
            laneTestTask(
                id: LinuxTaskIDs.testLoader(architecture),
                requirement: loaderRequirement,
                sharedInputs: sharedInputs,
                lock: linuxSwiftPMExecutionLock,
                targetArtifacts: targetArtifacts),
            laneTestTask(
                id: LinuxTaskIDs.testGPUHeadless(architecture),
                requirement: headlessRequirement,
                sharedInputs: sharedInputs,
                lock: linuxSwiftPMExecutionLock,
                targetArtifacts: targetArtifacts),
        ]
    }

}

private enum LinuxRuntimeArtifactFailure: Error, CustomStringConvertible {
    case requiresOCI
    case missingArchitecture(PlatformArchitecture)
    case missingBrowser(PlatformArchitecture)
    case missingAndroidPackageInput(PlatformArchitecture)

    var description: String {
        switch self {
        case .requiresOCI:
            "Linux runtime artifact assembly requires the canonical OCI builder"
        case .missingArchitecture(let architecture):
            "Linux runtime artifact assembly has no \(architecture.rawValue) lane"
        case .missingBrowser(let architecture):
            "Linux package assembly has no \(architecture.rawValue) browser input"
        case .missingAndroidPackageInput(let architecture):
            "Linux package assembly has no \(architecture.rawValue) Android input"
        }
    }
}

private func laneTestTask(
    id: TaskID,
    requirement: SwiftTestRequirement,
    sharedInputs: [ArtifactInput],
    lock: TaskLock,
    targetArtifacts: ArtifactReferenceSet
) -> TaskDeclaration {
    var builder = TaskBuilder(
        id: id,
        component: ComponentID(rawValue: "linux"))
    builder.consume(targetArtifacts)
    return builder.build(
        swiftTests: [requirement],
        inputs: sharedInputs,
        postconditions: [requirement.invocation.postcondition],
        locks: [lock],
        assessmentPolicy: .always)
}
