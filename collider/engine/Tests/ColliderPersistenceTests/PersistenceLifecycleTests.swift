import ColliderCore
import Foundation
import SystemPackage
import Testing

@testable import ColliderPersistence

@Test func directoryRetentionKeepsNewestAndCurrentContentIdentities() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-directory-retention-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let generations = directory.appendingPathComponent("generations")
    try FileManager.default.createDirectory(
        at: generations, withIntermediateDirectories: true)
    let names = [
        "111111111111111111111111",
        "222222222222222222222222",
        "333333333333333333333333",
    ]
    for (index, name) in names.enumerated() {
        let path = generations.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: path, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: Double(index))],
            ofItemAtPath: path.path)
    }
    let current = directory.appendingPathComponent("current")
    try FileManager.default.createSymbolicLink(
        atPath: current.path,
        withDestinationPath: "generations/\(names[0])")

    try DirectoryLifecycle.prune(
        DirectoryRetentionPlan(
            safetyRoot: FilePath(directory.path),
            rules: [
                DirectoryRetentionRule(
                    root: FilePath(generations.path),
                    current: FilePath(current.path),
                    retain: 1,
                    naming: .contentIdentity)
            ]))

    #expect(
        FileManager.default.fileExists(
            atPath: generations.appendingPathComponent(names[0]).path))
    #expect(
        !FileManager.default.fileExists(
            atPath: generations.appendingPathComponent(names[1]).path))
    #expect(
        FileManager.default.fileExists(
            atPath: generations.appendingPathComponent(names[2]).path))
}

@Test func directoryRetentionCountsOnlyInactiveRollbackGenerations() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-rollback-retention-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let generations = directory.appendingPathComponent("generations")
    try FileManager.default.createDirectory(
        at: generations, withIntermediateDirectories: true)
    let names = [
        "111111111111111111111111",
        "222222222222222222222222",
        "333333333333333333333333",
    ]
    for (index, name) in names.enumerated() {
        let path = generations.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: path, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: Double(index))],
            ofItemAtPath: path.path)
    }
    let current = directory.appendingPathComponent("current")
    try FileManager.default.createSymbolicLink(
        atPath: current.path,
        withDestinationPath: "generations/\(names[2])")

    try DirectoryLifecycle.prune(
        DirectoryRetentionPlan(
            safetyRoot: FilePath(directory.path),
            rules: [
                DirectoryRetentionRule(
                    root: FilePath(generations.path),
                    current: FilePath(current.path),
                    retain: 1,
                    naming: .contentIdentity)
            ]))

    #expect(
        !FileManager.default.fileExists(
            atPath: generations.appendingPathComponent(names[0]).path))
    #expect(
        FileManager.default.fileExists(
            atPath: generations.appendingPathComponent(names[1]).path))
    #expect(
        FileManager.default.fileExists(
            atPath: generations.appendingPathComponent(names[2]).path))
}

@Test func retainedRollbackGenerationCanBeReactivatedAtomically() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-generation-rollback-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let generations = directory.appendingPathComponent("generations")
    let previous = generations.appendingPathComponent("111111111111111111111111")
    let currentGeneration = generations.appendingPathComponent("222222222222222222222222")
    for (index, generation) in [previous, currentGeneration].enumerated() {
        try FileManager.default.createDirectory(
            at: generation, withIntermediateDirectories: true)
        try Data("generation-\(index)".utf8).write(
            to: generation.appendingPathComponent("payload"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: Double(index))],
            ofItemAtPath: generation.path)
    }
    let active = directory.appendingPathComponent("current")
    try FileManager.default.createSymbolicLink(
        atPath: active.path,
        withDestinationPath: "generations/\(currentGeneration.lastPathComponent)")
    let retention = DirectoryRetentionPlan(
        safetyRoot: FilePath(directory.path),
        rules: [
            DirectoryRetentionRule(
                root: FilePath(generations.path),
                current: FilePath(active.path),
                retain: 1,
                naming: .contentIdentity)
        ])

    try DirectoryLifecycle.prune(retention)
    try DirectoryLifecycle.activate(
        target: "generations/\(previous.lastPathComponent)",
        link: FilePath(active.path))
    try DirectoryLifecycle.prune(retention)

    #expect(
        try FileManager.default.destinationOfSymbolicLink(atPath: active.path)
            == "generations/\(previous.lastPathComponent)")
    #expect(FileManager.default.fileExists(atPath: previous.path))
    #expect(FileManager.default.fileExists(atPath: currentGeneration.path))
}

