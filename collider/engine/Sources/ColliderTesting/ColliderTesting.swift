import ColliderCore
import Synchronization
import SystemPackage

public struct RecordedActionExecution: Sendable {
    public let imagePreparations: [OCIImagePreparation]
    public let ociExecutions: [OCIExecution]
    public let hardwareProbes: [HardwareProbeObservation]

    public init(
        imagePreparations: [OCIImagePreparation],
        ociExecutions: [OCIExecution],
        hardwareProbes: [HardwareProbeObservation]
    ) {
        self.imagePreparations = imagePreparations
        self.ociExecutions = ociExecutions
        self.hardwareProbes = hardwareProbes
    }
}

private struct ActionExecutionRecording: Sendable {
    var imagePreparations: [OCIImagePreparation] = []
    var ociExecutions: [OCIExecution] = []
    var hardwareProbes: [HardwareProbeObservation] = []
}

public func recordActionExecution(
    _ action: AnyColliderAction?,
    commandResult: @escaping @Sendable (CommandSpec) async throws -> CommandResult = {
        _ in CommandResult(status: 0)
    },
    containerResult: @escaping @Sendable (OCIExecution) async throws -> CommandResult = {
        _ in CommandResult(status: 0)
    }
) async throws -> RecordedActionExecution {
    let recording = Mutex(ActionExecutionRecording())
    guard let action else {
        return RecordedActionExecution(
            imagePreparations: [],
            ociExecutions: [],
            hardwareProbes: [])
    }
    try await action.execute(
        in: ActionContext(
            files: inertActionFileSystem(),
            cancellation: ActionCancellation {},
            logger: ActionLogger { _ in },
            commands: ActionCommandExecutor(execute: commandResult),
            downloads: ActionDownloader { _, _ in },
            containers: ActionContainerExecutor(
                prepareImage: { preparation in
                    recording.withLock {
                        $0.imagePreparations.append(preparation)
                    }
                },
                run: { execution in
                    recording.withLock {
                        $0.ociExecutions.append(execution)
                    }
                    return try await containerResult(execution)
                }),
            observations: ActionObservationRecorder { observation in
                recording.withLock {
                    $0.hardwareProbes.append(observation)
                }
            }))
    return recording.withLock {
        RecordedActionExecution(
            imagePreparations: $0.imagePreparations,
            ociExecutions: $0.ociExecutions,
            hardwareProbes: $0.hardwareProbes)
    }
}

public func recordOCIActionExecution(
    _ action: AnyColliderAction?,
    commandResult: @escaping @Sendable (CommandSpec) async throws -> CommandResult = {
        _ in CommandResult(status: 0)
    },
    containerResult: @escaping @Sendable (OCIExecution) async throws -> CommandResult = {
        _ in CommandResult(status: 0)
    }
) async throws -> RecordedActionExecution {
    guard let action,
        action.requirements.executionPlatform.environment == .oci
    else {
        return RecordedActionExecution(
            imagePreparations: [],
            ociExecutions: [],
            hardwareProbes: [])
    }
    return try await recordActionExecution(
        action,
        commandResult: commandResult,
        containerResult: containerResult)
}

public func inertActionFileSystem() -> ActionFileSystem {
    ActionFileSystem(
        metadata: { _ in nil },
        contentsEqual: { _, _ in true },
        createDirectory: { _ in },
        copy: { _, _ in },
        remove: { _ in },
        setPermissions: { _, _ in },
        write: { _, _ in })
}
