import ArgumentParser
import ColliderCore
import ColliderEngine
import ColliderRuntime
import Foundation
import Synchronization
import SystemPackage
import Testing

@testable import ColliderWorkspaceCommands

private final class StorageConsoleCapture: Sendable {
    private let storage = Mutex("")

    var text: String {
        storage.withLock { $0 }
    }

    func write(_ value: Data) {
        storage.withLock { $0 += String(decoding: value, as: UTF8.self) }
    }
}

private struct WorkspaceFixtureIdentity: ColliderActionIdentity {
    let value: String

    func encode(into encoder: inout IdentityEncoder) {
        encoder.append(value)
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

private struct ReconstructFixtureIdentity: ColliderActionIdentity {
    let input: FilePath
    let output: FilePath

    func encode(into encoder: inout IdentityEncoder) {
        encoder.append(path: input)
        encoder.append(path: output)
    }
}

private struct ReconstructFixtureAction: ColliderAction {
    static let kind: ActionKind = "fixture.reconstruct"

    let input: FilePath
    let output: FilePath
    var identity: ReconstructFixtureIdentity {
        ReconstructFixtureIdentity(input: input, output: output)
    }
    var requirements: ActionRequirements {
        ActionRequirements(
            effects: [
                ActionEffect(.read, scope: .input(input)),
                ActionEffect(.write, scope: .output(output.removingLastComponent())),
            ],
            executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        let bytes = try context.files.read(input)
        try context.files.createDirectory(output.removingLastComponent())
        try context.files.write(bytes, to: output)
    }
}

/// One double for both surfaces.
///
/// Inspection and mutation are separate protocols because they have separate
/// requirements of the host, not because they describe separate stores. A
/// fixture that answered them differently would be testing a disagreement that
/// cannot occur.
private actor RecordingPersistentWorkspaceBackend: OCIRuntimeBackend, OCIStoreInspection {
    private var workspaces: [OCIPersistentWorkspaceState]
    private var imageStates: [OCIImageState]
    private var deletedNames: [String] = []
    private var deletedImageReferences: [String] = []
    private var collectionCount = 0
    private var containerStates: [OCIContainerState]
    private var deletedContainers: [String] = []

    private let imageListingFailure: String?
    private let infrastructure: OCIInfrastructureImages
    private let liveness: OCIExecutionLiveness
    private let orphanedContent: OCIOrphanedImageContent

    init(
        workspaces: [OCIPersistentWorkspaceState],
        images: [OCIImageState] = [],
        imageListingFailure: String? = nil,
        infrastructure: OCIInfrastructureImages = OCIInfrastructureImages(
            currentByRepository: [:]),
        containers: [OCIContainerState] = [],
        liveness: OCIExecutionLiveness = .idle,
        orphanedContent: OCIOrphanedImageContent = OCIOrphanedImageContent(
            orphanedBlobs: 0,
            orphanedBlobBytes: 0,
            orphanedSnapshots: 0,
            orphanedSnapshotBytes: 0)
    ) {
        self.workspaces = workspaces
        imageStates = images
        self.imageListingFailure = imageListingFailure
        self.infrastructure = infrastructure
        containerStates = containers
        self.liveness = liveness
        self.orphanedContent = orphanedContent
    }

    func prepareImage(_: OCIImagePreparation) async throws -> String {
        throw WorkspaceFailure.message("unused fixture operation")
    }

    func execute(
        _: OCIRuntimeExecutionRequest
    ) async throws -> OCIRuntimeExecutionOutcome {
        throw WorkspaceFailure.message("unused fixture operation")
    }

    private var reclaimed: [(key: String, imageReference: String)] = []

    func persistentWorkspaces(
        configuration _: OCIRuntimeConfiguration
    ) async throws -> [OCIPersistentWorkspaceState] {
        workspaces
    }

    func reclaimPersistentWorkspace(
        _ workspace: PersistentWorkspaceDeclaration,
        imageReference: String,
        configuration _: OCIRuntimeConfiguration,
        cancellation _: RuntimeCancellation
    ) async throws {
        reclaimed.append((workspace.identity.key, imageReference))
        workspaces = workspaces.map { state in
            state.identity == workspace.identity
                ? OCIPersistentWorkspaceState(
                    name: state.name,
                    identity: state.identity,
                    capacityBytes: state.capacityBytes,
                    allocatedBytes: state.allocatedBytes / 2,
                    active: state.active)
                : state
        }
    }

    func reclamations() -> [(key: String, imageReference: String)] { reclaimed }

    func executionLiveness() async -> OCIExecutionLiveness { liveness }

    func orphanedImageContent() async throws -> OCIOrphanedImageContent {
        if let imageListingFailure {
            throw WorkspaceFailure.message(imageListingFailure)
        }
        return orphanedContent
    }

    func diskUsage(
        configuration _: OCIRuntimeConfiguration
    ) async throws -> OCIRuntimeDiskUsage {
        let empty = OCIRuntimeResourceUsage(
            active: 0,
            reclaimable: 0,
            sizeInBytes: 0,
            total: 0)
        return OCIRuntimeDiskUsage(
            containers: empty,
            images: empty,
            volumes: empty)
    }

    func images() async throws -> [OCIImageState] {
        if let imageListingFailure {
            throw WorkspaceFailure.message(imageListingFailure)
        }
        return imageStates
    }

    func deleteImages(references: [String]) async throws {
        deletedImageReferences.append(contentsOf: references)
        imageStates.removeAll { references.contains($0.reference) }
    }

    func collectOrphanedImageContent() async throws -> UInt64 {
        collectionCount += 1
        return 4_096
    }

    func infrastructureImages() async throws -> OCIInfrastructureImages {
        infrastructure
    }

    func containers() async throws -> [OCIContainerState] {
        containerStates
    }

    func deleteContainer(named name: String) async throws {
        deletedContainers.append(name)
        containerStates.removeAll { $0.name == name }
    }

    func containerDeletions() -> [String] { deletedContainers }

    func deletePersistentWorkspace(
        named name: String,
        configuration _: OCIRuntimeConfiguration
    ) async throws {
        deletedNames.append(name)
        workspaces.removeAll { $0.name == name }
    }

    func deletions() -> [String] { deletedNames }
    func imageDeletions() -> [String] { deletedImageReferences }
    func collections() -> Int { collectionCount }
}

private struct ImageFixtureAction: ColliderAction {
    static let kind: ActionKind = "fixture.image"

    let preparation: OCIImagePreparation
    var identity: WorkspaceFixtureIdentity {
        WorkspaceFixtureIdentity(value: preparation.imageName)
    }
    var requirements: ActionRequirements {
        ociImagePreparationActionRequirements(preparation: preparation)
    }
    var imagePreparations: [OCIImagePreparation] { [preparation] }

    func execute(in _: ActionContext) async throws {}
}

private func fixtureWorkspace(
    key: String = "fixture-build",
    retentionPolicy: StorageRetentionPolicy = .explicitClean
) -> PersistentWorkspaceDeclaration {
    PersistentWorkspaceDeclaration(
        identity: PersistentWorkspaceIdentity(
            key: key,
            artifactTarget: .linuxARM64,
            role: "build"),
        capacityBytes: 128 * 1_024 * 1_024,
        filesystem: .ext4,
        journal: .writeback64MiB,
        retentionPolicy: retentionPolicy)
}

private func workspaceRuntime(
    root: URL,
    backend: RecordingPersistentWorkspaceBackend
) -> ColliderRuntime {
    ColliderRuntime(
        downloadCacheRoot: FilePath(root.appendingPathComponent("downloads").path),
        ociConfiguration: .engineDefault,
        ociBackend: backend,
        ociStore: backend)
}

private func repositoryContext(
    root: URL,
    runtime: ColliderRuntime,
    cacheRoot: URL? = nil,
    console: CommandConsole = .processDefault
) -> WorkspaceContext {
    let cache = cacheRoot ?? root.appendingPathComponent("cache", isDirectory: true)
    return WorkspaceContext(
        root: FilePath(root.path),
        environment: ["HOME": root.path],
        runtime: runtime,
        console: console,
        cacheRoot: FilePath(cache.path),
        hostBuildRoot: FilePath(root.appendingPathComponent("host-build").path),
        artifactRoot: FilePath(root.appendingPathComponent("host-artifacts").path),
        logRoot: FilePath(root.appendingPathComponent("host-logs").path))
}

private actor SlowObservationBackend: OCIRuntimeBackend, OCIStoreInspection {
    func prepareImage(_: OCIImagePreparation) async throws -> String {
        throw WorkspaceFailure.message("unused fixture operation")
    }

    func execute(
        _: OCIRuntimeExecutionRequest
    ) async throws -> OCIRuntimeExecutionOutcome {
        throw WorkspaceFailure.message("unused fixture operation")
    }

    func executionLiveness() async -> OCIExecutionLiveness { .idle }

    func orphanedImageContent() async throws -> OCIOrphanedImageContent {
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }

    func diskUsage(
        configuration _: OCIRuntimeConfiguration
    ) async throws -> OCIRuntimeDiskUsage {
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }

    func images() async throws -> [OCIImageState] {
        try await Task.sleep(for: .seconds(60))
        return []
    }

    func persistentWorkspaces(
        configuration _: OCIRuntimeConfiguration
    ) async throws -> [OCIPersistentWorkspaceState] {
        try await Task.sleep(for: .seconds(60))
        return []
    }
}

@Test func cacheStatusMakesRecursiveAllocationMeasurementExplicit() throws {
    let defaultStatus = try Cache.Status.parse([])
    #expect(!defaultStatus.measureAllocations)

    let measuredStatus = try Cache.Status.parse(["--measure-allocations"])
    #expect(measuredStatus.measureAllocations)
}

/// A terabyte-scale working set is only manageable if the report answers what
/// it weighs in total. Per-root detail says where a byte went; it never says
/// whether the host is running out.
@Test func cacheStatusTotalsWhatCollidesStateWeighs() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-status-totals-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let roomy = fixtureWorkspace(key: "roomy-build")
    let nearlyFull = fixtureWorkspace(key: "nearly-full-build")
    // An ext4 image cannot grow past the size it was created with, so the
    // warning marks the workspace whose next build fails for space rather than
    // for anything it did. Both sides of that threshold are pinned here, and
    // the threshold is inclusive.
    let warningThreshold = nearlyFull.capacityBytes - nearlyFull.capacityBytes / 5
    let backend = RecordingPersistentWorkspaceBackend(
        workspaces: [
            OCIPersistentWorkspaceState(
                name: "roomy-volume",
                identity: roomy.identity,
                capacityBytes: roomy.capacityBytes,
                allocatedBytes: warningThreshold - 1,
                active: false),
            OCIPersistentWorkspaceState(
                name: "nearly-full-volume",
                identity: nearlyFull.identity,
                capacityBytes: nearlyFull.capacityBytes,
                allocatedBytes: warningThreshold,
                active: false),
        ])
    let output = StorageConsoleCapture()
    let console = CommandConsole(
        format: .text,
        progress: .never,
        standardOutputIsTerminal: false,
        standardErrorIsTerminal: false,
        standardOutput: output.write,
        standardError: output.write)
    try await RepositoryCache(
        context: repositoryContext(
            root: root,
            runtime: workspaceRuntime(root: root, backend: backend),
            console: console),
        catalog: ComponentCatalog(components: [], publicEntrypoints: [])
    ).status()

    #expect(output.text.contains("storage-total:"))
    #expect(output.text.contains("2 workspaces"))
    #expect(output.text.contains("1 workspace(s) within 20% of declared capacity"))
    // Declared host roots need a recursive walk, so an unmeasured total must
    // say what it left out rather than under-report the host as smaller.
    #expect(output.text.contains("declared roots not measured"))
    #expect(!output.text.contains("declared roots 0 B"))
}

@Test func cacheStatusBoundsUnavailableRuntimeAndReportsUnknownOwnedPaths() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-status-bounds-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = root.appendingPathComponent("cache", isDirectory: true)
    let unknown = cache.appendingPathComponent("undeclared", isDirectory: true)
    try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
    let output = StorageConsoleCapture()
    let console = CommandConsole(
        format: .text,
        progress: .never,
        standardOutputIsTerminal: false,
        standardErrorIsTerminal: false,
        standardOutput: output.write,
        standardError: output.write)
    let runtime = ColliderRuntime(
        downloadCacheRoot: FilePath(cache.appendingPathComponent("downloads").path),
        ociConfiguration: .engineDefault,
        ociBackend: SlowObservationBackend(),
        ociStore: SlowObservationBackend())
    let repository = RepositoryCache(
        context: repositoryContext(
            root: root,
            runtime: runtime,
            cacheRoot: cache,
            console: console),
        catalog: ComponentCatalog(components: [], publicEntrypoints: []),
        observationTimeout: .milliseconds(10))

    try await repository.status()
    #expect(output.text.contains("apple-container: unavailable"))
    #expect(output.text.contains("apple-container-images: unavailable"))
    #expect(output.text.contains("persistent-workspaces: unavailable"))
    #expect(output.text.contains("/cache/undeclared"))

    try await RepositoryCache(
        context: repositoryContext(
            root: root,
            runtime: ColliderRuntime(),
            cacheRoot: cache),
        catalog: ComponentCatalog(components: [], publicEntrypoints: [])
    ).prune(dryRun: false)
    #expect(FileManager.default.fileExists(atPath: unknown.path))
}

@Test func repositoryPruneEnforcesBoundedDiagnosticHistory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-diagnostic-retention-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let context = repositoryContext(root: root, runtime: ColliderRuntime())
    let history = URL(
        fileURLWithPath: context.logRoot.appending("diagnostics").string,
        isDirectory: true)
    try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
    let oldest = history.appendingPathComponent("oldest.log")
    let middle = history.appendingPathComponent("middle.log")
    let newest = history.appendingPathComponent("newest.log")
    for entry in [oldest, middle, newest] {
        try Data(entry.lastPathComponent.utf8).write(to: entry)
    }
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 1)],
        ofItemAtPath: oldest.path)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 2)],
        ofItemAtPath: middle.path)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 3)],
        ofItemAtPath: newest.path)

    let owner = ComponentID(rawValue: "fixture")
    let catalog = ComponentCatalog(
        components: [
            try ComponentDefinition(
                descriptor: ComponentDescriptor(
                    id: owner,
                    canonicalName: "fixture",
                    directoryName: "fixture"),
                tasks: [],
                entrypoints: [],
                storage: [
                    StorageDeclaration(
                        id: "fixture-diagnostics",
                        owner: owner,
                        producers: [.runtime("fixture")],
                        storageClass: .diagnostic,
                        root: FilePath(history.path),
                        safetyRoot: context.logRoot,
                        retentionPolicy: .boundedHistory(maximumEntries: 2))
                ])
        ],
        publicEntrypoints: [])

    try await RepositoryCache(context: context, catalog: catalog).prune(dryRun: false)

    #expect(!FileManager.default.fileExists(atPath: oldest.path))
    #expect(FileManager.default.fileExists(atPath: middle.path))
    #expect(FileManager.default.fileExists(atPath: newest.path))
}

