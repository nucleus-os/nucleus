import ColliderCore
import SystemPackage

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
}

public enum LinuxColliderRecipe: ColliderComponent {
    public static let descriptor = ComponentDescriptor(
        id: ComponentID(rawValue: "linux"),
        canonicalName: "linux",
        directoryName: ".")

    public static func makeComponent(
        in context: RecipeContext
    ) throws -> ComponentDefinition {
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
                targetArtifacts: try context.targetArtifacts(for: target))
            buildRoots.insert(LinuxTaskIDs.build(architecture))
            testRoots.insert(LinuxTaskIDs.test(architecture))
            loaderRoots.insert(LinuxTaskIDs.testLoader(architecture))
            headlessRoots.insert(LinuxTaskIDs.testGPUHeadless(architecture))
        }
        return try ComponentDefinition(
            descriptor: descriptor,
            tasks: tasks,
            entrypoints: [
                ComponentEntrypoint(id: .build, roots: buildRoots),
                ComponentEntrypoint(id: .testDefault, roots: testRoots),
                ComponentEntrypoint(id: .testGPUHeadless, roots: headlessRoots),
                ComponentEntrypoint(
                    id: ComponentEntrypointID(rawValue: "test.loader"),
                    roots: loaderRoots),
            ])
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
        let testRequirement = swiftPM.testProduct(
            package: "nucleus",
            testProduct: "NucleusLinuxPlatformPackageTests",
            packageRoot: root,
            environment: environment,
            arguments: [
                "--no-parallel", "--skip",
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
        switch architecture {
        case .arm64:
            return [
                build,
                TaskDeclaration(
                    id: LinuxTaskIDs.test(architecture),
                    component: ComponentID(rawValue: "linux"),
                    dependencies: [buildID],
                    subsumedDependencies: [buildID],
                    swiftTests: [testRequirement],
                    inputs: sharedInputs,
                    postconditions: [swiftPM.postcondition],
                    locks: [.checkout("linux-\(name)")],
                    assessmentPolicy: .always),
                laneTestTask(
                    id: LinuxTaskIDs.testLoader(architecture),
                    buildID: buildID,
                    requirement: loaderRequirement,
                    sharedInputs: sharedInputs,
                    lockName: "linux-\(name)"),
                laneTestTask(
                    id: LinuxTaskIDs.testGPUHeadless(architecture),
                    buildID: buildID,
                    requirement: headlessRequirement,
                    sharedInputs: sharedInputs,
                    lockName: "linux-\(name)"),
            ]
        case .x86_64:
            let probeRequirement = swiftPM.product(
                package: "nucleus",
                product: "NucleusVulkanLaneProbe",
                packageRoot: root,
                environment: environment,
                expectedOutputs: [
                    PathPostcondition(
                        path: swiftPM.executable("NucleusVulkanLaneProbe"),
                        validation: .executableFile)
                ])
            return [
                build,
                try translatedExecutableTask(
                    id: LinuxTaskIDs.test(architecture),
                    buildID: buildID,
                    requirements: [buildRequirement, probeRequirement],
                    inputs: sharedInputs,
                    swiftPM: swiftPM,
                    environment: environment,
                    operations: [
                        (swiftPM.executable("NucleusVulkanLaneProbe"), ["loader"]),
                        (swiftPM.executable("NucleusVulkanLaneProbe"), ["gpu-headless"]),
                        (swiftPM.executable("NucleusSessionSupervisor"), ["--help"]),
                    ]),
                try translatedExecutableTask(
                    id: LinuxTaskIDs.testLoader(architecture),
                    buildID: buildID,
                    requirements: [probeRequirement],
                    inputs: sharedInputs,
                    swiftPM: swiftPM,
                    environment: environment,
                    operations: [
                        (swiftPM.executable("NucleusVulkanLaneProbe"), ["loader"])
                    ]),
                try translatedExecutableTask(
                    id: LinuxTaskIDs.testGPUHeadless(architecture),
                    buildID: buildID,
                    requirements: [probeRequirement],
                    inputs: sharedInputs,
                    swiftPM: swiftPM,
                    environment: environment,
                    operations: [
                        (swiftPM.executable("NucleusVulkanLaneProbe"), ["gpu-headless"])
                    ]),
            ]
        }
    }

}

private func laneTestTask(
    id: TaskID,
    buildID: TaskID,
    requirement: SwiftTestRequirement,
    sharedInputs: [ArtifactInput],
    lockName: String
) -> TaskDeclaration {
    TaskDeclaration(
        id: id,
        component: ComponentID(rawValue: "linux"),
        dependencies: [buildID],
        subsumedDependencies: [buildID],
        swiftTests: [requirement],
        inputs: sharedInputs,
        postconditions: [requirement.invocation.postcondition],
        locks: [.checkout(lockName)],
        assessmentPolicy: .always)
}

private func translatedExecutableTask(
    id: TaskID,
    buildID: TaskID,
    requirements: [SwiftProductRequirement],
    inputs: [ArtifactInput],
    swiftPM: SwiftPMInvocation,
    environment: [String: String],
    operations: [(FilePath, [String])]
) throws -> TaskDeclaration {
    TaskDeclaration(
        id: id,
        component: ComponentID(rawValue: "linux"),
        dependencies: [buildID],
        subsumedDependencies: requirements.contains(where: {
            $0.product == "NucleusSessionSupervisor"
        }) ? [buildID] : [],
        swiftProducts: requirements,
        inputs: inputs,
        postconditions: [swiftPM.postcondition],
        locks: [.checkout("linux-x86_64")],
        assessmentPolicy: .always,
        action:
            try AnyColliderAction(
                RunLinuxLaneExecutablesAction(
                    executions: try operations.map { executable, arguments in
                        try swiftPM.ociExecutableExecution(
                            executable: executable,
                            arguments: arguments,
                            workingDirectory: swiftPM.context.packageRoot,
                            environment: environment)
                    })))
}

private struct RunLinuxLaneExecutablesAction: ColliderAction {
    static let kind: ActionKind = "linux.run-lane-executables"

    let pipeline: OCIExecutionPipeline

    init(executions: [OCIExecution]) throws {
        pipeline = try OCIExecutionPipeline(executions)
    }

    var identity: OCIExecutionPipelineIdentity { pipeline.identity }
    var requirements: ActionRequirements { pipeline.requirements }
    var environment: [String: String] { pipeline.environment }

    func execute(in context: ActionContext) async throws {
        try await pipeline.execute(in: context)
    }
}
