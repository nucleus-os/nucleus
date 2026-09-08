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

@Test func taskStateKeepsIdentityComponentsAndReadsRecordsWrittenWithoutThem()
    throws
{
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-task-state-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TaskStateStore(root: FilePath(directory.path))
    let identity = ArtifactDigest(bytes: Array(repeating: 3, count: 32))
    let components: [UInt8] = [0x10, 0x20, 0x30, 0x40]
    let explained = TaskID(rawValue: "fixture.explained")
    let inherited = TaskID(rawValue: "fixture.inherited")

    try store.persist(
        TaskStateRecord(
            task: explained,
            identity: identity,
            outputs: [],
            completedAt: "2026-09-08T00:00:00Z",
            identityComponents: components))
    // The shape every record on a store predating this has. A plan that could
    // not read them would treat every such task as unexplainable rather than
    // as one whose prior components are simply not known.
    try Data(
        """
        {"task":"fixture.inherited","identity":"\(identity)",\
        "outputs":[],"completedAt":"2026-09-08T00:00:00Z"}
        """.utf8
    ).write(to: URL(fileURLWithPath: store.path(for: inherited).string))

    let snapshot = try store.snapshot()
    guard case .record(let round) = snapshot.lookup(explained) else {
        Issue.record("record with identity components was not loaded")
        return
    }
    #expect(round.identityComponents.map(Array.init) == components)
    guard case .record(let older) = snapshot.lookup(inherited) else {
        Issue.record("record without identity components was not loaded")
        return
    }
    #expect(older.identity == identity)
    #expect(older.identityComponents == nil)
}
