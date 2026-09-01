import ColliderCore
import Foundation
import SystemPackage

public struct SwiftPMLowering: TaskPlanLowering {
    /// Restricts every test invocation this lowering produces to the tests
    /// whose names match.
    ///
    /// The filter joins the test task's arguments, which already participate in
    /// that task's identity, so a filtered run is a different task from the
    /// unfiltered one and can never record it as satisfied. It reaches SwiftPM
    /// rather than the graph, so the build the tests run against is the same
    /// one either way and no filtered run mints a scratch context of its own.
    /// A test product no name matches is not an error: SwiftPM warns and
    /// succeeds, which is what lets one filter cross several test products.
    private let testFilter: String?

    public init(testFilter: String? = nil) {
        self.testFilter = testFilter
    }

    public func lower(
        _ assessed: [AssessedTaskDeclaration]
    ) throws -> [LoweredExecutionTask] {
        let selected = assessed.filter { !$0.isClean }
        let products = selected.flatMap { assessed in
            assessed.task.swiftProducts.map {
                ProductEntry(owner: assessed.task, requirement: $0)
            }
        }
        let tests = selected.flatMap { assessed in
            assessed.task.swiftTests.map {
                TestEntry(owner: assessed.task, requirement: $0)
            }
        }
        let contexts = Set(
            products.map(\.requirement.invocation.context)
                + tests.map(\.requirement.invocation.context)
        )
        let tasksByID = Dictionary(
            uniqueKeysWithValues: assessed.map { ($0.task.id, $0.task) })

        return try contexts.sorted {
            $0.identityBytes.lexicographicallyPrecedes($1.identityBytes)
        }.flatMap { context in
            try lower(
                context: context,
                products: products.filter {
                    $0.requirement.invocation.context == context
                },
                tests: tests.filter {
                    $0.requirement.invocation.context == context
                },
                tasksByID: tasksByID)
        }
    }

    private func lower(
        context: SwiftBuildContext,
        products: [ProductEntry],
        tests: [TestEntry],
        tasksByID: [TaskID: TaskDeclaration]
    ) throws -> [LoweredExecutionTask] {
        let groupedTests = Dictionary(grouping: tests) {
            $0.requirement.options
        }.sorted {
            SwiftPMOperation.test($0.key).identityArguments.lexicographicallyPrecedes(
                SwiftPMOperation.test($1.key).identityArguments)
        }
        let invocation =
            products.first?.requirement.invocation
            ?? tests.first?.requirement.invocation
        let materialization: LoweredTask?
        if let invocation,
            case .oci = invocation.context.execution,
            invocation.dependencyLock != nil
        {
            materialization = try dependencyMaterializationTask(
                invocation: invocation,
                environment: dependencyEnvironment(products: products, tests: tests))
        } else {
            materialization = nil
        }
        let dependencyPrerequisites = Set(materialization.map { [$0.task.id] } ?? [])
        var lowered: [LoweredExecutionTask] = []
        if let materialization {
            let logicalOwners = products.map(\.owner) + tests.map(\.owner)
            lowered.append(
                LoweredExecutionTask(
                    task: materialization.task.addingLocks(
                        logicalOwnerLocks(owners: logicalOwners)),
                    attribution: "host:swift-package-dependencies",
                    logicalOwners: Set(logicalOwners.map(\.id)),
                    prerequisites: [],
                    identityBytes: materialization.identityBytes))
        }
        if !products.isEmpty {
            lowered.append(
                contentsOf: try loweredBuilds(
                    products,
                    context: context,
                    tasksByID: tasksByID,
                    additionalPrerequisites: dependencyPrerequisites))
        }
        for grouping in groupedTests {
            lowered.append(
                try loweredTest(
                    grouping.value,
                    context: context,
                    tasksByID: tasksByID,
                    additionalPrerequisites: dependencyPrerequisites))
        }
        return lowered
    }

    /// One build per product, because SwiftPM builds either one named product
    /// or the entire package. Grouping several products into one invocation
    /// therefore stops naming them and builds everything in the package, which
    /// compiles targets no consumer asked for and drags their dependencies
    /// into the closure with them. Products sharing a scratch path serialize
    /// on the invocation's lock, so the builds remain incremental against one
    /// another.
    private func loweredBuilds(
        _ entries: [ProductEntry],
        context: SwiftBuildContext,
        tasksByID: [TaskID: TaskDeclaration],
        additionalPrerequisites: Set<TaskID>
    ) throws -> [LoweredExecutionTask] {
        let grouped = Dictionary(grouping: entries) {
            $0.requirement.qualifiedProduct
        }
        // Every owner contributing a product to this context, not just the
        // owners of one product. An action sitting behind any of these builds
        // cannot be a prerequisite of any of them: it cannot run until the
        // build it waits on has completed, and in a graph where two owners'
        // chains cross, treating it as one closes a cycle.
        let contextOwners = Set(entries.map(\.owner.id))
        return try grouped.keys.sorted().map { product in
            let group = grouped[product] ?? []
            let owners = group.map(\.owner)
            let lowered = try buildTask(group.map(\.requirement), owners: owners)
            return LoweredExecutionTask(
                task: lowered.task,
                attribution: attribution(
                    group.map { ($0.owner, $0.requirement.qualifiedProduct) }),
                logicalOwners: Set(owners.map(\.id)),
                prerequisites: prerequisites(
                    for: owners,
                    context: context,
                    tasksByID: tasksByID,
                    logicalOwners: contextOwners
                ).union(additionalPrerequisites),
                identityBytes: lowered.identityBytes)
        }
    }

