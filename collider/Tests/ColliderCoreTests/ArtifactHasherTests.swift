import ColliderRuntime
import Foundation
import SystemPackage
import Testing

@Test func fileDigestStreamsExactContents() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-hash-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("value")
    try Data("nucleus".utf8).write(to: file)
    #expect(try ArtifactHasher.digest(file: FilePath(file.path))
        == ArtifactHasher.digest(bytes: Data("nucleus".utf8)))
}

@Test func fileDigestStreamsLargeFilesWithoutChangingTheirIdentity() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-large-hash-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("large")
    let contents = Data(
        (0..<(17 * 1_024 * 1_024 + 37)).lazy.map {
            UInt8(truncatingIfNeeded: $0)
        })
    try contents.write(to: file)

    #expect(try ArtifactHasher.digest(file: FilePath(file.path))
        == ArtifactHasher.digest(bytes: contents))
}

@Test func treeDigestIgnoresTimestampsButIncludesPermissionsAndSymlinks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-tree-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("tool")
    try Data("payload".utf8).write(to: file)
    try FileManager.default.createSymbolicLink(
        at: directory.appendingPathComponent("active"),
        withDestinationURL: URL(fileURLWithPath: "tool"))
    let path = FilePath(directory.path)
    let initial = try ArtifactHasher.digest(tree: path)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 1)],
        ofItemAtPath: file.path)
    #expect(try ArtifactHasher.digest(tree: path) == initial)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: file.path)
    let executable = try ArtifactHasher.digest(tree: path)
    #expect(executable != initial)
    try FileManager.default.removeItem(
        at: directory.appendingPathComponent("active"))
    try FileManager.default.createSymbolicLink(
        at: directory.appendingPathComponent("active"),
        withDestinationURL: URL(fileURLWithPath: "replacement"))
    #expect(try ArtifactHasher.digest(tree: path) != executable)
}
