import ColliderCore
import ColliderTesting

func ociExecutions(in action: AnyColliderAction?) async throws -> [OCIExecution] {
    try await recordOCIActionExecution(action).ociExecutions
}