    private func loweredTest(
        _ tests: [TestEntry],
        context: SwiftBuildContext,
        tasksByID: [TaskID: TaskDeclaration],
        additionalPrerequisites: Set<TaskID>
    ) throws -> LoweredExecutionTask {
        let owners = tests.map(\.owner)
        let lowered = try testTask(tests.map(\.requirement), owners: owners)
        return LoweredExecutionTask(
            task: lowered.task,
            attribution: attribution(
                tests.map { ($0.owner, $0.requirement.qualifiedProduct) }),
            logicalOwners: Set(owners.map(\.id)),
            prerequisites: prerequisites(
                for: owners,
                context: context,
                tasksByID: tasksByID,
                logicalOwners: Set(owners.map(\.id))
            ).union(additionalPrerequisites),
            identityBytes: lowered.identityBytes)
    }

    private func dependencyEnvironment(
        products: [ProductEntry],
        tests: [TestEntry]
    ) -> [String: String] {
        let environments =
            products.map(\.requirement.environment)
            + tests.map(\.requirement.environment)
        guard let first = environments.first else { return [:] }
        return first.filter { name, value in
            environments.allSatisfy { $0[name] == value }
        }
    }

    private func dependencyMaterializationTask(
        invocation: SwiftPMInvocation,
        environment: [String: String]
    ) throws -> LoweredTask {
        guard case .oci(let execution) = invocation.context.execution,
            let lock = invocation.dependencyLock
        else {
            throw SwiftPMLoweringFailure.invalidDependencyMaterialization
        }
        let marker = invocation.scratchPath.appending(
            ".collider/dependencies-resolved")
        let identity = physicalTaskID(
            role: "dependencies",
            context: invocation.context,
            products: [],
            prebuildTargets: [],
            arguments: [lock.string])
        var hostEnvironment = environment
        hostEnvironment.removeValue(forKey: "NUCLEUS_SWIFT_SOURCE_ID")
        hostEnvironment.removeValue(
            forKey: "NUCLEUS_SWIFT_SDK_GENERATOR_SOURCE_ID")
        let command = CommandSpec(
            executable: .named("swift"),
            arguments: [
                "package",
                "--package-path", invocation.context.packageRoot.string,
                "--scratch-path", invocation.scratchPath.string,
                "--cache-path", execution.hostDependencyCache.string,
                "--only-use-versions-from-resolved-file",
                "resolve",
            ],
            workingDirectory: invocation.context.packageRoot,
            environment: hostEnvironment)
        return LoweredTask(
            task: TaskBuilder(
                id: identity.id,
                component: ComponentID(rawValue: "swift-package")
            ).build(
                inputs: [
                    .file(invocation.context.packageRoot.appending("Package.swift")),
                    .file(lock),
                    .tool(.named("swift")),
                ] + invocation.dependencyConfigurationFiles.map(ArtifactInput.file),
                postconditions: [
                    PathPostcondition(path: marker, validation: .regularFile)
                ],
                locks: [
                    invocation.lock,
                    .shared(
                        execution.hostDependencyCache.appending(
                            ".collider.lock")),
                ],
                assessmentPolicy: .incremental,
                durationEstimationMode: invocation.context.configuration.rawValue,
                action: try AnyColliderAction(
                    SwiftPMDependencyMaterializationAction(
                        command: command,
                        packageRoot: invocation.context.packageRoot,
                        scratchPath: invocation.scratchPath,
                        dependencyCache: execution.hostDependencyCache,
                        lock: lock,
                        dependencyConfigurationFiles: invocation.dependencyConfigurationFiles,
                        marker: marker))),
            identityBytes: identity.bytes)
    }

    private func attribution(
        _ entries: [(task: TaskDeclaration, product: String)]
    ) -> String {
        entries.map {
            "\($0.task.component.rawValue):\($0.product)"
        }.sorted().joined(separator: ", ")
    }

    private func prerequisites(
        for owners: [TaskDeclaration],
        context: SwiftBuildContext,
        tasksByID: [TaskID: TaskDeclaration],
        logicalOwners: Set<TaskID>
    ) -> Set<TaskID> {
        var result: Set<TaskID> = []
        for owner in owners {
            for dependency in owner.executionDependencies {
                collectPrerequisite(
                    dependency,
                    context: context,
                    tasksByID: tasksByID,
                    logicalOwners: logicalOwners,
                    into: &result)
            }
        }
        return result
    }

    private func collectPrerequisite(
        _ id: TaskID,
        context: SwiftBuildContext,
        tasksByID: [TaskID: TaskDeclaration],
        logicalOwners: Set<TaskID>,
        into prerequisites: inout Set<TaskID>
    ) {
        guard let task = tasksByID[id] else { return }
        if task.swiftProducts.contains(where: {
            $0.invocation.context == context
        })
            || task.swiftTests.contains(where: {
                $0.invocation.context == context
            })
        {
            for dependency in task.executionDependencies {
                collectPrerequisite(
                    dependency,
                    context: context,
                    tasksByID: tasksByID,
                    logicalOwners: logicalOwners,
                    into: &prerequisites)
            }
        } else if transitivelyDepends(
            task,
            onAnyOf: logicalOwners,
            tasksByID: tasksByID
        ) {
            // This action sits after another owner of the same coalesced build.
            // Making it a compiler prerequisite would make the build wait for
            // an action that cannot run until that build has completed.
        } else {
            prerequisites.insert(id)
        }
    }