@Test func repositoryImageRetentionUsesDeclaredReachabilityAndRollback() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-image-retention-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let context = root.appendingPathComponent("context", isDirectory: true)
    try FileManager.default.createDirectory(at: context, withIntermediateDirectories: true)
    let activeDigest = "sha256:" + String(repeating: "a", count: 64)
    let imageID = root.appendingPathComponent("image-id")
    try Data("localhost/fixture\n\(activeDigest)\n".utf8).write(to: imageID)
    let preparation = OCIImagePreparation(
        executionPlatform: .linuxARM64OCI,
        context: FilePath(context.path),
        containerFile: FilePath(context.appendingPathComponent("Containerfile").path),
        imageID: FilePath(imageID.path),
        imageName: "localhost/fixture",
        rollbackGenerationCount: 1,
        environment: [:])
    let componentID = ComponentID(rawValue: "fixture")
    let component = try ComponentDefinition(
        descriptor: ComponentDescriptor(
            id: componentID,
            canonicalName: componentID.rawValue,
            directoryName: componentID.rawValue),
        tasks: [
            TaskDeclaration(
                id: TaskID(rawValue: "fixture.image"),
                component: componentID,
                action: try AnyColliderAction(
                    ImageFixtureAction(preparation: preparation)))
        ],
        entrypoints: [])
    let date = Date(timeIntervalSince1970: 1_000)
    func image(
        _ reference: String,
        repository: String = "localhost/fixture",
        tag: String?,
        digestCharacter: Character,
        age: TimeInterval,
        active: Bool = false
    ) -> OCIImageState {
        OCIImageState(
            reference: reference,
            repository: repository,
            tag: tag,
            digest: "sha256:" + String(repeating: digestCharacter, count: 64),
            creationDate: date.addingTimeInterval(age),
            active: active)
    }
    let obsolete = "localhost/fixture:digest-" + String(repeating: "c", count: 64)
    let dangling = "localhost/fixture@sha256:" + String(repeating: "d", count: 64)
    let backend = RecordingPersistentWorkspaceBackend(
        workspaces: [],
        images: [
            image(
                "localhost/fixture:latest",
                tag: "latest",
                digestCharacter: "a",
                age: 5),
            image(
                "localhost/fixture:digest-" + String(repeating: "a", count: 64),
                tag: "digest-" + String(repeating: "a", count: 64),
                digestCharacter: "a",
                age: 4),
            image(
                "localhost/fixture:digest-" + String(repeating: "b", count: 64),
                tag: "digest-" + String(repeating: "b", count: 64),
                digestCharacter: "b",
                age: 3),
            image(
                obsolete,
                tag: "digest-" + String(repeating: "c", count: 64),
                digestCharacter: "c",
                age: 2),
            image(
                dangling,
                tag: nil,
                digestCharacter: "d",
                age: 1),
            image(
                "localhost/fixture:digest-" + String(repeating: "e", count: 64),
                tag: "digest-" + String(repeating: "e", count: 64),
                digestCharacter: "e",
                age: 0,
                active: true),
            image(
                "localhost/fixture:manual",
                tag: "manual",
                digestCharacter: "f",
                age: 0),
            image(
                "localhost/foreign@sha256:" + String(repeating: "1", count: 64),
                repository: "localhost/foreign",
                tag: nil,
                digestCharacter: "1",
                age: 0),
        ])
    let repository = RepositoryCache(
        context: repositoryContext(
            root: root,
            runtime: workspaceRuntime(root: root, backend: backend)),
        catalog: ComponentCatalog(
            components: [component],
            publicEntrypoints: []))

    let retention = repository.containerImageRetention(
        images: try await backend.images(),
        infrastructure: OCIInfrastructureImages(currentByRepository: [:]))
    #expect(
        Set(retention.filter { $0.state == "reclaimable" }.map(\.reference)) == [
            obsolete, dangling,
        ])
    #expect(
        retention.first { $0.reference.contains("localhost/foreign") }?.state
            == "unknown")

    try await repository.prune(dryRun: true)
    #expect(await backend.imageDeletions().isEmpty)
    try await repository.prune(dryRun: false)
    #expect(Set(await backend.imageDeletions()) == [obsolete, dangling])
}

