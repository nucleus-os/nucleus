import ColliderCore
import Foundation
import SystemPackage
import Testing

@testable import ColliderPersistence

@Test func fileDigestStreamsExactContents() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-hash-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("value")
    try Data("nucleus".utf8).write(to: file)
    #expect(
        try ArtifactHasher.digest(file: FilePath(file.path))
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

    #expect(
        try ArtifactHasher.digest(file: FilePath(file.path))
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

@Test func treeDigestIsIndependentOfTheRootPath() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-tree-placement-\(UUID().uuidString)")
    let first = directory.appendingPathComponent("first")
    let second = directory.appendingPathComponent("second-placement")
    for root in [first, second] {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        try Data("payload".utf8).write(
            to: root.appendingPathComponent("artifact"))
    }
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(
        try ArtifactHasher.digest(tree: FilePath(first.path))
            == ArtifactHasher.digest(tree: FilePath(second.path)))
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

@Test func sourceCheckoutDigestUsesGitTreesAcrossCheckoutLocations() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-source-checkout-placement-\(UUID().uuidString)")
    let first = directory.appendingPathComponent("first")
    let second = directory.appendingPathComponent("second")
    defer { try? FileManager.default.removeItem(at: directory) }
    for repository in [first, second] {
        try initializeGitRepository(repository)
        let sources = repository.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(
            at: sources,
            withIntermediateDirectories: true)
        try Data("let value = 1\n".utf8).write(
            to: sources.appendingPathComponent("Value.swift"))
        try Data("Sources/*.ignored\n".utf8).write(
            to: repository.appendingPathComponent(".gitignore"))
        try commitAll(repository)
    }

    #expect(
        try sourceCheckoutDigest(first.appendingPathComponent("Sources"))
            == sourceCheckoutDigest(second.appendingPathComponent("Sources")))
}

@Test func sourceCheckoutDigestTracksScopedWorkingCopyContents() throws {
    let repository = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-source-checkout-dirty-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: repository) }
    try initializeGitRepository(repository)
    let sources = repository.appendingPathComponent("Sources")
    let other = repository.appendingPathComponent("Other")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    let tracked = sources.appendingPathComponent("Value.swift")
    try Data("let value = 1\n".utf8).write(to: tracked)
    try Data("outside\n".utf8).write(to: other.appendingPathComponent("value"))
    try Data("Sources/*.ignored\n".utf8).write(
        to: repository.appendingPathComponent(".gitignore"))
    try commitAll(repository)
    let baseline = try sourceCheckoutDigest(sources)

    try Data("changed outside\n".utf8).write(
        to: other.appendingPathComponent("value"))
    #expect(try sourceCheckoutDigest(sources) == baseline)

    try Data("ignored\n".utf8).write(
        to: sources.appendingPathComponent("cache.ignored"))
    #expect(try sourceCheckoutDigest(sources) == baseline)

    let untracked = sources.appendingPathComponent("New.swift")
    try Data("let added = true\n".utf8).write(to: untracked)
    #expect(try sourceCheckoutDigest(sources) != baseline)
    try FileManager.default.removeItem(at: untracked)

    try Data("let value = 2\n".utf8).write(to: tracked)
    #expect(try sourceCheckoutDigest(sources) != baseline)
    try Data("let value = 1\n".utf8).write(to: tracked)
    #expect(try sourceCheckoutDigest(sources) == baseline)

    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: tracked.path)
    #expect(try sourceCheckoutDigest(sources) != baseline)
}

@Test func sourceCheckoutDigestIncludesDirtyNestedSubmodules() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-source-checkout-submodule-\(UUID().uuidString)")
    let child = directory.appendingPathComponent("child")
    let parent = directory.appendingPathComponent("parent")
    defer { try? FileManager.default.removeItem(at: directory) }

    try initializeGitRepository(child)
    try Data("first\n".utf8).write(to: child.appendingPathComponent("value"))
    try commitAll(child)
    try initializeGitRepository(parent)
    try runGit(
        at: parent,
        arguments: [
            "-c", "protocol.file.allow=always", "submodule", "add", "--quiet",
            child.path, "Dependency",
        ])
    try commitAll(parent)
    let baseline = try sourceCheckoutDigest(parent)

    try Data("second\n".utf8).write(
        to: parent.appendingPathComponent("Dependency/value"))
    #expect(try sourceCheckoutDigest(parent) != baseline)
}

private func sourceCheckoutDigest(_ url: URL) throws -> ArtifactDigest {
    try PlanningArtifactDigestCache().digest(
        sourceCheckout: FilePath(url.path))
}

private func initializeGitRepository(_ repository: URL) throws {
    try FileManager.default.createDirectory(
        at: repository,
        withIntermediateDirectories: true)
    try runGit(at: repository, arguments: ["init", "--quiet"])
    try runGit(
        at: repository,
        arguments: ["config", "user.name", "Collider Tests"])
    try runGit(
        at: repository,
        arguments: ["config", "user.email", "collider@example.invalid"])
}

private func commitAll(_ repository: URL) throws {
    try runGit(at: repository, arguments: ["add", "--all"])
    try runGit(
        at: repository,
        arguments: ["commit", "--quiet", "--message", "fixture"])
}

private func runGit(at repository: URL, arguments: [String]) throws {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.currentDirectoryURL = repository
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    try process.run()
    _ = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CocoaError(.fileWriteUnknown)
    }
}
