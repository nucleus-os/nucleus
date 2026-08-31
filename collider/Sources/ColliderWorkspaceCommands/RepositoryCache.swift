import ColliderCore
import ColliderPersistence
import ColliderRuntime
import Foundation
import SystemPackage

struct StorageStatusRecord: Codable, Equatable {
    let id: String
    let owner: String
    let storageClass: StorageClass
    let path: String
    let allocatedBytes: UInt64?
    let reclaimableBytes: UInt64?
    let retentionPolicy: StorageRetentionPolicy
    let residency: String?
    let state: String
}

/// One selected target that would not be removed, and the path that refused.
struct StorageRemovalFailure: Error, Sendable {
    let declaration: String
    let target: FilePath
    let offendingPath: FilePath
    let underlying: any Error

    var description: String {
        var line = "\(declaration): \(target)"
        if offendingPath != target {
            line += "\n    refused at: \(offendingPath)"
        }
        if let attributes = try? FileManager.default.attributesOfItem(
            atPath: offendingPath.string),
            let mode = attributes[.posixPermissions] as? NSNumber,
            let owner = attributes[.ownerAccountName] as? String
        {
            line += "\n    mode \(String(mode.intValue, radix: 8)) owner \(owner)"
        }
        return line + "\n    \(underlying)"
    }
}

/// Every target a prune could not remove, raised once the rest are collected.
struct StorageRemovalFailures: Error, CustomStringConvertible, Sendable {
    let failures: [StorageRemovalFailure]

    var description: String {
        "\(failures.count) selected storage target(s) could not be removed; "
            + "every other target was collected\n"
            + failures.map { "  " + $0.description }.joined(separator: "\n")
    }
}

private struct StorageStatusReport: Codable {
    let hostFilesystem: HostFilesystemStatusRecord?
    let totals: StorageTotalsRecord
    let storage: [StorageStatusRecord]
    let appleContainer: RuntimeObservation<OCIRuntimeDiskUsage>
    let appleContainerImages: RuntimeObservation<[OCIImageRetentionRecord]>
    let persistentWorkspaces: RuntimeObservation<[PersistentWorkspaceStatusRecord]>
    let unknownPaths: [String]
}

/// What Collider's state weighs on this host, summed from the three disjoint
/// sources that hold it: declared host roots, persistent workspace images, and
/// the container content store. Per-root detail answers where a byte went;
/// this answers whether the host is running out, which is the question a
/// terabyte-scale working set makes urgent and which no single record states.
///
/// Workspace and image totals come from the runtime and cost nothing. Declared
/// host roots require a recursive walk, so `declaredRootBytes` is absent unless
/// the caller asked for it, and `accountedBytes` then reports only what was
/// actually counted.
private struct StorageTotalsRecord: Codable {
    let declaredRootBytes: UInt64?
    let workspaceCount: Int
    let workspaceAllocatedBytes: UInt64?
    let workspaceCapacityBytes: UInt64?
    let workspacesNearCapacity: Int
    let containerStoreBytes: UInt64?
    let accountedBytes: UInt64
}

private enum RuntimeObservation<Value: Codable & Sendable>: Codable, Sendable {
    case available(Value)
    case unavailable(String)
}

private actor ObservationRace<Value: Codable & Sendable> {
    private var result: RuntimeObservation<Value>?
    private var continuations: [CheckedContinuation<RuntimeObservation<Value>, Never>] = []

    func resolve(_ result: RuntimeObservation<Value>) {
        guard self.result == nil else { return }
        self.result = result
        let continuations = continuations
        self.continuations.removeAll()
        for continuation in continuations { continuation.resume(returning: result) }
    }

    func value() async -> RuntimeObservation<Value> {
        if let result { return result }
        return await withCheckedContinuation { continuations.append($0) }
    }
}

private func boundedObservation<Value: Codable & Sendable>(
    _ name: String,
    timeout: Duration,
    operation: @escaping @Sendable () async throws -> Value
) async -> RuntimeObservation<Value> {
    let race = ObservationRace<Value>()
    let operationTask = Task {
        do {
            await race.resolve(.available(try await operation()))
        } catch {
            await race.resolve(.unavailable(String(describing: error)))
        }
    }
    let timeoutTask = Task {
        do {
            try await Task.sleep(for: timeout)
            await race.resolve(.unavailable("\(name) timed out"))
        } catch {}
    }
    let result = await withTaskCancellationHandler {
        await race.value()
    } onCancel: {
        Task { await race.resolve(.unavailable("\(name) cancelled")) }
    }
    operationTask.cancel()
    timeoutTask.cancel()
    return result
}

struct OCIImageRetentionRecord: Codable, Equatable, Sendable {
    let reference: String
    let repository: String
    let digest: String
    let creationDate: Date?
    let state: String
}

private struct HostFilesystemStatusRecord: Codable {
    let path: String
    let totalBytes: UInt64
    let availableBytes: UInt64
}

private struct PersistentWorkspaceStatusRecord: Codable {
    let name: String
    let identity: PersistentWorkspaceIdentity
    let capacityBytes: UInt64
    let allocatedBytes: UInt64
    let retentionPolicy: StorageRetentionPolicy?
    let residency: String?
    let state: String

    /// Close enough to its declared ceiling that the next build may fail for
    /// space rather than for anything it did. An ext4 image cannot grow past
    /// the size it was created with, so this is the signal that matters about
    /// a workspace; the sum of declared ceilings across workspaces is not,
    /// because an unclaimed ceiling on a sparse image occupies nothing.
    var isNearCapacity: Bool {
        capacityBytes > 0 && allocatedBytes >= exhaustionThresholdBytes
    }

    /// What remains before the run that mounts this workspace is refused.
    ///
    /// Measured against the threshold rather than against the ceiling, so the
    /// number a reader sees is the number enforcement acts on. Reporting the
    /// distance to a ceiling nothing is allowed to reach would say a workspace
    /// had room left at the moment it stopped admitting work.
    var headroomBytes: UInt64 {
        let threshold = exhaustionThresholdBytes
        return allocatedBytes >= threshold ? 0 : threshold - allocatedBytes
    }

    private var exhaustionThresholdBytes: UInt64 {
        capacityBytes - capacityBytes / 5
    }
}

private struct PersistentWorkspaceUsage {
    let declaration: PersistentWorkspaceDeclaration
    var consumers: Set<ComponentID>
}

struct StorageRemovalTarget: Codable, Equatable, Sendable {
    let id: String
    let path: String
    let allocatedBytes: UInt64
}

struct ReclaimedWorkspaceRecord: Codable, Equatable, Sendable {
    let key: String
    let allocatedBeforeBytes: UInt64
    let allocatedAfterBytes: UInt64
}

struct ReclaimResult: Codable, Equatable, Sendable {
    let workspaces: [ReclaimedWorkspaceRecord]
    let reclaimedBytes: UInt64
    let dryRun: Bool
}

struct StorageAllocationMeasurement: Equatable, Sendable {
    let allocatedBytes: UInt64
    let reclaimableBytes: UInt64
}

struct PersistentWorkspaceRemovalTarget: Codable, Equatable, Sendable {
    let name: String
    let identity: PersistentWorkspaceIdentity
    let allocatedBytes: UInt64
    let active: Bool
}

struct CleanResult: Codable, Equatable, Sendable {
    let component: String
    let targets: [StorageRemovalTarget]
    let persistentWorkspaces: [PersistentWorkspaceRemovalTarget]
    let selectedAllocatedBytes: UInt64
    let recoveredBytes: UInt64?
    let dryRun: Bool
}

struct PruneResult: Codable, Equatable, Sendable {
    let removedRuns: [String]
    let targets: [StorageRemovalTarget]
    let persistentWorkspaces: [PersistentWorkspaceRemovalTarget]
    /// Why the workspace store could not be enumerated, when it could not be.
    /// Absent means the listing succeeded and `persistentWorkspaces` is the
    /// complete set of orphans.
    let persistentWorkspacesUnavailable: String?
    let appleContainerImages: [OCIImageRetentionRecord]
    /// Container records removed because no execution owns them.
    let appleContainers: [String]
    /// Why the container records could not be read, when they could not be.
    let appleContainersUnavailable: String?
    /// Why the image store could not be read, when it could not be. Absent
    /// means `appleContainerImages` is the complete selection rather than what
    /// survived a question nothing answered.
    let appleContainerImagesUnavailable: String?
    let selectedAllocatedBytes: UInt64
    let recoveredBytes: UInt64?
    /// Bytes returned by collecting stored image content no live image reaches.
    /// Absent on a plan, which performs no collection, and distinct from a
    /// collection that returned nothing.
    let appleContainerCollectedBytes: UInt64?
    let dryRun: Bool
}

