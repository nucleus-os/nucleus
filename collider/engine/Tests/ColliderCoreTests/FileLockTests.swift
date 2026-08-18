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
    let record = ColliderFileLock.holder(at: FilePath(path.path))
    #expect(record?.contains("run=run-1") == true)
    #expect(record?.contains("task=artifact.publish") == true)
    #expect(record?.contains("user=\(NSUserName())") == true)

    // The record explains a wait; the kernel lock is what enforces it. Erasing
    // the record must not hand the lock to a second holder.
    try Data().write(to: path)
    #expect(ColliderFileLock.holder(at: FilePath(path.path)) == nil)
    #expect(throws: RuntimeLockFailure.self) {
        _ = try ColliderFileLock(
            path: FilePath(path.path),
            purpose: "artifact publication",
            waitForExistingOwner: false)
    }

    owner = nil
    // A clean release clears the record, so a record without a holder is
    // evidence of a dead process rather than a current claim.
    #expect(ColliderFileLock.holder(at: FilePath(path.path)) == nil)
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

    // A wait on a lease shared with another account names its holder, or a
    // blocked terminal cannot tell contention from a stalled command. The
    // rendered host phase is built from this resource, so the holder has to be
    // in it rather than in a one-shot console line the next frame overwrites.
    for _ in 0..<100 {
        let state = try await registry.reducedEvents(
            in: try await registry.recordedRun(run.id))
        if !state.activeWaits.isEmpty { break }
        try await ContinuousClock().sleep(for: .milliseconds(10))
    }
    var state = try await registry.reducedEvents(
        in: try await registry.recordedRun(run.id))
    let waited = try #require(state.activeWaits.first)
    #expect(state.activeWaits.count == 1)
    #expect(waited.task == nil)
    #expect(waited.resource.hasPrefix("host execution admission held by "))
    #expect(waited.resource.contains("user=\(NSUserName())"))

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