/// A catalog declaring one image family whose active digest is `a` repeated.
private func imageFixtureCatalog(root: URL) throws -> ComponentCatalog {
    let context = root.appendingPathComponent("context", isDirectory: true)
    try FileManager.default.createDirectory(at: context, withIntermediateDirectories: true)
    try Data(
        """
        FROM docker.io/library/ubuntu:26.04@sha256:\(String(repeating: "b", count: 64))
        RUN true
        """.utf8
    ).write(to: context.appendingPathComponent("Containerfile"))
    let imageID = root.appendingPathComponent("image-id")
    try Data(
        "localhost/fixture\nsha256:\(String(repeating: "a", count: 64))\n".utf8
    ).write(to: imageID)
    let componentID = ComponentID(rawValue: "fixture")
    return ComponentCatalog(
        components: [
            try ComponentDefinition(
                descriptor: ComponentDescriptor(
                    id: componentID,
                    canonicalName: componentID.rawValue,
                    directoryName: componentID.rawValue),
                tasks: [
                    TaskDeclaration(
                        id: TaskID(rawValue: "fixture.image"),
                        component: componentID,
                        action: try AnyColliderAction(
                            ImageFixtureAction(
                                preparation: OCIImagePreparation(
                                    executionPlatform: .linuxARM64OCI,
                                    context: FilePath(context.path),
                                    containerFile: FilePath(
                                        context.appendingPathComponent("Containerfile").path),
                                    imageID: FilePath(imageID.path),
                                    imageName: "localhost/fixture",
                                    rollbackGenerationCount: 1,
                                    environment: [:]))))
                ],
                entrypoints: [])
        ],
        publicEntrypoints: [])
}