/// What pruning did about the image store.
private struct ImagePruneOutcome {
    var selected: [OCIImageRetentionRecord] = []
    var unavailable: String?
    var collectedBytes: UInt64?
}

/// What pruning did about container records.
private struct ContainerPruneOutcome {
    var selected: [String] = []
    var unavailable: String?
}

private struct OCIImageFamily {
    let repository: String
    let rollbackGenerationCount: UInt32
    var activeDigests: Set<String>
}

struct RepositoryCache {
    let context: WorkspaceContext
    let catalog: ComponentCatalog
    let observationTimeout: Duration

    init(
        context: WorkspaceContext,
        catalog: ComponentCatalog,
        observationTimeout: Duration = .seconds(5)
    ) {
        self.context = context
        self.catalog = catalog
        self.observationTimeout = observationTimeout
    }

    private var storageDeclarations: [StorageDeclaration] { catalog.storage }

    /// Removes a component's explicitly cleanable storage, or one declaration
    /// of it.
    ///
    /// Naming one declaration is how an artifact is produced a second time. A
    /// working set is replaced in place, so a build reuses it and never has an
    /// opportunity to disagree with itself; discarding exactly the working set
    /// makes the next build produce independently, which is what comparing
    /// bytes requires. Selecting one also keeps a component whose other
    /// declarations are unreachable from blocking that.
    func clean(
        component selection: String,
        storage storageSelection: String? = nil,
        dryRun: Bool
    ) async throws {
        try validateStorageDeclarations()
        guard
            let component = catalog.components.first(where: {
                $0.descriptor.canonicalName == selection
                    || $0.descriptor.aliases.contains(selection)
            })
        else {
            throw WorkspaceFailure.message("unknown component '\(selection)'")
        }
        let declarations = component.storage
            .filter {
                $0.retentionPolicy.allowsExplicitClean
                    && (storageSelection == nil || $0.id == storageSelection)
            }
            .sorted { $0.id < $1.id }
        let workspaceUsage = try persistentWorkspaceUsage()
        let workspaceDeclarations = component.persistentWorkspaces.filter {
            $0.retentionPolicy.allowsExplicitClean
                && workspaceUsage[$0.identity]?.consumers == Set([component.descriptor.id])
                && (storageSelection == nil || $0.identity.key == storageSelection)
        }
        if let storageSelection, declarations.isEmpty, workspaceDeclarations.isEmpty {
            throw WorkspaceFailure.message(
                "component '\(component.descriptor.canonicalName)' declares no "
                    + "explicitly cleanable storage '\(storageSelection)'")
        }
        guard !declarations.isEmpty || !workspaceDeclarations.isEmpty else {
            throw WorkspaceFailure.message(
                "component '\(component.descriptor.canonicalName)' has no explicitly cleanable storage"
            )
        }
        var locks = Set<TaskLock>()
        for declaration in declarations {
            let declarationLocks = try catalog.workflowLocks(for: declaration)
            guard !declarationLocks.isEmpty else {
                throw StorageCatalogFailure.invalid(
                    "cleanable storage has no producer lock: \(declaration.id)")
            }
            locks.formUnion(declarationLocks)
        }
        for workspace in workspaceDeclarations {
            locks.insert(
                .persistentWorkspace(
                    workspace.identity,
                    stateRoot: context.taskStateRoot))
        }
        let targets = try declarations.map { declaration in
            StorageRemovalTarget(
                id: declaration.id,
                path: declaration.root.string,
                allocatedBytes: try allocatedSize(
                    URL(fileURLWithPath: declaration.root.string)))
        }
        if dryRun {
            let workspaces = try await persistentWorkspaceTargets(
                matching: Set(workspaceDeclarations.map(\.identity)))
            try emit(
                cleanResult(
                    component: component.descriptor.canonicalName,
                    targets: targets,
                    workspaces: workspaces,
                    recoveredBytes: nil,
                    dryRun: true))
            return
        }
        let availableBefore = hostFilesystemStatus()?.availableBytes
        let workspaces = try await context.runtime.withTaskLocks(
            locks,
            stateRoot: context.taskStateRoot,
            purpose: "clean \(component.descriptor.canonicalName) storage"
        ) {
            let workspaces = try await persistentWorkspaceTargets(
                matching: Set(workspaceDeclarations.map(\.identity)))
            if let active = workspaces.first(where: \.active) {
                throw WorkspaceFailure.message(
                    "persistent workspace '\(active.name)' is still attached")
            }
            for declaration in declarations {
                try removeDeclaredRoot(declaration)
            }
            for workspace in workspaces {
                try await context.runtime.deleteOCIPersistentWorkspace(
                    named: workspace.name)
            }
            return workspaces
        }
        try emit(
            cleanResult(
                component: component.descriptor.canonicalName,
                targets: targets,
                workspaces: workspaces,
                recoveredBytes: recoveredBytes(since: availableBefore),
                dryRun: false))
    }

    func status(measureAllocations: Bool = false) async throws {
        try validateStorageDeclarations()
        let declarations = storageDeclarations
        let reclaimableRuns = await RunRegistry(
            root: context.logRoot.appending("runs")
        )
        .reclaimableRuns(keeping: retainedRunCount())
        var reclaimableTargets: [String: [URL]] = [:]
        for declaration in declarations {
            if declaration.storageClass == .runRecord {
                reclaimableTargets[declaration.id] = reclaimableRuns.map {
                    URL(fileURLWithPath: $0.directory.string)
                }
            } else if declaration.retentionPolicy.hasAutomaticPruneTargets {
                reclaimableTargets[declaration.id] = try pruneTargets(for: declaration)
            }
        }
        // Recorded rather than walked. Measuring 1.4 TiB to print a number is
        // a cost the question does not justify, and it is also the wrong
        // shape: most roots do not change in a given run, so most of that walk
        // re-derives what the previous one established. The explicit
        // measurement remains the way to check the record.
        let measurements: [String: StorageAllocationMeasurement]
        if measureAllocations {
            measurements = try await allocationMeasurements(
                declarations: declarations,
                reclaimableTargets: reclaimableTargets)
            allocationLedger.record(measurements.mapValues(\.allocatedBytes))
            allocationLedger.retaining(Set(declarations.map(\.id)))
        } else {
            measurements = allocationLedger.load().mapValues {
                StorageAllocationMeasurement(
                    allocatedBytes: $0.allocatedBytes,
                    // Reclaimable is a property of what a prune would select
                    // now, not of what a past measurement found, so it is left
                    // to the measurement that computes it.
                    reclaimableBytes: 0)
            }
        }
        let declaredWorkspaces = try persistentWorkspaceUsage().mapValues(\.declaration)
        async let ociUsage = boundedObservation(
            "Apple Container disk usage",
            timeout: observationTimeout
        ) {
            try await context.runtime.storedOCIDiskUsage()
        }
        async let imageRetention = boundedObservation(
            "Apple Container images",
            timeout: observationTimeout
        ) {
            let images = try await context.runtime.storedOCIImages()
            return containerImageRetention(
                images: images,
                infrastructure:
                    try await context.runtime.storedOCIInfrastructureImages())
        }
        async let persistentWorkspaces = boundedObservation(
            "Apple Container persistent workspaces",
            timeout: observationTimeout
        ) {
            try await context.runtime.storedOCIPersistentWorkspaces().map { workspace in
                let declaration = declaredWorkspaces[workspace.identity]
                return PersistentWorkspaceStatusRecord(
                    name: workspace.name,
                    identity: workspace.identity,
                    capacityBytes: workspace.capacityBytes,
                    allocatedBytes: workspace.allocatedBytes,
                    retentionPolicy: declaration?.retentionPolicy,
                    residency: declaration?.residency?.description,
                    state: workspace.active
                        ? "active"
                        : declaration?.retentionPolicy.isProtected == true
                            ? "protected"
                            : declaration != nil ? "retained" : "reclaimable")
            }
        }
        var records = declarations.map { declaration in
            let exists = FileManager.default.fileExists(atPath: declaration.root.string)
            let measurement = measurements[declaration.id]
            let allocated = exists ? measurement?.allocatedBytes : 0
            let targets = reclaimableTargets[declaration.id] ?? []
            let reclaimable = targets.isEmpty ? 0 : measurement?.reclaimableBytes
            return StorageStatusRecord(
                id: declaration.id,
                owner: declaration.owner.rawValue,
                storageClass: declaration.storageClass,
                path: declaration.root.string,
                allocatedBytes: allocated,
                reclaimableBytes: reclaimable,
                retentionPolicy: declaration.retentionPolicy,
                residency: declaration.residency?.description,
                state: storageState(
                    declaration: declaration,
                    exists: exists,
                    hasReclaimableStorage: !targets.isEmpty))
        }
        records.sort { $0.id < $1.id }
        let resolvedContainer = await ociUsage
        let resolvedWorkspaces = await persistentWorkspaces
        let report = StorageStatusReport(
            hostFilesystem: hostFilesystemStatus(),
            totals: storageTotals(
                storage: records,
                measuredDeclaredRoots: measureAllocations || !measurements.isEmpty,
                appleContainer: resolvedContainer,
                persistentWorkspaces: resolvedWorkspaces),
            storage: records,
            appleContainer: resolvedContainer,
            appleContainerImages: await imageRetention,
            persistentWorkspaces: resolvedWorkspaces,
            unknownPaths: unknownOwnedPaths())
        try emit(report)
    }

