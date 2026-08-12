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
    let state: String
}

private struct StorageStatusReport: Codable {
    let hostFilesystem: HostFilesystemStatusRecord?
    let storage: [StorageStatusRecord]
    let appleContainer: RuntimeObservation<OCIRuntimeDiskUsage>
    let appleContainerImages: RuntimeObservation<[OCIImageRetentionRecord]>
    let persistentWorkspaces: RuntimeObservation<[PersistentWorkspaceStatusRecord]>
    let unknownPaths: [String]
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
    let state: String
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
    let appleContainerImages: [OCIImageRetentionRecord]
    let selectedAllocatedBytes: UInt64
    let recoveredBytes: UInt64?
    let appleContainerImageReclaimedBytes: UInt64
    let dryRun: Bool
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

    func clean(
        component selection: String,
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
            .filter { $0.retentionPolicy.allowsExplicitClean }
            .sorted { $0.id < $1.id }
        let workspaceUsage = try persistentWorkspaceUsage()
        let workspaceDeclarations = component.persistentWorkspaces.filter {
            $0.retentionPolicy.allowsExplicitClean
                && workspaceUsage[$0.identity]?.consumers == Set([component.descriptor.id])
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
        let measurements: [String: StorageAllocationMeasurement] =
            if measureAllocations {
                try allocationMeasurements(
                    declarations: declarations,
                    reclaimableTargets: reclaimableTargets)
            } else {
                [:]
            }
        let declaredWorkspaces = try persistentWorkspaceUsage().mapValues(\.declaration)
        async let ociUsage = boundedObservation(
            "Apple Container disk usage",
            timeout: observationTimeout
        ) {
            try await context.runtime.ociRuntimeDiskUsage()
        }
        async let imageRetention = boundedObservation(
            "Apple Container images",
            timeout: observationTimeout
        ) {
            let images = try await context.runtime.ociImages()
            return containerImageRetention(images: images)
        }
        async let persistentWorkspaces = boundedObservation(
            "Apple Container persistent workspaces",
            timeout: observationTimeout
        ) {
            try await context.runtime.ociPersistentWorkspaces().map { workspace in
                let declaration = declaredWorkspaces[workspace.identity]
                return PersistentWorkspaceStatusRecord(
                    name: workspace.name,
                    identity: workspace.identity,
                    capacityBytes: workspace.capacityBytes,
                    allocatedBytes: workspace.allocatedBytes,
                    retentionPolicy: declaration?.retentionPolicy,
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
                state: storageState(
                    declaration: declaration,
                    exists: exists,
                    hasReclaimableStorage: !targets.isEmpty))
        }
        records.sort { $0.id < $1.id }
        let report = StorageStatusReport(
            hostFilesystem: hostFilesystemStatus(),
            storage: records,
            appleContainer: await ociUsage,
            appleContainerImages: await imageRetention,
            persistentWorkspaces: await persistentWorkspaces,
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
        let orphanedWorkspaceIdentities = Set(
            await containerPersistentWorkspaces()
                .filter {
                    !$0.active && !declaredWorkspaceIdentities.contains($0.identity)
                }
                .map(\.identity))
        var targetRecords: [StorageRemovalTarget]
        var workspaceRecords: [PersistentWorkspaceRemovalTarget]
        var selectedImages: [OCIImageRetentionRecord]
        var imageReclaimedBytes: UInt64
        let availableBefore = hostFilesystemStatus()?.availableBytes

        if dryRun {
            targetRecords = try resolvedPruneTargets(pruneDeclarations).records
            workspaceRecords = try await persistentWorkspaceTargets(
                matching: orphanedWorkspaceIdentities)
            if let images = try? await context.runtime.ociImages() {
                selectedImages = containerImageRetention(images: images)
                    .filter { $0.state == "reclaimable" }
            } else {
                selectedImages = []
            }
            imageReclaimedBytes = 0
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
            (targetRecords, workspaceRecords, selectedImages, imageReclaimedBytes) =
                try await context.runtime.withTaskLocks(
                    locks,
                    stateRoot: context.taskStateRoot,
                    purpose: "declared storage pruning"
                ) {
                    let resolved = try resolvedPruneTargets(pruneDeclarations)
                    for (declaration, urls) in resolved.targets {
                        for url in urls {
                            try removeDeclaredTarget(url, from: declaration)
                        }
                    }
                    let workspaces = try await persistentWorkspaceTargets(
                        matching: orphanedWorkspaceIdentities
                    ).filter { !$0.active }
                    for workspace in workspaces {
                        try await context.runtime.deleteOCIPersistentWorkspace(
                            named: workspace.name)
                    }
                    let selectedImages: [OCIImageRetentionRecord]
                    if let images = try? await context.runtime.ociImages() {
                        selectedImages = containerImageRetention(images: images)
                            .filter { $0.state == "reclaimable" }
                    } else {
                        selectedImages = []
                    }
                    let imageReclaimedBytes =
                        if selectedImages.isEmpty {
                            UInt64(0)
                        } else {
                            try await context.runtime.deleteOCIImages(
                                references: selectedImages.map(\.reference))
                        }
                    return (
                        resolved.records,
                        workspaces,
                        selectedImages,
                        imageReclaimedBytes
                    )
                }
            try await registry.remove(reclaimableRuns)
        }
        let declaredReclaimableBytes = targetRecords.reduce(UInt64(0)) {
            $0 &+ $1.allocatedBytes
        }
        let workspaceReclaimableBytes = workspaceRecords.reduce(UInt64(0)) {
            $0 &+ $1.allocatedBytes
        }

        let selectedAllocatedBytes =
            runBytes &+ declaredReclaimableBytes &+ workspaceReclaimableBytes
        try emit(
            PruneResult(
                removedRuns: reclaimableRuns.map(\.id.rawValue),
                targets: targetRecords,
                persistentWorkspaces: workspaceRecords,
                appleContainerImages: selectedImages,
                selectedAllocatedBytes: selectedAllocatedBytes,
                recoveredBytes: dryRun ? nil : recoveredBytes(since: availableBefore),
                appleContainerImageReclaimedBytes: imageReclaimedBytes,
                dryRun: dryRun))
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

    private func pruneTargets(
        for declaration: StorageDeclaration
    ) throws -> [URL] {
        if case .taskIdentityContexts = declaration.retentionPolicy {
            return try obsoleteTaskIdentityContexts(in: declaration)
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
        let root = URL(fileURLWithPath: declaration.root.string, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let activeName = try activeGenerationName(link: activeLink)
        let entries = try realDirectories(in: root)
        let generations = try matching(entries, pattern: .contentIdentity)
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
        in declaration: StorageDeclaration
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
        let firstLevel = try realDirectories(in: rootURL)
        var candidates = try matching(firstLevel, pattern: .artifactDigestDirectory)
        for directory in firstLevel {
            candidates += try matching(
                realDirectories(in: directory),
                pattern: .artifactDigestDirectory)
        }
        return candidates.filter {
            !active.contains(resolvedFilesystemPath(FilePath($0.path)))
        }.sorted { $0.path < $1.path }
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
        try FileManager.default.removeItem(atPath: path.string)
    }

    private func resolvedFilesystemPath(_ path: FilePath) -> FilePath {
        FilePath(
            URL(fileURLWithPath: path.string)
                .resolvingSymlinksInPath().path
        ).lexicallyNormalized()
    }

    private func allocationMeasurements(
        declarations: [StorageDeclaration],
        reclaimableTargets: [String: [URL]]
    ) throws -> [String: StorageAllocationMeasurement] {
        let declaredRoots = declarations.map {
            $0.root.normalizedForComparison()
        }
        var result: [String: StorageAllocationMeasurement] = [:]
        defer { try? context.console.finishProgress() }
        for declaration in declarations.sorted(by: { $0.id < $1.id }) {
            try Task.checkCancellation()
            try context.console.progress(
                "measuring storage allocation: \(declaration.id)")
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
        }
        return result
    }

    func containerImageRetention(
        images: [OCIImageState]
    ) -> [OCIImageRetentionRecord] {
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
                states[image.reference] = "unknown"
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

    private func containerPersistentWorkspaces() async -> [OCIPersistentWorkspaceState] {
        (try? await context.runtime.ociPersistentWorkspaces()) ?? []
    }

    private func persistentWorkspaceTargets(
        matching identities: Set<PersistentWorkspaceIdentity>
    ) async throws -> [PersistentWorkspaceRemovalTarget] {
        guard !identities.isEmpty else { return [] }
        return try await context.runtime.ociPersistentWorkspaces()
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

    private func hostFilesystemStatus() -> HostFilesystemStatusRecord? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard
            let values = try? home.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey,
            ]),
            let total = values.volumeTotalCapacity,
            let available = values.volumeAvailableCapacityForImportantUsage,
            total >= 0,
            available >= 0
        else { return nil }
        return HostFilesystemStatusRecord(
            path: home.path,
            totalBytes: UInt64(total),
            availableBytes: UInt64(available))
    }

    private func emit(_ report: StorageStatusReport) throws {
        var lines: [String] = []
        if let filesystem = report.hostFilesystem {
            lines.append(
                "host-filesystem: \(formatted(filesystem.availableBytes)) available / "
                    + "\(formatted(filesystem.totalBytes)) total")
            lines.append("  \(filesystem.path)")
        }
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
                    + "\(counts["reclaimable", default: 0]) reclaimable, "
                    + "\(counts["unknown", default: 0]) unknown")
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
                let capacityWarning =
                    workspace.capacityBytes > 0
                    && workspace.allocatedBytes
                        >= workspace.capacityBytes - workspace.capacityBytes / 5
                let warning = capacityWarning ? ", capacity warning" : ""
                lines.append(
                    "persistent-workspace:\(workspace.identity.key): \(workspace.state)\(warning), "
                        + "\(formatted(workspace.allocatedBytes)) allocated / "
                        + "\(formatted(workspace.capacityBytes)) logical")
                lines.append(
                    "  \(workspace.identity.artifactTarget.operatingSystem.rawValue)/"
                        + "\(workspace.identity.artifactTarget.architecture.rawValue) · "
                        + workspace.identity.role
                        + (workspace.retentionPolicy.map { " · \($0.name)" } ?? ""))
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

    private func emit(_ result: PruneResult) throws {
        let action = result.dryRun ? "would remove" : "removed"
        var lines = [
            "cache prune: \(action) \(result.removedRuns.count) run(s), "
                + "\(result.targets.count) declared storage target(s), "
                + "\(result.persistentWorkspaces.count) orphaned workspace(s), "
                + "\(formatted(result.selectedAllocatedBytes)) selected allocation"
        ]
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
        if result.appleContainerImageReclaimedBytes > 0 {
            lines.append(
                "  Apple Container reclaimed "
                    + formatted(result.appleContainerImageReclaimedBytes))
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
    let target = identity.artifactTarget
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
