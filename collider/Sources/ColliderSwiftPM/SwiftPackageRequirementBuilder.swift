import ColliderCore
import SystemPackage

public struct SwiftPackageRequirementBuilder: Sendable {
    public let component: ComponentID
    public let package: String
    public let packageRoot: FilePath
    public let sourceTrees: [FilePath]
    public let testTrees: [FilePath]
    public let lock: TaskLock
    public let invocation: SwiftPMInvocation
    public let environment: [String: String]

    public init(
        component: ComponentID,
        package: String,
        packageRoot: FilePath,
        sourceTrees: [FilePath],
        testTrees: [FilePath] = [],
        lock: TaskLock,
        invocation: SwiftPMInvocation,
        environment: [String: String]
    ) {
        self.component = component
        self.package = package
        self.packageRoot = packageRoot
        self.sourceTrees = sourceTrees
        self.testTrees = testTrees
        self.lock = lock
        self.invocation = invocation
        self.environment = environment
    }

    public func build(
        id: TaskID,
        products: [String],
        dependencies: [TaskID] = [],
        prebuildTargets: [String] = [],
        expectedOutputs: [PathPostcondition] = [],
        additionalInputs: [ArtifactInput] = [],
        additionalPostconditions: [PathPostcondition] = []
    ) -> TaskDeclaration {
        TaskDeclaration(
            id: id,
            component: component,
            dependencies: dependencies,
            swiftProducts: products.map { product in
                invocation.product(
                    package: package,
                    product: product,
                    packageRoot: packageRoot,
                    environment: environment,
                    prebuildTargets: prebuildTargets,
                    expectedOutputs: expectedOutputs)
            },
            inputs: declaredInputs(includeTests: false) + additionalInputs,
            postconditions: [invocation.postcondition] + additionalPostconditions,
            locks: [lock])
    }

    public func test(
        id: TaskID,
        testProduct: String,
        dependencies: [TaskID] = [],
        subsumedBuild: TaskID? = nil,
        arguments: [String] = [],
        expectedBuildOutputs: [PathPostcondition] = [],
        additionalInputs: [ArtifactInput] = [],
        additionalPostconditions: [PathPostcondition] = []
    ) -> TaskDeclaration {
        TaskDeclaration(
            id: id,
            component: component,
            dependencies: dependencies,
            subsumedDependencies: subsumedBuild.map { [$0] } ?? [],
            swiftTests: [
                invocation.testProduct(
                    package: package,
                    testProduct: testProduct,
                    packageRoot: packageRoot,
                    environment: environment,
                    arguments: arguments,
                    expectedBuildOutputs: expectedBuildOutputs)
            ],
            inputs: declaredInputs(includeTests: true) + additionalInputs,
            postconditions: [invocation.postcondition] + additionalPostconditions,
            locks: [lock],
            assessmentPolicy: .always)
    }

    private func declaredInputs(includeTests: Bool) -> [ArtifactInput] {
        sourceTrees.map(ArtifactInput.tree)
            + (includeTests ? testTrees.map(ArtifactInput.tree) : [])
            + [invocation.identityInput]
    }
}
