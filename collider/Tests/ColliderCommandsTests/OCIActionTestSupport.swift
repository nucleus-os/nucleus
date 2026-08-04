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

func ociExecutions(in action: AnyColliderAction?) async throws -> [OCIExecution] {
    let recorder = OCIExecutionRecorder()
    try await executeContainerAction(action, recorder: recorder)
    return await recorder.executions()
}

private func executeContainerAction(
    _ action: AnyColliderAction?,
    recorder: OCIExecutionRecorder
) async throws {
    guard let action,
        action.requirements.executionPlatform?.environment == .oci
    else { return }
    try await action.execute(
        in: ActionContext(
            files: inertActionFileSystem(),
            cancellation: ActionCancellation {},
            logger: ActionLogger { _ in },
            commands: ActionCommandExecutor { _ in
                CommandResult(status: 0)
            },
            downloads: ActionDownloader { _, _ in },
            containers: ActionContainerExecutor(
                prepareImage: { _ in },
                run: { execution in
                    await recorder.append(execution)
                    return CommandResult(status: 0)
                })))
}

private func inertActionFileSystem() -> ActionFileSystem {
    ActionFileSystem(
        metadata: { _ in nil },
        contentsEqual: { _, _ in true },
        createDirectory: { _ in },
        copy: { _, _ in },
        remove: { _ in },
        setPermissions: { _, _ in },
        write: { _, _ in })
}
