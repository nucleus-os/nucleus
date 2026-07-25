import Foundation
import Testing
@testable import ColliderCommands

@Test func xwaylandDiscoveryReturnsCanonicalExecutableRegularFile() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true)
    let executable = root.appendingPathComponent("real-Xwayland")
    #expect(FileManager.default.createFile(
        atPath: executable.path,
        contents: Data("#!/bin/sh\n".utf8)))
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: executable.path)
    let link = root.appendingPathComponent("Xwayland")
    try FileManager.default.createSymbolicLink(
        at: link,
        withDestinationURL: executable)

    let resolved = try resolveXwaylandExecutable(
        environment: ["PATH": root.path])

    #expect(resolved == executable.path)
}

@Test func xwaylandDiscoveryRejectsNonRegularAndMissingCandidates() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent(
        "Xwayland", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: directory.path)

    #expect(throws: WorkspaceFailure.self) {
        try resolveXwaylandExecutable(environment: ["PATH": root.path])
    }
    #expect(throws: WorkspaceFailure.self) {
        try resolveXwaylandExecutable(environment: [:])
    }
}
