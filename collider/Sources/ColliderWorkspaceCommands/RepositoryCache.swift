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
    let cleanupPolicy: StorageCleanupPolicy
    let state: String
    let retention: String
    let rollbackGenerationCount: UInt32?
    let quotaBytes: UInt64?
    let reserveBytes: UInt64?
}

private struct StorageStatusReport: Codable {
    let storage: [StorageStatusRecord]
    let appleContainer: OCIRuntimeDiskUsage?
    let persistentWorkspaces: [PersistentWorkspaceStatusRecord]
}

private struct PersistentWorkspaceStatusRecord: Codable {
    let name: String
    let identity: PersistentWorkspaceIdentity
    let capacityBytes: UInt64
    let allocatedBytes: UInt64
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
    let reclaimedBytes: UInt64
    let dryRun: Bool
}

struct PruneResult: Codable, Equatable, Sendable {
    let removedRuns: [String]
    let targets: [StorageRemovalTarget]
    let persistentWorkspaces: [PersistentWorkspaceRemovalTarget]
    let reclaimedBytes: UInt64
    let appleContainerImagesPruned: Bool
    let appleContainerReclaimableBytes: UInt64
    let dryRun: Bool
}

struct RepositoryCache {
    let context: WorkspaceContext
    let catalog: ComponentCatalog

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
            .filter { $0.cleanupPolicy == .explicitClean }
            .sorted { $0.id < $1.id }
        let workspaceUsage = try persistentWorkspaceUsage()
        let workspaceDeclarations = component.persistentWorkspaces.filter {
            workspaceUsage[$0.identity]?.consumers == Set([component.descriptor.id])
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
                    stateRoot: context.layout.tasks))
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
                    dryRun: true))
            return
        }
        let workspaces = try await context.runtime.withTaskLocks(
            locks,
            stateRoot: context.layout.tasks,
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
                dryRun: false))
    }

    func status(measureAllocations: Bool = false) async throws {
        try validateStorageDeclarations()
        let declarations = storageDeclarations
        let reclaimableRuns = await RunRegistry(root: context.layout.state)
            .reclaimableRuns(keeping: RunRegistry.defaultRetainedRunCount)
        var reclaimableTargets: [String: [URL]] = [:]
        for declaration in declarations {
            if declaration.storageClass == .runRecord {
                reclaimableTargets[declaration.id] = reclaimableRuns.map {
                    URL(fileURLWithPath: $0.directory.string)
                }
            } else if declaration.cleanupPolicy == .explicitPrune {
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
        let ociUsage = try await containerDiskUsage()
        let declaredWorkspaceIdentities = Set(
            catalog.components.flatMap(\.persistentWorkspaces).map(\.identity))
        let persistentWorkspaces = await containerPersistentWorkspaces().map { workspace in
            PersistentWorkspaceStatusRecord(
                name: workspace.name,
                identity: workspace.identity,
                capacityBytes: workspace.capacityBytes,
                allocatedBytes: workspace.allocatedBytes,
                state: workspace.active
                    ? "active"
                    : declaredWorkspaceIdentities.contains(workspace.identity)
                        ? "retained" : "reclaimable")
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
                cleanupPolicy: declaration.cleanupPolicy,
                state: storageState(
                    declaration: declaration,
                    exists: exists,
                    hasReclaimableStorage: !targets.isEmpty),
                retention: declaration.retention,
                rollbackGenerationCount: declaration.rollbackGenerationCount,
                quotaBytes: nil,
                reserveBytes: nil)
        }
        records.sort { $0.id < $1.id }
        let report = StorageStatusReport(
            storage: records,
            appleContainer: ociUsage,
            persistentWorkspaces: persistentWorkspaces)
        try emit(report)
    }

    func prune(
        keepingRuns keepCount: Int,
        dryRun: Bool
    ) async throws {
        try validateStorageDeclarations()
        let pruneLock: ColliderFileLock? =
            if dryRun {
                nil
            } else {
                try ColliderFileLock(
                    path: context.layout.locks.appending(
                        "cache-prune.lock"),
                    purpose: "Collider-owned storage pruning",
                    waitForExistingOwner: false)
            }
        defer { withExtendedLifetime(pruneLock) {} }
        let registry = RunRegistry(root: context.layout.state)
        let reclaimableRuns = await registry.reclaimableRuns(keeping: keepCount)
        let runBytes = try reclaimableRuns.reduce(into: UInt64(0)) { total, run in
            total &+= try allocatedSize(URL(fileURLWithPath: run.directory.string))
        }
        let pruneDeclarations =
            storageDeclarations
            .filter { $0.cleanupPolicy == .explicitPrune }
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
        let beforeOCI = try await containerDiskUsage()

        if dryRun {
            targetRecords = try resolvedPruneTargets(pruneDeclarations).records
            workspaceRecords = try await persistentWorkspaceTargets(
                matching: orphanedWorkspaceIdentities)
        } else {
            var locks = Set<TaskLock>()
            for declaration in pruneDeclarations {
                locks.formUnion(try catalog.workflowLocks(for: declaration))
            }
            for identity in orphanedWorkspaceIdentities {
                locks.insert(
                    .persistentWorkspace(
                        identity,
                        stateRoot: context.layout.tasks))
            }
            (targetRecords, workspaceRecords) = try await context.runtime.withTaskLocks(
                locks,
                stateRoot: context.layout.tasks,
                purpose: "declared storage pruning"
            ) {
                let resolved = try resolvedPruneTargets(pruneDeclarations)
                for (_, urls) in resolved.targets {
                    for url in urls {
                        try FileManager.default.removeItem(at: url)
                    }
                }
                let workspaces = try await persistentWorkspaceTargets(
                    matching: orphanedWorkspaceIdentities
                ).filter { !$0.active }
                for workspace in workspaces {
                    try await context.runtime.deleteOCIPersistentWorkspace(
                        named: workspace.name)
                }
                return (resolved.records, workspaces)
            }
            try await registry.remove(reclaimableRuns)
            if beforeOCI != nil {
                try await context.runtime.pruneOCIImages()
            }
        }
        let declaredReclaimableBytes = targetRecords.reduce(UInt64(0)) {
            $0 &+ $1.allocatedBytes
        }
        let workspaceReclaimableBytes = workspaceRecords.reduce(UInt64(0)) {
            $0 &+ $1.allocatedBytes
        }

        let afterOCI = dryRun ? beforeOCI : try await containerDiskUsage()
        let ociReclaimed =
            dryRun
            ? 0
            : max(
                0,
                Int64(beforeOCI?.reclaimableBytes ?? 0)
                    - Int64(afterOCI?.reclaimableBytes ?? 0))
        let reclaimed =
            dryRun
            ? runBytes &+ declaredReclaimableBytes &+ workspaceReclaimableBytes
            : runBytes &+ declaredReclaimableBytes &+ workspaceReclaimableBytes
                &+ UInt64(ociReclaimed)
        try emit(
            PruneResult(
                removedRuns: reclaimableRuns.map(\.id.rawValue),
                targets: targetRecords,
                persistentWorkspaces: workspaceRecords,
                reclaimedBytes: reclaimed,
                appleContainerImagesPruned: !dryRun && beforeOCI != nil,
                appleContainerReclaimableBytes: beforeOCI?.reclaimableBytes ?? 0,
                dryRun: dryRun))
    }

    private func validateStorageDeclarations() throws {
        try StorageCatalog.validate(
            storageDeclarations,
            forbiddenRemovalRoots: [
                FilePath("/"), context.root,
                context.cacheRoot.appending("nucleus"),
                FilePath(FileManager.default.homeDirectoryForCurrentUser),
            ])
        try StorageCatalog.validateProducers(storageDeclarations, tasks: catalog.tasks)
        _ = try persistentWorkspaceUsage()
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
        guard declaration.storageClass == .generation,
            let activeLink = declaration.activeGenerationLink,
            let rollbackCount = declaration.rollbackGenerationCount
        else {
            throw StorageCatalogFailure.invalid(
                "explicit prune requires generation storage with active-link retention: "
                    + declaration.id)
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

    private func containerDiskUsage() async throws -> OCIRuntimeDiskUsage? {
        try? await context.runtime.ociRuntimeDiskUsage()
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
        dryRun: Bool
    ) -> CleanResult {
        CleanResult(
            component: component,
            targets: targets,
            persistentWorkspaces: workspaces,
            reclaimedBytes: targets.reduce(0) { $0 &+ $1.allocatedBytes }
                &+ workspaces.reduce(0) { $0 &+ $1.allocatedBytes },
            dryRun: dryRun)
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
        if declaration.cleanupPolicy == .protected { return "protected" }
        return exists ? "reusable" : "missing"
    }

    private func emit(_ report: StorageStatusReport) throws {
        var lines: [String] = []
        for entry in report.storage {
            let capacity =
                entry.quotaBytes.map {
                    " / \(formatted($0)) quota"
                } ?? ""
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
                "\(entry.id): \(entry.state), \(allocation)\(capacity)\(reclaimable)"
            )
            lines.append(
                "  \(entry.storageClass.rawValue) · \(entry.owner) · \(entry.cleanupPolicy.rawValue)"
            )
            lines.append("  \(entry.path)")
            lines.append("  \(entry.retention)")
        }
        if let usage = report.appleContainer {
            lines.append(
                "apple-container: \(formatted(usage.images.sizeInBytes)) images, "
                    + "\(formatted(usage.containers.sizeInBytes)) containers, "
                    + "\(formatted(usage.reclaimableBytes)) reclaimable")
        }
        for workspace in report.persistentWorkspaces {
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
                    + workspace.identity.role)
            lines.append("  \(workspace.name)")
        }
        try context.console.report(report, text: lines.joined(separator: "\n"))
    }

    private func emit(_ result: PruneResult) throws {
        let action = result.dryRun ? "would remove" : "removed"
        var lines = [
            "cache prune: \(action) \(result.removedRuns.count) run(s), "
                + "\(result.targets.count) declared storage target(s), "
                + "\(result.persistentWorkspaces.count) orphaned workspace(s), "
                + formatted(result.reclaimedBytes)
        ]
        for run in result.removedRuns { lines.append("  run \(run)") }
        for target in result.targets {
            lines.append("  \(target.id): \(target.path)")
        }
        for workspace in result.persistentWorkspaces {
            lines.append(
                "  persistent-workspace:\(workspace.identity.key): \(workspace.name)")
        }
        if result.appleContainerReclaimableBytes > 0 {
            let verb = result.dryRun ? "reports" : "reported before dangling-image pruning"
            lines.append(
                "  Apple Container \(verb) "
                    + "\(formatted(result.appleContainerReclaimableBytes)) reclaimable")
        }
        try context.console.report(result, text: lines.joined(separator: "\n"))
    }

    private func emit(_ result: CleanResult) throws {
        let action = result.dryRun ? "would remove" : "removing"
        var lines = [
            "clean \(result.component): \(action) \(result.targets.count) declared root(s), "
                + "\(result.persistentWorkspaces.count) persistent workspace(s), "
                + formatted(result.reclaimedBytes)
        ]
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