    private func transitivelyDepends(
        _ task: TaskDeclaration,
        onAnyOf logicalOwners: Set<TaskID>,
        tasksByID: [TaskID: TaskDeclaration]
    ) -> Bool {
        var pending = task.executionDependencies
        var visited: Set<TaskID> = []
        while let id = pending.popLast() {
            guard visited.insert(id).inserted else { continue }
            if logicalOwners.contains(id) { return true }
            if let dependency = tasksByID[id] {
                pending.append(contentsOf: dependency.executionDependencies)
            }
        }
        return false
    }

    /// Names the fields two requirements for one product disagree on. A
    /// lowering group is a set of requirements the graph expected to be
    /// identical, so the useful question on failure is never that they differ
    /// but which producer disagreed and about what. Reporting the field is what
    /// distinguishes two lanes asking for one product under different
    /// invocations from a single lane whose environment is not stable.
    private static func difference(
        between lhs: SwiftProductRequirement,
        and rhs: SwiftProductRequirement
    ) -> String {
        var fields: [String] = []
        if lhs.invocation.context != rhs.invocation.context {
            fields.append("build context")
        }
        if lhs.invocation.scratchPath != rhs.invocation.scratchPath {
            fields.append(
                "scratch path (\(lhs.invocation.scratchPath) "
                    + "vs \(rhs.invocation.scratchPath))")
        }
        if lhs.invocation.swiftExecutable != rhs.invocation.swiftExecutable {
            fields.append("swift executable")
        }
        if lhs.invocation.dependencyLock != rhs.invocation.dependencyLock {
            fields.append("dependency lock")
        }
        if lhs.invocation.dependencyConfigurationFiles
            != rhs.invocation.dependencyConfigurationFiles
        {
            fields.append("dependency configuration files")
        }
        if lhs.invocation.sourceGraph != rhs.invocation.sourceGraph {
            fields.append("source graph")
        }
        if lhs.environment != rhs.environment {
            let names = Set(lhs.environment.keys)
                .union(rhs.environment.keys)
                .filter { lhs.environment[$0] != rhs.environment[$0] }
                .sorted()
            fields.append("environment (\(names.joined(separator: ", ")))")
        }
        return fields.joined(separator: "; ")
    }

    private func buildTask(
        _ requirements: [SwiftProductRequirement],
        owners: [TaskDeclaration]
    ) throws -> LoweredTask {
        guard let first = requirements.first else {
            throw SwiftPMLoweringFailure.emptyInvocation
        }
        if let mismatch = requirements.first(where: {
            $0.invocation != first.invocation || $0.environment != first.environment
        }) {
            throw SwiftPMLoweringFailure.incompatibleBuildContexts(
                product: first.qualifiedProduct,
                detail: Self.difference(between: first, and: mismatch))
        }

        let products = Array(Set(requirements.map(\.qualifiedProduct))).sorted()
        var inputs = [first.invocation.identityInput]
        inputs += first.invocation.context.toolsets.map(ArtifactInput.file)
        if case .host = first.invocation.context.execution,
            case .artifact = first.invocation.swiftExecutable
        {
            // The typed producer dependency carries the compiler identity.
        } else if case .host = first.invocation.context.execution {
            inputs.append(.tool(first.invocation.swiftExecutable))
        }
        for requirement in requirements.sorted(by: {
            $0.qualifiedProduct < $1.qualifiedProduct
        }) {
            for input in requirement.inputs where !inputs.contains(input) {
                inputs.append(input)
            }
        }
        let prebuildTargets = Array(
            Set(requirements.flatMap(\.prebuildTargets))
        ).sorted()
        let identity = physicalTaskID(
            role: "build",
            context: first.invocation.context,
            products: products,
            prebuildTargets: prebuildTargets)
        let requestedProducts = Array(Set(requirements.map(\.product))).sorted()
        guard requestedProducts.count == 1, let requestedProduct = requestedProducts.first
        else {
            throw SwiftPMLoweringFailure.incompatibleBuildContexts(
                product: first.qualifiedProduct,
                detail: "one group names several products: "
                    + requestedProducts.joined(separator: ", "))
        }
        let buildOperation = SwiftPMOperation.buildProduct(requestedProduct)
        var builder = TaskBuilder(
            id: identity.id,
            component: ComponentID(rawValue: "swift-package"))
        consumeSwiftExecutable(first.invocation, into: &builder)
        consumeOwnerReferences(owners, into: &builder)
        if case .oci(let configuration) = first.invocation.context.execution {
            builder.consume(configuration.image)
        }
        return LoweredTask(
            task: builder.build(
                inputs: inputs,
                postconditions: [first.invocation.postcondition]
                    + uniqued(requirements.flatMap(\.expectedOutputs)),
                locks: [first.invocation.lock] + logicalOwnerLocks(owners: owners),
                assessmentPolicy: assessmentPolicy(for: first.invocation),
                durationEstimationMode: first.invocation.context.configuration.rawValue,
                action: try swiftPMAction(
                    invocation: first.invocation,
                    environment: first.environment,
                    operations: prebuildTargets.map(SwiftPMOperation.buildTarget)
                        + [buildOperation])
            )
            .addingDependencies(owners.flatMap(\.dependencies)),
            identityBytes: identity.bytes)
    }