    func prune(dryRun: Bool) async throws {
        try validateStorageDeclarations()
        let pruneLock: ColliderFileLock? =
            if dryRun {
                nil
            } else {
                try ColliderFileLock(
                    path: context.lockRoot.appending(
                        "cache-prune.lock"),
                    purpose: "Collider-owned storage pruning",
                    waitForExistingOwner: false)
            }
        defer { withExtendedLifetime(pruneLock) {} }
        let registry = RunRegistry(
            root: context.logRoot.appending("runs"))
        let reclaimableRuns = await registry.reclaimableRuns(
            keeping: retainedRunCount())
        let runBytes = try reclaimableRuns.reduce(into: UInt64(0)) { total, run in
            total &+= try allocatedSize(URL(fileURLWithPath: run.directory.string))
        }
        let pruneDeclarations =
            storageDeclarations
            .filter { $0.retentionPolicy.hasAutomaticPruneTargets }
            .sorted { $0.id < $1.id }
        let declaredWorkspaceIdentities = Set(
            catalog.components.flatMap(\.persistentWorkspaces).map(\.identity))
        let workspacesUnavailable: String?
        let orphanedWorkspaceIdentities: Set<PersistentWorkspaceIdentity>
        switch await containerPersistentWorkspaces() {
        case .success(let workspaces):
            workspacesUnavailable = nil
            orphanedWorkspaceIdentities = Set(
                workspaces
                    .filter {
                        !$0.active && !declaredWorkspaceIdentities.contains($0.identity)
                    }
                    .map(\.identity))
        case .failure(let error):
            // An orphan set cannot be computed against a store that did not
            // answer. Nothing is reclaimed, and the reason reaches the report.
            workspacesUnavailable = "\(error)"
            orphanedWorkspaceIdentities = []
        }
        var targetRecords: [StorageRemovalTarget]
        var workspaceRecords: [PersistentWorkspaceRemovalTarget]
        var images: ImagePruneOutcome
        var containers: ContainerPruneOutcome
        var removalFailures: [StorageRemovalFailure] = []
        let availableBefore = hostFilesystemStatus()?.availableBytes

        if dryRun {
            targetRecords = try resolvedPruneTargets(pruneDeclarations).records
            workspaceRecords = try await persistentWorkspaceTargets(
                matching: orphanedWorkspaceIdentities)
            // Reachability over blobs and snapshots is computed from the store
            // here, so a preview states what collection would return rather
            // than stating that it runs. It used to be a property only the
            // service could answer, and only by performing the collection.
            images = await reclaimableImages()
            if images.unavailable == nil {
                images.collectedBytes =
                    try? await context.runtime
                    .storedOrphanedOCIImageContent().totalBytes
            }
            containers = await reclaimableContainers()
        } else {
            var locks = Set<TaskLock>()
            for declaration in pruneDeclarations {
                locks.formUnion(try catalog.workflowLocks(for: declaration))
            }
            for identity in orphanedWorkspaceIdentities {
                locks.insert(
                    .persistentWorkspace(
                        identity,
                        stateRoot: context.taskStateRoot))
            }
            for task in catalog.tasks where task.action?.imagePreparations.isEmpty == false {
                locks.formUnion(task.locks)
            }
            (targetRecords, workspaceRecords, images, containers, removalFailures) =
                try await context.runtime.withTaskLocks(
                    locks,
                    stateRoot: context.taskStateRoot,
                    purpose: "declared storage pruning"
                ) {
                    let resolved = try resolvedPruneTargets(pruneDeclarations)
                    // One target that will not go must not hold the rest of the
                    // store hostage. Every other target is collected, and what
                    // refused is carried to the end of the run and reported.
                    var failures: [StorageRemovalFailure] = []
                    for (declaration, urls) in resolved.targets {
                        for url in urls {
                            do {
                                try removeDeclaredTarget(url, from: declaration)
                            } catch let failure as StorageRemovalFailure {
                                failures.append(failure)
                            }
                        }
                    }
                    let workspaces = try await persistentWorkspaceTargets(
                        matching: orphanedWorkspaceIdentities
                    ).filter { !$0.active }
                    for workspace in workspaces {
                        try await context.runtime.deleteOCIPersistentWorkspace(
                            named: workspace.name)
                    }
                    // Before images, because a container record names an
                    // image and holds it active for as long as it exists.
                    let containers = await reclaimableContainers()
                    for name in containers.selected {
                        try await context.runtime.deleteOCIContainer(named: name)
                    }
                    var images = await reclaimableImages()
                    if !images.selected.isEmpty {
                        try await context.runtime.deleteOCIImages(
                            references: images.selected.map(\.reference))
                    }
                    // Unconditionally, and after any deletion. Content is
                    // orphaned by rebuilding an image, not by pruning one:
                    // every rebuild replaces the reference its layers and
                    // unpacked filesystem belonged to and leaves them reachable
                    // from nothing. A store therefore accumulates collectable
                    // bytes across runs that select no image at all, and gating
                    // collection on a non-empty selection is what let that
                    // accumulation run to the size of the images themselves.
                    if images.unavailable == nil {
                        images.collectedBytes =
                            try await context.runtime.collectOrphanedOCIImageContent()
                    }
                    return (
                        resolved.records,
                        workspaces,
                        images,
                        containers,
                        failures
                    )
                }
            try await registry.remove(reclaimableRuns)
        }
        // A target that refused was not reclaimed, so it does not belong in the
        // record of what this run recovered.
        let failedPaths = Set(removalFailures.map(\.target.string))
        targetRecords.removeAll { failedPaths.contains($0.path) }
        let declaredReclaimableBytes = targetRecords.reduce(UInt64(0)) {
            $0 &+ $1.allocatedBytes
        }
        let workspaceReclaimableBytes = workspaceRecords.reduce(UInt64(0)) {
            $0 &+ $1.allocatedBytes
        }

        // A prune is the other thing that changes a root, so it records what
        // it left behind. Only the roots it touched: measuring the rest would
        // be the walk this record exists to avoid.
        if !dryRun {
            let touched = Set(targetRecords.map(\.id))
            let changed = storageDeclarations.filter { touched.contains($0.id) }
            if !changed.isEmpty,
                let measured = try? await allocationMeasurements(
                    declarations: changed,
                    reclaimableTargets: [:])
            {
                allocationLedger.record(measured.mapValues(\.allocatedBytes))
            }
        }

        let selectedAllocatedBytes =
            runBytes &+ declaredReclaimableBytes &+ workspaceReclaimableBytes
        try emit(
            PruneResult(
                removedRuns: reclaimableRuns.map(\.id.rawValue),
                targets: targetRecords,
                persistentWorkspaces: workspaceRecords,
                persistentWorkspacesUnavailable: workspacesUnavailable,
                appleContainerImages: images.selected,
                appleContainers: containers.selected,
                appleContainersUnavailable: containers.unavailable,
                appleContainerImagesUnavailable: images.unavailable,
                selectedAllocatedBytes: selectedAllocatedBytes,
                recoveredBytes: dryRun ? nil : recoveredBytes(since: availableBefore),
                appleContainerCollectedBytes: images.collectedBytes,
                dryRun: dryRun))
        guard removalFailures.isEmpty else {
            throw StorageRemovalFailures(failures: removalFailures)
        }
    }

    private func validateStorageDeclarations() throws {
        try StorageCatalog.validate(
            storageDeclarations,
            forbiddenRemovalRoots: [
                FilePath("/"), context.root,
                context.cacheRoot, context.hostBuildRoot,
                context.artifactRoot, context.logRoot,
                FilePath(FileManager.default.homeDirectoryForCurrentUser),
            ])
        try StorageCatalog.validateProducers(storageDeclarations, tasks: catalog.tasks)
        try validateImageFamilies()
        _ = try persistentWorkspaceUsage()
    }

