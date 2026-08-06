import ColliderCore
import NativeBuilderColliderRecipe
import SystemPackage

package enum LinuxEntrypoints {
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
}

public enum LinuxColliderRecipe: ColliderComponent {
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
                ComponentEntrypoint(
                    id: LinuxEntrypoints.testGPUHeadless,
                    roots: headlessRoots),
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
        return [
            build,
            TaskDeclaration(
                id: LinuxTaskIDs.test(architecture),
                component: ComponentID(rawValue: "linux"),
                swiftTests: [testRequirement],
                inputs: sharedInputs,
                postconditions: [swiftPM.postcondition],
                locks: [.checkout("linux-\(name)")],
                assessmentPolicy: .always),
            laneTestTask(
                id: LinuxTaskIDs.testLoader(architecture),
                requirement: loaderRequirement,
                sharedInputs: sharedInputs,
                lockName: "linux-\(name)"),
            laneTestTask(
                id: LinuxTaskIDs.testGPUHeadless(architecture),
                requirement: headlessRequirement,
                sharedInputs: sharedInputs,
                lockName: "linux-\(name)"),
        ]
    }

}

private func laneTestTask(
    id: TaskID,
    requirement: SwiftTestRequirement,
    sharedInputs: [ArtifactInput],
    lockName: String
) -> TaskDeclaration {
    TaskDeclaration(
        id: id,
        component: ComponentID(rawValue: "linux"),
        swiftTests: [requirement],
        inputs: sharedInputs,
        postconditions: [requirement.invocation.postcondition],
        locks: [.checkout(lockName)],
        assessmentPolicy: .always)
}