    private func testTask(
        _ requirements: [SwiftTestRequirement],
        owners: [TaskDeclaration]
    ) throws -> LoweredTask {
        guard let first = requirements.first,
            requirements.allSatisfy({
                $0.invocation == first.invocation
                    && $0.options == first.options
            })
        else {
            throw SwiftPMLoweringFailure.incompatibleTestContexts
        }
        let environments = requirements.map(\.environment)
        let environment = first.environment.filter { name, value in
            environments.allSatisfy { $0[name] == value }
        }
        let testProducts = Array(
            Set(requirements.map(\.qualifiedProduct))
        ).sorted()
        var inputs = [first.invocation.identityInput]
        inputs += first.invocation.context.toolsets.map(ArtifactInput.file)
        if case .host = first.invocation.context.execution,
            case .artifact = first.invocation.swiftExecutable
        {
            // The typed producer dependency carries the compiler identity.
        } else if case .host = first.invocation.context.execution {
            inputs.append(.tool(first.invocation.swiftExecutable))
        }
        for requirement in requirements.sorted(by: {
            $0.qualifiedProduct < $1.qualifiedProduct
        }) {
            for input in requirement.inputs where !inputs.contains(input) {
                inputs.append(input)
            }
        }
        let testOptions = first.options.addingFilter(testFilter)
        let testOperation = SwiftPMOperation.test(testOptions)
        let identity = physicalTaskID(
            role: "test",
            context: first.invocation.context,
            products: testProducts,
            prebuildTargets: [],
            arguments: testOperation.identityArguments)
        var builder = TaskBuilder(
            id: identity.id,
            component: ComponentID(rawValue: "swift-package"))
        consumeSwiftExecutable(first.invocation, into: &builder)
        consumeOwnerReferences(owners, into: &builder)
        if case .oci(let configuration) = first.invocation.context.execution {
            builder.consume(configuration.image)
        }
        return LoweredTask(
            task: builder.build(
                inputs: inputs,
                postconditions: [first.invocation.postcondition]
                    + uniqued(requirements.flatMap(\.expectedBuildOutputs)),
                locks: [first.invocation.lock] + logicalOwnerLocks(owners: owners),
                assessmentPolicy: assessmentPolicy(for: first.invocation),
                durationEstimationMode: first.invocation.context.configuration.rawValue,
                action: try swiftPMAction(
                    invocation: first.invocation,
                    environment: environment,
                    operations: [testOperation],
                    recordsTestResults: true)
            )
            .addingDependencies(owners.flatMap(\.dependencies)),
            identityBytes: identity.bytes)
    }

    private func consumeOwnerReferences(
        _ owners: [TaskDeclaration],
        into builder: inout TaskBuilder
    ) {
        for owner in owners {
            for reference in owner.artifactReferences {
                builder.consume(reference)
            }
        }
    }

    private func logicalOwnerLocks(
        owners: [TaskDeclaration]
    ) -> [TaskLock] {
        var result: [TaskLock] = []
        for lock in owners.flatMap(\.locks) where !result.contains(lock) {
            result.append(lock)
        }
        return result
    }

    private func consumeSwiftExecutable(
        _ invocation: SwiftPMInvocation,
        into builder: inout TaskBuilder
    ) {
        guard case .host = invocation.context.execution,
            case .artifact(let reference) = invocation.swiftExecutable
        else { return }
        builder.consume(reference)
    }

