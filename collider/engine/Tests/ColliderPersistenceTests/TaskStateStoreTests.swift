import ColliderCore
import ColliderPersistence
import Foundation
import SystemPackage
import Testing

@Test func taskStateStorePublishesCompleteRecordsAndSnapshotsCorruption() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-task-state-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = FilePath(directory.path)
    let store = TaskStateStore(root: root)
    let validID = TaskID(rawValue: "fixture.valid")
    let corruptID = TaskID(rawValue: "fixture.corrupt")
    let record = TaskStateRecord(
        task: validID,
        identity: ArtifactDigest(bytes: Array(repeating: 7, count: 32)),
        outputs: ["/fixture/output"],
        completedAt: "2026-08-04T00:00:00Z")

    try store.persist(record)
    try Data("not-json".utf8).write(to: URL(fileURLWithPath: store.path(for: corruptID).string))

    let snapshot = try store.snapshot()
    guard case .record(let loaded) = snapshot.lookup(validID) else {
        Issue.record("valid task state was not loaded")
        return
    }
    #expect(loaded.identity == record.identity)
    guard case .corrupt = snapshot.lookup(corruptID) else {
        Issue.record("corrupt task state was not isolated")
        return
    }
    guard case .missing = snapshot.lookup(TaskID(rawValue: "fixture.missing")) else {
        Issue.record("missing task state was not reported as missing")
        return
    }
}
