import ColliderCore
import ColliderPersistence
import Foundation
import SystemPackage
import Testing

@Test func portableSnapshotRestoresACompleteTreeAtANewPlacement() throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-portable-relocation-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let first = FilePath(temporary.appendingPathComponent("first/output").path)
    let second = FilePath(temporary.appendingPathComponent("second/output").path)
    let storeRoot = FilePath(temporary.appendingPathComponent("store").path)
    try materializePortableFixture(at: first)
    let firstTask = try portableDirectoryTask(output: first)
    let identity = ArtifactDigest(bytes: Array(repeating: 0x41, count: 32))
    let store = PortableArtifactStore(root: storeRoot)

    try store.capture(task: firstTask, identity: identity)
    #expect(store.state(task: firstTask.id, identity: identity) == .available)

    let manifest = try String(
        contentsOf: URL(
            fileURLWithPath: storeRoot.appending(
                "sha256-\(identity.hexadecimal)/manifest.json"
            ).string),
        encoding: .utf8)
    #expect(!manifest.contains(first.string))

    let relocatedTask = try portableDirectoryTask(output: second)
    try store.restore(task: relocatedTask, identity: identity)

    #expect(
        try String(
            contentsOf: URL(fileURLWithPath: second.appending("script").string),
            encoding: .utf8) == "#!/bin/sh\necho portable\n")
    #expect(
        try FileManager.default.destinationOfSymbolicLink(
            atPath: second.appending("current").string) == "script")
    #expect(
        try second.appending("script").stat().permissions.rawValue & 0o777
            == 0o751)
    #expect(
        try second.stat().permissions.rawValue & 0o777 == 0o750)
    #expect(
        try second.appending("empty").stat().type == .directory)
}

@Test func corruptPortableSnapshotIsQuarantined() throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-portable-corruption-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let output = FilePath(temporary.appendingPathComponent("output").path)
    let storeRoot = FilePath(temporary.appendingPathComponent("store").path)
    try materializePortableFixture(at: output)
    let task = try portableDirectoryTask(output: output)
    let identity = ArtifactDigest(bytes: Array(repeating: 0x52, count: 32))
    let store = PortableArtifactStore(root: storeRoot)
    try store.capture(task: task, identity: identity)
    let storedScript = storeRoot.appending(
        "sha256-\(identity.hexadecimal)/payload/000000/script")
    try Data("corrupt".utf8).write(
        to: URL(fileURLWithPath: storedScript.string))

    #expect(throws: PortableArtifactStoreFailure.self) {
        try store.restore(task: task, identity: identity)
    }
    try store.quarantine(identity: identity)

    #expect(store.state(task: task.id, identity: identity) == .missing)
    #expect(
        try FileManager.default.contentsOfDirectory(
            atPath: storeRoot.appending("quarantine").string
        ).count == 1)
}

@Test func portableSnapshotRetentionIsBounded() throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-portable-retention-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let storeRoot = FilePath(temporary.appendingPathComponent("store").path)
    let store = PortableArtifactStore(
        root: storeRoot,
        limits: PortableArtifactStore.Limits(
            maximumSnapshotBytes: 1_024 * 1_024,
            maximumTotalBytes: 2 * 1_024 * 1_024,
            maximumSnapshots: 2,
            maximumQuarantinedSnapshots: 1))

    for index in 0..<3 {
        let output = FilePath(
            temporary.appendingPathComponent("output-\(index)").path)
        try materializePortableFixture(at: output)
        let task = try portableDirectoryTask(
            id: TaskID(rawValue: "fixture.portable-\(index)"),
            output: output)
        try store.capture(
            task: task,
            identity: ArtifactDigest(bytes: Array(repeating: UInt8(index), count: 32)))
    }

    let snapshots = try FileManager.default.contentsOfDirectory(
        atPath: storeRoot.string
    ).filter { $0.hasPrefix("sha256-") }
    #expect(snapshots.count == 2)
}