    private func swiftPMAction(
        invocation: SwiftPMInvocation,
        environment: [String: String],
        operations: [SwiftPMOperation],
        recordsTestResults: Bool = false
    ) throws -> AnyColliderAction {
        let processes: [SwiftPMProcess]
        switch invocation.context.execution {
        case .host:
            var hostEnvironment = environment
            hostEnvironment.removeValue(forKey: "NUCLEUS_SWIFT_SOURCE_ID")
            hostEnvironment.removeValue(
                forKey: "NUCLEUS_SWIFT_SDK_GENERATOR_SOURCE_ID")
            processes = operations.enumerated().map { index, operation in
                let results =
                    recordsTestResults
                    ? invocation.testResultsDirectory.appending("swift-test-\(index).xml")
                    : nil
                let executionResults =
                    recordsTestResults
                    ? invocation.executionTestResultsDirectory
                        .appending("swift-test-\(index).xml")
                    : nil
                return SwiftPMProcess(
                    stageName: operation.stageName,
                    execution: .host(
                        invocation.command(
                            arguments: operation.commandArguments
                                + (executionResults.map {
                                    ["--xunit-output", $0.string]
                                } ?? []),
                            workingDirectory: invocation.context.packageRoot,
                            environment: hostEnvironment)),
                    testResults: results,
                    driverRequest: nil,
                    requestPath: nil,
                    eventsPath: nil)
            }
        case .oci where invocation.usesSwiftPMOverlayDriver:
            processes = try operations.enumerated().map { index, operation in
                let results =
                    recordsTestResults
                    ? invocation.testResultsDirectory.appending("swift-test-\(index).xml")
                    : nil
                let executionResults =
                    recordsTestResults
                    ? invocation.executionTestResultsDirectory
                        .appending("swift-test-\(index).xml")
                    : nil
                let requestPath = invocation.productsDirectory.appending(
                    ".collider-driver/request-\(index).json")
                let eventsPath = invocation.productsDirectory.appending(
                    ".collider-driver/events-\(index).jsonl")
                let executionRequestPath = FilePath(
                    "/swiftpm-products/.collider-driver/request-\(index).json")
                let executionEventsPath = FilePath(
                    "/swiftpm-products/.collider-driver/events-\(index).jsonl")
                return SwiftPMProcess(
                    stageName: operation.stageName,
                    execution: .oci(
                        try invocation.ociExecution(
                            arguments: [
                                "nucleus-driver",
                                "--request-path", executionRequestPath.string,
                                "--events-path", executionEventsPath.string,
                            ],
                            workingDirectory: FilePath(
                                invocation.executionPackageRoot),
                            environment: environment)),
                    testResults: results,
                    driverRequest: SwiftPMDriverRequest(
                        invocation: invocation,
                        operation: operation,
                        xUnitOutputPath: executionResults?.string),
                    requestPath: requestPath,
                    eventsPath: eventsPath)
            }
        case .oci:
            processes = try operations.enumerated().map { index, operation in
                let results =
                    recordsTestResults
                    ? invocation.testResultsDirectory.appending("swift-test-\(index).xml")
                    : nil
                let executionResults =
                    recordsTestResults
                    ? invocation.executionTestResultsDirectory
                        .appending("swift-test-\(index).xml")
                    : nil
                return SwiftPMProcess(
                    stageName: operation.stageName,
                    execution: .oci(
                        try invocation.ociExecution(
                            arguments: operation.commandArguments
                                + (executionResults.map {
                                    ["--xunit-output", $0.string]
                                } ?? []),
                            workingDirectory: FilePath(invocation.executionPackageRoot),
                            environment: environment)),
                    testResults: results,
                    driverRequest: nil,
                    requestPath: nil,
                    eventsPath: nil)
            }
        }
        let binPathQuery: SwiftPMProcess
        switch invocation.context.execution {
        case .host:
            var hostEnvironment = environment
            hostEnvironment.removeValue(forKey: "NUCLEUS_SWIFT_SOURCE_ID")
            hostEnvironment.removeValue(
                forKey: "NUCLEUS_SWIFT_SDK_GENERATOR_SOURCE_ID")
            binPathQuery = SwiftPMProcess(
                stageName: "swift-package.products-publication",
                execution: .host(
                    invocation.command(
                        arguments: ["build", "--show-bin-path"],
                        workingDirectory: invocation.context.packageRoot,
                        environment: hostEnvironment,
                        output: .captured(limit: 64 * 1_024))),
                testResults: nil,
                driverRequest: nil,
                requestPath: nil,
                eventsPath: nil)
        case .oci where invocation.usesSwiftPMOverlayDriver:
            let index = operations.count
            let requestPath = invocation.productsDirectory.appending(
                ".collider-driver/request-\(index).json")
            let eventsPath = invocation.productsDirectory.appending(
                ".collider-driver/events-\(index).jsonl")
            binPathQuery = SwiftPMProcess(
                stageName: "swift-package.products-publication",
                execution: .oci(
                    try invocation.ociExecution(
                        arguments: [
                            "nucleus-driver",
                            "--request-path",
                            "/swiftpm-products/.collider-driver/request-\(index).json",
                            "--events-path",
                            "/swiftpm-products/.collider-driver/events-\(index).jsonl",
                            "--export-products",
                        ],
                        workingDirectory: FilePath(invocation.executionPackageRoot),
                        environment: environment,
                        output: .captured(limit: 64 * 1_024))),
                testResults: nil,
                driverRequest: SwiftPMDriverRequest(
                    invocation: invocation,
                    operation: .productsPath,
                    xUnitOutputPath: nil),
                requestPath: requestPath,
                eventsPath: eventsPath)
        case .oci:
            binPathQuery = SwiftPMProcess(
                stageName: "swift-package.products-publication",
                execution: .oci(
                    try invocation.ociExecution(
                        arguments: ["build", "--show-bin-path"],
                        workingDirectory: FilePath(invocation.executionPackageRoot),
                        environment: environment,
                        output: .captured(limit: 64 * 1_024))),
                testResults: nil,
                driverRequest: nil,
                requestPath: nil,
                eventsPath: nil)
        }
        return try AnyColliderAction(
            SwiftPMAction(
                processes: processes + [binPathQuery],
                packageRoot: invocation.context.packageRoot,
                scratchPath: invocation.scratchPath,
                productsDirectory: invocation.productsDirectory))
    }

    private func assessmentPolicy(
        for invocation: SwiftPMInvocation
    ) -> TaskAssessmentPolicy {
        switch invocation.context.execution {
        case .host: .always
        case .oci: .incremental
        }
    }

    /// The task name a SwiftPM invocation gets.
    ///
    /// A name resolves through the declared placement roots for the same
    /// reason an identity does. A lockfile is named absolutely here, so a
    /// name built from the raw string gives one invocation two names across
    /// two checkouts, and a second checkout then finds no recorded state to
    /// compare against rather than finding state that disagrees.
    /// A lowered task's name and the bytes it was derived from.
    ///
    /// The bytes travel with the name because nothing else can recover them.
    /// A lowered task is created after planning has finished, so the identity
    /// explanation planning collects never sees one, and the directory a
    /// SwiftPM context occupies is named for exactly this digest. Carrying them
    /// out is what lets the identity behind that name be read rather than
    /// inferred.
    struct PhysicalTaskIdentity {
        let id: TaskID
        let bytes: [UInt8]
    }

    /// A lowered task beside the identity bytes its name was derived from.
    struct LoweredTask {
        let task: TaskDeclaration
        let identityBytes: [UInt8]
    }

    private func physicalTaskID(
        role: String,
        context: SwiftBuildContext,
        products: [String],
        prebuildTargets: [String],
        arguments: [String] = []
    ) -> PhysicalTaskIdentity {
        var encoder = IdentityEncoder(identityPathMap: context.identityPathMap)
        encoder.append(bytes: context.identityBytes)
        for product in products {
            encoder.append(product)
        }
        for target in prebuildTargets {
            encoder.append(target)
        }
        for argument in arguments {
            encoder.append(argument: argument)
        }
        return PhysicalTaskIdentity(
            id: TaskID(
                rawValue: "swift.package.\(role).\(ArtifactDigest.sha256(encoder.bytes))"),
            bytes: encoder.bytes)
    }