    private func retainedRunCount() -> Int {
        for declaration in storageDeclarations where declaration.storageClass == .runRecord {
            if case .boundedHistory(let maximumEntries) = declaration.retentionPolicy {
                return Int(maximumEntries)
            }
        }
        return 0
    }

    private func unknownOwnedPaths() -> [String] {
        let declaredRoots = storageDeclarations.map { $0.root.normalizedForComparison() }
        let ownershipRoots = Set([
            context.cacheRoot.normalizedForComparison(),
            context.hostBuildRoot.normalizedForComparison(),
            context.artifactRoot.normalizedForComparison(),
            context.logRoot.normalizedForComparison(),
        ])
        var unknown = Set<String>()
        for root in ownershipRoots {
            guard
                let children = try? FileManager.default.contentsOfDirectory(
                    at: URL(fileURLWithPath: root.string),
                    includingPropertiesForKeys: nil,
                    options: [])
            else { continue }
            for childURL in children {
                let child = FilePath(childURL.path).normalizedForComparison()
                let belongsToDeclaration = declaredRoots.contains {
                    child.overlaps($0)
                }
                if !belongsToDeclaration { unknown.insert(child.string) }
            }
        }
        return unknown.sorted()
    }

    private func validateImageFamilies() throws {
        var rollbackCounts: [String: UInt32] = [:]
        for preparation in catalog.imagePreparations {
            let repository = preparation.imageName
            guard repository.hasPrefix("localhost/"),
                !repository.contains(where: { $0.isWhitespace || $0 == "@" }),
                !repository.dropFirst("localhost/".count).contains(":")
            else {
                throw WorkspaceFailure.message(
                    "Collider-owned image family must use an untagged localhost repository: \(repository)"
                )
            }
            if let existing = rollbackCounts[repository],
                existing != preparation.rollbackGenerationCount
            {
                throw WorkspaceFailure.message(
                    "Collider-owned image family has conflicting rollback retention: \(repository)"
                )
            }
            rollbackCounts[repository] = preparation.rollbackGenerationCount
        }
    }

    /// The image a maintenance container runs. Any first-party Linux image
    /// carries the tool, and one is present on every host that has built, so
    /// reclamation introduces no pinned input of its own. A host that has never
    /// built has nothing to reclaim.
    static let reclamationImageRepositories = [
        "localhost/nucleus-linux-build-dependencies",
        "localhost/nucleus-apt-resolver",
    ]

    func reclaim(dryRun: Bool) async throws {
        try validateStorageDeclarations()
        let declared = try persistentWorkspaceUsage()
        // Read from the store. A preview must be available to whoever asks,
        // and the reclamation itself is what needs the service.
        let present = try await context.runtime.storedOCIPersistentWorkspaces()
        let allocationBefore = Dictionary(
            present.map { ($0.identity, $0.allocatedBytes) },
            uniquingKeysWith: { first, _ in first })
        let selected = present.compactMap { state in
            declared[state.identity].map { ($0.declaration, state) }
        }
        guard !selected.isEmpty else {
            try context.console.human("cache reclaim: no declared workspace is present")
            return
        }
        if dryRun {
            try emit(
                ReclaimResult(
                    workspaces: selected.map {
                        ReclaimedWorkspaceRecord(
                            key: $0.0.identity.key,
                            allocatedBeforeBytes: $0.1.allocatedBytes,
                            allocatedAfterBytes: $0.1.allocatedBytes)
                    },
                    reclaimedBytes: 0,
                    dryRun: true))
            return
        }
        let images = try await context.runtime.storedOCIImages()
        guard
            let image = Self.reclamationImageRepositories.lazy.compactMap({ repository in
                images.first { $0.repository == repository }
            }).first
        else {
            throw WorkspaceFailure.message(
                "no first-party Linux image is present to run workspace reclamation; "
                    + "run a build or bootstrap first")
        }
        let phase = try await context.hostPhases.begin(
            "reclaiming workspace allocation",
            totalItems: selected.count)
        do {
            for (index, entry) in selected.enumerated() {
                try Task.checkCancellation()
                try await context.runtime.reclaimOCIPersistentWorkspace(
                    entry.0,
                    imageReference: image.reference)
                try await context.hostPhases.advance(
                    phase,
                    completedItems: index + 1,
                    totalItems: selected.count)
            }
            try await context.hostPhases.finish(phase)
        } catch {
            try? await context.hostPhases.fail(phase)
            throw error
        }
        let after = try await context.runtime.storedOCIPersistentWorkspaces()
        var records: [ReclaimedWorkspaceRecord] = []
        var reclaimed: UInt64 = 0
        for state in after {
            guard let before = allocationBefore[state.identity] else { continue }
            guard declared[state.identity] != nil else { continue }
            records.append(
                ReclaimedWorkspaceRecord(
                    key: state.identity.key,
                    allocatedBeforeBytes: before,
                    allocatedAfterBytes: state.allocatedBytes))
            if before > state.allocatedBytes { reclaimed &+= before - state.allocatedBytes }
        }
        records.sort { $0.key < $1.key }
        try emit(
            ReclaimResult(workspaces: records, reclaimedBytes: reclaimed, dryRun: false))
    }

    private func emit(_ result: ReclaimResult) throws {
        var lines = [
            result.dryRun
                ? "cache reclaim: would trim \(result.workspaces.count) workspace(s)"
                : "cache reclaim: trimmed \(result.workspaces.count) workspace(s), "
                    + "\(formatted(result.reclaimedBytes)) returned to the host"
        ]
        for workspace in result.workspaces
        where workspace.allocatedBeforeBytes > workspace.allocatedAfterBytes {
            lines.append(
                "  \(workspace.key): \(formatted(workspace.allocatedBeforeBytes)) -> "
                    + formatted(workspace.allocatedAfterBytes))
        }
        try context.console.report(result, text: lines.joined(separator: "\n"))
    }

    private func persistentWorkspaceUsage() throws -> [PersistentWorkspaceIdentity:
        PersistentWorkspaceUsage]
    {
        var usage: [PersistentWorkspaceIdentity: PersistentWorkspaceUsage] = [:]
        for component in catalog.components {
            for workspace in component.persistentWorkspaces {
                if var existing = usage[workspace.identity] {
                    guard existing.declaration == workspace else {
                        throw WorkspaceFailure.message(
                            "persistent workspace '\(workspaceLabel(workspace.identity))' has conflicting declarations"
                        )
                    }
                    existing.consumers.insert(component.descriptor.id)
                    usage[workspace.identity] = existing
                } else {
                    usage[workspace.identity] = PersistentWorkspaceUsage(
                        declaration: workspace,
                        consumers: [component.descriptor.id])
                }
            }
        }
        return usage
    }

    /// Bring every identity-context root within its declared count.
    ///
    /// A context costs gigabytes and every identity-changing edit mints
    /// another, so a root left to an explicit prune grows for as long as nobody
    /// runs one. This is that bound, applied where planning has already
    /// resolved both halves of the answer: which contexts a current identity
    /// reaches, and how many of the rest a declaration keeps.
    ///
    /// Reachability outranks the count. A context a planned task will read is
    /// never a candidate however old it is, so the bound only ever applies to
    /// contexts nothing in this run can reach.
    ///
    /// A refusal here is not a build failure. The context stays, the run
    /// proceeds, and an explicit prune is where a caller asks to be told.
    func boundIdentityContexts() throws {
        for declaration in storageDeclarations {
            guard
                case .taskIdentityContexts(let location, let retaining) =
                    declaration.retentionPolicy
            else { continue }
            let unreachable = try obsoleteTaskIdentityContexts(
                in: declaration, at: location)
            guard unreachable.count > Int(retaining) else { continue }
            for url in unreachable.sorted(by: newestFirst).dropFirst(Int(retaining)) {
                try? removeDeclaredTarget(url, from: declaration)
            }
        }
    }