/// A container record outlives the process that ran it, and Collider deletes its
/// own on completion, cancellation, and failure alike, so one that is not
/// running belongs to an execution none of those paths reached. It is not inert:
/// it holds an unpacked root filesystem and names an image, and while it exists
/// that image can never be collected. The runtime's own builder container is
/// excluded because the next image build expects it.
@Test func pruningRemovesContainerRecordsNoExecutionOwns() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-container-records-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let catalog = try imageFixtureCatalog(root: root)
    let backend = RecordingPersistentWorkspaceBackend(
        workspaces: [],
        containers: [
            OCIContainerState(
                name: "stale-overlay",
                imageReference: "localhost/fixture:latest",
                running: false,
                infrastructure: false),
            OCIContainerState(
                name: "in-flight",
                imageReference: "localhost/fixture:latest",
                running: true,
                infrastructure: false),
            OCIContainerState(
                name: "buildkit",
                imageReference: "ghcr.io/apple/container-builder-shim/builder:0.13.1",
                running: false,
                infrastructure: true),
        ])
    let repository = RepositoryCache(
        context: repositoryContext(
            root: root,
            runtime: workspaceRuntime(root: root, backend: backend)),
        catalog: catalog)

    try await repository.prune(dryRun: true)
    #expect(await backend.containerDeletions().isEmpty)

    try await repository.prune(dryRun: false)
    #expect(await backend.containerDeletions() == ["stale-overlay"])
}

/// Reachability has three sources, and only the catalog is one of them. The
/// runtime requires its own init and builder images to boot a container or
/// build an image at all, and every first-party image is built `FROM` a base
/// the catalog pins in a Containerfile rather than in a declaration. Treating
/// what the component catalog alone cannot place as collectable would delete
/// the runtime out from under itself.
@Test func imageRetentionKeepsTheRuntimeAndTheBaseItBuildsFrom() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-image-sources-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let catalog = try imageFixtureCatalog(root: root)
    let vminit = "ghcr.io/apple/containerization/vminit"
    let ubuntu = "docker.io/library/ubuntu"
    func image(
        _ reference: String,
        repository: String,
        tag: String?,
        digestCharacter: Character
    ) -> OCIImageState {
        OCIImageState(
            reference: reference,
            repository: repository,
            tag: tag,
            digest: "sha256:" + String(repeating: digestCharacter, count: 64),
            creationDate: Date(timeIntervalSince1970: 1_000),
            active: false)
    }
    let backend = RecordingPersistentWorkspaceBackend(
        workspaces: [],
        images: [
            image(
                "localhost/fixture:latest",
                repository: "localhost/fixture",
                tag: "latest",
                digestCharacter: "a"),
            image(vminit + ":0.40.2", repository: vminit, tag: "0.40.2", digestCharacter: "d"),
            image(vminit + ":0.33.3", repository: vminit, tag: "0.33.3", digestCharacter: "e"),
            image(
                ubuntu + "@sha256:" + String(repeating: "b", count: 64),
                repository: ubuntu,
                tag: nil,
                digestCharacter: "b"),
            image(ubuntu + ":24.04", repository: ubuntu, tag: "24.04", digestCharacter: "c"),
            image(
                "localhost/foreign@sha256:" + String(repeating: "1", count: 64),
                repository: "localhost/foreign",
                tag: nil,
                digestCharacter: "1"),
        ],
        infrastructure: OCIInfrastructureImages(
            currentByRepository: [vminit: vminit + ":0.40.2"]))
    let repository = RepositoryCache(
        context: repositoryContext(
            root: root,
            runtime: workspaceRuntime(root: root, backend: backend)),
        catalog: catalog)

    let retention = repository.containerImageRetention(
        images: try await backend.images(),
        infrastructure: try await backend.infrastructureImages())
    let state = Dictionary(
        uniqueKeysWithValues: retention.map { ($0.reference, $0.state) })
    #expect(state[vminit + ":0.40.2"] == "infrastructure")
    #expect(state[ubuntu + "@sha256:" + String(repeating: "b", count: 64)] == "base")
    #expect(state["localhost/fixture:latest"] == "active")
    // A version of a repository the catalog or the runtime names, that neither
    // selects, is superseded rather than unaccountable.
    #expect(state[vminit + ":0.33.3"] == "reclaimable")
    #expect(state[ubuntu + ":24.04"] == "reclaimable")
    // Nothing accounts for this one, so it is reported rather than collected.
    #expect(
        state["localhost/foreign@sha256:" + String(repeating: "1", count: 64)] == "unknown")

    try await repository.prune(dryRun: false)
    #expect(
        Set(await backend.imageDeletions()) == [vminit + ":0.33.3", ubuntu + ":24.04"])
}

