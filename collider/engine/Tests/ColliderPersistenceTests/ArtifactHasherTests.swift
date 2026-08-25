import ColliderCore
import Foundation
import Synchronization
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

@Test func planningDigestCacheRewritesUnrecognizedFileFormat() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-incompatible-digest-cache-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cacheURL = directory.appendingPathComponent("digests.json")
    let sourceURL = directory.appendingPathComponent("source.swift")
    try Data(#"{"invalid-entry":{"digest":"unused"}}"#.utf8).write(
        to: cacheURL)
    try Data("let value = 1\n".utf8).write(to: sourceURL)

    let cache = PlanningArtifactDigestCache(
        persistentFile: FilePath(cacheURL.path))
    _ = try cache.digest(file: FilePath(sourceURL.path))
    try cache.persist()

    let object = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL))
            as? [String: Any])
    let files = try #require(object["files"] as? [String: Any])
    #expect(files.count == 1)
    #expect(files[sourceURL.path] != nil)
    #expect(object["invalid-entry"] == nil)
}

@Test func sourceCheckoutDigestUsesGitTreesAcrossCheckoutLocations() async throws {
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
        try await sourceCheckoutDigest(first.appendingPathComponent("Sources"))
            == sourceCheckoutDigest(second.appendingPathComponent("Sources")))
}

@Test func sourceCheckoutDigestTracksScopedWorkingCopyContents() async throws {
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
    let baseline = try await sourceCheckoutDigest(sources)

    try Data("changed outside\n".utf8).write(
        to: other.appendingPathComponent("value"))
    #expect(try await sourceCheckoutDigest(sources) == baseline)

    try Data("ignored\n".utf8).write(
        to: sources.appendingPathComponent("cache.ignored"))
    #expect(try await sourceCheckoutDigest(sources) == baseline)

    let untracked = sources.appendingPathComponent("New.swift")
    try Data("let added = true\n".utf8).write(to: untracked)
    #expect(try await sourceCheckoutDigest(sources) != baseline)
    try FileManager.default.removeItem(at: untracked)

    try Data("let value = 2\n".utf8).write(to: tracked)
    #expect(try await sourceCheckoutDigest(sources) != baseline)
    try Data("let value = 1\n".utf8).write(to: tracked)
    #expect(try await sourceCheckoutDigest(sources) == baseline)

    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: tracked.path)
    #expect(try await sourceCheckoutDigest(sources) != baseline)
}

@Test func sourceCheckoutDigestMatchesBeforeAndAfterCommit() async throws {
    let repository = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-source-checkout-commit-independent-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: repository) }
    try initializeGitRepository(repository)
    let sources = repository.appendingPathComponent("Sources")
    try FileManager.default.createDirectory(
        at: sources,
        withIntermediateDirectories: true)
    let tracked = sources.appendingPathComponent("Value.swift")
    try Data("let value = 1\n".utf8).write(to: tracked)
    let removed = sources.appendingPathComponent("Removed.swift")
    try Data("let removed = true\n".utf8).write(to: removed)
    try commitAll(repository)

    try Data("let value = 2\n".utf8).write(to: tracked)
    try FileManager.default.removeItem(at: removed)
    let added = sources.appendingPathComponent("Added.swift")
    try Data("let added = true\n".utf8).write(to: added)
    let dirty = try await sourceCheckoutDigest(sources)

    try commitAll(repository)
    #expect(try await sourceCheckoutDigest(sources) == dirty)
}

@Test func sourceCheckoutDigestSupportsAnEntirelyNewSourceDirectory() async throws {
    let repository = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-source-checkout-new-scope-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: repository) }
    try initializeGitRepository(repository)
    try Data("tracked\n".utf8).write(
        to: repository.appendingPathComponent("README.md"))
    try commitAll(repository)

    let sources = repository.appendingPathComponent("Sources/NewTarget")
    try FileManager.default.createDirectory(
        at: sources,
        withIntermediateDirectories: true)
    let source = sources.appendingPathComponent("Value.swift")
    try Data("let value = 1\n".utf8).write(to: source)
    let initial = try await sourceCheckoutDigest(sources)

    try Data("let value = 2\n".utf8).write(to: source)
    #expect(try await sourceCheckoutDigest(sources) != initial)
}

@Test func sourceCheckoutClosureTracksOnlySelectedTargetDirectories() async throws {
    let repository = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-source-closure-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: repository) }
    try initializeGitRepository(repository)
    let app = repository.appendingPathComponent("domains/app")
    let shared = repository.appendingPathComponent("domains/shared")
    let unrelated = repository.appendingPathComponent("domains/unrelated")
    for directory in [app, shared, unrelated] {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        try Data("original\n".utf8).write(
            to: directory.appendingPathComponent("value"))
    }
    try commitAll(repository)
    let selected = [FilePath(app.path), FilePath(shared.path)]
    let baseline = try await sourceCheckoutClosureDigest(selected)

    try Data("changed\n".utf8).write(
        to: unrelated.appendingPathComponent("value"))
    #expect(try await sourceCheckoutClosureDigest(selected) == baseline)

    try Data("changed\n".utf8).write(
        to: shared.appendingPathComponent("value"))
    #expect(try await sourceCheckoutClosureDigest(selected) != baseline)
}

