import ColliderCore
import ColliderPersistence
import ColliderRuntime
import Foundation
import SystemPackage
import Testing

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

@Test func contendedFileLockRecordsItsWaitAndThenAcquires() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-file-lock-wait-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = FilePath(directory.path)
    let path = root.appending("admission.lock")
    var owner: ColliderFileLock? = try ColliderFileLock(
        path: path,
        purpose: "fixture owner")
    let registry = RunRegistry(root: root.appending("state"))
    let run = try await registry.begin(command: ["collider", "build", "fixture"])
    let cancellation = RuntimeCancellation()
    let waiter = Task {
        try await acquireColliderFileLock(
            path: path,
            purpose: "fixture waiter",
            resource: "host execution admission",
            run: run,
            registry: registry,
            cancellation: cancellation)
    }

    for _ in 0..<100 {
        let state = try await registry.reducedEvents(
            in: try await registry.recordedRun(run.id))
        if state.activeWaits.contains(
            ActiveWait(task: nil, resource: "host execution admission"))
        {
            break
        }
        try await ContinuousClock().sleep(for: .milliseconds(10))
    }
    var state = try await registry.reducedEvents(
        in: try await registry.recordedRun(run.id))
    #expect(
        state.activeWaits
            == [ActiveWait(task: nil, resource: "host execution admission")])

    owner = nil
    let acquired = try await waiter.value
    state = try await registry.reducedEvents(
        in: try await registry.recordedRun(run.id))
    #expect(state.activeWaits.isEmpty)
    withExtendedLifetime(acquired) {}
    try await registry.finish(run, status: .succeeded)
    _ = owner
}

@Test func cancellingAContendedFileLockWaitLeavesTheLockReusable() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-file-lock-wait-cancel-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = FilePath(directory.appendingPathComponent("admission.lock").path)
    var owner: ColliderFileLock? = try ColliderFileLock(
        path: path,
        purpose: "fixture owner")
    let cancellation = RuntimeCancellation()
    let waiter = Task {
        try await acquireColliderFileLock(
            path: path,
            purpose: "fixture waiter",
            resource: "host execution admission",
            cancellation: cancellation)
    }
    try await ContinuousClock().sleep(for: .milliseconds(150))
    await cancellation.interruptAll()

    await #expect(throws: CancellationError.self) {
        _ = try await waiter.value
    }
    owner = nil
    let replacement = try ColliderFileLock(
        path: path,
        purpose: "replacement after cancellation",
        waitForExistingOwner: false)
    withExtendedLifetime(replacement) {}
    _ = owner
}
