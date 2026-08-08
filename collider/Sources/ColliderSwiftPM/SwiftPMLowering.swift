import ColliderCore
import SystemPackage

public struct SwiftPMLowering: TaskPlanLowering {
    public init() {}

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
            $0.requirement.arguments
        }.sorted {
            $0.key.lexicographicallyPrecedes($1.key)
        }
        let invocation =
            products.first?.requirement.invocation
            ?? tests.first?.requirement.invocation
        let materialization: TaskDeclaration?
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
        let dependencyPrerequisites = Set(materialization.map { [$0.id] } ?? [])
        var lowered: [LoweredExecutionTask] = []
        if let materialization {
            let owners = Set(
                products.map(\.owner.id) + tests.map(\.owner.id))
            lowered.append(
                LoweredExecutionTask(
                    task: materialization,
                    attribution: "host:swift-package-dependencies",
                    logicalOwners: owners,
                    prerequisites: []))
        }
        if !products.isEmpty {
            lowered.append(
                try loweredBuild(
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

    private func loweredBuild(
        _ entries: [ProductEntry],
        context: SwiftBuildContext,
        tasksByID: [TaskID: TaskDeclaration],
        additionalPrerequisites: Set<TaskID>
    ) throws -> LoweredExecutionTask {
        let owners = entries.map(\.owner)
        return LoweredExecutionTask(
            task: try buildTask(
                entries.map(\.requirement),
                owners: owners),
            attribution: attribution(
                entries.map { ($0.owner, $0.requirement.qualifiedProduct) }),
            logicalOwners: Set(owners.map(\.id)),
            prerequisites: prerequisites(
                for: owners,
                context: context,
                tasksByID: tasksByID
            ).union(additionalPrerequisites))
    }

    private func loweredTest(
        _ tests: [TestEntry],
        context: SwiftBuildContext,
        tasksByID: [TaskID: TaskDeclaration],
        additionalPrerequisites: Set<TaskID>
    ) throws -> LoweredExecutionTask {
        let owners = tests.map(\.owner)
        return LoweredExecutionTask(
            task: try testTask(
                tests.map(\.requirement),
                owners: owners),
            attribution: attribution(
                tests.map { ($0.owner, $0.requirement.qualifiedProduct) }),
            logicalOwners: Set(owners.map(\.id)),
            prerequisites: prerequisites(
                for: owners,
                context: context,
                tasksByID: tasksByID
            ).union(additionalPrerequisites))
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
    ) throws -> TaskDeclaration {
        guard case .oci(let execution) = invocation.context.execution,
            let lock = invocation.dependencyLock
        else {
            throw SwiftPMLoweringFailure.invalidDependencyMaterialization
        }
        let marker = invocation.scratchPath.appending(
            ".collider/dependencies-resolved")
        let taskID = physicalTaskID(
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
        return TaskBuilder(
            id: taskID,
            component: ComponentID(rawValue: "swift-package")
        ).build(
            inputs: [
                .file(invocation.context.packageRoot.appending("Package.swift")),
                .file(lock),
                .tool(.named("swift")),
            ],
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
            action: try AnyColliderAction(
                SwiftPMDependencyMaterializationAction(
                    command: command,
                    packageRoot: invocation.context.packageRoot,
                    scratchPath: invocation.scratchPath,
                    dependencyCache: execution.hostDependencyCache,
                    marker: marker)))
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
        tasksByID: [TaskID: TaskDeclaration]
    ) -> Set<TaskID> {
        var result: Set<TaskID> = []
        for owner in owners {
            for dependency in owner.executionDependencies {
                collectPrerequisite(
                    dependency,
                    context: context,
                    tasksByID: tasksByID,
                    into: &result)
            }
        }
        return result
    }

    private func collectPrerequisite(
        _ id: TaskID,
        context: SwiftBuildContext,
        tasksByID: [TaskID: TaskDeclaration],
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
                    into: &prerequisites)
            }
        } else {
            prerequisites.insert(id)
        }
    }

    private func buildTask(
        _ requirements: [SwiftProductRequirement],
        owners: [TaskDeclaration]
    ) throws -> TaskDeclaration {
        guard let first = requirements.first,
            requirements.allSatisfy({
                $0.invocation == first.invocation
                    && $0.environment == first.environment
            })
        else {
            throw SwiftPMLoweringFailure.incompatibleBuildContexts
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
        let taskID = physicalTaskID(
            role: "build",
            context: first.invocation.context,
            products: products,
            prebuildTargets: prebuildTargets)
        let buildArguments =
            requirements.count == 1
            ? ["build", "--product", first.product]
            : ["build"]
        var builder = TaskBuilder(
            id: taskID,
            component: ComponentID(rawValue: "swift-package"))
        consumeSwiftExecutable(first.invocation, into: &builder)
        consumeOwnerReferences(owners, into: &builder)
        if case .oci(let configuration) = first.invocation.context.execution {
            builder.consume(configuration.image)
        }
        return builder.build(
            inputs: inputs,
            postconditions: [first.invocation.postcondition]
                + uniqued(requirements.flatMap(\.expectedOutputs)),
            locks: [first.invocation.lock],
            assessmentPolicy: assessmentPolicy(for: first.invocation),
            action: try swiftPMAction(
                invocation: first.invocation,
                environment: first.environment,
                arguments: prebuildTargets.map {
                    ["build", "--target", $0]
                } + [buildArguments])
        )
        .addingDependencies(owners.flatMap(\.dependencies))
    }

    private func testTask(
        _ requirements: [SwiftTestRequirement],
        owners: [TaskDeclaration]
    ) throws -> TaskDeclaration {
        guard let first = requirements.first,
            requirements.allSatisfy({
                $0.invocation == first.invocation
                    && $0.arguments == first.arguments
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
        let taskID = physicalTaskID(
            role: "test",
            context: first.invocation.context,
            products: testProducts,
            prebuildTargets: [],
            arguments: first.arguments)
        var builder = TaskBuilder(
            id: taskID,
            component: ComponentID(rawValue: "swift-package"))
        consumeSwiftExecutable(first.invocation, into: &builder)
        consumeOwnerReferences(owners, into: &builder)
        if case .oci(let configuration) = first.invocation.context.execution {
            builder.consume(configuration.image)
        }
        return builder.build(
            inputs: inputs,
            postconditions: [first.invocation.postcondition]
                + uniqued(requirements.flatMap(\.expectedBuildOutputs)),
            locks: [first.invocation.lock],
            assessmentPolicy: assessmentPolicy(for: first.invocation),
            action: try swiftPMAction(
                invocation: first.invocation,
                environment: environment,
                arguments: [["test"] + first.arguments])
        )
        .addingDependencies(owners.flatMap(\.dependencies))
    }

    private func consumeOwnerReferences(
        _ owners: [TaskDeclaration],
        into builder: inout TaskBuilder
    ) {
        for owner in owners {
            for reference in owner.artifactReferences {
                builder.consume(reference)
            }
            for reference in owner.resultReferences {
                builder.consume(reference)
            }
        }
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
        arguments: [[String]]
    ) throws -> AnyColliderAction {
        let processes: [SwiftPMProcess]
        switch invocation.context.execution {
        case .host:
            var hostEnvironment = environment
            hostEnvironment.removeValue(forKey: "NUCLEUS_SWIFT_SOURCE_ID")
            hostEnvironment.removeValue(
                forKey: "NUCLEUS_SWIFT_SDK_GENERATOR_SOURCE_ID")
            processes = arguments.map {
                .host(
                    invocation.command(
                        arguments: $0,
                        workingDirectory: invocation.context.packageRoot,
                        environment: hostEnvironment))
            }
        case .oci:
            processes = try arguments.map {
                .oci(
                    try invocation.ociExecution(
                        arguments: $0,
                        workingDirectory: invocation.context.packageRoot,
                        environment: environment))
            }
        }
        let binPathQuery: SwiftPMProcess
        switch invocation.context.execution {
        case .host:
            var hostEnvironment = environment
            hostEnvironment.removeValue(forKey: "NUCLEUS_SWIFT_SOURCE_ID")
            hostEnvironment.removeValue(
                forKey: "NUCLEUS_SWIFT_SDK_GENERATOR_SOURCE_ID")
            binPathQuery = .host(
                invocation.command(
                    arguments: ["build", "--show-bin-path"],
                    workingDirectory: invocation.context.packageRoot,
                    environment: hostEnvironment,
                    output: .captured(limit: 64 * 1_024)))
        case .oci:
            binPathQuery = .oci(
                try invocation.ociExecution(
                    arguments: ["build", "--show-bin-path"],
                    workingDirectory: invocation.context.packageRoot,
                    environment: environment,
                    output: .captured(limit: 64 * 1_024)))
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

    private func physicalTaskID(
        role: String,
        context: SwiftBuildContext,
        products: [String],
        prebuildTargets: [String],
        arguments: [String] = []
    ) -> TaskID {
        var encoder = CanonicalDigestEncoder()
        encoder.append(tag: 1, bytes: context.identityBytes)
        for product in products {
            encoder.append(tag: 2, string: product)
        }
        for target in prebuildTargets {
            encoder.append(tag: 3, string: target)
        }
        for argument in arguments {
            encoder.append(tag: 4, string: argument)
        }
        return TaskID(
            rawValue: "swift.package.\(role).\(ArtifactDigest.sha256(encoder.bytes))")
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

private enum SwiftPMProcess: Hashable, Sendable {
    case host(CommandSpec)
    case oci(OCIExecution)
}

private struct SwiftPMAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let processes: [SwiftPMProcess]
        let productsDirectory: FilePath

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, integer: UInt64(processes.count))
            for (index, process) in processes.enumerated() {
                let tag = UInt64(index + 2)
                switch process {
                case .host(let command):
                    encoder.append(
                        tag: tag,
                        nested: HostSwiftPMCommandIdentity(command: command))
                case .oci(let execution):
                    encoder.append(
                        tag: tag,
                        nested: OCIExecutionActionIdentity(execution))
                }
            }
            encoder.append(
                tag: UInt64(processes.count + 2),
                string: productsDirectory.string)
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
                switch $0 {
                case .host(let command): command.environment
                case .oci(let execution): execution.environment
                }
            } ?? [:]
        switch processes.first {
        case .host(let command):
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
        case .oci:
            requirements = try OCIExecutionPipeline(
                processes.compactMap {
                    guard case .oci(let execution) = $0 else { return nil }
                    return execution
                }
            ).requirements
        case nil:
            throw SwiftPMLoweringFailure.emptyInvocation
        }
    }

    func execute(in context: ActionContext) async throws {
        for (index, process) in identity.processes.enumerated() {
            try context.cancellation.check()
            let result: CommandResult
            switch process {
            case .host(let command):
                result = try await context.commands.execute(command)
            case .oci(let execution):
                result = try await context.containers.execute(execution)
            }
            guard result.status == 0 else {
                throw SwiftPMLoweringFailure.commandFailed(result.status)
            }
            if index == identity.processes.indices.last {
                try publishProductsDirectory(
                    result.standardOutput,
                    context: context)
            }
        }
    }

    private func publishProductsDirectory(
        _ output: String,
        context: ActionContext
    ) throws {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = FilePath(value).lexicallyNormalized()
        guard !value.isEmpty, path.isAbsolute, path.isContained(in: scratchPath)
        else {
            throw SwiftPMLoweringFailure.invalidBinPath(value)
        }
        try context.files.createDirectory(productsDirectory.removingLastComponent())
        try context.files.replaceSymlink(
            at: productsDirectory,
            target: path.string)
    }
}

private struct HostSwiftPMCommandIdentity: ColliderActionIdentity {
    let command: CommandSpec

    func encode(into encoder: inout ActionIdentityEncoder) {
        encoder.append(tag: 1, string: command.workingDirectory.string)
        var environment = CanonicalDigestEncoder()
        let volatile = Set(["PATH", "NUCLEUS_RUN_DIR", "NUCLEUS_RUN_LOG", "TERM"])
        for (name, value) in command.environment.filter({
            !volatile.contains($0.key)
        }).sorted(by: { $0.key < $1.key }) {
            environment.append(tag: 1, string: name)
            environment.append(tag: 2, string: value)
        }
        encoder.append(tag: 2, bytes: environment.bytes)
        var arguments = CanonicalDigestEncoder()
        for argument in command.arguments {
            arguments.append(tag: 1, string: argument)
        }
        encoder.append(tag: 3, bytes: arguments.bytes)
    }
}

private struct SwiftPMDependencyMaterializationAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let command: CommandSpec
        let dependencyCache: FilePath
        let marker: FilePath

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(
                tag: 1,
                nested: HostSwiftPMCommandIdentity(command: command))
            encoder.append(tag: 2, string: dependencyCache.string)
            encoder.append(tag: 3, string: marker.string)
        }
    }

    static let kind = ActionKind(rawValue: "swift-package.materialize-dependencies")

    let identity: Identity
    let requirements: ActionRequirements
    let environment: [String: String]
    let command: CommandSpec
    let marker: FilePath

    init(
        command: CommandSpec,
        packageRoot: FilePath,
        scratchPath: FilePath,
        dependencyCache: FilePath,
        marker: FilePath
    ) throws {
        self.command = command
        self.marker = marker
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
        guard result.status == 0 else {
            throw SwiftPMLoweringFailure.commandFailed(result.status)
        }
        try context.files.createDirectory(marker.removingLastComponent())
        try context.files.write(Array("resolved\n".utf8), to: marker)
    }
}

public enum SwiftPMLoweringFailure: Error, CustomStringConvertible, Sendable {
    case incompatibleBuildContexts
    case incompatibleTestContexts
    case emptyInvocation
    case invalidDependencyMaterialization
    case commandFailed(Int32)
    case invalidBinPath(String)

    public var description: String {
        switch self {
        case .incompatibleBuildContexts:
            "Swift product requirements in one lowering group have incompatible contexts"
        case .incompatibleTestContexts:
            "Swift test requirements in one lowering group have incompatible contexts"
        case .emptyInvocation:
            "SwiftPM lowering produced an empty physical invocation"
        case .invalidDependencyMaterialization:
            "SwiftPM dependency materialization requires an OCI invocation with a lockfile"
        case .commandFailed(let status):
            "SwiftPM command failed with status \(status)"
        case .invalidBinPath(let value):
            "SwiftPM returned an invalid binary output path: \(value)"
        }
    }
}