/// Content is orphaned by rebuilding an image, not by pruning one: a rebuild
/// replaces the reference its layers and unpacked filesystem belonged to and
/// leaves them reachable from nothing. Collection that only runs when some
/// image was selected therefore never runs on the store that needs it most,
/// which is a store whose every image is current.
@Test func pruningCollectsOrphanedImageContentWithNoImageToDelete() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-image-collection-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let catalog = try imageFixtureCatalog(root: root)
    let backend = RecordingPersistentWorkspaceBackend(
        workspaces: [],
        images: [
            OCIImageState(
                reference: "localhost/fixture:latest",
                repository: "localhost/fixture",
                tag: "latest",
                digest: "sha256:" + String(repeating: "a", count: 64),
                creationDate: Date(timeIntervalSince1970: 1_000),
                active: false)
        ])
    let repository = RepositoryCache(
        context: repositoryContext(
            root: root,
            runtime: workspaceRuntime(root: root, backend: backend)),
        catalog: catalog)

    try await repository.prune(dryRun: false)
    #expect(await backend.imageDeletions().isEmpty)
    #expect(await backend.collections() == 1)
}

/// A store nothing enumerated and a store holding nothing collectable are the
/// same empty selection. Only one of them means the report is complete, so the
/// reason the question went unanswered reaches the result.
@Test func pruningReportsAnImageStoreItCouldNotRead() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-image-unavailable-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let catalog = try imageFixtureCatalog(root: root)
    let backend = RecordingPersistentWorkspaceBackend(
        workspaces: [],
        imageListingFailure: "image store did not answer")
    let output = StorageConsoleCapture()
    let console = CommandConsole(
        format: .text,
        progress: .never,
        standardOutputIsTerminal: false,
        standardErrorIsTerminal: false,
        standardOutput: output.write,
        standardError: output.write)
    let repository = RepositoryCache(
        context: repositoryContext(
            root: root,
            runtime: workspaceRuntime(root: root, backend: backend),
            console: console),
        catalog: catalog)

    try await repository.prune(dryRun: false)
    #expect(output.text.contains("images not evaluated"))
    #expect(output.text.contains("image store did not answer"))
    // Nothing was enumerated, so nothing may be collected against it either.
    #expect(await backend.collections() == 0)
}

/// Reclamation trims declared workspaces in place. It removes nothing, so an
/// undeclared workspace is left for pruning to decide about rather than being
/// touched by a maintenance pass.
@Test func repositoryReclaimTrimsDeclaredWorkspacesOnly() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-workspace-reclaim-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let declared = fixtureWorkspace(key: "declared-build")
    let undeclared = fixtureWorkspace(key: "undeclared-build")
    let backend = RecordingPersistentWorkspaceBackend(
        workspaces: [
            OCIPersistentWorkspaceState(
                name: "declared-volume",
                identity: declared.identity,
                capacityBytes: declared.capacityBytes,
                allocatedBytes: 8_192,
                active: false),
            OCIPersistentWorkspaceState(
                name: "undeclared-volume",
                identity: undeclared.identity,
                capacityBytes: undeclared.capacityBytes,
                allocatedBytes: 8_192,
                active: false),
        ],
        images: [
            OCIImageState(
                reference: "localhost/nucleus-apt-resolver:latest",
                repository: "localhost/nucleus-apt-resolver",
                tag: "latest",
                digest: "sha256:" + String(repeating: "a", count: 64),
                creationDate: nil,
                active: false)
        ])
    let componentID = ComponentID(rawValue: "fixture")
    let catalog = ComponentCatalog(
        components: [
            try ComponentDefinition(
                descriptor: ComponentDescriptor(
                    id: componentID,
                    canonicalName: "fixture",
                    directoryName: "fixture"),
                tasks: [
                    TaskDeclaration(
                        id: TaskID(rawValue: "fixture.build"),
                        component: componentID,
                        action: try AnyColliderAction(
                            WorkspaceFixtureAction(workspace: declared)))
                ],
                entrypoints: [])
        ],
        publicEntrypoints: [])
    let repository = RepositoryCache(
        context: repositoryContext(
            root: root,
            runtime: workspaceRuntime(root: root, backend: backend)),
        catalog: catalog)

    try await repository.reclaim(dryRun: true)
    #expect(await backend.reclamations().isEmpty)

    try await repository.reclaim(dryRun: false)
    let reclamations = await backend.reclamations()
    #expect(reclamations.map(\.key) == ["declared-build"])
    // The maintenance container runs a first-party Linux image that any built
    // host already has, so reclamation introduces no pinned input of its own.
    #expect(reclamations.first?.imageReference == "localhost/nucleus-apt-resolver:latest")
}

/// A host that has never built has no image to run the maintenance container
/// and nothing to reclaim, so it must say so rather than fail obscurely.
@Test func repositoryReclaimRequiresAFirstPartyLinuxImage() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-workspace-reclaim-image-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let declared = fixtureWorkspace(key: "declared-build")
    let backend = RecordingPersistentWorkspaceBackend(
        workspaces: [
            OCIPersistentWorkspaceState(
                name: "declared-volume",
                identity: declared.identity,
                capacityBytes: declared.capacityBytes,
                allocatedBytes: 8_192,
                active: false)
        ])
    let componentID = ComponentID(rawValue: "fixture")
    let repository = RepositoryCache(
        context: repositoryContext(
            root: root,
            runtime: workspaceRuntime(root: root, backend: backend)),
        catalog: ComponentCatalog(
            components: [
                try ComponentDefinition(
                    descriptor: ComponentDescriptor(
                        id: componentID,
                        canonicalName: "fixture",
                        directoryName: "fixture"),
                    tasks: [
                        TaskDeclaration(
                            id: TaskID(rawValue: "fixture.build"),
                            component: componentID,
                            action: try AnyColliderAction(
                                WorkspaceFixtureAction(workspace: declared)))
                    ],
                    entrypoints: [])
            ],
            publicEntrypoints: []))

    await #expect(throws: (any Error).self) {
        try await repository.reclaim(dryRun: false)
    }
    #expect(await backend.reclamations().isEmpty)
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
        context: repositoryContext(root: root, runtime: runtime),
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
        context: repositoryContext(root: root, runtime: runtime),
        catalog: ComponentCatalog(components: [], publicEntrypoints: []))

    try await repository.prune(dryRun: false)
    #expect(await backend.deletions() == ["orphaned-volume"])
}

