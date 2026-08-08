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
            cleanupPolicy: .automaticRetention,
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
                    cleanupPolicy: .explicitClean,
                    retention: "fixture"),
                StorageDeclaration(
                    id: "child",
                    owner: ComponentID(rawValue: "second"),
                    producers: [.runtime("fixture")],
                    storageClass: .generation,
                    root: cache.appending("generated/candidates"),
                    safetyRoot: cache,
                    cleanupPolicy: .explicitPrune,
                    retention: "fixture"),
            ],
            forbiddenRemovalRoots: [cache])
    }
}

@Test func storageCatalogProtectsSourceAndIdentityBoundaries() throws {
    let scope = FilePath("/scope")
    let workspace = scope.appending("workspace")
    for storageClass in [StorageClass.source, .identity] {
        let protected = StorageDeclaration(
            id: storageClass.rawValue,
            owner: ComponentID(rawValue: "core"),
            producers: [.runtime("fixture")],
            storageClass: storageClass,
            root: workspace.appending(storageClass.rawValue),
            safetyRoot: workspace,
            cleanupPolicy: .protected,
            retention: "fixture")
        try StorageCatalog.validate([protected], forbiddenRemovalRoots: [])

        let unprotected = StorageDeclaration(
            id: "unprotected-\(storageClass.rawValue)",
            owner: ComponentID(rawValue: "core"),
            producers: [.runtime("fixture")],
            storageClass: storageClass,
            root: workspace.appending("unprotected-\(storageClass.rawValue)"),
            safetyRoot: workspace,
            cleanupPolicy: .explicitClean,
            retention: "fixture")
        #expect(throws: StorageCatalogFailure.self) {
            try StorageCatalog.validate([unprotected], forbiddenRemovalRoots: [])
        }

        let removable = StorageDeclaration(
            id: "removable-\(storageClass.rawValue)",
            owner: ComponentID(rawValue: "core"),
            producers: [.runtime("fixture")],
            storageClass: .cache,
            root: workspace,
            safetyRoot: scope,
            cleanupPolicy: .explicitClean,
            retention: "fixture")
        #expect(throws: StorageCatalogFailure.self) {
            try StorageCatalog.validate(
                [protected, removable], forbiddenRemovalRoots: [])
        }
    }
}

@Test func activeGenerationLinkMustStayInsideItsSafetyRoot() {
    let declaration = StorageDeclaration(
        id: "generations",
        owner: ComponentID(rawValue: "core"),
        producers: [.runtime("fixture")],
        storageClass: .generation,
        root: FilePath("/cache/generations"),
        safetyRoot: FilePath("/cache"),
        cleanupPolicy: .explicitPrune,
        activeGenerationLink: FilePath("/outside/current"),
        rollbackGenerationCount: 0,
        retention: "fixture")
    #expect(throws: StorageCatalogFailure.self) {
        try StorageCatalog.validate([declaration], forbiddenRemovalRoots: [])
    }
}

@Test func automaticRetentionOnlyAppliesToVersionedOrRunRecordStorage() {
    let declaration = StorageDeclaration(
        id: "incremental",
        owner: ComponentID(rawValue: "core"),
        producers: [.runtime("fixture")],
        storageClass: .incremental,
        root: FilePath("/cache/incremental"),
        safetyRoot: FilePath("/cache"),
        cleanupPolicy: .automaticRetention,
        retention: "fixture")
    #expect(throws: StorageCatalogFailure.self) {
        try StorageCatalog.validate([declaration], forbiddenRemovalRoots: [])
    }

    let unversionedGeneration = StorageDeclaration(
        id: "unversioned",
        owner: ComponentID(rawValue: "core"),
        producers: [.runtime("fixture")],
        storageClass: .generation,
        root: FilePath("/cache/generations"),
        safetyRoot: FilePath("/cache"),
        cleanupPolicy: .automaticRetention,
        retention: "fixture")
    #expect(throws: StorageCatalogFailure.self) {
        try StorageCatalog.validate(
            [unversionedGeneration], forbiddenRemovalRoots: [])
    }
}

@Test func activeGenerationStorageRequiresExplicitRollbackRetention() {
    let cache = FilePath("/cache")
    let declaration = StorageDeclaration(
        id: "generations",
        owner: ComponentID(rawValue: "runtime"),
        producers: [.runtime("fixture")],
        storageClass: .generation,
        root: cache.appending("generations"),
        safetyRoot: cache,
        cleanupPolicy: .explicitPrune,
        activeGenerationLink: cache.appending("current"),
        retention: "fixture")
    #expect(throws: StorageCatalogFailure.self) {
        try StorageCatalog.validate([declaration], forbiddenRemovalRoots: [])
    }

    let valid = StorageDeclaration(
        id: "generations",
        owner: ComponentID(rawValue: "runtime"),
        producers: [.runtime("fixture")],
        storageClass: .generation,
        root: cache.appending("generations"),
        safetyRoot: cache,
        cleanupPolicy: .explicitPrune,
        activeGenerationLink: cache.appending("current"),
        rollbackGenerationCount: 1,
        retention: "fixture")
    #expect(throws: Never.self) {
        try StorageCatalog.validate([valid], forbiddenRemovalRoots: [])
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

@Test func removableStorageDerivesEveryWorkflowLockFromItsProducerTasks() throws {
    let owner = ComponentID(rawValue: "core")
    let first = TaskDeclaration(
        id: TaskID(rawValue: "core.first"),
        component: owner,
        locks: [.checkout("core-build")])
    let shared = TaskLock.shared(FilePath("/cache/core/.publish.lock"))
    let second = TaskDeclaration(
        id: TaskID(rawValue: "core.second"),
        component: owner,
        locks: [shared])
    let declaration = StorageDeclaration(
        id: "build",
        owner: owner,
        producers: [.task(first.id), .task(second.id)],
        storageClass: .incremental,
        root: FilePath("/cache/core/build"),
        safetyRoot: FilePath("/cache/core"),
        cleanupPolicy: .explicitClean,
        retention: "fixture")

    try StorageCatalog.validateProducers([declaration], tasks: [first, second])
    #expect(
        try StorageCatalog.workflowLocks(for: declaration, tasks: [first, second])
            == [.checkout("core-build"), shared])

    let unlocked = TaskDeclaration(id: first.id, component: owner)
    #expect(throws: StorageCatalogFailure.self) {
        try StorageCatalog.validateProducers([declaration], tasks: [unlocked, second])
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