@Test func sourceCheckoutDigestIncludesDirtyNestedSubmodules() async throws {
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
    let baseline = try await sourceCheckoutDigest(parent)

    try Data("second\n".utf8).write(
        to: parent.appendingPathComponent("Dependency/value"))
    #expect(try await sourceCheckoutDigest(parent) != baseline)
}

@Test func productSourceSnapshotSeparatesContentFromGitProvenance() async throws {
    let repository = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-product-source-snapshot-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: repository) }
    try initializeGitRepository(repository)
    let source = repository.appendingPathComponent("Source.swift")
    try Data("let value = 1\n".utf8).write(to: source)
    try commitAll(repository)

    let clean = try await ProductArtifactSourceSnapshot.capture(
        repositoryRoot: FilePath(repository.path),
        sourceAuthority: .localDevelopment)
    #expect(clean.provenance.baseCommit?.isEmpty == false)
    #expect(clean.provenance.dirtyPaths.isEmpty)

    try Data("let value = 2\n".utf8).write(to: source)
    try Data("untracked\n".utf8).write(
        to: repository.appendingPathComponent("New.txt"))
    let dirty = try await ProductArtifactSourceSnapshot.capture(
        repositoryRoot: FilePath(repository.path),
        sourceAuthority: .localDevelopment)
    #expect(dirty.closure != clean.closure)
    #expect(dirty.provenance.dirtyPaths == ["New.txt", "Source.swift"])

    try commitAll(repository)
    let committed = try await ProductArtifactSourceSnapshot.capture(
        repositoryRoot: FilePath(repository.path),
        sourceAuthority: .localDevelopment)
    #expect(committed.closure == dirty.closure)
    #expect(committed.provenance.dirtyPaths.isEmpty)
    #expect(committed.provenance.identity != dirty.provenance.identity)
}

@Test func productSourceSnapshotUsesItsDeclaredSourceClosure() async throws {
    let repository = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-scoped-product-source-snapshot-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: repository) }
    try initializeGitRepository(repository)
    let source = repository.appendingPathComponent("Source.swift")
    let unrelated = repository.appendingPathComponent("Notes.md")
    try Data("let value = 1\n".utf8).write(to: source)
    try Data("first\n".utf8).write(to: unrelated)
    try commitAll(repository)

    let sourcePaths = [FilePath(source.path)]
    let clean = try await ProductArtifactSourceSnapshot.capture(
        repositoryRoot: FilePath(repository.path),
        sourceAuthority: .localDevelopment,
        sourcePaths: sourcePaths)

    try Data("second\n".utf8).write(to: unrelated)
    try Data("untracked\n".utf8).write(
        to: repository.appendingPathComponent("Untracked.md"))
    let unrelatedDirty = try await ProductArtifactSourceSnapshot.capture(
        repositoryRoot: FilePath(repository.path),
        sourceAuthority: .localDevelopment,
        sourcePaths: sourcePaths)
    #expect(unrelatedDirty == clean)

    try Data("let value = 2\n".utf8).write(to: source)
    let sourceDirty = try await ProductArtifactSourceSnapshot.capture(
        repositoryRoot: FilePath(repository.path),
        sourceAuthority: .localDevelopment,
        sourcePaths: sourcePaths)
    #expect(sourceDirty.closure != clean.closure)
    #expect(sourceDirty.provenance.dirtyPaths == ["Source.swift"])
}

@Test func onlySourceARunReadSupersedesIt() async throws {
    let repository = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-source-revalidation-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: repository) }
    try initializeGitRepository(repository)
    let read = repository.appendingPathComponent("read")
    let unread = repository.appendingPathComponent("unread")
    try FileManager.default.createDirectory(at: read, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: unread, withIntermediateDirectories: true)
    let consumed = read.appendingPathComponent("Source.swift")
    let plan = unread.appendingPathComponent("plan.md")
    try Data("let value = 1\n".utf8).write(to: consumed)
    try Data("first\n".utf8).write(to: plan)
    try commitAll(repository)

    let paths = [FilePath(read.path)]
    let revalidation = SourceRevalidation()
    revalidation.record([
        PlannedSourceClosure(
            paths: paths,
            digest: try await SourceClosureIdentity.digest(paths))
    ])

    // A document the plan never named is not something the run consumed.
    try Data("second\n".utf8).write(to: plan)
    try Data("untracked\n".utf8).write(
        to: unread.appendingPathComponent("Untracked.md"))
    #expect(await revalidation.supersedingClosures().isEmpty)

    // The tree a task declared is.
    try Data("let value = 2\n".utf8).write(to: consumed)
    #expect(await revalidation.supersedingClosures().flatMap(\.paths) == paths)
}

