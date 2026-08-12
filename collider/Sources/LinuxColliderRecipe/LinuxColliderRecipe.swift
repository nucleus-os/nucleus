import ColliderCore
import NativeBuilderColliderRecipe
import ShellColliderRecipe
import SystemPackage

package enum LinuxEntrypoints {
    package static let runtimeArtifact = ComponentEntrypointID(
        rawValue: "artifact.runtime")
    package static let testGPUHeadless = ComponentEntrypointID(
        rawValue: "test.gpu-headless")
}

package enum LinuxTaskIDs {
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

    package static let runtimeArtifact = TaskID(
        rawValue: "linux.arm64.runtime-artifact")
}

package struct LinuxRuntimeArtifactConfiguration: RecipeConfiguration {
    package let runtimeSwiftPM: SwiftPMInvocation
    package let assemblerSwiftPM: SwiftPMInvocation
    package let artifactRoot: FilePath
    package let sessionPackage: FilePath
    package let kernelContract: FilePath
    package let environment: [String: String]

    package init(
        runtimeSwiftPM: SwiftPMInvocation,
        assemblerSwiftPM: SwiftPMInvocation,
        artifactRoot: FilePath,
        sessionPackage: FilePath,
        kernelContract: FilePath,
        environment: [String: String]
    ) {
        self.runtimeSwiftPM = runtimeSwiftPM
        self.assemblerSwiftPM = assemblerSwiftPM
        self.artifactRoot = artifactRoot
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
        }
        let artifactTask = try runtimeArtifactTask(
            configuration: runtimeArtifact,
            targetArtifacts: try native.artifacts(
                for: NativeLinuxTarget(architecture: .arm64)))
        tasks.append(artifactTask)
        return try ComponentDefinition(
            descriptor: descriptor,
            tasks: tasks,
            entrypoints: [
                ComponentEntrypoint(id: .build, roots: buildRoots),
                ComponentEntrypoint(id: .testDefault, roots: testRoots),
                ComponentEntrypoint(
                    id: LinuxEntrypoints.runtimeArtifact,
                    roots: [artifactTask.id]),
                ComponentEntrypoint(
                    id: LinuxEntrypoints.testGPUHeadless,
                    roots: headlessRoots),
                ComponentEntrypoint(
                    id: ComponentEntrypointID(rawValue: "test.loader"),
                    roots: loaderRoots),
            ],
            storage: [
                StorageDeclaration(
                    id: "linux-runtime-artifact-root",
                    owner: descriptor.id,
                    producers: [.task(artifactTask.id)],
                    storageClass: .published,
                    root: runtimeArtifact.artifactRoot,
                    safetyRoot: runtimeArtifact.artifactRoot.removingLastComponent(),
                    retentionPolicy: .protected),
                StorageDeclaration(
                    id: "linux-runtime-generations",
                    owner: descriptor.id,
                    producers: [.task(artifactTask.id)],
                    storageClass: .generation,
                    root: runtimeArtifact.artifactRoot.appending("generations"),
                    safetyRoot: runtimeArtifact.artifactRoot,
                    retentionPolicy: .keepActiveAndRollback(count: rollbackGenerationCount),
                    activeGenerationLink: runtimeArtifact.artifactRoot.appending("current"),
                    interruptedCandidateNaming: nil),
                StorageDeclaration(
                    id: "linux-package-manifest-generations",
                    owner: descriptor.id,
                    producers: [.task(artifactTask.id)],
                    storageClass: .generation,
                    root: runtimeArtifact.artifactRoot.appending("package-manifests"),
                    safetyRoot: runtimeArtifact.artifactRoot,
                    retentionPolicy: .keepActiveAndRollback(count: rollbackGenerationCount),
                    activeGenerationLink: runtimeArtifact.artifactRoot.appending(
                        "package-manifests/current"),
                    interruptedCandidateNaming: nil),
            ])
    }

    private static func runtimeArtifactTask(
        configuration: LinuxRuntimeArtifactConfiguration,
        targetArtifacts: ArtifactReferenceSet
    ) throws -> TaskDeclaration {
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
            configuration.runtimeSwiftPM.product(
                package: "nucleus",
                product: product,
                packageRoot: configuration.runtimeSwiftPM.context.packageRoot,
                environment: configuration.environment,
                expectedOutputs: [
                    PathPostcondition(
                        path: configuration.runtimeSwiftPM.executable(product),
                        validation: .executableFile)
                ])
        }
        let assembler = configuration.assemblerSwiftPM.product(
            package: "collider-cli",
            product: "nucleus-runtime-assembler",
            packageRoot: configuration.assemblerSwiftPM.context.packageRoot,
            environment: configuration.environment,
            expectedOutputs: [
                PathPostcondition(
                    path: configuration.assemblerSwiftPM.executable(
                        "nucleus-runtime-assembler"),
                    validation: .executableFile)
            ])
        let generations = configuration.artifactRoot.appending("generations")
        let packageManifests = configuration.artifactRoot.appending(
            "package-manifests")
        var builder = TaskBuilder(
            id: LinuxTaskIDs.runtimeArtifact,
            component: descriptor.id)
        builder.consume(targetArtifacts)
        guard
            case .oci(let runtimeOCI) =
                configuration.runtimeSwiftPM.context.execution
        else {
            throw LinuxRuntimeArtifactFailure.requiresOCI
        }
        builder.consume(runtimeOCI.image)
        let _: ArtifactReference = try builder.output(
            "runtime",
            path: configuration.artifactRoot.appending("current"),
            validation: .symlinkTarget)
        let _: ArtifactReference = try builder.output(
            "package-manifests",
            path: packageManifests.appending("current"),
            validation: .symlinkTarget)
        return builder.build(
            swiftProducts: runtimeRequirements + [assembler],
            inputs: RuntimeHostIntegration.sourceFiles.map {
                .file(configuration.sessionPackage.appending($0))
            } + [
                .file(configuration.kernelContract),
                configuration.runtimeSwiftPM.identityInput,
                configuration.assemblerSwiftPM.identityInput,
            ],
            locks: [
                .shared(configuration.artifactRoot.appending(".publish.lock"))
            ],
            action: try AnyColliderAction(
                PublishLinuxRuntimeArtifactAction(
                    runtimeSwiftPM: configuration.runtimeSwiftPM,
                    assemblerSwiftPM: configuration.assemblerSwiftPM,
                    artifactRoot: configuration.artifactRoot,
                    generationsRoot: generations,
                    packageManifestsRoot: packageManifests,
                    rollbackGenerationCount: rollbackGenerationCount,
                    sessionPackage: configuration.sessionPackage,
                    kernelContract: configuration.kernelContract,
                    environment: configuration.environment)))
    }

    package static func architectureLane(
        architecture: PlatformArchitecture,
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation,
        targetArtifacts: ArtifactReferenceSet
    ) throws -> [TaskDeclaration] {
        let name = architecture.rawValue
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
            locks: [.checkout("linux-\(name)")],
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
            locks: [.checkout("linux-\(name)")],
            assessmentPolicy: .always)
        return [
            build,
            test,
            laneTestTask(
                id: LinuxTaskIDs.testLoader(architecture),
                requirement: loaderRequirement,
                sharedInputs: sharedInputs,
                lockName: "linux-\(name)",
                targetArtifacts: targetArtifacts),
            laneTestTask(
                id: LinuxTaskIDs.testGPUHeadless(architecture),
                requirement: headlessRequirement,
                sharedInputs: sharedInputs,
                lockName: "linux-\(name)",
                targetArtifacts: targetArtifacts),
        ]
    }

}

private enum LinuxRuntimeArtifactFailure: Error, CustomStringConvertible {
    case requiresOCI

    var description: String {
        "Linux runtime artifact assembly requires the canonical OCI builder"
    }
}

private func laneTestTask(
    id: TaskID,
    requirement: SwiftTestRequirement,
    sharedInputs: [ArtifactInput],
    lockName: String,
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
        locks: [.checkout(lockName)],
        assessmentPolicy: .always)
}