    private func uniqued<Value: Hashable>(_ values: [Value]) -> [Value] {
        values.reduce(into: []) {
            if !$0.contains($1) { $0.append($1) }
        }
    }

    private struct ProductEntry {
        let owner: TaskDeclaration
        let requirement: SwiftProductRequirement
    }

    private struct TestEntry {
        let owner: TaskDeclaration
        let requirement: SwiftTestRequirement
    }
}

private enum SwiftPMProcessExecution: Hashable, Sendable {
    case host(CommandSpec)
    case oci(OCIExecution)
}

private struct SwiftPMProcess: Hashable, Sendable {
    let stageName: String
    let execution: SwiftPMProcessExecution
    let testResults: FilePath?
    let driverRequest: SwiftPMDriverRequest?
    let requestPath: FilePath?
    let eventsPath: FilePath?
}

private enum SwiftPMOperation: Hashable, Sendable {
    case buildProduct(String)
    case buildTarget(String)
    case test(SwiftTestOptions)
    case productsPath

    var commandArguments: [String] {
        switch self {
        case .buildProduct(let product): ["build", "--product", product]
        case .buildTarget(let target): ["build", "--target", target]
        case .test(let options):
            ["test"]
                + options.filters.flatMap { ["--filter", $0] }
                + options.skips.flatMap { ["--skip", $0] }
                + (options.parallel ? ["--parallel"] : [])
                + (options.workers.map { ["--num-workers", String($0)] } ?? [])
        case .productsPath: ["build", "--show-bin-path"]
        }
    }

    var identityArguments: [String] { commandArguments }

    var stageName: String {
        switch self {
        case .buildProduct(let product): "swift-package.build-product.\(product)"
        case .buildTarget(let target): "swift-package.compile.\(target)"
        case .test: "swift-package.test"
        case .productsPath: "swift-package.products-publication"
        }
    }
}

private struct SwiftPMDriverRequest: Codable, Hashable, Sendable {
    struct TestOptions: Codable, Hashable, Sendable {
        let product: String?
        let filters: [String]
        let skips: [String]
        let parallel: Bool
        let workers: Int?
        let xUnitOutputPath: String?
    }

    let operation: String
    let selection: String?
    let test: TestOptions?
    let packagePath: String
    let scratchPath: String
    let cachePath: String?
    let swiftSDKsPath: String?
    let buildSystem: String
    let configuration: String
    let jobs: UInt32
    let debugInformationFormat: String?
    let targetTriple: String?
    let swiftSDK: String?
    let toolsetPaths: [String]
    let staticSwiftStandardLibrary: Bool
    let forceResolvedVersions: Bool
    let sanitizer: String?
    let traits: [String]
    let swiftCompilerFlags: [String]
    let cCompilerFlags: [String]
    let cxxCompilerFlags: [String]
    let linkerFlags: [String]

    init(
        invocation: SwiftPMInvocation,
        operation: SwiftPMOperation,
        xUnitOutputPath: String?
    ) {
        switch operation {
        case .buildProduct(let product):
            self.operation = "buildProduct"
            selection = product
            test = nil
        case .buildTarget(let target):
            self.operation = "buildTarget"
            selection = target
            test = nil
        case .test(let options):
            self.operation = "test"
            selection = nil
            test = TestOptions(
                product: nil,
                filters: options.filters,
                skips: options.skips,
                parallel: options.parallel,
                workers: options.workers,
                xUnitOutputPath: xUnitOutputPath)
        case .productsPath:
            self.operation = "productsPath"
            selection = nil
            test = nil
        }
        packagePath = invocation.executionPackageRoot
        scratchPath = invocation.executionScratchPath.string
        cachePath = nil
        if case .oci = invocation.context.execution,
            case .swiftSDK = invocation.context.target
        {
            swiftSDKsPath = SwiftPMInvocation.ociSwiftSDKDirectory.string
        } else {
            swiftSDKsPath = nil
        }
        buildSystem = invocation.context.buildSystem.rawValue
        configuration = invocation.context.configuration.rawValue
        jobs = invocation.context.maximumParallelism
        debugInformationFormat = invocation.context.debugInformationFormat?.rawValue
        switch invocation.context.target {
        case .host:
            targetTriple = nil
            swiftSDK = nil
        case .triple(let triple):
            targetTriple = triple
            swiftSDK = nil
        case .swiftSDK(let name, let triple):
            targetTriple = triple
            swiftSDK = name
        }
        toolsetPaths = invocation.executionToolsetPaths
        staticSwiftStandardLibrary = invocation.context.staticSwiftStandardLibrary
        forceResolvedVersions = invocation.dependencyLock != nil
        sanitizer = invocation.context.sanitizer
        traits = invocation.context.traits
        swiftCompilerFlags = invocation.context.swiftFlags
        cCompilerFlags = invocation.context.cFlags
        cxxCompilerFlags = invocation.context.cxxFlags
        linkerFlags = invocation.context.linkerFlags
    }
}

private struct SwiftPMDriverEvent: Codable, Sendable {
    let kind: String
    let message: String?
    let target: String?
    let success: Bool?
    let productsPath: String?
}

