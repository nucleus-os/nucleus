import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage
import Testing

@testable import ColliderWorkspaceCommands

private struct WorkspaceFixtureIdentity: ColliderActionIdentity {
    let value: String

    func encode(into encoder: inout ActionIdentityEncoder) {
        encoder.append(tag: 1, string: value)
    }
}

private struct WorkspaceFixtureAction: ColliderAction {
    static let kind: ActionKind = "fixture.workspace"

    let workspace: PersistentWorkspaceDeclaration
    var identity: WorkspaceFixtureIdentity {
        WorkspaceFixtureIdentity(value: workspace.identity.key)
    }
    var requirements: ActionRequirements {
        ActionRequirements(
            persistentWorkspaceEffects: [
                ActionPersistentWorkspaceEffect(
                    workspace: workspace,
                    target: "/workspace",
                    access: .readWrite)
            ],
            executionPlatform: .linuxARM64OCI,
            artifactTarget: workspace.identity.artifactTarget)
    }

    func execute(in _: ActionContext) async throws {}
}

private actor RecordingPersistentWorkspaceBackend: OCIRuntimeBackend {
    private var workspaces: [OCIPersistentWorkspaceState]
    private var deletedNames: [String] = []

    init(workspaces: [OCIPersistentWorkspaceState]) {
        self.workspaces = workspaces
    }

    func prepareImage(_: OCIImagePreparation) async throws -> String {
        throw WorkspaceFailure.message("unused fixture operation")
    }

    func execute(
        _: OCIRuntimeExecutionRequest
    ) async throws -> OCIRuntimeExecutionOutcome {
        throw WorkspaceFailure.message("unused fixture operation")
    }

    func persistentWorkspaces(
        configuration _: OCIRuntimeConfiguration
    ) async throws -> [OCIPersistentWorkspaceState] {
        workspaces
    }

    func deletePersistentWorkspace(
        named name: String,
        configuration _: OCIRuntimeConfiguration
    ) async throws {
        deletedNames.append(name)
        workspaces.removeAll { $0.name == name }
    }

    func deletions() -> [String] { deletedNames }
}

private func fixtureWorkspace(
    key: String = "fixture-build"
) -> PersistentWorkspaceDeclaration {
    PersistentWorkspaceDeclaration(
        identity: PersistentWorkspaceIdentity(
            key: key,
            artifactTarget: .linuxARM64,
            role: "build"),
        capacityBytes: 128 * 1_024 * 1_024,
        filesystem: .ext4,
        journal: .writeback64MiB)
}

private func workspaceRuntime(
    root: URL,
    backend: RecordingPersistentWorkspaceBackend
) -> ColliderRuntime {
    ColliderRuntime(
        downloadCacheRoot: FilePath(root.appendingPathComponent("downloads").path),
        ociConfiguration: .engineDefault,
        ociBackend: backend)
}

@Test func cacheStatusMakesRecursiveAllocationMeasurementExplicit() throws {
    let defaultStatus = try Cache.Status.parse([])
    #expect(!defaultStatus.measureAllocations)

    let measuredStatus = try Cache.Status.parse(["--measure-allocations"])
    #expect(measuredStatus.measureAllocations)
}

@Test func repositoryCleanRemovesOnlyTheSelectedComponentsDeclaredWorkspaces() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-workspace-clean-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let selectedWorkspace = fixtureWorkspace()
    let otherWorkspace = fixtureWorkspace(key: "other-build")
    let sharedWorkspace = fixtureWorkspace(key: "shared-build")
    let backend = RecordingPersistentWorkspaceBackend(
        workspaces: [
            OCIPersistentWorkspaceState(
                name: "selected-volume",
                identity: selectedWorkspace.identity,
                capacityBytes: selectedWorkspace.capacityBytes,
                allocatedBytes: 4_096,
                active: false),
            OCIPersistentWorkspaceState(
                name: "other-volume",
                identity: otherWorkspace.identity,
                capacityBytes: otherWorkspace.capacityBytes,
                allocatedBytes: 8_192,
                active: false),
            OCIPersistentWorkspaceState(
                name: "shared-volume",
                identity: sharedWorkspace.identity,
                capacityBytes: sharedWorkspace.capacityBytes,
                allocatedBytes: 16_384,
                active: false),
        ])
    let runtime = workspaceRuntime(root: root, backend: backend)
    let selectedID = ComponentID(rawValue: "selected")
    let otherID = ComponentID(rawValue: "other")
    func component(
        id: ComponentID,
        workspace: PersistentWorkspaceDeclaration,
        sharedWorkspace: PersistentWorkspaceDeclaration
    ) throws -> ComponentDefinition {
        try ComponentDefinition(
            descriptor: ComponentDescriptor(
                id: id,
                canonicalName: id.rawValue,
                directoryName: id.rawValue),
            tasks: [
                TaskDeclaration(
                    id: TaskID(rawValue: "\(id.rawValue).build"),
                    component: id,
                    action: try AnyColliderAction(
                        WorkspaceFixtureAction(workspace: workspace))),
                TaskDeclaration(
                    id: TaskID(rawValue: "\(id.rawValue).shared"),
                    component: id,
                    action: try AnyColliderAction(
                        WorkspaceFixtureAction(workspace: sharedWorkspace))),
            ],
            entrypoints: [])
    }
    let repository = RepositoryCache(
        context: WorkspaceContext(
            root: FilePath(root.path),
            environment: ["HOME": root.path],
            runtime: runtime),
        catalog: ComponentCatalog(
            components: [
                try component(
                    id: selectedID,
                    workspace: selectedWorkspace,
                    sharedWorkspace: sharedWorkspace),
                try component(
                    id: otherID,
                    workspace: otherWorkspace,
                    sharedWorkspace: sharedWorkspace),
            ],
            publicEntrypoints: []))

    try await repository.clean(component: "selected", dryRun: true)
    #expect(await backend.deletions().isEmpty)

    try await repository.clean(component: "selected", dryRun: false)
    #expect(await backend.deletions() == ["selected-volume"])
}

