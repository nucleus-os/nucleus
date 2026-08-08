import SystemPackage
import Testing

@testable import ColliderCore

@Test func taskGraphOrdersDependenciesOnce() throws {
    let root = TaskDeclaration(
        id: TaskID(rawValue: "root"), component: ComponentID(rawValue: "core"))
    let leaf = TaskDeclaration(
        id: TaskID(rawValue: "leaf"), component: ComponentID(rawValue: "core"),
        dependencies: [root.id])
    let graph = try TaskGraph([leaf, root])
    #expect(try graph.orderedTasks(selecting: [leaf.id]).map(\.id) == [root.id, leaf.id])
}

@Test func taskGraphRejectsCycles() {
    let firstID = TaskID(rawValue: "first")
    let secondID = TaskID(rawValue: "second")
    #expect(throws: TaskGraphFailure.self) {
        _ = try TaskGraph([
            TaskDeclaration(
                id: firstID, component: ComponentID(rawValue: "core"),
                dependencies: [secondID]),
            TaskDeclaration(
                id: secondID, component: ComponentID(rawValue: "core"),
                dependencies: [firstID]),
        ])
    }
}

@Test func filePathContainmentUsesNormalizedComponents() {
    let root = FilePath("/workspace/build")
    #expect(FilePath("/workspace/build").isContained(in: root))
    #expect(FilePath("/workspace/build/arm64/../x86_64").isContained(in: root))
    #expect(!FilePath("/workspace/builder").isContained(in: root))
    #expect(!FilePath("workspace/build").isContained(in: root))
    #expect(root.overlaps(FilePath("/workspace/build/arm64")))
    #expect(!root.overlaps(FilePath("/workspace/build-output")))
    #expect(
        FilePath("/workspace/build/arm64/bin").relativeSubpath(from: root)
            == FilePath("arm64/bin"))
}

@Test func storageCatalogAllowsProtectedParentsWithLockedRemovalBoundaries() throws {
    let workspace = FilePath("/workspace")
    let state = workspace.appending(".nucleus")
    let declarations = [
        StorageDeclaration(
            id: "state",
            owner: ComponentID(rawValue: "runtime"),
            producers: [.runtime("fixture")],
            storageClass: .incremental,
            root: state,
            safetyRoot: workspace,
            cleanupPolicy: .protected,
            retention: "checkout state"),
        StorageDeclaration(
            id: "runs",
            owner: ComponentID(rawValue: "runtime"),
            producers: [.runtime("fixture")],
            storageClass: .runRecord,
            root: state.appending("runs"),
            safetyRoot: state,
            cleanupPolicy: .explicitPrune,
            workflowLock: state.appending("locks/cache-prune.lock"),
            retention: "bounded history"),
    ]

    try StorageCatalog.validate(
        declarations,
        forbiddenRemovalRoots: [FilePath("/"), workspace])
}

@Test func storageCatalogRejectsUnsafeOrOverlappingRemovalBoundaries() {
    let cache = FilePath("/cache")
    #expect(throws: StorageCatalogFailure.self) {
        try StorageCatalog.validate(
            [
                StorageDeclaration(
                    id: "cache",
                    owner: ComponentID(rawValue: "runtime"),
                    producers: [.runtime("fixture")],
                    storageClass: .cache,
                    root: cache,
                    safetyRoot: cache,
                    cleanupPolicy: .explicitPrune,
                    workflowLock: cache.appending("prune.lock"),
                    retention: "unsafe fixture")
            ],
            forbiddenRemovalRoots: [cache])
    }
    #expect(throws: StorageCatalogFailure.self) {
        try StorageCatalog.validate(
            [
                StorageDeclaration(
                    id: "parent",
                    owner: ComponentID(rawValue: "first"),
                    producers: [.runtime("fixture")],
                    storageClass: .cache,
                    root: cache.appending("generated"),
                    safetyRoot: cache,
                    cleanupPolicy: .explicitPrune,
                    workflowLock: cache.appending("first.lock"),
                    retention: "fixture"),
                StorageDeclaration(
                    id: "child",
                    owner: ComponentID(rawValue: "second"),
                    producers: [.runtime("fixture")],
                    storageClass: .generation,
                    root: cache.appending("generated/candidates"),
                    safetyRoot: cache,
                    cleanupPolicy: .explicitPrune,
                    workflowLock: cache.appending("second.lock"),
                    retention: "fixture"),
            ],
            forbiddenRemovalRoots: [cache])
    }
}

@Test func storageCatalogRejectsUnknownAndForeignTaskProducers() {
    let declaration = StorageDeclaration(
        id: "build",
        owner: ComponentID(rawValue: "core"),
        producers: [.task(TaskID(rawValue: "core.build"))],
        storageClass: .incremental,
        root: FilePath("/cache/core"),
        safetyRoot: FilePath("/cache"),
        cleanupPolicy: .protected,
        retention: "fixture")
    #expect(throws: StorageCatalogFailure.self) {
        try StorageCatalog.validateProducers([declaration], tasks: [])
    }
    #expect(throws: StorageCatalogFailure.self) {
        try StorageCatalog.validateProducers(
            [declaration],
            tasks: [
                TaskDeclaration(
                    id: TaskID(rawValue: "core.build"),
                    component: ComponentID(rawValue: "other"))
            ])
    }
}

@Test func canonicalFramingDistinguishesFieldBoundaries() {
    var first = CanonicalDigestEncoder()
    first.append(tag: 1, string: "ab")
    first.append(tag: 2, string: "c")
    var second = CanonicalDigestEncoder()
    second.append(tag: 1, string: "a")
    second.append(tag: 2, string: "bc")
    #expect(first.bytes != second.bytes)
}
