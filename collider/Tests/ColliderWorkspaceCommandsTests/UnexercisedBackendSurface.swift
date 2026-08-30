import ColliderCore
import ColliderRuntime
import SystemPackage

/// The parts of `OCIRuntimeBackend` a double under test does not exercise.
///
/// These stubs live in the test target, not beside the protocol. In production
/// every requirement is required, so a backend cannot quietly omit one and
/// discover it at runtime -- which is what a set of throwing defaults there had
/// allowed. A double legitimately drives only the surface its test needs, and
/// inherits the rest from here, where reaching one is a test defect rather than
/// a supported state.
struct UnexercisedBackendSurface: Error {}

extension OCIRuntimeBackend {
    func health() async throws -> OCIRuntimeHealth {
        throw UnexercisedBackendSurface()
    }

    func reclaimPersistentWorkspace(
        _ workspace: PersistentWorkspaceDeclaration,
        imageReference: String,
        configuration: OCIRuntimeConfiguration,
        cancellation: RuntimeCancellation
    ) async throws {
        throw UnexercisedBackendSurface()
    }

    func network(named name: String) async throws -> OCIRuntimeNetworkState {
        throw UnexercisedBackendSurface()
    }

    func diskUsage(
        configuration: OCIRuntimeConfiguration
    ) async throws -> OCIRuntimeDiskUsage {
        throw UnexercisedBackendSurface()
    }

    func images() async throws -> [OCIImageState] {
        throw UnexercisedBackendSurface()
    }

    func deleteImages(references _: [String]) async throws {
        throw UnexercisedBackendSurface()
    }

    func collectOrphanedImageContent() async throws -> UInt64 {
        throw UnexercisedBackendSurface()
    }

    func infrastructureImages() async throws -> OCIInfrastructureImages {
        throw UnexercisedBackendSurface()
    }

    func containers() async throws -> [OCIContainerState] {
        throw UnexercisedBackendSurface()
    }

    func deleteContainer(named _: String) async throws {
        throw UnexercisedBackendSurface()
    }

    func persistentWorkspaces(
        configuration: OCIRuntimeConfiguration
    ) async throws -> [OCIPersistentWorkspaceState] {
        throw UnexercisedBackendSurface()
    }

    func deletePersistentWorkspace(
        named name: String,
        configuration: OCIRuntimeConfiguration
    ) async throws {
        throw UnexercisedBackendSurface()
    }
}