    private func pruneTargets(
        for declaration: StorageDeclaration
    ) throws -> [URL] {
        // An explicit prune collects every unreachable context. The retained
        // count bounds what a run leaves behind, not what an operator asking
        // for collection gets.
        if case .taskIdentityContexts(let location, _) = declaration.retentionPolicy {
            return try obsoleteTaskIdentityContexts(in: declaration, at: location)
        }
        if case .boundedHistory(let maximumEntries) = declaration.retentionPolicy {
            guard declaration.storageClass != .runRecord else { return [] }
            return try obsoleteHistoryEntries(
                in: declaration,
                keeping: Int(maximumEntries))
        }
        guard declaration.storageClass == .generation,
            let activeLink = declaration.activeGenerationLink
        else {
            throw StorageCatalogFailure.invalid(
                "explicit prune requires generation storage with active-link retention: "
                    + declaration.id)
        }
        guard case .keepActiveAndRollback(let rollbackCount) = declaration.retentionPolicy else {
            throw StorageCatalogFailure.invalid(
                "generation pruning requires generation retention: \(declaration.id)")
        }
        guard let generationNaming = declaration.generationNaming else {
            throw StorageCatalogFailure.invalid(
                "generation pruning requires a naming contract: \(declaration.id)")
        }
        let root = URL(fileURLWithPath: declaration.root.string, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let activeName = try activeGenerationName(link: activeLink)
        let entries = try realDirectories(in: root)
        let generations = try matching(entries, pattern: generationNaming)
            .filter { $0.lastPathComponent != activeName }
            .sorted(by: newestFirst)
        var targets = Array(generations.dropFirst(Int(rollbackCount)))
        if let naming = declaration.interruptedCandidateNaming {
            targets += try matching(entries, pattern: naming)
        }
        return targets.sorted { $0.path < $1.path }
    }

    private func obsoleteHistoryEntries(
        in declaration: StorageDeclaration,
        keeping retainedEntryCount: Int
    ) throws -> [URL] {
        let root = URL(fileURLWithPath: declaration.root.string, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [
                .isSymbolicLinkKey, .contentModificationDateKey,
            ]
        )
        .filter { url in
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
            return values?.isSymbolicLink != true
        }
        .sorted(by: newestFirst)
        return Array(entries.dropFirst(retainedEntryCount))
            .sorted { $0.path < $1.path }
    }

    private func obsoleteTaskIdentityContexts(
        in declaration: StorageDeclaration,
        at location: ContextLocation
    ) throws -> [URL] {
        let root = resolvedFilesystemPath(declaration.root)
        let rootURL = URL(fileURLWithPath: root.string, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.string) else { return [] }

        let active = Set(
            catalog.tasks.flatMap { task in
                (task.swiftProducts.map(\.invocation) + task.swiftTests.map(\.invocation))
                    .map { resolvedFilesystemPath($0.scratchPath) }
                    .filter { $0.isContained(in: root) }
            })
        var enclosing = [rootURL]
        for _ in 0..<location.intermediateLevels {
            enclosing = try enclosing.flatMap { try realDirectories(in: $0) }
        }
        let candidates = try enclosing.flatMap {
            try matching(realDirectories(in: $0), pattern: location.naming)
        }
        if candidates.isEmpty {
            try requireNoContextsOutside(location, under: rootURL, of: declaration)
        }
        return candidates.filter {
            !active.contains(resolvedFilesystemPath(FilePath($0.path)))
        }.sorted { $0.path < $1.path }
    }

    /// A declaration whose contexts sit at a depth it does not name collects
    /// nothing and says so as though the root were clean, which is how one such
    /// root reached 156 GiB. An empty result is only trustworthy when the root
    /// really holds no contexts, so prove that before returning it.
    private func requireNoContextsOutside(
        _ location: ContextLocation,
        under rootURL: URL,
        of declaration: StorageDeclaration
    ) throws {
        var frontier = [rootURL]
        var depth: UInt32 = 0
        while !frontier.isEmpty, depth <= location.intermediateLevels + 2 {
            let found = try frontier.flatMap {
                try matching(realDirectories(in: $0), pattern: location.naming)
            }
            if let example = found.first, depth != location.intermediateLevels {
                throw StorageCatalogFailure.invalid(
                    "\(declaration.id) declares its contexts beneath "
                        + "\(location.intermediateLevels) intermediate level(s) of "
                        + "\(declaration.root), but one sits beneath \(depth): "
                        + example.path)
            }
            frontier = try frontier.flatMap { try realDirectories(in: $0) }
            depth += 1
        }
    }

    private func resolvedPruneTargets(
        _ declarations: [StorageDeclaration]
    ) throws -> (
        targets: [(StorageDeclaration, [URL])],
        records: [StorageRemovalTarget]
    ) {
        var targets: [(StorageDeclaration, [URL])] = []
        var records: [StorageRemovalTarget] = []
        for declaration in declarations {
            let urls = try pruneTargets(for: declaration)
            targets.append((declaration, urls))
            for url in urls {
                records.append(
                    StorageRemovalTarget(
                        id: declaration.id,
                        path: url.path,
                        allocatedBytes: try allocatedSize(url)))
            }
        }
        records.sort { $0.path < $1.path }
        return (targets, records)
    }

    private func activeGenerationName(link: FilePath) throws -> String? {
        let linkURL = URL(fileURLWithPath: link.string)
        guard let values = try? linkURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
            values.isSymbolicLink == true
        else { return nil }
        let destination = try FileManager.default.destinationOfSymbolicLink(
            atPath: link.string)
        return URL(
            fileURLWithPath: destination,
            relativeTo: linkURL.deletingLastPathComponent()
        ).standardizedFileURL.lastPathComponent
    }

    private func realDirectories(in root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey,
            ]
        ).filter { url in
            guard
                let values = try? url.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
    }

    private func matching(
        _ entries: [URL],
        pattern: DirectoryNamePattern
    ) throws -> [URL] {
        let expression = try NSRegularExpression(pattern: pattern.rawValue)
        return entries.filter { url in
            let name = url.lastPathComponent
            return expression.firstMatch(
                in: name,
                range: NSRange(name.startIndex..., in: name)) != nil
        }
    }

    private func newestFirst(_ left: URL, _ right: URL) -> Bool {
        let leftDate = try? left.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        let rightDate = try? right.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        if leftDate == rightDate { return left.path < right.path }
        return (leftDate ?? .distantPast) > (rightDate ?? .distantPast)
    }

    private func removeDeclaredRoot(_ declaration: StorageDeclaration) throws {
        let root = declaration.root.normalizedForComparison()
        let safetyRoot = declaration.safetyRoot.normalizedForComparison()
        guard root != safetyRoot, root.isContained(in: safetyRoot) else {
            throw StorageCatalogFailure.invalid(
                "refusing to clean unsafe storage root: \(declaration.id)")
        }
        guard FileManager.default.fileExists(atPath: root.string) else { return }
        try FileManager.default.removeItem(atPath: root.string)
    }

    private func removeDeclaredTarget(
        _ target: URL,
        from declaration: StorageDeclaration
    ) throws {
        let root = resolvedFilesystemPath(declaration.root)
        let path = resolvedFilesystemPath(FilePath(target.path))
        guard path != root, path.isContained(in: root) else {
            throw StorageCatalogFailure.invalid(
                "refusing to prune outside declared storage: \(declaration.id), \(path)")
        }
        do {
            try FileManager.default.removeItem(atPath: path.string)
        } catch {
            // The fast path failed. Descend to learn which entry refuses and
            // why, and take the tree down as far as it will go on the way.
            let offending = firstUnremovableDescendant(of: path)
            if offending == nil,
                (try? FileManager.default.removeItem(atPath: path.string)) != nil
            {
                return
            }
            throw StorageRemovalFailure(
                declaration: declaration.id,
                target: path,
                offendingPath: offending?.path ?? path,
                underlying: offending?.error ?? error)
        }
    }

    /// The path a removal actually refused, found by removing the tree entry by
    /// entry rather than by predicting which entry would refuse.
    ///
    /// `FileManager` reports the item the caller named, so a tree of thousands
    /// of entries yields one error naming its root and nothing about which
    /// descendant refused. Inspecting modes to guess the culprit answers a
    /// different question than the kernel does -- it found nothing on a tree
    /// that reliably refuses -- so this descends and reports the entry whose
    /// own removal failed, with the error that removal returned.
    ///
    /// Deepest first, so a directory is only reached once its contents are
    /// gone. Entries removed before the failure stay removed: the whole tree
    /// was already selected for collection.
    private func firstUnremovableDescendant(
        of path: FilePath
    ) -> (path: FilePath, error: any Error)? {
        let manager = FileManager.default
        guard
            let walker = manager.enumerator(
                at: URL(fileURLWithPath: path.string),
                includingPropertiesForKeys: nil)
        else { return nil }
        let entries = (walker.allObjects.compactMap { $0 as? URL })
            .sorted { $0.pathComponents.count > $1.pathComponents.count }
        var first: (path: FilePath, error: any Error)?
        var refused = 0
        for entry in entries {
            do {
                try manager.removeItem(at: entry)
            } catch {
                // Keep going. Stopping at the first refusal leaves everything
                // that would have gone, and reports one path when the useful
                // fact is how many refuse and whether they share a shape.
                refused += 1
                if first == nil { first = (FilePath(entry.path), error) }
            }
        }
        if let first, refused > 1 {
            return (
                first.path,
                StorageCatalogFailure.invalid(
                    "\(refused) entries refused; first: \(first.path): \(first.error)")
            )
        }
        // Every descendant went; the target itself is what refuses.
        return first
    }