@Test func repositoryCleanProtectsDeclaredSourceWorkspace() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-protected-workspace-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let workspace = fixtureWorkspace(
        key: "fixture-source",
        retentionPolicy: .protected)
    let backend = RecordingPersistentWorkspaceBackend(
        workspaces: [
            OCIPersistentWorkspaceState(
                name: "source-volume",
                identity: workspace.identity,
                capacityBytes: workspace.capacityBytes,
                allocatedBytes: 4_096,
                active: false)
        ])
    let componentID = ComponentID(rawValue: "selected")
    let component = try ComponentDefinition(
        descriptor: ComponentDescriptor(
            id: componentID,
            canonicalName: componentID.rawValue,
            directoryName: componentID.rawValue),
        tasks: [
            TaskDeclaration(
                id: TaskID(rawValue: "selected.source"),
                component: componentID,
                action: try AnyColliderAction(
                    WorkspaceFixtureAction(workspace: workspace)))
        ],
        entrypoints: [])
    let repository = RepositoryCache(
        context: repositoryContext(
            root: root,
            runtime: workspaceRuntime(root: root, backend: backend)),
        catalog: ComponentCatalog(
            components: [component],
            publicEntrypoints: []))

    await #expect(throws: WorkspaceFailure.self) {
        try await repository.clean(component: "selected", dryRun: false)
    }
    #expect(await backend.deletions().isEmpty)
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
        context: repositoryContext(
            root: root,
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
        "swift-target-sdks/generations", isDirectory: true)
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
            "swift-target-sdks/current"
        ).path,
        withDestinationPath: "generations/\(active.lastPathComponent)")
    let context = repositoryContext(
        root: workspace,
        runtime: ColliderRuntime(),
        cacheRoot: cache)

    let storage = [
        StorageDeclaration(
            id: "swift-target-sdk-generations",
            owner: ComponentID(rawValue: "fixture"),
            producers: [.runtime("fixture")],
            storageClass: .generation,
            root: FilePath(generations.path),
            safetyRoot: FilePath(generations.deletingLastPathComponent().path),
            retentionPolicy: .keepActiveAndRollback(count: 0),
            activeGenerationLink: FilePath(
                cache.appendingPathComponent("swift-target-sdks/current").path),
            generationNaming: .contentIdentity,
            interruptedCandidateNaming: DirectoryNamePattern(
                rawValue: #"^\.candidate-[0-9a-f]{24}-[0-9TZ-]+-[0-9]+$"#))
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
    ).prune(dryRun: false)

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
            retentionPolicy: .singleWorkingSet),
        StorageDeclaration(
            id: "fixture-source",
            owner: owner,
            producers: [.task(task.id)],
            storageClass: .source,
            root: FilePath(protected.path),
            safetyRoot: FilePath(workspace.path),
            retentionPolicy: .protected,
            residency: .resident(reason: "the fixture's authoritative tree")),
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
                retentionPolicy: .singleWorkingSet)
        ])
    let context = WorkspaceContext(
        root: FilePath(workspace.path),
        environment: ["HOME": workspace.path],
        runtime: ColliderRuntime(),
        cacheRoot: FilePath(workspace.appendingPathComponent("cache").path),
        hostBuildRoot: FilePath(workspace.appendingPathComponent("host-build").path),
        artifactRoot: FilePath(workspace.appendingPathComponent("artifacts").path),
        logRoot: FilePath(workspace.appendingPathComponent("logs").path))
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

@Test func cleanedWorkingSetReconstructsFromDeclaredInput() async throws {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-cold-reconstruction-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

    let input = FilePath(workspace.appendingPathComponent("source/input.txt").path)
    let outputRoot = FilePath(workspace.appendingPathComponent("build").path)
    let output = outputRoot.appending("output.txt")
    try FileManager.default.createDirectory(
        atPath: input.removingLastComponent().string,
        withIntermediateDirectories: true)
    try Data("authoritative input\n".utf8).write(to: URL(fileURLWithPath: input.string))

    let owner = ComponentID(rawValue: "fixture")
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.reconstruct"),
        component: owner,
        inputs: [.file(input)],
        outputs: [OutputDeclaration(path: output, validation: .regularFile)],
        locks: [.shared(FilePath(workspace.appendingPathComponent("fixture.lock").path))],
        action: try AnyColliderAction(
            ReconstructFixtureAction(input: input, output: output)))
    let declaration = StorageDeclaration(
        id: "fixture-working-set",
        owner: owner,
        producers: [.task(task.id)],
        storageClass: .incremental,
        root: outputRoot,
        safetyRoot: FilePath(workspace.path),
        retentionPolicy: .singleWorkingSet)
    let component = try ComponentDefinition(
        descriptor: ComponentDescriptor(
            id: owner,
            canonicalName: "fixture",
            directoryName: "fixture"),
        tasks: [task],
        entrypoints: [],
        storage: [declaration])
    let catalog = ComponentCatalog(components: [component], publicEntrypoints: [])
    try StorageCatalog.validateWritableEffects(catalog.storage, tasks: catalog.tasks)

    let context = repositoryContext(root: workspace, runtime: ColliderRuntime())
    let engine = ColliderEngine(runtime: context.runtime)
    let first = try await engine.execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: context.taskStateRoot)
    #expect(first.executed == [task.id])
    #expect(try String(contentsOfFile: output.string, encoding: .utf8) == "authoritative input\n")

    try await RepositoryCache(context: context, catalog: catalog).clean(
        component: "fixture",
        dryRun: false)
    #expect(!FileManager.default.fileExists(atPath: outputRoot.string))

    let second = try await engine.execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: context.taskStateRoot)
    #expect(second.executed == [task.id])
    #expect(try String(contentsOfFile: output.string, encoding: .utf8) == "authoritative input\n")
}

@Test func repositoryPruneRetainsOnlyCurrentSwiftPMTaskIdentityContexts() async throws {
    let workspace = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent(
            "collider-swiftpm-retention-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let context = repositoryContext(root: workspace, runtime: ColliderRuntime())
    let swiftPMRoot = context.hostBuildRoot.appending("swiftpm")
    let group = swiftPMRoot.appending("unsanitized")
    let active = group.appending("sha256-" + String(repeating: "a", count: 64))
    let obsolete = group.appending("sha256-" + String(repeating: "b", count: 64))
    let unrelated = group.appending("manually-managed")
    for path in [active, obsolete, unrelated] {
        try FileManager.default.createDirectory(
            atPath: path.string,
            withIntermediateDirectories: true)
        try Data("payload".utf8).write(
            to: URL(fileURLWithPath: path.appending("payload").string))
    }

    let invocation = SwiftPMInvocation(
        context: SwiftBuildContext(
            packageRoot: FilePath(workspace.path),
            configuration: .debug,
            target: .host(identity: "fixture"),
            toolchainIdentity: "fixture"),
        scratchPath: active)
    let owner = ComponentID(rawValue: "fixture")
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.build"),
        component: owner,
        swiftProducts: [
            SwiftProductRequirement(
                package: "fixture",
                product: "fixture",
                packageRoot: FilePath(workspace.path),
                invocation: invocation,
                inputs: [],
                environment: [:])
        ])
    let catalog = ComponentCatalog(
        components: [
            try ComponentDefinition(
                descriptor: ComponentDescriptor(
                    id: owner,
                    canonicalName: "fixture",
                    directoryName: "fixture"),
                tasks: [task],
                entrypoints: [],
                storage: [
                    StorageDeclaration(
                        id: "fixture-swiftpm-contexts",
                        owner: owner,
                        producers: [.runtime("swiftpm")],
                        storageClass: .incremental,
                        root: swiftPMRoot,
                        safetyRoot: context.hostBuildRoot,
                        retentionPolicy: .taskIdentityContexts(
                            .init(intermediateLevels: 1, naming: .artifactDigestDirectory),
                            retaining: 0))
                ])
        ],
        publicEntrypoints: [])

    try await RepositoryCache(context: context, catalog: catalog).prune(dryRun: false)

    #expect(FileManager.default.fileExists(atPath: active.string))
    #expect(!FileManager.default.fileExists(atPath: obsolete.string))
    #expect(FileManager.default.fileExists(atPath: unrelated.string))
}