private struct SwiftPMAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let processes: [SwiftPMProcess]
        let productsDirectory: FilePath

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(UInt64(processes.count))
            for process in processes {
                encoder.appendOptional(process.driverRequest) { requestEncoder, request in
                    let jsonEncoder = JSONEncoder()
                    jsonEncoder.outputFormatting = [.sortedKeys]
                    requestEncoder.append(
                        bytes: Array((try? jsonEncoder.encode(request)) ?? Data()))
                }
                switch process.execution {
                case .host(let command):
                    encoder.append(nested: HostSwiftPMCommandIdentity(command: command))
                case .oci(let execution):
                    encoder.append(nested: OCIExecutionActionIdentity(execution))
                }
            }
            encoder.append(path: productsDirectory)
        }
    }

    static let kind = ActionKind(rawValue: "swift-package.invoke")

    let identity: Identity
    let requirements: ActionRequirements
    let environment: [String: String]
    let productsDirectory: FilePath
    let scratchPath: FilePath

    init(
        processes: [SwiftPMProcess],
        packageRoot: FilePath,
        scratchPath: FilePath,
        productsDirectory: FilePath
    ) throws {
        identity = Identity(
            processes: processes,
            productsDirectory: productsDirectory)
        self.productsDirectory = productsDirectory
        self.scratchPath = scratchPath
        environment =
            processes.first.map {
                switch $0.execution {
                case .host(let command): command.environment
                case .oci(let execution): execution.environment
                }
            } ?? [:]
        switch processes.first {
        case .some(let process) where process.execution.isHost:
            guard case .host(let command) = process.execution else {
                throw SwiftPMLoweringFailure.emptyInvocation
            }
            requirements = ActionRequirements(
                tools: [
                    ActionToolRequirement(
                        "swift",
                        executable: command.executable,
                        role: .semantic)
                ],
                effects: [
                    ActionEffect(.read, scope: .input(packageRoot)),
                    ActionEffect(.readWrite, scope: .scratch(scratchPath)),
                ],
                lane: .hostExclusive,
                executionPlatform: .macOSARM64Native)
        case .some:
            let pipelineRequirements = try OCIExecutionPipeline(
                processes.compactMap {
                    guard case .oci(let execution) = $0.execution else { return nil }
                    return execution
                }
            ).requirements
            requirements = ActionRequirements(
                tools: pipelineRequirements.tools,
                effects: pipelineRequirements.effects.filter {
                    $0.scope.root != scratchPath
                } + [ActionEffect(.readWrite, scope: .scratch(scratchPath))],
                persistentWorkspaceEffects:
                    pipelineRequirements.persistentWorkspaceEffects,
                lane: pipelineRequirements.lane,
                networkAccess: pipelineRequirements.networkAccess,
                executionPlatform: pipelineRequirements.executionPlatform,
                artifactTarget: pipelineRequirements.artifactTarget)
        case nil:
            throw SwiftPMLoweringFailure.emptyInvocation
        }
    }

    func execute(in context: ActionContext) async throws {
        let usesDriver = identity.processes.contains(where: {
            $0.driverRequest != nil
        })
        if usesDriver
            || identity.processes.contains(where: {
                guard case .oci = $0.execution else { return false }
                return true
            })
        {
            try context.files.createDirectory(scratchPath)
            try context.files.remove(productsDirectory)
            try context.files.createDirectory(productsDirectory)
        }
        for results in identity.processes.compactMap(\.testResults) {
            try context.files.createDirectory(results.removingLastComponent())
            try context.files.remove(results)
        }
        for (index, process) in identity.processes.enumerated() {
            try context.cancellation.check()
            if let request = process.driverRequest,
                let requestPath = process.requestPath,
                let eventsPath = process.eventsPath
            {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                try context.files.createDirectory(requestPath.removingLastComponent())
                try context.files.write(Array(try encoder.encode(request)), to: requestPath)
                try context.files.remove(eventsPath)
            }
            let start = ContinuousClock.now
            let result: CommandResult
            switch process.execution {
            case .host(let command):
                result = try await context.commands.execute(command)
            case .oci(let execution):
                result = try await context.containers.execute(execution)
            }
            context.observations.record(
                ActionStageObservation(
                    name: process.stageName,
                    durationNanoseconds: elapsedNanoseconds(since: start),
                    inputByteCount: 0,
                    outputByteCount: 0))
            let driverEvents = try decodeDriverEvents(
                at: process.eventsPath,
                context: context)
            guard result.succeeded else {
                throw result.executionFailure(reason: "Swift package command failed")
            }
            if process.driverRequest != nil {
                guard
                    let completion = driverEvents.last(where: {
                        $0.kind == "completed"
                    }), completion.success == true
                else {
                    throw SwiftPMLoweringFailure.invalidDriverEvents(
                        driverEvents.last?.message ?? "missing successful completion event")
                }
            }
            if let results = process.testResults,
                try context.files.metadata(for: results) != nil
            {
                context.observations.record(
                    testCases: try SwiftXUnitResults.decode(
                        context.files.read(results)))
            }
            if index == identity.processes.indices.last {
                try publishProductsDirectory(
                    driverEvents.last(where: { $0.kind == "completed" })?.productsPath
                        ?? result.standardOutput,
                    context: context)
            }
        }
    }

    private func decodeDriverEvents(
        at path: FilePath?,
        context: ActionContext
    ) throws -> [SwiftPMDriverEvent] {
        guard let path else { return [] }
        guard try context.files.metadata(for: path) != nil else {
            throw SwiftPMLoweringFailure.invalidDriverEvents(
                "driver produced no event stream")
        }
        let bytes = try context.files.read(path)
        return try bytes.split(separator: 0x0A).map {
            try JSONDecoder().decode(SwiftPMDriverEvent.self, from: Data($0))
        }
    }

    private func publishProductsDirectory(
        _ output: String,
        context: ActionContext
    ) throws {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = FilePath(value).lexicallyNormalized()
        guard !value.isEmpty, path.isAbsolute,
            path.isContained(in: scratchPath)
                || path == productsDirectory
        else {
            throw SwiftPMLoweringFailure.invalidBinPath(value)
        }
        if path == productsDirectory { return }
        try context.files.createDirectory(productsDirectory.removingLastComponent())
        try context.files.replaceSymlink(
            at: productsDirectory,
            target: path.string)
    }
}