    private func resolvedFilesystemPath(_ path: FilePath) -> FilePath {
        FilePath(
            URL(fileURLWithPath: path.string)
                .resolvingSymlinksInPath().path
        ).lexicallyNormalized()
    }

    /// Where the measured allocation of each declared root is kept.
    var allocationLedger: StorageAllocationLedger {
        StorageAllocationLedger(root: context.stateRoot)
    }

    private func allocationMeasurements(
        declarations: [StorageDeclaration],
        reclaimableTargets: [String: [URL]]
    ) async throws -> [String: StorageAllocationMeasurement] {
        let declaredRoots = declarations.map {
            $0.root.normalizedForComparison()
        }
        var result: [String: StorageAllocationMeasurement] = [:]
        let sortedDeclarations = declarations.sorted(by: { $0.id < $1.id })
        let phase = try await context.hostPhases.begin(
            "measuring storage allocation",
            totalItems: sortedDeclarations.count)
        do {
            for (index, declaration) in sortedDeclarations.enumerated() {
                try Task.checkCancellation()
                let root = declaration.root.normalizedForComparison()
                let exclusions = declaredRoots.filter {
                    $0 != root && $0.isContained(in: root)
                }
                result[declaration.id] = try allocatedSize(
                    URL(fileURLWithPath: root.string),
                    excluding: exclusions,
                    reclaimableRoots: (reclaimableTargets[declaration.id] ?? []).map {
                        FilePath($0.path).normalizedForComparison()
                    })
                try await context.hostPhases.advance(
                    phase,
                    completedItems: index + 1,
                    totalItems: sortedDeclarations.count)
            }
            try await context.hostPhases.finish(phase)
            return result
        } catch {
            try? await context.hostPhases.fail(phase)
            throw error
        }
    }

    /// Selects the images no declared identity reaches, or says why the store
    /// could not be read.
    ///
    /// The image store answers only in the builder's session, so an inspection
    /// run from the developer account cannot reach it. That is a result worth
    /// reporting rather than an empty selection: a store nothing enumerated
    /// and a store holding nothing collectable are the same output otherwise,
    /// and only one of them means the report is complete.
    /// Container records no execution owns.
    ///
    /// Collider deletes its own container on completion, cancellation, and
    /// failure alike, so a record that is not running belongs to an execution
    /// none of those paths reached. It is not inert: it holds an unpacked root
    /// filesystem, and while it exists it names an image the store must keep.
    /// The runtime's own builder container is excluded, because the runtime
    /// creates it and the next image build expects it.
    private func reclaimableContainers() async -> ContainerPruneOutcome {
        guard context.runtime.hasOCIStoreInspection else {
            return ContainerPruneOutcome(
                unavailable: "no container store is configured")
        }
        do {
            let containers = try await context.runtime.storedOCIContainers()
            return ContainerPruneOutcome(
                selected:
                    containers
                    .filter { !$0.running && !$0.infrastructure }
                    .map(\.name)
                    .sorted())
        } catch {
            return ContainerPruneOutcome(unavailable: "\(error)")
        }
    }

    private func reclaimableImages() async -> ImagePruneOutcome {
        // Asked rather than attempted. Absence is a property of this runtime,
        // not a failure of the store, and reporting it as a caught error made
        // "there is no container backend here" read as a claim that the host
        // could not support one.
        guard context.runtime.hasOCIStoreInspection else {
            return ImagePruneOutcome(
                unavailable: "no container store is configured")
        }
        do {
            let images = try await context.runtime.storedOCIImages()
            let infrastructure =
                try await context.runtime.storedOCIInfrastructureImages()
            return ImagePruneOutcome(
                selected: containerImageRetention(
                    images: images,
                    infrastructure: infrastructure
                ).filter { $0.state == "reclaimable" })
        } catch {
            return ImagePruneOutcome(unavailable: "\(error)")
        }
    }