@Test func aRunThatPlannedNothingIsNeverSuperseded() async {
    #expect(await SourceRevalidation().supersedingClosures().isEmpty)
}

@Test func sourceARunCanNoLongerReadSupersedesIt() async throws {
    let repository = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-unreadable-source-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: repository) }
    try initializeGitRepository(repository)
    let consumed = repository.appendingPathComponent("Source.swift")
    try Data("let value = 1\n".utf8).write(to: consumed)
    try commitAll(repository)

    let paths = [FilePath(consumed.path)]
    let revalidation = SourceRevalidation()
    revalidation.record([
        PlannedSourceClosure(
            paths: paths,
            digest: try await SourceClosureIdentity.digest(paths))
    ])
    #expect(await revalidation.supersedingClosures().isEmpty)

    // A run cannot claim source it can no longer account for.
    try FileManager.default.removeItem(at: repository.appendingPathComponent(".git"))
    #expect(await revalidation.supersedingClosures().flatMap(\.paths) == paths)
}

@Test func protectedMainSourceSnapshotRequiresAnExactCleanCheckout() async throws {
    let repository = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-protected-main-source-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: repository) }
    try initializeGitRepository(repository)
    let source = repository.appendingPathComponent("Source.swift")
    try Data("let value = 1\n".utf8).write(to: source)
    try commitAll(repository)
    let commit = try gitOutput(at: repository, arguments: ["rev-parse", "HEAD"])

    let snapshot = try await ProductArtifactSourceSnapshot.capture(
        repositoryRoot: FilePath(repository.path),
        sourceAuthority: .protectedMain,
        assertedCommit: commit,
        assertedBranch: "refs/heads/main",
        sourcePaths: [FilePath(source.path)])
    #expect(snapshot.provenance.baseCommit == commit)
    #expect(snapshot.provenance.branch == "refs/heads/main")
    #expect(snapshot.provenance.dirtyPaths.isEmpty)

    await #expect(throws: ProductArtifactStoreFailure.self) {
        try await ProductArtifactSourceSnapshot.capture(
            repositoryRoot: FilePath(repository.path),
            sourceAuthority: .protectedMain,
            assertedCommit: String(commit.prefix(12)),
            assertedBranch: "refs/heads/main")
    }
    await #expect(throws: ProductArtifactStoreFailure.self) {
        try await ProductArtifactSourceSnapshot.capture(
            repositoryRoot: FilePath(repository.path),
            sourceAuthority: .protectedMain,
            assertedCommit: commit,
            assertedBranch: "refs/heads/topic")
    }

    try Data("untracked\n".utf8).write(
        to: repository.appendingPathComponent("OutsideDeclaredClosure.txt"))
    await #expect(throws: ProductArtifactContractFailure.self) {
        try await ProductArtifactSourceSnapshot.capture(
            repositoryRoot: FilePath(repository.path),
            sourceAuthority: .protectedMain,
            assertedCommit: commit,
            assertedBranch: "refs/heads/main",
            sourcePaths: [FilePath(source.path)])
    }
}

@Test func sourceCaptureReportsWhatItMustReadBeforeReadingIt() async throws {
    let repository = FileManager.default.temporaryDirectory
        .appendingPathComponent("nucleus-capture-progress-\(UUID().uuidString)")
    try initializeGitRepository(repository)
    try "one".write(
        to: repository.appendingPathComponent("first.txt"),
        atomically: true, encoding: .utf8)
    try "two".write(
        to: repository.appendingPathComponent("second.txt"),
        atomically: true, encoding: .utf8)
    try commitAll(repository)
    defer { try? FileManager.default.removeItem(at: repository) }

    func capture() async throws -> [SourceCaptureProgress] {
        let recorded = Mutex<[SourceCaptureProgress]>([])
        _ = try await ProductArtifactSourceSnapshot.capture(
            repositoryRoot: FilePath(repository.path),
            sourceAuthority: .localDevelopment,
            observe: { progress in recorded.withLock { $0.append(progress) } })
        return recorded.withLock { $0 }
    }

    // A clean tree costs nothing to read, and says so.
    let clean = try await capture()
    #expect(clean.count == 1)
    #expect(clean.first?.identifiedPaths == 2)
    #expect(clean.first?.inspectedPaths == 0)

    // A modified path and an untracked path are both content Git cannot
    // identify, and the count is reported before either is read.
    try "changed".write(
        to: repository.appendingPathComponent("first.txt"),
        atomically: true, encoding: .utf8)
    try "new".write(
        to: repository.appendingPathComponent("third.txt"),
        atomically: true, encoding: .utf8)
    let dirty = try await capture()
    #expect(dirty.count == 1)
    #expect(dirty.first?.identifiedPaths == 1)
    #expect(dirty.first?.inspectedPaths == 2)
}

