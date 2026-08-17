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
            let logicalOwners = products.map(\.owner) + tests.map(\.owner)
            lowered.append(
                LoweredExecutionTask(
                    task: materialization.addingLocks(
                        logicalOwnerLocks(owners: logicalOwners)),
                    attribution: "host:swift-package-dependencies",
                    logicalOwners: Set(logicalOwners.map(\.id)),
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
                tasksByID: tasksByID,
                logicalOwners: Set(owners.map(\.id))
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
                tasksByID: tasksByID,
                logicalOwners: Set(owners.map(\.id))
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
            action: try AnyColliderAction(
                SwiftPMDependencyMaterializationAction(
                    command: command,
                    packageRoot: invocation.context.packageRoot,
                    scratchPath: invocation.scratchPath,
                    dependencyCache: execution.hostDependencyCache,
                    lock: lock,
                    dependencyConfigurationFiles: invocation.dependencyConfigurationFiles,
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
        let requestedProducts = Array(Set(requirements.map(\.product))).sorted()
        let buildArguments =
            requestedProducts.count == 1
            ? ["build", "--product", requestedProducts[0]]
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
            locks: [first.invocation.lock] + logicalOwnerLocks(owners: owners),
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
            locks: [first.invocation.lock] + logicalOwnerLocks(owners: owners),
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
        arguments: [[String]]
    ) throws -> AnyColliderAction {
        let processes: [SwiftPMProcess]
        switch invocation.context.execution {
        case .host:
            var hostEnvironment = environment
            hostEnvironment.removeValue(forKey: "NUCLEUS_SWIFT_SOURCE_ID")
            hostEnvironment.removeValue(
                forKey: "NUCLEUS_SWIFT_SDK_GENERATOR_SOURCE_ID")
            processes = arguments.map { arguments in
                SwiftPMProcess(
                    stageName: SwiftPMAction.stageName(arguments: arguments),
                    execution: .host(
                        invocation.command(
                            arguments: arguments,
                            workingDirectory: invocation.context.packageRoot,
                            environment: hostEnvironment)))
            }
        case .oci:
            processes = try arguments.map { arguments in
                SwiftPMProcess(
                    stageName: SwiftPMAction.stageName(arguments: arguments),
                    execution: .oci(
                        try invocation.ociExecution(
                            arguments: arguments,
                            workingDirectory: invocation.context.packageRoot,
                            environment: environment)))
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
                        output: .captured(limit: 64 * 1_024))))
        case .oci:
            binPathQuery = SwiftPMProcess(
                stageName: "swift-package.products-publication",
                execution: .oci(
                    try invocation.ociExecution(
                        arguments: ["build", "--show-bin-path"],
                        workingDirectory: invocation.context.packageRoot,
                        environment: environment,
                        output: .captured(limit: 64 * 1_024))))
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
        var encoder = IdentityEncoder()
        encoder.append(bytes: context.identityBytes)
        for product in products {
            encoder.append(product)
        }
        for target in prebuildTargets {
            encoder.append(target)
        }
        for argument in arguments {
            encoder.append(argument)
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

private enum SwiftPMProcessExecution: Hashable, Sendable {
    case host(CommandSpec)
    case oci(OCIExecution)
}

private struct SwiftPMProcess: Hashable, Sendable {
    let stageName: String
    let execution: SwiftPMProcessExecution
}

private struct SwiftPMAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let processes: [SwiftPMProcess]
        let productsDirectory: FilePath

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(UInt64(processes.count))
            for process in processes {
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
        if identity.processes.contains(where: {
            guard case .oci = $0.execution else { return false }
            return true
        }) {
            try context.files.createDirectory(scratchPath)
            try context.files.remove(productsDirectory)
            try context.files.createDirectory(productsDirectory)
        }
        for (index, process) in identity.processes.enumerated() {
            try context.cancellation.check()
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
            guard result.succeeded else {
                throw result.executionFailure(reason: "Swift package command failed")
            }
            if index == identity.processes.indices.last {
                try publishProductsDirectory(
                    result.standardOutput,
                    context: context)
            }
        }
    }

    fileprivate static func stageName(arguments: [String]) -> String {
        if let index = arguments.firstIndex(of: "--target"),
            arguments.indices.contains(index + 1)
        {
            return "swift-package.compile.\(arguments[index + 1])"
        }
        if let index = arguments.firstIndex(of: "--product"),
            arguments.indices.contains(index + 1)
        {
            return "swift-package.build-product.\(arguments[index + 1])"
        }
        if arguments.contains("--show-bin-path") {
            return "swift-package.products-publication"
        }
        if arguments.first == "build" {
            return "swift-package.build-all-products"
        }
        return "swift-package.\(arguments.first ?? "invoke")"
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
            environment.append(entry.value)
        }
        encoder.appendSequence(command.arguments) { $0.append($1) }
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
    case incompatibleBuildContexts
    case incompatibleTestContexts
    case emptyInvocation
    case invalidDependencyMaterialization
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
        case .invalidBinPath(let value):
            "SwiftPM returned an invalid binary output path: \(value)"
        }
    }
}