@Test func directoryRetentionRemovesOnlyOwnedCandidateDirectories() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-candidate-retention-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let generations = directory.appendingPathComponent("generations")
    try FileManager.default.createDirectory(
        at: generations, withIntermediateDirectories: true)
    let candidate = generations.appendingPathComponent(
        ".candidate-1234567890abcdef12345678-2026-08-02T01-42-29Z-38631")
    let active = generations.appendingPathComponent("1234567890abcdef12345678")
    let unrelated = generations.appendingPathComponent(".candidate-manual-not-owned")
    for path in [candidate, active, unrelated] {
        try FileManager.default.createDirectory(
            at: path, withIntermediateDirectories: true)
    }

    try DirectoryLifecycle.prune(
        DirectoryRetentionPlan(
            safetyRoot: FilePath(directory.path),
            rules: [
                DirectoryRetentionRule(
                    root: FilePath(generations.path),
                    retain: 0,
                    naming: DirectoryNamePattern(
                        rawValue:
                            #"^\.candidate-[0-9a-f]{24}-[0-9TZ-]+-[0-9]+$"#))
            ]))

    #expect(!FileManager.default.fileExists(atPath: candidate.path))
    #expect(FileManager.default.fileExists(atPath: active.path))
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
}

@Test func directoryRetentionRemovesAbandonedContentIdentityCandidates() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-content-candidates-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let generations = directory.appendingPathComponent("generations")
    try FileManager.default.createDirectory(
        at: generations, withIntermediateDirectories: true)
    let identity = "1234567890abcdef12345678"
    let finalized = generations.appendingPathComponent(identity)
    let preparing = generations.appendingPathComponent(".\(identity).preparing")
    let prepared = generations.appendingPathComponent(".\(identity).prepared")
    let unrelated = generations.appendingPathComponent(".\(identity).manual")
    for path in [finalized, preparing, prepared, unrelated] {
        try FileManager.default.createDirectory(
            at: path, withIntermediateDirectories: true)
    }

    try DirectoryLifecycle.prune(
        DirectoryRetentionPlan(
            safetyRoot: FilePath(directory.path),
            rules: [
                DirectoryRetentionRule(
                    root: FilePath(generations.path),
                    retain: 0,
                    naming: .contentIdentityCandidate)
            ]))

    #expect(FileManager.default.fileExists(atPath: finalized.path))
    #expect(!FileManager.default.fileExists(atPath: preparing.path))
    #expect(!FileManager.default.fileExists(atPath: prepared.path))
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
}

@Test func directoryActivationAtomicallyReplacesOnlySymlinks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-directory-activation-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let active = directory.appendingPathComponent("current")
    try FileManager.default.createSymbolicLink(
        atPath: active.path, withDestinationPath: "old")

    try DirectoryLifecycle.activate(
        target: "new", link: FilePath(active.path))
    #expect(
        try FileManager.default.destinationOfSymbolicLink(atPath: active.path)
            == "new")

    try FileManager.default.removeItem(at: active)
    try Data("identity".utf8).write(to: active)
    #expect(throws: PersistenceFailure.self) {
        try DirectoryLifecycle.activate(
            target: "replacement", link: FilePath(active.path))
    }
    #expect(try Data(contentsOf: active) == Data("identity".utf8))
}

@Test func generationPublicationCutsOverAndReusesExistingGenerationKey() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-generation-cutover-\(UUID().uuidString)")
    let candidate = directory.appendingPathComponent("candidate")
    let generation = directory.appendingPathComponent("generation")
    let active = directory.appendingPathComponent("active")
    try FileManager.default.createDirectory(
        at: candidate, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: active, withIntermediateDirectories: true)
    try Data("obsolete".utf8).write(to: active.appendingPathComponent("mutable"))
    try Data("artifact".utf8).write(to: candidate.appendingPathComponent("payload"))
    defer { try? FileManager.default.removeItem(at: directory) }

    try GenerationPublisher.publish(
        candidate: FilePath(candidate.path),
        generation: FilePath(generation.path),
        active: FilePath(active.path))
    #expect(
        try FileManager.default.destinationOfSymbolicLink(atPath: active.path)
            == "generation")

    try FileManager.default.createDirectory(
        at: candidate, withIntermediateDirectories: true)
    try Data("redundant rebuild".utf8).write(
        to: candidate.appendingPathComponent("payload"))
    try GenerationPublisher.publish(
        candidate: FilePath(candidate.path),
        generation: FilePath(generation.path),
        active: FilePath(active.path))
    #expect(!FileManager.default.fileExists(atPath: candidate.path))
    #expect(
        try String(
            contentsOf: generation.appendingPathComponent("payload"),
            encoding: .utf8) == "artifact")
}

@Test func interruptedPublicationPreservesACompleteOldOrNewGeneration() throws {
    struct InjectedPublicationFault: Error {}

    for boundary in GenerationPublicationBoundary.allCases {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "collider-generation-fault-\(UUID().uuidString)")
        let previous = directory.appendingPathComponent("previous")
        let candidate = directory.appendingPathComponent("candidate")
        let generation = directory.appendingPathComponent("generation")
        let active = directory.appendingPathComponent("active")
        try FileManager.default.createDirectory(
            at: previous, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: candidate, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: previous.appendingPathComponent("payload"))
        try Data("new".utf8).write(to: candidate.appendingPathComponent("payload"))
        try FileManager.default.createSymbolicLink(
            atPath: active.path, withDestinationPath: "previous")
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: InjectedPublicationFault.self) {
            try GenerationPublisher.publish(
                candidate: FilePath(candidate.path),
                generation: FilePath(generation.path),
                active: FilePath(active.path),
                after: {
                    if $0 == boundary { throw InjectedPublicationFault() }
                })
        }

        let cutoverCompleted =
            switch boundary {
            case .activePointerReplaced, .activeDirectorySynchronized: true
            default: false
            }
        let target = try FileManager.default.destinationOfSymbolicLink(
            atPath: active.path)
        #expect(target == (cutoverCompleted ? "generation" : "previous"))
        let activePayload = active.resolvingSymlinksInPath().appendingPathComponent("payload")
        #expect(
            try String(contentsOf: activePayload, encoding: .utf8)
                == (cutoverCompleted ? "new" : "old"))
        #expect(FileManager.default.fileExists(atPath: previous.path))
    }
}