@Test func repositoryPruneRejectsContextsNestedDeeperThanDeclared() async throws {
    let workspace = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent(
            "collider-swiftpm-nesting-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let context = repositoryContext(root: workspace, runtime: ColliderRuntime())
    let swiftPMRoot = context.hostBuildRoot.appending("swiftpm")
    // Contexts written as `<target>/<sanitizer>/sha256-…` sit two levels below
    // the root while the declaration below names one.
    let stranded = swiftPMRoot.appending("linux-arm64").appending("unsanitized")
        .appending("sha256-" + String(repeating: "c", count: 64))
    try FileManager.default.createDirectory(
        atPath: stranded.string,
        withIntermediateDirectories: true)
    try Data("payload".utf8).write(
        to: URL(fileURLWithPath: stranded.appending("payload").string))

    let owner = ComponentID(rawValue: "fixture")
    let catalog = ComponentCatalog(
        components: [
            try ComponentDefinition(
                descriptor: ComponentDescriptor(
                    id: owner,
                    canonicalName: "fixture",
                    directoryName: "fixture"),
                tasks: [],
                entrypoints: [],
                storage: [
                    StorageDeclaration(
                        id: "fixture-swiftpm-contexts",
                        owner: owner,
                        producers: [.runtime("swiftpm")],
                        storageClass: .incremental,
                        root: swiftPMRoot,
                        safetyRoot: context.hostBuildRoot,
                        retentionPolicy: .taskIdentityContexts(
                            .init(intermediateLevels: 1, naming: .artifactDigestDirectory),
                            retaining: 0))
                ])
        ],
        publicEntrypoints: [])

    await #expect(throws: StorageCatalogFailure.self) {
        try await RepositoryCache(context: context, catalog: catalog).prune(dryRun: true)
    }
    #expect(FileManager.default.fileExists(atPath: stranded.string))
}

/// Builds a context root holding one reachable context and several stale ones
/// with decreasing modification dates, so "newest first" is deterministic.
private func identityContextFixture(
    workspace: URL,
    retaining: UInt32,
    staleCount: Int
) throws -> (
    context: WorkspaceContext, catalog: ComponentCatalog, active: FilePath,
    stale: [FilePath]
) {
    let context = repositoryContext(root: workspace, runtime: ColliderRuntime())
    let group = context.hostBuildRoot.appending("swiftpm").appending("unsanitized")
    let active = group.appending("sha256-" + String(repeating: "a", count: 64))
    var stale: [FilePath] = []
    for index in 0..<staleCount {
        let suffix = String(index, radix: 16)
        stale.append(
            group.appending(
                "sha256-" + String(repeating: "b", count: 64 - suffix.count) + suffix))
    }
    for (offset, path) in ([active] + stale).enumerated() {
        try FileManager.default.createDirectory(
            atPath: path.string, withIntermediateDirectories: true)
        try Data("payload".utf8).write(
            to: URL(fileURLWithPath: path.appending("payload").string))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000_000 - Double(offset * 60))],
            ofItemAtPath: path.string)
    }
    let owner = ComponentID(rawValue: "fixture")
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.build"),
        component: owner,
        swiftProducts: [
            SwiftProductRequirement(
                package: "fixture",
                product: "fixture",
                packageRoot: FilePath(workspace.path),
                invocation: SwiftPMInvocation(
                    context: SwiftBuildContext(
                        packageRoot: FilePath(workspace.path),
                        configuration: .debug,
                        target: .host(identity: "fixture"),
                        toolchainIdentity: "fixture"),
                    scratchPath: active),
                inputs: [],
                environment: [:])
        ])
    let catalog = ComponentCatalog(
        components: [
            try ComponentDefinition(
                descriptor: ComponentDescriptor(
                    id: owner, canonicalName: "fixture", directoryName: "fixture"),
                tasks: [task],
                entrypoints: [],
                storage: [
                    StorageDeclaration(
                        id: "fixture-swiftpm-contexts",
                        owner: owner,
                        producers: [.runtime("swiftpm")],
                        storageClass: .incremental,
                        root: context.hostBuildRoot.appending("swiftpm"),
                        safetyRoot: context.hostBuildRoot,
                        retentionPolicy: .taskIdentityContexts(
                            .init(intermediateLevels: 1, naming: .artifactDigestDirectory),
                            retaining: retaining))
                ])
        ],
        publicEntrypoints: [])
    return (context, catalog, active, stale)
}

@Test func boundingKeepsTheRetainedCountOfUnreachableContexts() async throws {
    let workspace = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("collider-context-bound-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let fixture = try identityContextFixture(
        workspace: workspace, retaining: 2, staleCount: 5)

    try RepositoryCache(context: fixture.context, catalog: fixture.catalog)
        .boundIdentityContexts()

    // The reachable context survives regardless of age.
    #expect(FileManager.default.fileExists(atPath: fixture.active.string))
    // Two newest stale contexts survive; the older three do not.
    let surviving = fixture.stale.filter {
        FileManager.default.fileExists(atPath: $0.string)
    }
    #expect(surviving == Array(fixture.stale.prefix(2)))
}

