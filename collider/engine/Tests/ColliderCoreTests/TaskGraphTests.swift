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
            retentionPolicy: .protected),
        StorageDeclaration(
            id: "runs",
            owner: ComponentID(rawValue: "runtime"),
            producers: [.runtime("fixture")],
            storageClass: .runRecord,
            root: state.appending("runs"),
            safetyRoot: state,
            retentionPolicy: .boundedHistory(maximumEntries: 20)),
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
                    retentionPolicy: .singleWorkingSet)
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
                    retentionPolicy: .singleWorkingSet),
                StorageDeclaration(
                    id: "child",
                    owner: ComponentID(rawValue: "second"),
                    producers: [.runtime("fixture")],
                    storageClass: .generation,
                    root: cache.appending("generated/candidates"),
                    safetyRoot: cache,
                    retentionPolicy: .keepActiveAndRollback(count: 0)),
            ],
            forbiddenRemovalRoots: [cache])
    }
}

@Test func storageCatalogFindsParentInsertedAfterChildAmongUnrelatedSiblings() throws {
    let cache = FilePath("/cache")
    var declarations = (0..<64).map { index in
        StorageDeclaration(
            id: "sibling-\(index)",
            owner: ComponentID(rawValue: "runtime"),
            producers: [.runtime("fixture")],
            storageClass: .cache,
            root: cache.appending("siblings/\(index)"),
            safetyRoot: cache,
            retentionPolicy: .protected)
    }
    declarations.insert(
        StorageDeclaration(
            id: "child",
            owner: ComponentID(rawValue: "runtime"),
            producers: [.runtime("fixture")],
            storageClass: .cache,
            root: cache.appending("generated/child"),
            safetyRoot: cache,
            retentionPolicy: .singleWorkingSet),
        at: 0)
    declarations.append(
        StorageDeclaration(
            id: "parent",
            owner: ComponentID(rawValue: "runtime"),
            producers: [.runtime("fixture")],
            storageClass: .cache,
            root: cache.appending("generated"),
            safetyRoot: cache,
            retentionPolicy: .singleWorkingSet))

    #expect(throws: StorageCatalogFailure.self) {
        try StorageCatalog.validate(declarations, forbiddenRemovalRoots: [cache])
    }

    try StorageCatalog.validate(
        declarations.filter { $0.id != "parent" },
        forbiddenRemovalRoots: [cache])
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
            retentionPolicy: .protected)
        try StorageCatalog.validate([protected], forbiddenRemovalRoots: [])

        let unprotected = StorageDeclaration(
            id: "unprotected-\(storageClass.rawValue)",
            owner: ComponentID(rawValue: "core"),
            producers: [.runtime("fixture")],
            storageClass: storageClass,
            root: workspace.appending("unprotected-\(storageClass.rawValue)"),
            safetyRoot: workspace,
            retentionPolicy: .singleWorkingSet)
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
            retentionPolicy: .singleWorkingSet)
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
        retentionPolicy: .keepActiveAndRollback(count: 0),
        activeGenerationLink: FilePath("/outside/current"),
        interruptedCandidateNaming: nil)
    #expect(throws: StorageCatalogFailure.self) {
        try StorageCatalog.validate([declaration], forbiddenRemovalRoots: [])
    }
}

@Test func generationRetentionOnlyAppliesToVersionedStorage() {
    let declaration = StorageDeclaration(
        id: "incremental",
        owner: ComponentID(rawValue: "core"),
        producers: [.runtime("fixture")],
        storageClass: .incremental,
        root: FilePath("/cache/incremental"),
        safetyRoot: FilePath("/cache"),
        retentionPolicy: .keepActiveAndRollback(count: 0))
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
        retentionPolicy: .keepActiveAndRollback(count: 0))
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
        retentionPolicy: .protected,
        activeGenerationLink: cache.appending("current"),
        interruptedCandidateNaming: nil)
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
        retentionPolicy: .keepActiveAndRollback(count: 1),
        activeGenerationLink: cache.appending("current"),
        interruptedCandidateNaming: nil)
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
        retentionPolicy: .protected)
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

@Test func writableEffectsRequireExactlyOneOwnedStorageDeclaration() throws {
    let owner = ComponentID(rawValue: "core")
    let taskID = TaskID(rawValue: "core.write")
    let output = FilePath("/cache/core/output/result")
    let task = TaskDeclaration(
        id: taskID,
        component: owner,
        action: try fixtureWriteAction(output, bytes: [1]))
    let declaration = StorageDeclaration(
        id: "core-output",
        owner: owner,
        producers: [.task(taskID)],
        storageClass: .incremental,
        root: FilePath("/cache/core/output"),
        safetyRoot: FilePath("/cache/core"),
        retentionPolicy: .protected)

    try StorageCatalog.validateWritableEffects([declaration], tasks: [task])
    #expect(throws: StorageCatalogFailure.self) {
        try StorageCatalog.validateWritableEffects([], tasks: [task])
    }
    #expect(throws: StorageCatalogFailure.self) {
        try StorageCatalog.validateWritableEffects(
            [
                declaration,
                StorageDeclaration(
                    id: "duplicate-output",
                    owner: owner,
                    producers: [.task(taskID)],
                    storageClass: .incremental,
                    root: FilePath("/cache/core/output/result"),
                    safetyRoot: FilePath("/cache/core"),
                    retentionPolicy: .protected),
            ],
            tasks: [task])
    }
}

@Test func runtimeOwnedStorageMayReceiveWritesFromAnotherComponent() throws {
    let task = TaskDeclaration(
        id: TaskID(rawValue: "core.export"),
        component: ComponentID(rawValue: "core"),
        action: try fixtureWriteAction(
            FilePath("/artifacts/core/result"),
            bytes: [1]))
    let declaration = StorageDeclaration(
        id: "artifact-store",
        owner: ComponentID(rawValue: "runtime"),
        producers: [.runtime("bounded-export")],
        storageClass: .published,
        root: FilePath("/artifacts"),
        safetyRoot: FilePath("/"),
        retentionPolicy: .protected)

    try StorageCatalog.validateWritableEffects([declaration], tasks: [task])
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
        retentionPolicy: .singleWorkingSet)

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
    var first = IdentityEncoder()
    first.append("ab")
    first.append("c")
    var second = IdentityEncoder()
    second.append("a")
    second.append("bc")
    #expect(first.bytes != second.bytes)
}