extension SwiftPMProcessExecution {
    fileprivate var isHost: Bool {
        guard case .host = self else { return false }
        return true
    }
}

private struct HostSwiftPMCommandIdentity: ColliderActionIdentity {
    let command: CommandSpec

    func encode(into encoder: inout IdentityEncoder) {
        encoder.append(path: command.workingDirectory)
        let volatile = Set(["PATH", "NUCLEUS_RUN_DIR", "NUCLEUS_RUN_LOG", "TERM"])
        encoder.appendSequence(
            command.environment.filter({
                !volatile.contains($0.key)
            }).sorted(by: { $0.key < $1.key })
        ) { environment, entry in
            environment.append(entry.key)
            environment.append(argument: entry.value)
        }
        encoder.appendSequence(command.arguments) { $0.append(argument: $1) }
    }
}

private struct SwiftPMDependencyMaterializationAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let command: CommandSpec
        let dependencyCache: FilePath
        let marker: FilePath

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(nested: HostSwiftPMCommandIdentity(command: command))
            encoder.append(path: dependencyCache)
            encoder.append(path: marker)
        }
    }

    static let kind = ActionKind(rawValue: "swift-package.materialize-dependencies")

    let identity: Identity
    let requirements: ActionRequirements
    let environment: [String: String]
    let command: CommandSpec
    let packageManifest: FilePath
    let lock: FilePath
    let dependencyConfigurationFiles: [FilePath]
    let marker: FilePath
    let checkouts: FilePath

    init(
        command: CommandSpec,
        packageRoot: FilePath,
        scratchPath: FilePath,
        dependencyCache: FilePath,
        lock: FilePath,
        dependencyConfigurationFiles: [FilePath],
        marker: FilePath
    ) throws {
        self.command = command
        packageManifest = packageRoot.appending("Package.swift")
        self.lock = lock
        self.dependencyConfigurationFiles = dependencyConfigurationFiles
        self.marker = marker
        checkouts = scratchPath.appending("checkouts")
        identity = Identity(
            command: command,
            dependencyCache: dependencyCache,
            marker: marker)
        environment = command.environment
        requirements = ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "swift",
                    executable: command.executable,
                    role: .semantic)
            ],
            effects: [
                ActionEffect(.read, scope: .input(packageRoot)),
                ActionEffect(.readWrite, scope: .scratch(scratchPath)),
                ActionEffect(.readWrite, scope: .scratch(dependencyCache)),
            ],
            lane: .hostExclusive,
            networkAccess: .unrestricted,
            executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        let result = try await context.commands.execute(command)
        guard result.succeeded else {
            throw result.executionFailure(reason: "Swift package command failed")
        }
        // A pinned dependency is identified by its revision, so when this
        // materialization happened to run is not part of it. Compilation
        // records source timestamps, and carrying the moment of a fetch into a
        // product makes the product unreproducible on any machine that fetched
        // at a different moment.
        try context.files.normalizeTimestamps(
            under: checkouts,
            toSecondsSinceEpoch: pinnedDependencyTimestamp)
        try context.files.createDirectory(marker.removingLastComponent())
        var encoder = IdentityEncoder()
        encoder.append(try context.files.digest(file: packageManifest).description)
        encoder.append(try context.files.digest(file: lock).description)
        for configuration in dependencyConfigurationFiles {
            encoder.append(try context.files.digest(file: configuration).description)
        }
        let digest = ArtifactDigest.sha256(encoder.bytes)
        try context.files.write(Array("\(digest)\n".utf8), to: marker)
    }
}

public enum SwiftPMLoweringFailure: Error, CustomStringConvertible, Sendable {
    case incompatibleBuildContexts(product: String, detail: String)
    case incompatibleTestContexts
    case emptyInvocation
    case invalidDependencyMaterialization
    case invalidBinPath(String)
    case invalidDriverEvents(String)

    public var description: String {
        switch self {
        case .incompatibleBuildContexts(let product, let detail):
            """
            Swift product requirements for \(product) in one lowering group \
            have incompatible contexts: \(detail)
            """
        case .incompatibleTestContexts:
            "Swift test requirements in one lowering group have incompatible contexts"
        case .emptyInvocation:
            "SwiftPM lowering produced an empty physical invocation"
        case .invalidDependencyMaterialization:
            "SwiftPM dependency materialization requires an OCI invocation with a lockfile"
        case .invalidBinPath(let value):
            "SwiftPM returned an invalid binary output path: \(value)"
        case .invalidDriverEvents(let value):
            "Nucleus SwiftPM driver returned an invalid event stream: \(value)"
        }
    }
}

/// The one modification time every materialized dependency carries.
///
/// The value is arbitrary and its stability is the point: it has to be the
/// same on every machine and in every checkout, so it cannot be derived from
/// anything local. This is the first second of 2026 in UTC.
private let pinnedDependencyTimestamp: Int64 = 1_767_225_600