@Test func transientRestoreFailurePreservesTheSnapshot() throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-portable-transient-restore-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let output = FilePath(temporary.appendingPathComponent("output").path)
    let storeRoot = FilePath(temporary.appendingPathComponent("store").path)
    try materializePortableFixture(at: output)
    let task = try portableDirectoryTask(output: output)
    let identity = ArtifactDigest(bytes: Array(repeating: 0x63, count: 32))
    let store = PortableArtifactStore(root: storeRoot)
    try store.capture(task: task, identity: identity)

    let blockedParent = temporary.appendingPathComponent("blocked")
    try Data("not-a-directory".utf8).write(to: blockedParent)
    let relocated = try portableDirectoryTask(
        output: FilePath(blockedParent.appendingPathComponent("output").path))
    #expect(throws: (any Error).self) {
        try store.restore(task: relocated, identity: identity)
    }

    #expect(store.state(task: task.id, identity: identity) == .available)
}

@Test func retentionQuarantinesUndecodableSnapshotsAndAbandonedCandidates() throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-portable-corrupt-retention-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let storeRoot = FilePath(temporary.appendingPathComponent("store").path)
    try FileManager.default.createDirectory(
        atPath: storeRoot.string,
        withIntermediateDirectories: true)
    let identity = ArtifactDigest(bytes: Array(repeating: 0x74, count: 32))
    let corrupt = storeRoot.appending("sha256-\(identity.hexadecimal)")
    try FileManager.default.createDirectory(
        atPath: corrupt.string,
        withIntermediateDirectories: true)
    try Data("not-json".utf8).write(
        to: URL(fileURLWithPath: corrupt.appending("manifest.json").string))
    let abandoned = storeRoot.appending(".candidate-invalid")
    try FileManager.default.createDirectory(
        atPath: abandoned.string,
        withIntermediateDirectories: true)

    try PortableArtifactStore(root: storeRoot).prune()

    #expect(!FileManager.default.fileExists(atPath: corrupt.string))
    #expect(!FileManager.default.fileExists(atPath: abandoned.string))
    #expect(
        try FileManager.default.contentsOfDirectory(
            atPath: storeRoot.appending("quarantine").string
        ).count == 2)
}

@Test func portableSnapshotsRejectSymlinksThatEscapeTheOutputTree() throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-portable-escaping-symlink-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let output = FilePath(temporary.appendingPathComponent("output").path)
    try FileManager.default.createDirectory(
        atPath: output.string,
        withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        atPath: output.appending("escape").string,
        withDestinationPath: "../outside")
    let task = try portableDirectoryTask(output: output)
    let identity = ArtifactDigest(bytes: Array(repeating: 0x85, count: 32))

    #expect(throws: PortableArtifactStoreFailure.self) {
        try PortableArtifactStore(
            root: FilePath(temporary.appendingPathComponent("store").path)
        ).capture(task: task, identity: identity)
    }
}

private func portableDirectoryTask(
    id: TaskID = TaskID(rawValue: "fixture.portable"),
    output: FilePath
) throws -> TaskDeclaration {
    var builder = TaskBuilder(
        id: id,
        component: ComponentID(rawValue: "fixture"))
    let _: ArtifactReference<DirectoryArtifact> = try builder.output(
        "tree",
        path: output,
        validation: .nonEmptyDirectory)
    return builder.build(assessmentPolicy: .portable)
}

private func materializePortableFixture(at output: FilePath) throws {
    try FileManager.default.createDirectory(
        atPath: output.appending("empty").string,
        withIntermediateDirectories: true)
    try Data("#!/bin/sh\necho portable\n".utf8).write(
        to: URL(fileURLWithPath: output.appending("script").string))
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o751)],
        ofItemAtPath: output.appending("script").string)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o750)],
        ofItemAtPath: output.string)
    try FileManager.default.createSymbolicLink(
        atPath: output.appending("current").string,
        withDestinationPath: "script")
}
