import ColliderRuntime
import Foundation
import SystemPackage
import Testing

#if os(Linux)
@Test func colliderFileLockRetainsKernelOwnershipUntilDescriptorClosure() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-file-lock-\(UUID().uuidString)")
    let path = directory.appendingPathComponent("artifact.lock")
    defer { try? FileManager.default.removeItem(at: directory) }

    var owner: ColliderFileLock? = try ColliderFileLock(
        path: FilePath(path.path),
        purpose: "artifact publication",
        owner: LockOwner(run: "run-1", task: "artifact.publish"))
    let ownerRecord = URL(fileURLWithPath: path.path + ".owner")
    let record = try String(contentsOf: ownerRecord, encoding: .utf8)
    #expect(record.contains("run=run-1"))
    #expect(record.contains("task=artifact.publish"))

    try FileManager.default.removeItem(at: ownerRecord)
    #expect(throws: RuntimeLockFailure.self) {
        _ = try ColliderFileLock(
            path: FilePath(path.path),
            purpose: "artifact publication",
            waitForExistingOwner: false)
    }

    owner = nil
    let replacement = try ColliderFileLock(
        path: FilePath(path.path),
        purpose: "artifact publication",
        waitForExistingOwner: false)
    withExtendedLifetime(replacement) {}
    _ = owner
}
#endif