@Test func repositoryPruneRemovesOnlyInactiveUndeclaredWorkspaces() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-workspace-prune-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let orphaned = fixtureWorkspace(key: "orphaned")
    let active = fixtureWorkspace(key: "active")
    let backend = RecordingPersistentWorkspaceBackend(
        workspaces: [
            OCIPersistentWorkspaceState(
                name: "orphaned-volume",
                identity: orphaned.identity,
                capacityBytes: orphaned.capacityBytes,
                allocatedBytes: 4_096,
                active: false),
            OCIPersistentWorkspaceState(
                name: "active-volume",
                identity: active.identity,
                capacityBytes: active.capacityBytes,
                allocatedBytes: 8_192,
                active: true),
        ])
    let runtime = workspaceRuntime(root: root, backend: backend)
    let repository = RepositoryCache(
        context: WorkspaceContext(
            root: FilePath(root.path),
            environment: ["HOME": root.path],
            runtime: runtime),
        catalog: ComponentCatalog(components: [], publicEntrypoints: []))

    try await repository.prune(keepingRuns: 0, dryRun: false)
    #expect(await backend.deletions() == ["orphaned-volume"])
}

@Test func repositoryCleanRefusesAnActiveDeclaredWorkspace() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-workspace-active-clean-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let workspace = fixtureWorkspace()
    let backend = RecordingPersistentWorkspaceBackend(
        workspaces: [
            OCIPersistentWorkspaceState(
                name: "active-volume",
                identity: workspace.identity,
                capacityBytes: workspace.capacityBytes,
                allocatedBytes: 4_096,
                active: true)
        ])
    let componentID = ComponentID(rawValue: "selected")
    let component = try ComponentDefinition(
        descriptor: ComponentDescriptor(
            id: componentID,
            canonicalName: componentID.rawValue,
            directoryName: componentID.rawValue),
        tasks: [
            TaskDeclaration(
                id: TaskID(rawValue: "selected.build"),
                component: componentID,
                action: try AnyColliderAction(
                    WorkspaceFixtureAction(workspace: workspace)))
        ],
        entrypoints: [])
    let repository = RepositoryCache(
        context: WorkspaceContext(
            root: FilePath(root.path),
            environment: ["HOME": root.path],
            runtime: workspaceRuntime(root: root, backend: backend)),
        catalog: ComponentCatalog(
            components: [component],
            publicEntrypoints: []))

    await #expect(throws: WorkspaceFailure.self) {
        try await repository.clean(component: "selected", dryRun: false)
    }
    #expect(await backend.deletions().isEmpty)
}

