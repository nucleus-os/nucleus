import ColliderCore
import Foundation

public struct HostPhaseRecorder: Sendable {
    private let registry: RunRegistry?
    private let run: RunHandle?

    public init(registry: RunRegistry?, run: RunHandle?) {
        self.registry = registry
        self.run = run
    }

    public func begin(_ name: String, totalItems: Int? = nil) async throws -> HostPhaseID {
        let id = HostPhaseID(rawValue: UUID().uuidString)
        try await record(.started(id: id, name: name, totalItems: totalItems))
        return id
    }

    public func advance(
        _ id: HostPhaseID,
        completedItems: Int,
        totalItems: Int? = nil
    ) async throws {
        try await record(
            .advanced(
                id: id,
                completedItems: completedItems,
                totalItems: totalItems))
    }

    public func finish(_ id: HostPhaseID) async throws {
        try await record(.finished(id))
    }

    public func fail(_ id: HostPhaseID) async throws {
        try await record(.failed(id))
    }

    public func withPhase<Result: Sendable>(
        _ name: String,
        totalItems: Int? = nil,
        operation: () async throws -> Result
    ) async throws -> Result {
        let id = try await begin(name, totalItems: totalItems)
        do {
            let result = try await operation()
            try await finish(id)
            return result
        } catch {
            try? await fail(id)
            throw error
        }
    }

    private func record(_ event: HostPhaseEvent) async throws {
        guard let registry, let run else { return }
        try await registry.record(.hostPhase(event), in: run)
    }
}