@Test func sourceCheckoutDigestRejectsPathsGitReportsWithoutInspecting() async throws {
    let repository = FileManager.default.temporaryDirectory
        .appendingPathComponent("nucleus-unverifiable-\(UUID().uuidString)")
    try initializeGitRepository(repository)
    let tracked = repository.appendingPathComponent("source.txt")
    try "one".write(to: tracked, atomically: true, encoding: .utf8)
    try commitAll(repository)
    defer { try? FileManager.default.removeItem(at: repository) }

    let clean = try await sourceCheckoutDigest(repository)

    // assume-unchanged tells Git to report the path as unmodified without
    // looking at it. An identity taken on that word would claim content the
    // working tree no longer holds, so the capture must refuse instead.
    try runGit(
        at: repository, arguments: ["update-index", "--assume-unchanged", "source.txt"])
    try "two".write(to: tracked, atomically: true, encoding: .utf8)
    await #expect(throws: (any Error).self) { try await sourceCheckoutDigest(repository) }

    try runGit(
        at: repository, arguments: ["update-index", "--no-assume-unchanged", "source.txt"])
    #expect(try await sourceCheckoutDigest(repository) != clean)
    try "one".write(to: tracked, atomically: true, encoding: .utf8)
    #expect(try await sourceCheckoutDigest(repository) == clean)
}

@Test func sourceCheckoutDigestIgnoresHowTheTreeWasMaterialized() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("collider-materialization-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let origin = root.appendingPathComponent("origin")
    try initializeGitRepository(origin)
    try Data("let value = 1\n".utf8)
        .write(to: origin.appendingPathComponent("Value.swift"))
    let scripts = origin.appendingPathComponent("Scripts")
    try FileManager.default.createDirectory(
        at: scripts,
        withIntermediateDirectories: true)
    let script = scripts.appendingPathComponent("run.sh")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: script)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: script.path)
    try FileManager.default.createSymbolicLink(
        atPath: origin.appendingPathComponent("link").path,
        withDestinationPath: "Value.swift")
    try commitAll(origin)

    // The same commit reached two ways: a clone that owns its own `.git`
    // directory, and a submodule whose `.git` is a file pointing into the
    // superproject. The content is identical, so the identity must be too.
    let standalone = root.appendingPathComponent("standalone")
    try runGit(
        at: root,
        arguments: ["clone", "--quiet", origin.path, standalone.path])
    let superproject = root.appendingPathComponent("superproject")
    try initializeGitRepository(superproject)
    try runGit(
        at: superproject,
        arguments: [
            "-c", "protocol.file.allow=always", "submodule", "add", "--quiet",
            origin.path, "child",
        ])
    try commitAll(superproject)
    let submodule = superproject.appendingPathComponent("child")

    func gitEntryType(_ tree: URL) throws -> FileAttributeType {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: tree.appendingPathComponent(".git").path)
        return attributes[.type] as? FileAttributeType ?? .typeUnknown
    }
    #expect(try gitEntryType(standalone) == .typeDirectory)
    #expect(try gitEntryType(submodule) == .typeRegular)

    #expect(try await sourceCheckoutDigest(standalone) == sourceCheckoutDigest(submodule))

    // The repository database is not source. A tree digest counts it, which is
    // what made one commit hash two ways; a source checkout must not.
    let before = try await sourceCheckoutDigest(standalone)
    try Data("residue\n".utf8).write(
        to: standalone.appendingPathComponent(".git/collider-fixture-residue"))
    #expect(try await sourceCheckoutDigest(standalone) == before)
    #expect(try treeDigest(standalone) != before)
}

private func treeDigest(_ url: URL) throws -> ArtifactDigest {
    try PlanningArtifactDigestCache().digest(tree: FilePath(url.path))
}

private func sourceCheckoutDigest(_ url: URL) async throws -> ArtifactDigest {
    try await PlanningArtifactDigestCache().digest(
        sourceCheckout: FilePath(url.path))
}

private func sourceCheckoutClosureDigest(
    _ paths: [FilePath]
) async throws -> ArtifactDigest {
    try await PlanningArtifactDigestCache().digest(sourceCheckoutClosure: paths)
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

private func gitOutput(at repository: URL, arguments: [String]) throws -> String {
    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.currentDirectoryURL = repository
    process.arguments = arguments
    process.standardOutput = standardOutput
    process.standardError = standardError
    try process.run()
    let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
    _ = standardError.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CocoaError(.fileReadUnknown)
    }
    return String(decoding: output, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