@Test func repositoryCachePrunesAbandonedCandidatesAndInactiveSwiftSDKGenerations() async throws {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-storage-workspace-\(UUID().uuidString)", isDirectory: true)
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-storage-cache-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: workspace)
        try? FileManager.default.removeItem(at: cache)
    }
    try FileManager.default.createDirectory(
        at: workspace, withIntermediateDirectories: true)
    let generations = cache.appendingPathComponent(
        "nucleus/swift-target-sdks/generations", isDirectory: true)
    try FileManager.default.createDirectory(
        at: generations, withIntermediateDirectories: true)
    let candidate = generations.appendingPathComponent(
        ".candidate-1234567890abcdef12345678-2026-08-02T01-42-29Z-38631")
    let active = generations.appendingPathComponent("1234567890abcdef12345678")
    let inactive = generations.appendingPathComponent("abcdef1234567890abcdef12")
    let unrelated = generations.appendingPathComponent(".candidate-user-directory")
    for directory in [candidate, active, inactive, unrelated] {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try Data("payload".utf8).write(
            to: directory.appendingPathComponent("payload"))
    }
    try FileManager.default.createSymbolicLink(
        atPath: cache.appendingPathComponent(
            "nucleus/swift-target-sdks/current"
        ).path,
        withDestinationPath: "generations/\(active.lastPathComponent)")
    let context = WorkspaceContext(
        root: FilePath(workspace.path),
        environment: [
            "HOME": workspace.path,
            "XDG_CACHE_HOME": cache.path,
            "NUCLEUS_NATIVE_SDK_ROOT": cache.appendingPathComponent(
                "nucleus/nucleus-native-sdk/linux-arm64"
            ).path,
            "ANDROID_SDK_ROOT": cache.appendingPathComponent("android-sdk").path,
        ],
        runtime: ColliderRuntime())

    let storage = [
        StorageDeclaration(
            id: "swift-target-sdk-generations",
            owner: ComponentID(rawValue: "fixture"),
            producers: [.runtime("fixture")],
            storageClass: .generation,
            root: FilePath(generations.path),
            safetyRoot: FilePath(generations.deletingLastPathComponent().path),
            cleanupPolicy: .explicitPrune,
            activeGenerationLink: FilePath(
                cache.appendingPathComponent("nucleus/swift-target-sdks/current").path),
            rollbackGenerationCount: 0,
            interruptedCandidateNaming: DirectoryNamePattern(
                rawValue: #"^\.candidate-[0-9a-f]{24}-[0-9TZ-]+-[0-9]+$"#),
            retention: "fixture")
    ]
    let catalog = ComponentCatalog(
        components: [
            try ComponentDefinition(
                descriptor: ComponentDescriptor(
                    id: ComponentID(rawValue: "fixture"),
                    canonicalName: "fixture",
                    directoryName: "fixture"),
                tasks: [],
                entrypoints: [],
                storage: storage)
        ],
        publicEntrypoints: [])
    try await RepositoryCache(
        context: context,
        catalog: catalog
    ).prune(
        keepingRuns: 0,
        dryRun: false)

    #expect(!FileManager.default.fileExists(atPath: candidate.path))
    #expect(FileManager.default.fileExists(atPath: active.path))
    #expect(!FileManager.default.fileExists(atPath: inactive.path))
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
}

@Test func repositoryCleanRemovesOnlySelectedExplicitlyCleanableRoots() async throws {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-clean-workspace-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let cleanable = workspace.appendingPathComponent("build", isDirectory: true)
    let protected = workspace.appendingPathComponent("source", isDirectory: true)
    let unrelated = workspace.appendingPathComponent("other-build", isDirectory: true)
    for directory in [cleanable, protected, unrelated] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: directory.appendingPathComponent("payload"))
    }
    let owner = ComponentID(rawValue: "fixture")
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.build"),
        component: owner,
        locks: [.shared(FilePath(workspace.appendingPathComponent("fixture.lock").path))])
    let storage = [
        StorageDeclaration(
            id: "fixture-build",
            owner: owner,
            producers: [.task(task.id)],
            storageClass: .incremental,
            root: FilePath(cleanable.path),
            safetyRoot: FilePath(workspace.path),
            cleanupPolicy: .explicitClean,
            retention: "fixture"),
        StorageDeclaration(
            id: "fixture-source",
            owner: owner,
            producers: [.task(task.id)],
            storageClass: .source,
            root: FilePath(protected.path),
            safetyRoot: FilePath(workspace.path),
            cleanupPolicy: .protected,
            retention: "fixture"),
    ]
    let fixture = try ComponentDefinition(
        descriptor: ComponentDescriptor(
            id: owner,
            canonicalName: "fixture",
            directoryName: "fixture",
            aliases: ["alias"]),
        tasks: [task],
        entrypoints: [],
        storage: storage)
    let otherOwner = ComponentID(rawValue: "other")
    let otherTask = TaskDeclaration(
        id: TaskID(rawValue: "other.build"),
        component: otherOwner,
        locks: [.shared(FilePath(workspace.appendingPathComponent("other.lock").path))])
    let other = try ComponentDefinition(
        descriptor: ComponentDescriptor(
            id: otherOwner,
            canonicalName: "other",
            directoryName: "other"),
        tasks: [otherTask],
        entrypoints: [],
        storage: [
            StorageDeclaration(
                id: "other-build",
                owner: otherOwner,
                producers: [.task(otherTask.id)],
                storageClass: .incremental,
                root: FilePath(unrelated.path),
                safetyRoot: FilePath(workspace.path),
                cleanupPolicy: .explicitClean,
                retention: "fixture")
        ])
    let context = WorkspaceContext(
        root: FilePath(workspace.path),
        environment: ["HOME": workspace.path],
        runtime: ColliderRuntime())
    let cache = RepositoryCache(
        context: context,
        catalog: ComponentCatalog(
            components: [fixture, other],
            publicEntrypoints: []))

    try await cache.clean(component: "alias", dryRun: true)
    #expect(FileManager.default.fileExists(atPath: cleanable.path))

    try await cache.clean(component: "fixture", dryRun: false)
    #expect(!FileManager.default.fileExists(atPath: cleanable.path))
    #expect(FileManager.default.fileExists(atPath: protected.path))
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
}

