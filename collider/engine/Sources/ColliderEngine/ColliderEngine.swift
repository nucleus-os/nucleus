import ColliderCore
import ColliderPersistence
import ColliderPlanning
import ColliderRuntime
import Foundation
import SystemPackage

public struct ColliderEngine: Sendable {
    public let runtime: ColliderRuntime

    public init(runtime: ColliderRuntime) {
        self.runtime = runtime
    }

    public func execute(
        graph: TaskGraph,
        selected: [TaskID],
        stateRoot: FilePath,
        identityPathMap: IdentityPathMap = .empty,
        workflowLocks: [TaskLock] = [],
        lowerings: [any TaskPlanLowering] = [],
        run: RunHandle? = nil,
        registry: RunRegistry? = nil,
        options: TaskExecutionOptions = TaskExecutionOptions()
    ) async throws -> TaskExecutionReport {
        try await execute(
            stateRoot: stateRoot,
            identityPathMap: identityPathMap,
            workflowLocks: workflowLocks,
            run: run,
            registry: registry,
            options: options
        ) { services in
            try ColliderPlanner().plan(
                graph: graph,
                selected: selected,
                rebuildSelected: options.rebuildSelected,
                lowerings: lowerings,
                services: services)
        }
    }

    public func execute(
        catalog: ComponentCatalog,
        requests: [ComponentEntrypointRequest],
        stateRoot: FilePath,
        identityPathMap: IdentityPathMap = .empty,
        workflowLocks: [TaskLock] = [],
        lowerings: [any TaskPlanLowering] = [],
        run: RunHandle? = nil,
        registry: RunRegistry? = nil,
        options: TaskExecutionOptions = TaskExecutionOptions()
    ) async throws -> TaskExecutionReport {
        try await execute(
            stateRoot: stateRoot,
            identityPathMap: identityPathMap,
            workflowLocks: workflowLocks,
            run: run,
            registry: registry,
            options: options
        ) { services in
            try ColliderPlanner().plan(
                catalog: catalog,
                requests: requests,
                rebuildSelected: options.rebuildSelected,
                lowerings: lowerings,
                services: services)
        }
    }

    private func execute(
        stateRoot: FilePath,
        identityPathMap: IdentityPathMap,
        workflowLocks: [TaskLock],
        run: RunHandle?,
        registry: RunRegistry?,
        options: TaskExecutionOptions,
        planning: (TaskPlanningServices) throws -> ExecutionPlan
    ) async throws -> TaskExecutionReport {
        try FileManager.default.createDirectory(
            atPath: stateRoot.string,
            withIntermediateDirectories: true)
        let state = try TaskStateStore(root: stateRoot).snapshot()
        let planningInputs = PlanningInputProvider(
            digestIndex: stateRoot.appending("artifact-digests.json"))
        let outputValidator = TaskOutputValidator(
            fileSystem: runtime.actionFileSystem())
        let services = TaskPlanningServices(
            identityPathMap: identityPathMap,
            digestBytes: planningInputs.digest(bytes:),
            digestFile: planningInputs.digest(file:),
            digestTree: planningInputs.digest(tree:),
            digestSourceCheckout: planningInputs.digest(sourceCheckout:),
            optionalSourceCheckoutDigest:
                planningInputs.optionalSourceCheckoutDigest,
            semanticToolIdentity: planningInputs.semanticToolIdentity,
            taskState: state.lookup,
            validateOutputs: outputValidator.validate)
        let planningStart = ContinuousClock().now
        let plan = try planning(services)
        let planningDuration = elapsedNanoseconds(since: planningStart)
        let hashingDuration = planningInputs.hashingDurationNanoseconds
        try planningInputs.persistDigestIndex()
        return try await runtime.execute(
            plan: plan,
            stateRoot: stateRoot,
            workflowLocks: workflowLocks,
            run: run,
            registry: registry,
            options: options,
            planningDurationNanoseconds: planningDuration,
            selectedInputHashingDurationNanoseconds: hashingDuration)
    }
}