    /// The base image each declared preparation builds `FROM`.
    ///
    /// A base is reachable and the catalog names it, but it names it in a
    /// Containerfile rather than in a storage declaration, so nothing that
    /// reads declarations alone can see it. Removing one is recoverable only by
    /// a registry pull, which is a host action a container can never perform,
    /// so a base that a preparation still selects is retained like any other
    /// reachable input.
    ///
    /// Matching is by digest. Every first-party Containerfile pins its base by
    /// digest, and a pull stores the result under repository and digest with
    /// the tag dropped, so the tag written in the `FROM` line never appears in
    /// the store and only the digest identifies the same bytes in both places.
    private func declaredBaseImages() -> (repositories: Set<String>, digests: Set<String>) {
        var repositories: Set<String> = []
        var digests: Set<String> = []
        for preparation in catalog.imagePreparations {
            guard
                let contents = try? String(
                    contentsOfFile: preparation.containerFile.string,
                    encoding: .utf8)
            else { continue }
            for line in contents.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("FROM ") else { continue }
                guard
                    let reference = trimmed.dropFirst("FROM ".count)
                        .split(separator: " ").first
                else { continue }
                let parts = reference.split(separator: "@", maxSplits: 1)
                guard let name = parts.first else { continue }
                // A tag may or may not be present, and a registry host may
                // carry a port, so only a colon after the final path separator
                // is a tag separator.
                let repository: Substring
                if let colon = name.lastIndex(of: ":"),
                    !name[colon...].contains(where: { $0 == "/" })
                {
                    repository = name[name.startIndex..<colon]
                } else {
                    repository = name
                }
                repositories.insert(String(repository))
                if parts.count == 2 { digests.insert(String(parts[1])) }
            }
        }
        return (repositories, digests)
    }

    func containerImageRetention(
        images: [OCIImageState],
        infrastructure: OCIInfrastructureImages
    ) -> [OCIImageRetentionRecord] {
        let base = declaredBaseImages()
        var families: [String: OCIImageFamily] = [:]
        for preparation in catalog.imagePreparations {
            var family =
                families[preparation.imageName]
                ?? OCIImageFamily(
                    repository: preparation.imageName,
                    rollbackGenerationCount: preparation.rollbackGenerationCount,
                    activeDigests: [])
            if let digest = activeImageDigest(preparation) {
                family.activeDigests.insert(digest)
            }
            families[preparation.imageName] = family
        }

        var states: [String: String] = [:]
        for image in images {
            guard let family = families[image.repository] else {
                // An image in a repository the catalog or the runtime names, at
                // a version neither selects, is superseded rather than
                // unaccountable. That is what makes the previous runtime
                // version and the previous base collectable while the current
                // ones are never candidates.
                if let current = infrastructure.currentByRepository[image.repository] {
                    states[image.reference] =
                        image.reference == current ? "infrastructure" : "reclaimable"
                } else if base.repositories.contains(image.repository) {
                    states[image.reference] =
                        base.digests.contains(image.digest) ? "base" : "reclaimable"
                } else {
                    states[image.reference] = "unknown"
                }
                continue
            }
            if image.active || image.tag == "latest"
                || image.tag.map({ family.activeDigests.contains(digest(forTag: $0) ?? "") })
                    == true
            {
                states[image.reference] = "active"
            } else if image.tag == nil {
                states[image.reference] = "reclaimable"
            } else if image.tag?.hasPrefix("digest-") != true {
                states[image.reference] = "retained"
            }
        }

        for family in families.values {
            let candidates = images.filter {
                $0.repository == family.repository
                    && states[$0.reference] == nil
                    && $0.tag?.hasPrefix("digest-") == true
            }.sorted {
                if $0.creationDate != $1.creationDate {
                    return ($0.creationDate ?? .distantPast)
                        > ($1.creationDate ?? .distantPast)
                }
                return $0.reference < $1.reference
            }
            for (index, image) in candidates.enumerated() {
                states[image.reference] =
                    index < Int(family.rollbackGenerationCount)
                    ? "retained" : "reclaimable"
            }
        }

        return images.map {
            OCIImageRetentionRecord(
                reference: $0.reference,
                repository: $0.repository,
                digest: $0.digest,
                creationDate: $0.creationDate,
                state: states[$0.reference] ?? "retained")
        }.sorted { $0.reference < $1.reference }
    }

    private func activeImageDigest(_ preparation: OCIImagePreparation) -> String? {
        guard
            let contents = try? String(
                contentsOfFile: preparation.imageID.string,
                encoding: .utf8)
        else { return nil }
        let components = contents.split(whereSeparator: \.isNewline).map(String.init)
        guard components.count == 2,
            components[0] == preparation.imageName,
            components[1].hasPrefix("sha256:"),
            components[1].count == 71,
            components[1].dropFirst("sha256:".count).allSatisfy(\.isHexDigit)
        else { return nil }
        return components[1]
    }

    private func digest(forTag tag: String) -> String? {
        guard tag.hasPrefix("digest-") else { return nil }
        let value = tag.dropFirst("digest-".count)
        guard value.count == 64, value.allSatisfy(\.isHexDigit) else { return nil }
        return "sha256:" + value
    }

    /// An unreachable workspace store is not an empty one. Reclamation is
    /// part of what prune is for, so a failure to enumerate is reported and
    /// the orphan set is withheld rather than silently reported as zero.
    private func containerPersistentWorkspaces() async -> Result<
        [OCIPersistentWorkspaceState], any Error
    > {
        do {
            return .success(try await context.runtime.storedOCIPersistentWorkspaces())
        } catch {
            return .failure(error)
        }
    }

    private func persistentWorkspaceTargets(
        matching identities: Set<PersistentWorkspaceIdentity>
    ) async throws -> [PersistentWorkspaceRemovalTarget] {
        guard !identities.isEmpty else { return [] }
        return try await context.runtime.storedOCIPersistentWorkspaces()
            .filter { identities.contains($0.identity) }
            .map {
                PersistentWorkspaceRemovalTarget(
                    name: $0.name,
                    identity: $0.identity,
                    allocatedBytes: $0.allocatedBytes,
                    active: $0.active)
            }
            .sorted { $0.name < $1.name }
    }

    private func cleanResult(
        component: String,
        targets: [StorageRemovalTarget],
        workspaces: [PersistentWorkspaceRemovalTarget],
        recoveredBytes: UInt64?,
        dryRun: Bool
    ) -> CleanResult {
        CleanResult(
            component: component,
            targets: targets,
            persistentWorkspaces: workspaces,
            selectedAllocatedBytes: targets.reduce(0) { $0 &+ $1.allocatedBytes }
                &+ workspaces.reduce(0) { $0 &+ $1.allocatedBytes },
            recoveredBytes: recoveredBytes,
            dryRun: dryRun)
    }

    private func recoveredBytes(since availableBefore: UInt64?) -> UInt64? {
        guard let availableBefore,
            let availableAfter = hostFilesystemStatus()?.availableBytes
        else { return nil }
        return availableAfter > availableBefore ? availableAfter - availableBefore : 0
    }

    private func storageTotals(
        storage: [StorageStatusRecord],
        measuredDeclaredRoots: Bool,
        appleContainer: RuntimeObservation<OCIRuntimeDiskUsage>,
        persistentWorkspaces: RuntimeObservation<[PersistentWorkspaceStatusRecord]>
    ) -> StorageTotalsRecord {
        let declaredRootBytes: UInt64? =
            measuredDeclaredRoots
            ? storage.reduce(UInt64(0)) { $0 &+ ($1.allocatedBytes ?? 0) }
            : nil
        var workspaces: [PersistentWorkspaceStatusRecord]?
        if case .available(let value) = persistentWorkspaces { workspaces = value }
        var containerStoreBytes: UInt64?
        if case .available(let usage) = appleContainer {
            containerStoreBytes =
                usage.images.sizeInBytes &+ usage.containers.sizeInBytes
        }
        let workspaceAllocated = workspaces.map { workspaces in
            workspaces.reduce(UInt64(0)) { $0 &+ $1.allocatedBytes }
        }
        return StorageTotalsRecord(
            declaredRootBytes: declaredRootBytes,
            workspaceCount: workspaces?.count ?? 0,
            workspaceAllocatedBytes: workspaceAllocated,
            workspaceCapacityBytes: workspaces.map { workspaces in
                workspaces.reduce(UInt64(0)) { $0 &+ $1.capacityBytes }
            },
            workspacesNearCapacity: workspaces?.filter(\.isNearCapacity).count ?? 0,
            containerStoreBytes: containerStoreBytes,
            accountedBytes: (declaredRootBytes ?? 0) &+ (workspaceAllocated ?? 0)
                &+ (containerStoreBytes ?? 0))
    }

    private func storageState(
        declaration: StorageDeclaration,
        exists: Bool,
        hasReclaimableStorage: Bool
    ) -> String {
        if hasReclaimableStorage { return "reclaimable" }
        if let link = declaration.activeGenerationLink,
            FileManager.default.fileExists(atPath: link.string)
        {
            return "active"
        }
        if declaration.retentionPolicy.isProtected { return "protected" }
        return exists ? "reusable" : "missing"
    }

    /// The filesystem holding the storage this report concerns.
    ///
    /// Not the invoking account's home: the storage reported here is the build
    /// store, which on a provisioned host belongs to no home at all. Reporting
    /// the home's filesystem names a volume the reader did not ask about, and
    /// answers with its free space wherever the two differ.
    private func hostFilesystemStatus() -> HostFilesystemStatusRecord? {
        let root = context.cacheRoot
        guard
            let attributes = try? FileManager.default.attributesOfFileSystem(
                forPath: root.string),
            let total = attributes[.systemSize] as? NSNumber,
            let available = attributes[.systemFreeSize] as? NSNumber
        else { return nil }
        return HostFilesystemStatusRecord(
            path: root.string,
            totalBytes: total.uint64Value,
            availableBytes: available.uint64Value)
    }

    private func emit(_ report: StorageStatusReport) throws {
        var lines: [String] = []
        if let filesystem = report.hostFilesystem {
            lines.append(
                "host-filesystem: \(formatted(filesystem.availableBytes)) available / "
                    + "\(formatted(filesystem.totalBytes)) total")
            lines.append("  \(filesystem.path)")
        }
        lines += totalsLines(report.totals)
        for entry in report.storage {
            let allocation =
                entry.allocatedBytes.map(formatted)
                ?? "allocation not measured"
            let reclaimable: String
            if let reclaimableBytes = entry.reclaimableBytes,
                reclaimableBytes > 0
            {
                reclaimable = ", \(formatted(reclaimableBytes)) reclaimable"
            } else if entry.state == "reclaimable",
                entry.reclaimableBytes == nil
            {
                reclaimable = ", reclaimable allocation not measured"
            } else {
                reclaimable = ""
            }
            lines.append(
                "\(entry.id): \(entry.state), \(allocation)\(reclaimable)"
            )
            lines.append(
                "  \(entry.storageClass.rawValue) · \(entry.owner) · \(entry.retentionPolicy.name)"
                    + (entry.residency.map { " · \($0)" } ?? "")
            )
            lines.append("  \(entry.path)")
            lines.append("  \(entry.retentionPolicy.description)")
        }
        switch report.appleContainer {
        case .available(let usage):
            lines.append(
                "apple-container: \(formatted(usage.images.sizeInBytes)) images, "
                    + "\(formatted(usage.containers.sizeInBytes)) containers, "
                    + "\(formatted(usage.images.reclaimable)) runtime-unattached images")
        case .unavailable(let reason):
            lines.append("apple-container: unavailable (\(reason))")
        }
        switch report.appleContainerImages {
        case .available(let images) where !images.isEmpty:
            let counts = Dictionary(
                grouping: images,
                by: \.state
            ).mapValues(\.count)
            lines.append(
                "apple-container-images: \(counts["active", default: 0]) active, "
                    + "\(counts["retained", default: 0]) retained, "
                    + "\(counts["infrastructure", default: 0]) infrastructure, "
                    + "\(counts["base", default: 0]) base, "
                    + "\(counts["reclaimable", default: 0]) reclaimable, "
                    + "\(counts["unknown", default: 0]) unknown")
            for image in images where image.state == "unknown" {
                // An image nothing accounts for is not collected, and is not
                // silently retained either: the catalog failing to explain what
                // the store holds is the finding.
                lines.append("  unknown \(image.reference)")
            }
            for image in images where image.state == "reclaimable" {
                lines.append("  reclaimable \(image.reference)")
            }
        case .available:
            lines.append("apple-container-images: none")
        case .unavailable(let reason):
            lines.append("apple-container-images: unavailable (\(reason))")
        }
        switch report.persistentWorkspaces {
        case .available(let workspaces):
            for workspace in workspaces {
                let warning = workspace.isNearCapacity ? ", capacity warning" : ""
                lines.append(
                    "persistent-workspace:\(workspace.identity.key): \(workspace.state)\(warning), "
                        + "\(formatted(workspace.allocatedBytes)) allocated / "
                        + "\(formatted(workspace.capacityBytes)) logical, "
                        + "\(formatted(workspace.headroomBytes)) headroom")
                let target = workspace.identity.artifactTarget
                lines.append(
                    "  "
                        + (target.map {
                            "\($0.operatingSystem.rawValue)/\($0.architecture.rawValue)"
                        } ?? "any target")
                        + " · "
                        + workspace.identity.role
                        + (workspace.retentionPolicy.map { " · \($0.name)" } ?? "")
                        + (workspace.residency.map { " · \($0)" } ?? ""))
                lines.append("  \(workspace.name)")
            }
        case .unavailable(let reason):
            lines.append("persistent-workspaces: unavailable (\(reason))")
        }
        for path in report.unknownPaths {
            lines.append("unknown: \(path)")
        }
        try context.console.report(report, text: lines.joined(separator: "\n"))
    }

    /// The headline the per-root detail cannot give: what Collider holds in
    /// total, and how that compares to the disk it holds it on.
    private func totalsLines(_ totals: StorageTotalsRecord) -> [String] {
        var components: [String] = []
        if let declared = totals.declaredRootBytes {
            components.append("declared roots \(formatted(declared))")
        }
        if let allocated = totals.workspaceAllocatedBytes {
            let logical =
                totals.workspaceCapacityBytes.map {
                    " of \(formatted($0)) logical"
                } ?? ""
            components.append(
                "\(totals.workspaceCount) workspaces \(formatted(allocated))\(logical)")
        }
        if let store = totals.containerStoreBytes {
            components.append("container store \(formatted(store))")
        }
        // Workspace and container-store figures come from the container
        // service, which one account owns on a host with a build store. Saying
        // the total is partial is the report's job; printing nothing would read
        // as a host holding nothing.
        if totals.workspaceAllocatedBytes == nil {
            components.append("workspaces unavailable without the container service")
        }
        guard !components.isEmpty else { return [] }
        let unmeasured =
            totals.declaredRootBytes == nil
            ? ", declared roots not measured; pass --measure-allocations" : ""
        // A measured zero and an unmeasurable total are different facts, and
        // reporting the second as "0 B" would describe a terabyte-scale host as
        // empty.
        let measuredAnything =
            totals.declaredRootBytes != nil || totals.workspaceAllocatedBytes != nil
            || totals.containerStoreBytes != nil
        let headline =
            measuredAnything
            ? "storage-total: \(formatted(totals.accountedBytes)) accounted\(unmeasured)"
            : "storage-total: nothing measurable from this account\(unmeasured)"
        var lines = [
            headline,
            "  " + components.joined(separator: " · "),
        ]
        if totals.workspacesNearCapacity > 0 {
            lines.append(
                "  \(totals.workspacesNearCapacity) workspace(s) within 20% of declared capacity")
        }
        return lines
    }

    private func emit(_ result: PruneResult) throws {
        let action = result.dryRun ? "would remove" : "removed"
        let workspaceSummary =
            result.persistentWorkspacesUnavailable == nil
            ? "\(result.persistentWorkspaces.count) orphaned workspace(s)"
            : "orphaned workspaces not evaluated"
        let imageSummary =
            result.appleContainerImagesUnavailable == nil
            ? "\(result.appleContainerImages.count) unreachable image(s)"
            : "images not evaluated"
        var lines = [
            "cache prune: \(action) \(result.removedRuns.count) run(s), "
                + "\(result.targets.count) declared storage target(s), "
                + workspaceSummary + ", "
                + imageSummary + ", "
                + "\(formatted(result.selectedAllocatedBytes)) selected allocation"
        ]
        if let reason = result.persistentWorkspacesUnavailable {
            lines.append("  persistent workspaces unavailable: \(reason)")
        }
        if let recoveredBytes = result.recoveredBytes {
            lines.append("  \(formatted(recoveredBytes)) physical space recovered")
        }
        for run in result.removedRuns { lines.append("  run \(run)") }
        for target in result.targets {
            lines.append("  \(target.id): \(target.path)")
        }
        for workspace in result.persistentWorkspaces {
            lines.append(
                "  persistent-workspace:\(workspace.identity.key): \(workspace.name)")
        }
        for image in result.appleContainerImages {
            lines.append("  apple-container-image: \(image.reference)")
        }
        for name in result.appleContainers {
            lines.append("  apple-container: \(name)")
        }
        if let reason = result.appleContainersUnavailable {
            lines.append("  apple-container records unavailable: \(reason)")
        }
        if let reason = result.appleContainerImagesUnavailable {
            lines.append("  apple-container images unavailable: \(reason)")
        } else if let collected = result.appleContainerCollectedBytes {
            // A preview states the size. Reachability over blobs and snapshots
            // is computed from the store, so the question "how much would this
            // return" has an answer before anything is deleted rather than
            // only after.
            lines.append(
                "  \(formatted(collected)) "
                    + (result.dryRun ? "collectable from" : "collected from")
                    + " orphaned image content")
        } else {
            lines.append("  orphaned image content is collected on execution")
        }
        try context.console.report(result, text: lines.joined(separator: "\n"))
    }

    private func emit(_ result: CleanResult) throws {
        let action = result.dryRun ? "would remove" : "removed"
        var lines = [
            "clean \(result.component): \(action) \(result.targets.count) declared root(s), "
                + "\(result.persistentWorkspaces.count) persistent workspace(s), "
                + "\(formatted(result.selectedAllocatedBytes)) selected allocation"
        ]
        if let recoveredBytes = result.recoveredBytes {
            lines.append("  \(formatted(recoveredBytes)) physical space recovered")
        }
        for target in result.targets {
            lines.append("  \(target.id): \(target.path)")
        }
        for workspace in result.persistentWorkspaces {
            let active = workspace.active ? " (active)" : ""
            lines.append(
                "  persistent-workspace:\(workspace.identity.key): \(workspace.name)\(active)")
        }
        try context.console.report(result, text: lines.joined(separator: "\n"))
    }
}

