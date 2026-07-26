import Foundation
import SystemPackage
import Testing

@testable import ColliderRuntime

@Test func aospProductStagingPreservesUnchangedFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-aosp-product-stage-\(UUID().uuidString)")
    let source = root.appendingPathComponent("source")
    let destination = root.appendingPathComponent("destination")
    try FileManager.default.createDirectory(
        at: source,
        withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: destination,
        withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    for name in ["unchanged", "changed"] {
        try Data(name.utf8).write(
            to: source.appendingPathComponent(name))
        try Data(name.utf8).write(
            to: destination.appendingPathComponent(name))
    }
    try Data("metadata".utf8).write(
        to: destination.appendingPathComponent(
            ".nucleus-product-stage.json"))
    let unchanged = destination.appendingPathComponent("unchanged")
    let originalInode = try #require(
        FileManager.default.attributesOfItem(atPath: unchanged.path)[
            .systemFileNumber
        ] as? NSNumber)

    try synchronizeAOSPProductTree(
        from: FilePath(source.path),
        to: FilePath(destination.path),
        preservingAtRoot: [".nucleus-product-stage.json"])
    #expect(FileManager.default.fileExists(
        atPath: destination.appendingPathComponent(
            ".nucleus-product-stage.json").path))
    #expect(
        try FileManager.default.attributesOfItem(atPath: unchanged.path)[
            .systemFileNumber
        ] as? NSNumber == originalInode)

    try Data("replacement".utf8).write(
        to: source.appendingPathComponent("changed"))
    try synchronizeAOSPProductTree(
        from: FilePath(source.path),
        to: FilePath(destination.path),
        preservingAtRoot: [".nucleus-product-stage.json"])
    #expect(
        try FileManager.default.attributesOfItem(atPath: unchanged.path)[
            .systemFileNumber
        ] as? NSNumber == originalInode)
    #expect(
        try String(
            contentsOf: destination.appendingPathComponent("changed"),
            encoding: .utf8) == "replacement")
}
