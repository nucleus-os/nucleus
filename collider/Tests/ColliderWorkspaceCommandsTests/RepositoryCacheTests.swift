import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage
import Testing

@testable import ColliderWorkspaceCommands

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
        dryRun: false,
        json: true)

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

    try await cache.clean(component: "alias", dryRun: true, json: true)
    #expect(FileManager.default.fileExists(atPath: cleanable.path))

    try await cache.clean(component: "fixture", dryRun: false, json: true)
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

    async let status: Void = repository.status(json: true)
    async let prune: Void = repository.prune(
        keepingRuns: 0,
        dryRun: false,
        json: true)
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
