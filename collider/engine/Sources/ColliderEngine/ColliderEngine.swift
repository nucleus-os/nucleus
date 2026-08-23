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
        hostPhases: HostPhaseRecorder? = nil,
        options: TaskExecutionOptions = TaskExecutionOptions()
    ) async throws -> TaskExecutionReport {
        try await execute(
            stateRoot: stateRoot,
            identityPathMap: identityPathMap,
            workflowLocks: workflowLocks,
            run: run,
            registry: registry,
            hostPhases: hostPhases,
            options: options
        ) { services in
            try await ColliderPlanner().plan(
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
        hostPhases: HostPhaseRecorder? = nil,
        options: TaskExecutionOptions = TaskExecutionOptions()
    ) async throws -> TaskExecutionReport {
        try await execute(
            stateRoot: stateRoot,
            identityPathMap: identityPathMap,
            workflowLocks: workflowLocks,
            run: run,
            registry: registry,
            hostPhases: hostPhases,
            options: options
        ) { services in
            try await ColliderPlanner().plan(
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
        hostPhases: HostPhaseRecorder?,
        options: TaskExecutionOptions,
        planning: (TaskPlanningServices) async throws -> ExecutionPlan
    ) async throws -> TaskExecutionReport {
        if !options.dryRun {
            try FileManager.default.createDirectory(
                atPath: stateRoot.string,
                withIntermediateDirectories: true)
        }
        let durationStore = TaskDurationEstimateStore(
            root: stateRoot.appending("duration-estimates"))
        let planningResult = try await
            (hostPhases ?? HostPhaseRecorder(registry: registry, run: run))
            .withPhase("planning and input hashing") {
                let planningStart = ContinuousClock().now
                let state = try TaskStateStore(root: stateRoot).snapshot()
                let durationEstimates = durationStore.snapshot()
                let planningInputs = PlanningInputProvider(
                    digestIndex: stateRoot.appending("artifact-digests.json"))
                let outputValidator = TaskOutputValidator(
                    fileSystem: runtime.actionFileSystem())
                func services(
                    validatingOCIImages imageValidator: OCIImageOutputValidator? = nil
                ) -> TaskPlanningServices {
                    TaskPlanningServices(
                        identityPathMap: identityPathMap,
                        digestBytes: planningInputs.digest(bytes:),
                        digestFile: planningInputs.digest(file:),
                        digestTree: planningInputs.digest(tree:),
                        digestSourceCheckout: planningInputs.digest(sourceCheckout:),
                        digestSourceCheckoutClosure:
                            planningInputs.digest(sourceCheckoutClosure:),
                        semanticToolIdentity: planningInputs.semanticToolIdentity,
                        taskState: state.lookup,
                        durationEstimate: durationEstimates.estimate,
                        validateOutputs: { task in
                            try outputValidator.validate(task)
                            try imageValidator?.validate(task)
                        },
                        observeIdentity: options.identityObserver)
                }
                var plan = try await planning(services())
                // A dry run reports what planning decided. Confirming that a
                // clean image output is still present in the image store means
                // asking the container service, which only the builder account
                // runs, so an inspection from the interactive account would
                // fail for want of a service it is deliberately without. The
                // account that executes revalidates before it executes.
                if runtime.hasOCIRuntimeBackend,
                    !options.dryRun,
                    plan.containsCleanOCIImageOutput
                {
                    let imageValidator = OCIImageOutputValidator(
                        images: try await runtime.ociImages())
                    plan = try await planning(
                        services(validatingOCIImages: imageValidator))
                }
                let hashingDuration = planningInputs.hashingDurationNanoseconds
                if !options.dryRun {
                    try planningInputs.persistDigestIndex()
                }
                return (
                    plan,
                    hashingDuration,
                    elapsedNanoseconds(since: planningStart)
                )
            }
        let (plan, hashingDuration, planningDuration) = planningResult
        let report = try await runtime.execute(
            plan: plan,
            stateRoot: stateRoot,
            workflowLocks: workflowLocks,
            run: run,
            registry: registry,
            options: options,
            planningDurationNanoseconds: planningDuration,
            selectedInputHashingDurationNanoseconds: hashingDuration)
        if !options.dryRun {
            try? durationStore.record(
                Dictionary(
                    uniqueKeysWithValues: report.taskTimings.map {
                        ($0.task, $0.durationNanoseconds)
                    }),
                plan: report.plan)
        }
        return report
    }
}