@Test func boundingNeverEvictsAContextATaskStillReaches() async throws {
    let workspace = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("collider-context-reach-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    // A count of zero would evict everything the bound applies to; the
    // reachable context is not something it applies to.
    let fixture = try identityContextFixture(
        workspace: workspace, retaining: 0, staleCount: 2)

    try RepositoryCache(context: fixture.context, catalog: fixture.catalog)
        .boundIdentityContexts()

    #expect(FileManager.default.fileExists(atPath: fixture.active.string))
    for stale in fixture.stale {
        #expect(!FileManager.default.fileExists(atPath: stale.string))
    }
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
    let active = generations.appendingPathComponent(
        "sha256-" + String(repeating: "a", count: 64))
    try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
    try Data("active".utf8).write(to: active.appendingPathComponent("payload"))
    for index in 0..<64 {
        let suffix = String(index + 1, radix: 16)
        let name =
            "sha256-" + String(repeating: "0", count: 64 - suffix.count) + suffix
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
        retentionPolicy: .keepActiveAndRollback(count: 0),
        activeGenerationLink: FilePath(current.path),
        generationNaming: .artifactDigestDirectory,
        interruptedCandidateNaming: nil)
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
    let context = repositoryContext(
        root: workspace,
        runtime: ColliderRuntime(),
        cacheRoot: cacheRoot)
    let repository = RepositoryCache(context: context, catalog: catalog)

    async let status: Void = repository.status(measureAllocations: true)
    async let prune: Void = repository.prune(dryRun: false)
    _ = try await (status, prune)

    #expect(FileManager.default.fileExists(atPath: active.path))
    let remaining = try FileManager.default.contentsOfDirectory(atPath: generations.path)
    #expect(remaining == [active.lastPathComponent])
}

/// Source is the one class whose cost is worth a decision, and the store held
/// three copies of AOSP because nothing required one.
///
/// The rule this replaces was that source storage must be protected, which made
/// "this is source" and "this can never be collected" the same statement. They
/// are not: a tree materialized from a pinned input is source and is
/// reconstructible.
@Test func materializedSourceMustSayWhetherItStays() throws {
    func declaration(
        retention: StorageRetentionPolicy,
        residency: StorageResidency?,
        producers: Set<StorageProducer> = [.task(TaskID(rawValue: "example.rebuild"))]
    ) -> StorageDeclaration {
        StorageDeclaration(
            id: "example-source",
            owner: ComponentID(rawValue: "example"),
            producers: producers,
            storageClass: .source,
            root: FilePath("/store/example/source"),
            safetyRoot: FilePath("/store/example"),
            retentionPolicy: retention,
            residency: residency)
    }
    func catalog(_ declarations: [StorageDeclaration]) throws {
        try StorageCatalog.validate(declarations, forbiddenRemovalRoots: [])
    }

    // Undeclared residency is the state this rule exists to reject.
    #expect(throws: (any Error).self) {
        try catalog([declaration(retention: .protected, residency: nil)])
    }
    // A tree that stays is authoritative for as long as it stays.
    #expect(throws: Never.self) {
        try catalog([
            declaration(retention: .protected, residency: .resident(reason: "the checkout"))
        ])
    }
    #expect(throws: (any Error).self) {
        try catalog([
            declaration(
                retention: .singleWorkingSet,
                residency: .resident(reason: "the checkout"))
        ])
    }
    // A tree that does not stay must be collectable, or the promise to rebuild
    // it is never called on.
    #expect(throws: (any Error).self) {
        try catalog([
            declaration(
                retention: .protected,
                residency: .onDemand(reconstructedBy: TaskID(rawValue: "example.rebuild")))
        ])
    }
    // And it must name a task that actually produces it, so "reconstructible"
    // is checkable rather than asserted.
    #expect(throws: (any Error).self) {
        try catalog([
            declaration(
                retention: .singleWorkingSet,
                residency: .onDemand(reconstructedBy: TaskID(rawValue: "nobody.rebuilds")),
                producers: [.task(TaskID(rawValue: "example.rebuild"))])
        ])
    }
    #expect(throws: Never.self) {
        try catalog([
            declaration(
                retention: .singleWorkingSet,
                residency: .onDemand(reconstructedBy: TaskID(rawValue: "example.rebuild")))
        ])
    }
}

/// An on-demand root promises that deleting it costs a rebuild rather than a
/// result. Only a declared output covering that root makes the promise
/// checkable.
///
/// AOSP's host object store was written as scratch, so nothing validated it:
/// deleting seventy-three gigabytes left its producing task clean, and the
/// materialization that mounts it read-only would have run against an empty
/// directory. Declaring the residency without this rule would have been a
/// sentence nothing enforced.
@Test func onDemandStorageMustBeObservableAsMissing() throws {
    let owner = ComponentID(rawValue: "example")
    let reconstructor = TaskID(rawValue: "example.materialize")
    let root = FilePath("/store/example/source")
    let declaration = StorageDeclaration(
        id: "example-source",
        owner: owner,
        producers: [.task(reconstructor)],
        storageClass: .source,
        root: root,
        safetyRoot: FilePath("/store/example"),
        retentionPolicy: .singleWorkingSet,
        residency: .onDemand(reconstructedBy: reconstructor))
    // Built through the builder, which is how a task states an output slot at
    // all: the slot type's initializer is deliberately not reachable from
    // outside it.
    func task(outputPaths: [FilePath] = []) throws -> TaskDeclaration {
        var builder = TaskBuilder(id: reconstructor, component: owner)
        for (index, path) in outputPaths.enumerated() {
            let _: ArtifactReference = try builder.output(
                OutputSlotID(rawValue: "slot-\(index)"),
                path: path,
                validation: .nonEmptyDirectory)
        }
        return builder.build(locks: [.checkout("example")])
    }
    func validate(_ task: TaskDeclaration) throws {
        try StorageCatalog.validateProducers([declaration], tasks: [task])
    }

    // Scratch: nothing declared at all.
    #expect(throws: (any Error).self) { try validate(try task()) }

    // An output beside the root does not vouch for it. This is the shape that
    // hid the defect: two small files under AOSP's source-input root, and the
    // object store next to them unwatched.
    #expect(throws: (any Error).self) {
        try validate(try task(outputPaths: [root.appending("locks/manifest.xml")]))
    }

    // The root itself, stated as a slot, which is how a task states most of
    // its outputs -- checking only the other spelling made this rule vacuous
    // for every task that uses this one.
    #expect(throws: Never.self) {
        try validate(try task(outputPaths: [root]))
    }

    // Or an output containing the root, which observes it just as well.
    #expect(throws: Never.self) {
        try validate(
            TaskDeclaration(
                id: reconstructor,
                component: owner,
                outputs: [
                    OutputDeclaration(
                        path: FilePath("/store/example"),
                        validation: .nonEmptyDirectory)
                ],
                locks: [.checkout("example")]))
    }
}