@Test func repositoryStatusToleratesConcurrentGenerationPruning() async throws {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-concurrent-status-workspace-\(UUID().uuidString)", isDirectory: true)
    let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-concurrent-status-cache-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: workspace)
        try? FileManager.default.removeItem(at: cacheRoot)
    }
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let artifactRoot = cacheRoot.appendingPathComponent("artifacts", isDirectory: true)
    let generations = artifactRoot.appendingPathComponent("generations", isDirectory: true)
    try FileManager.default.createDirectory(at: generations, withIntermediateDirectories: true)
    let active = generations.appendingPathComponent("aaaaaaaaaaaaaaaaaaaaaaaa")
    try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
    try Data("active".utf8).write(to: active.appendingPathComponent("payload"))
    for index in 0..<64 {
        let suffix = String(index + 1, radix: 16)
        let name = String(repeating: "0", count: 24 - suffix.count) + suffix
        let generation = generations.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: generation, withIntermediateDirectories: true)
        try Data(repeating: UInt8(index), count: 4_096).write(
            to: generation.appendingPathComponent("payload"))
    }
    let current = artifactRoot.appendingPathComponent("current")
    try FileManager.default.createSymbolicLink(
        atPath: current.path,
        withDestinationPath: "generations/\(active.lastPathComponent)")
    let owner = ComponentID(rawValue: "fixture")
    let declaration = StorageDeclaration(
        id: "fixture-generations",
        owner: owner,
        producers: [.runtime("fixture")],
        storageClass: .generation,
        root: FilePath(generations.path),
        safetyRoot: FilePath(artifactRoot.path),
        cleanupPolicy: .explicitPrune,
        activeGenerationLink: FilePath(current.path),
        rollbackGenerationCount: 0,
        retention: "fixture")
    let catalog = ComponentCatalog(
        components: [
            try ComponentDefinition(
                descriptor: ComponentDescriptor(
                    id: owner,
                    canonicalName: "fixture",
                    directoryName: "fixture"),
                tasks: [],
                entrypoints: [],
                storage: [declaration])
        ],
        publicEntrypoints: [])
    let context = WorkspaceContext(
        root: FilePath(workspace.path),
        environment: [
            "HOME": workspace.path,
            "XDG_CACHE_HOME": cacheRoot.path,
        ],
        runtime: ColliderRuntime())
    let repository = RepositoryCache(context: context, catalog: catalog)

    async let status: Void = repository.status(measureAllocations: true)
    async let prune: Void = repository.prune(
        keepingRuns: 0,
        dryRun: false)
    _ = try await (status, prune)

    #expect(FileManager.default.fileExists(atPath: active.path))
    let remaining = try FileManager.default.contentsOfDirectory(atPath: generations.path)
    #expect(remaining == [active.lastPathComponent])
}

@Test func apfsInventoryRejectsAmbiguousNamesWithoutLosingUniqueVolumes() throws {
    let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Containers</key><array>
          <dict><key>Volumes</key><array>
            <dict><key>Name</key><string>Recovery</string><key>CapacityInUse</key><integer>1</integer><key>CapacityQuota</key><integer>0</integer><key>CapacityReserve</key><integer>0</integer></dict>
            <dict><key>Name</key><string>NucleusCache</string><key>CapacityInUse</key><integer>2</integer><key>CapacityQuota</key><integer>350</integer><key>CapacityReserve</key><integer>0</integer></dict>
          </array></dict>
          <dict><key>Volumes</key><array>
            <dict><key>Name</key><string>Recovery</string><key>CapacityInUse</key><integer>3</integer><key>CapacityQuota</key><integer>0</integer><key>CapacityReserve</key><integer>0</integer></dict>
          </array></dict>
        </array></dict></plist>
        """

    let inventory = try APFSStorageInventory.decode(plist)

    #expect(inventory["Recovery"] == nil)
    #expect(inventory["NucleusCache"]?.capacityInUse == 2)
    #expect(inventory["NucleusCache"]?.capacityQuota == 350)
}