private func workspaceLabel(_ identity: PersistentWorkspaceIdentity) -> String {
    guard let target = identity.artifactTarget else {
        return "\(identity.key):any:\(identity.role)"
    }
    let abi = target.abi.map { "-\($0)" } ?? ""
    let api = target.androidAPILevel.map { "-api\($0)" } ?? ""
    return
        "\(identity.key):\(target.operatingSystem.rawValue)-\(target.architecture.rawValue)\(abi)\(api):\(identity.role)"
}

private func allocatedSize(of roots: [URL]) throws -> UInt64 {
    try roots.reduce(into: UInt64(0)) { total, root in
        total &+= try allocatedSize(root)
    }
}

private func allocatedSize(_ root: URL) throws -> UInt64 {
    try allocatedSize(
        root,
        excluding: [],
        reclaimableRoots: []
    ).allocatedBytes
}

private func allocatedSize(
    _ root: URL,
    excluding excludedRoots: [FilePath],
    reclaimableRoots: [FilePath]
) throws -> StorageAllocationMeasurement {
    try Task.checkCancellation()
    guard FileManager.default.fileExists(atPath: root.path) else {
        return StorageAllocationMeasurement(
            allocatedBytes: 0,
            reclaimableBytes: 0)
    }
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileAllocatedSizeKey, .fileSizeKey]
    guard
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in false })
    else {
        return StorageAllocationMeasurement(
            allocatedBytes: 0,
            reclaimableBytes: 0)
    }
    var total: UInt64 = 0
    var reclaimable: UInt64 = 0
    for case let url as URL in enumerator {
        try Task.checkCancellation()
        let path = FilePath(url.path).normalizedForComparison()
        if excludedRoots.contains(path) {
            enumerator.skipDescendants()
            continue
        }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: Set(keys))
        } catch  where isMissingFile(error) {
            continue
        }
        guard values.isRegularFile == true else { continue }
        let bytes = UInt64(values.fileAllocatedSize ?? values.fileSize ?? 0)
        total &+= bytes
        if reclaimableRoots.contains(where: {
            path == $0 || path.isContained(in: $0)
        }) {
            reclaimable &+= bytes
        }
    }
    return StorageAllocationMeasurement(
        allocatedBytes: total,
        reclaimableBytes: reclaimable)
}

private func isMissingFile(_ error: any Error) -> Bool {
    let error = error as NSError
    return
        (error.domain == NSCocoaErrorDomain
        && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError))
        || (error.domain == NSPOSIXErrorDomain
            && error.code == Int(POSIXErrorCode.ENOENT.rawValue))
}

private func formatted(_ bytes: UInt64) -> String {
    let units = ["B", "KiB", "MiB", "GiB", "TiB"]
    var value = Double(bytes)
    var index = 0
    while value >= 1_024, index < units.count - 1 {
        value /= 1_024
        index += 1
    }
    guard index > 0 else { return "\(bytes) \(units[index])" }
    let tenths = Int((value * 10).rounded())
    return "\(tenths / 10).\(tenths % 10) \(units[index])"
}
