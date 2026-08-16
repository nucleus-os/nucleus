import ChromiumColliderRecipe
import ColliderCore
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
    package let qualificationRoot: FilePath

    package init(
        runtimeSwiftPM: SwiftPMInvocation,
        artifactRoot: FilePath,
        packageRoot: FilePath,
        qualificationRoot: FilePath
    ) {
        self.runtimeSwiftPM = runtimeSwiftPM
        self.artifactRoot = artifactRoot
        self.packageRoot = packageRoot
        self.qualificationRoot = qualificationRoot
    }
}

package struct LinuxRuntimeArtifactConfiguration: RecipeConfiguration {
    package let lanes: [PlatformArchitecture: LinuxRuntimeArtifactLane]
    package let browserPackageInputs: [PlatformArchitecture: ChromiumColliderRecipe.PackageInput]
    package let assemblerSwiftPM: SwiftPMInvocation
    package let packageSourceSnapshotRoot: FilePath
    package let productStoreRoot: FilePath
    package let sessionPackage: FilePath
    package let kernelContract: FilePath
    package let environment: [String: String]

    package init(
        lanes: [PlatformArchitecture: LinuxRuntimeArtifactLane],
        browserPackageInputs:
            [PlatformArchitecture: ChromiumColliderRecipe.PackageInput],
        assemblerSwiftPM: SwiftPMInvocation,
        packageSourceSnapshotRoot: FilePath,
        productStoreRoot: FilePath,
        sessionPackage: FilePath,
        kernelContract: FilePath,
        environment: [String: String]
    ) {
        self.lanes = lanes
        self.browserPackageInputs = browserPackageInputs
        self.assemblerSwiftPM = assemblerSwiftPM
        self.packageSourceSnapshotRoot = packageSourceSnapshotRoot
        self.productStoreRoot = productStoreRoot
        self.sessionPackage = sessionPackage
        self.kernelContract = kernelContract
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
            let nativePackages = try packageTask(
                architecture: architecture,
                lane: lane,
                runtime: artifact,
                browser: browser,
                sourceSnapshot: packageSourceSnapshot.snapshot,
                configuration: runtimeArtifact)
            tasks.append(nativePackages.task)
            packagePublications.append(nativePackages)
            let qualification = try packageQualificationTask(
                architecture: architecture,
                lane: lane,
                packages: nativePackages,
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
                        StorageProducer.task(LinuxTaskIDs.packageCohort($0))
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
            storage += [
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
            swiftProducts: runtimeRequirements + [assembler],
            inputs: RuntimeHostIntegration.sourceFiles.map {
                .file(configuration.sessionPackage.appending($0))
            } + [
                .file(configuration.kernelContract),
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
                    kernelContract: configuration.kernelContract,
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
                .shared(lane.packageRoot.appending(".publish.lock")),
                .shared(
                    configuration.productStoreRoot.appending(".publish.lock")),
                .shared(
                    configuration.packageSourceSnapshotRoot.appending(
                        ".publish.lock")),
            ],
            assessmentPolicy: .incremental,
            action: try AnyColliderAction(
                PackageLinuxRuntimeCohortAction(
                    architecture: architecture,
                    sourceSnapshot: sourceSnapshot.path,
                    runtimeArtifactRoot: lane.artifactRoot,
                    browser: browser,
                    assemblerSwiftPM: configuration.assemblerSwiftPM,
                    outputRoot: lane.packageRoot,
                    productStoreRoot: configuration.productStoreRoot,
                    producerRunner: .current,
                    environment: configuration.environment)))
        return PreparedNativePackages(task: task, publication: publication)
    }

    private static func packageQualificationTask(
        architecture: PlatformArchitecture,
        lane: LinuxRuntimeArtifactLane,
        packages: PreparedNativePackages,
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
        builder.consume(assemblerOCI.image)
        let report: ArtifactReference = try builder.output(
            "package-lifecycle-qualification",
            path: lane.qualificationRoot,
            validation: .nonEmptyDirectory)
        let task = builder.build(
            swiftProducts: [qualifier],
            inputs: [configuration.assemblerSwiftPM.identityInput],
            locks: [
                .shared(lane.qualificationRoot.appending(".publish.lock")),
                .shared(
                    configuration.productStoreRoot.appending(".publish.lock")),
            ],
            assessmentPolicy: .incremental,
            action: try AnyColliderAction(
                QualifyLinuxRuntimePackagesAction(
                    architecture: architecture,
                    packagePublicationRoot: lane.packageRoot,
                    productStoreRoot: configuration.productStoreRoot,
                    assemblerSwiftPM: configuration.assemblerSwiftPM,
                    qualificationRoot: lane.qualificationRoot,
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

    var description: String {
        switch self {
        case .requiresOCI:
            "Linux runtime artifact assembly requires the canonical OCI builder"
        case .missingArchitecture(let architecture):
            "Linux runtime artifact assembly has no \(architecture.rawValue) lane"
        case .missingBrowser(let architecture):
            "Linux package assembly has no \(architecture.rawValue) browser input"
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
