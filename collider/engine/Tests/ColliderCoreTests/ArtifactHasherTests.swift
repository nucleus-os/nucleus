import ColliderCore
import Foundation
import SystemPackage
import Testing
@testable import ColliderRuntime

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

@Test func treeDigestCanExcludeOwnedMetadata() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-tree-exclusion-\(UUID().uuidString)")
    let source = directory.appendingPathComponent("source")
    let staged = directory.appendingPathComponent("staged")
    try FileManager.default.createDirectory(
        at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: staged, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("product".utf8).write(
        to: source.appendingPathComponent("product.mk"))
    try Data("product".utf8).write(
        to: staged.appendingPathComponent("product.mk"))
    try Data("owned metadata".utf8).write(
        to: staged.appendingPathComponent(".nucleus-product-stage.json"))

    #expect(
        try ArtifactHasher.digest(tree: FilePath(source.path))
            == ArtifactHasher.digest(
                tree: FilePath(staged.path),
                excluding: [".nucleus-product-stage.json"]))
}

@Test func planningDigestCacheReusesTreesAndOverlappingFileContents() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-planning-hash-cache-\(UUID().uuidString)")
    let nested = directory.appendingPathComponent("nested")
    try FileManager.default.createDirectory(
        at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = nested.appendingPathComponent("source.swift")
    try Data("let value = 1\n".utf8).write(to: source)
    let root = FilePath(directory.path)
    let nestedRoot = FilePath(nested.path)
    let file = FilePath(source.path)
    let cache = PlanningArtifactDigestCache()

    let first = try cache.digest(tree: root)
    #expect(try cache.digest(tree: root) == first)
    #expect(cache.treeMissCount == 1)
    #expect(cache.fileMissCount == 1)

    _ = try cache.digest(tree: nestedRoot)
    #expect(cache.treeMissCount == 2)
    #expect(cache.fileMissCount == 1)
    _ = try cache.digest(file: file)
    #expect(cache.fileMissCount == 1)
}

@Test func planningDigestCachePersistsContentDigestsUntilFileIdentityChanges()
    throws
{
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-persistent-hash-cache-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("source.swift")
    let cacheFile = FilePath(
        directory.appendingPathComponent("digests.json").path)
    let source = FilePath(sourceURL.path)
    try Data("let value = 1\n".utf8).write(to: sourceURL)

    let firstCache = PlanningArtifactDigestCache(
        persistentFile: cacheFile)
    let first = try firstCache.digest(file: source)
    try firstCache.persist()
    #expect(firstCache.fileMissCount == 1)

    let reusedCache = PlanningArtifactDigestCache(
        persistentFile: cacheFile)
    #expect(try reusedCache.digest(file: source) == first)
    #expect(reusedCache.fileMissCount == 0)

    try Data("let value = 200\n".utf8).write(to: sourceURL)
    let changed = try reusedCache.digest(file: source)
    #expect(changed != first)
    #expect(reusedCache.fileMissCount == 1)
}

@Test func aospProductDefinitionDigestIncludesEveryOverlayCanonically() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-aosp-product-hash-\(UUID().uuidString)")
    let product = directory.appendingPathComponent("product")
    let firstOverlay = directory.appendingPathComponent("first-overlay")
    let secondOverlay = directory.appendingPathComponent("second-overlay")
    for path in [product, firstOverlay, secondOverlay] {
        try FileManager.default.createDirectory(
            at: path, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("product".utf8).write(
        to: product.appendingPathComponent("device.mk"))
    try Data("first".utf8).write(
        to: firstOverlay.appendingPathComponent("transport.c"))
    try Data("second".utf8).write(
        to: secondOverlay.appendingPathComponent("policy.c"))

    let overlays = [
        AOSPProductSourceOverlay(
            source: FilePath(firstOverlay.path),
            relativeDestination: "native/transport"),
        AOSPProductSourceOverlay(
            source: FilePath(secondOverlay.path),
            relativeDestination: "native/policy"),
    ]
    let initial = try aospProductDefinitionDigest(
        productSource: FilePath(product.path),
        sourceOverlays: overlays)
    #expect(try aospProductDefinitionDigest(
        productSource: FilePath(product.path),
        sourceOverlays: Array(overlays.reversed())) == initial)

    try Data("changed".utf8).write(
        to: firstOverlay.appendingPathComponent("transport.c"))
    #expect(try aospProductDefinitionDigest(
        productSource: FilePath(product.path),
        sourceOverlays: overlays) != initial)
    #expect(try aospProductDefinitionDigest(
        productSource: FilePath(product.path),
        sourceOverlays: []) != initial)
}
