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

@Test func taskGraphRejectsSubsumingANonDependency() {
    let build = TaskDeclaration(
        id: TaskID(rawValue: "build"),
        component: ComponentID(rawValue: "core"))
    let test = TaskDeclaration(
        id: TaskID(rawValue: "test"),
        component: ComponentID(rawValue: "core"),
        subsumedDependencies: [build.id])

    #expect(throws: TaskGraphFailure.self) {
        _ = try TaskGraph([build, test])
    }
}

@Test func storageCatalogAllowsProtectedParentsWithLockedRemovalBoundaries() throws {
    let workspace = FilePath("/workspace")
    let state = workspace.appending(".nucleus")
    let declarations = [
        StorageDeclaration(
            id: "state",
            owner: "runtime",
            storageClass: .incremental,
            root: state,
            safetyRoot: workspace,
            cleanupPolicy: .protected,
            retention: "checkout state"),
        StorageDeclaration(
            id: "runs",
            owner: "runtime",
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
                    owner: "runtime",
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
                    owner: "first",
                    storageClass: .cache,
                    root: cache.appending("generated"),
                    safetyRoot: cache,
                    cleanupPolicy: .explicitPrune,
                    workflowLock: cache.appending("first.lock"),
                    retention: "fixture"),
                StorageDeclaration(
                    id: "child",
                    owner: "second",
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

@Test func canonicalFramingDistinguishesFieldBoundaries() {
    var first = CanonicalDigestEncoder()
    first.append(tag: 1, string: "ab")
    first.append(tag: 2, string: "c")
    var second = CanonicalDigestEncoder()
    second.append(tag: 1, string: "a")
    second.append(tag: 2, string: "bc")
    #expect(first.bytes != second.bytes)
}
