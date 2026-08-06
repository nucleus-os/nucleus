import ColliderCore
import ColliderRuntime
import SystemPackage

final class WorkspaceFileLock {
    private let lock: ColliderFileLock

    init(path: String, purpose: String, waitForExistingOwner: Bool = true) throws {
        do {
            lock = try ColliderFileLock(
                path: FilePath(path),
                purpose: purpose,
                waitForExistingOwner: waitForExistingOwner)
        } catch {
            throw WorkspaceFailure.message(String(describing: error))
        }
    }
}
