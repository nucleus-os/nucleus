import ColliderCore

private actor OCIExecutionRecorder {
    private var recorded: [OCIExecution] = []

    func append(_ execution: OCIExecution) {
        recorded.append(execution)
    }

    func executions() -> [OCIExecution] {
        recorded
    }
}

func ociExecutions(in operation: TaskOperation) async throws -> [OCIExecution] {
    let recorder = OCIExecutionRecorder()
    try await executeContainerActions(
        in: operation,
        recorder: recorder)
    return await recorder.executions()
}

private func executeContainerActions(
    in operation: TaskOperation,
    recorder: OCIExecutionRecorder
) async throws {
    switch operation {
    case .action(let action):
        guard action.requirements.executionPlatform?.environment == .oci else {
            return
        }
        try await action.execute(
            in: ActionContext(
                files: inertActionFileSystem(),
                cancellation: ActionCancellation {},
                logger: ActionLogger { _ in },
                commands: ActionCommandExecutor { _ in
                    throw ActionContainerExecutorFailure.unavailable
                },
                downloads: ActionDownloader { _, _ in },
                containers: ActionContainerExecutor(
                    prepareImage: { _ in },
                    run: { execution in
                        await recorder.append(execution)
                    })))
    case .runOCI(let execution):
        await recorder.append(execution)
    case .sequence(let operations):
        for operation in operations {
            try await executeContainerActions(
                in: operation,
                recorder: recorder)
        }
    default:
        return
    }
}

private func inertActionFileSystem() -> ActionFileSystem {
    ActionFileSystem(
        metadata: { _ in nil },
        contentsEqual: { _, _ in true },
        createDirectory: { _ in },
        copy: { _, _ in },
        setPermissions: { _, _ in },
        write: { _, _ in })
}
