import ColliderCore
import ColliderPersistence
import ColliderRuntime
import Foundation
import SwiftTargetSDKColliderRecipe
import SystemPackage

struct StorageStatusRecord: Codable, Equatable {
    let id: String
    let owner: String
    let storageClass: StorageClass
    let path: String
    let allocatedBytes: UInt64
    let reclaimableBytes: UInt64
    let cleanupPolicy: StorageCleanupPolicy
    let state: String
    let retention: String
    let quotaBytes: UInt64?
    let reserveBytes: UInt64?
}

private struct StorageStatusReport: Codable {
    let storage: [StorageStatusRecord]
    let appleContainer: AppleContainerDiskUsage?
}

private struct PruneResult: Codable {
    let removedRuns: [String]
    let removedSwiftSDKCandidates: [String]
    let removedSwiftSDKGenerations: [String]
    let reclaimedBytes: UInt64
    let appleContainerImagesPruned: Bool
    let appleContainerReclaimableBytes: UInt64
    let dryRun: Bool
}

struct RepositoryCache {
    let context: WorkspaceContext

    func status(json: Bool) async throws {
        let declarations = try storageDeclarations()
        let runs = await runReclamation(keeping: 20)
        let sdkCandidates = try swiftSDKCandidates()
        let sdkGenerations = try inactiveSwiftSDKGenerations()
        let sdkReclaimableBytes = try allocatedSize(of: sdkCandidates + sdkGenerations)
        let apfs = try await apfsVolumes()
        let ociUsage = try await containerDiskUsage()
        let contract = try? MacOSBuilderContract.load(root: context.root)
        var records = try declarations.map { declaration in
            let allocated = try allocatedSize(
                URL(fileURLWithPath: declaration.root.string))
            let reclaimable: UInt64
            switch declaration.id {
            case "run-records": reclaimable = runs.bytes
            case "swift-target-sdk-generations": reclaimable = sdkReclaimableBytes
            default: reclaimable = 0
            }
            return StorageStatusRecord(
                id: declaration.id,
                owner: declaration.owner,
                storageClass: declaration.storageClass,
                path: declaration.root.string,
                allocatedBytes: allocated,
                reclaimableBytes: reclaimable,
                cleanupPolicy: declaration.cleanupPolicy,
                state: storageState(
                    declaration: declaration,
                    allocatedBytes: allocated,
                    reclaimableBytes: reclaimable),
                retention: declaration.retention,
                quotaBytes: nil,
                reserveBytes: nil)
        }
        if let contract {
            records += contract.storage.map { declaration in
                let volume = apfs[declaration.name]
                let reclaimableBytes: UInt64
                if declaration.storageClass == .container {
                    reclaimableBytes = ociUsage?.reclaimableBytes ?? 0
                } else {
                    let mount = URL(fileURLWithPath: declaration.mountPath)
                        .standardizedFileURL.path
                    reclaimableBytes = records.reduce(into: UInt64(0)) {
                        total, record in
                        let path = URL(fileURLWithPath: record.path)
                            .standardizedFileURL.path
                        if path == mount || path.hasPrefix(mount + "/") {
                            total &+= record.reclaimableBytes
                        }
                    }
                }
                return StorageStatusRecord(
                    id: "volume:\(declaration.name)",
                    owner: declaration.owner,
                    storageClass: declaration.storageClass,
                    path: declaration.mountPath,
                    allocatedBytes: volume?.capacityInUse ?? 0,
                    reclaimableBytes: reclaimableBytes,
                    cleanupPolicy: declaration.cleanupPolicy,
                    state: volume == nil
                        ? "missing"
                        : reclaimableBytes > 0 ? "reclaimable" : "mounted",
                    retention: declaration.retention,
                    quotaBytes: declaration.quotaBytes,
                    reserveBytes: declaration.reserveBytes)
            }
        }
        records.sort { $0.id < $1.id }
        let report = StorageStatusReport(
            storage: records,
            appleContainer: ociUsage)
        try emit(report, json: json)
    }

    func prune(
        keepingRuns keepCount: Int,
        dryRun: Bool,
        json: Bool
    ) async throws {
        _ = try storageDeclarations()
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
        var sdkCandidates = try swiftSDKCandidates()
        var sdkGenerations = try inactiveSwiftSDKGenerations()
        var sdkReclaimableBytes = try allocatedSize(of: sdkCandidates + sdkGenerations)
        let beforeOCI = try await containerDiskUsage()

        if !dryRun {
            let paths = SwiftTargetSDKStoragePaths(cacheRoot: context.cacheRoot)
            let sdkLock = try ColliderFileLock(
                path: paths.rebuildLock,
                purpose: "Swift target SDK candidate pruning",
                waitForExistingOwner: false)
            try withExtendedLifetime(sdkLock) {
                sdkCandidates = try swiftSDKCandidates()
                sdkGenerations = try inactiveSwiftSDKGenerations()
                sdkReclaimableBytes = try allocatedSize(of: sdkCandidates + sdkGenerations)
                try DirectoryLifecycle.prune(
                    DirectoryRetentionPlan(
                        safetyRoot: paths.artifactRoot,
                        rules: [
                            DirectoryRetentionRule(
                                root: paths.artifactRoot.appending("generations"),
                                retain: 0,
                                naming: .swiftSDKCandidate),
                            DirectoryRetentionRule(
                                root: paths.artifactRoot.appending("generations"),
                                current: paths.artifactRoot.appending("current"),
                                retain: 0,
                                naming: .contentIdentity),
                        ]))
            }
            try await registry.remove(reclaimableRuns)
            if beforeOCI != nil {
                try await pruneAppleContainerImages()
            }
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
            ? runBytes &+ sdkReclaimableBytes
            : runBytes &+ sdkReclaimableBytes &+ UInt64(ociReclaimed)
        try emit(
            PruneResult(
                removedRuns: reclaimableRuns.map(\.id.rawValue),
                removedSwiftSDKCandidates: sdkCandidates.map(\.lastPathComponent),
                removedSwiftSDKGenerations: sdkGenerations.map(\.lastPathComponent),
                reclaimedBytes: reclaimed,
                appleContainerImagesPruned: !dryRun && beforeOCI != nil,
                appleContainerReclaimableBytes: beforeOCI?.reclaimableBytes ?? 0,
                dryRun: dryRun),
            json: json)
    }

    private func storageDeclarations() throws -> [StorageDeclaration] {
        let root = context.root
        let state = context.layout.state
        let cache = context.cacheRoot.appending("nucleus")
        let sdkPaths = SwiftTargetSDKStoragePaths(cacheRoot: context.cacheRoot)
        let declarations = [
            StorageDeclaration(
                id: "checkout-state",
                owner: "collider-runtime",
                storageClass: .incremental,
                root: state,
                safetyRoot: root,
                cleanupPolicy: .protected,
                retention: "task state and workflow locks remain with the checkout"),
            StorageDeclaration(
                id: "run-records",
                owner: "collider-runtime",
                storageClass: .runRecord,
                root: context.layout.runs,
                safetyRoot: state,
                cleanupPolicy: .explicitPrune,
                workflowLock: context.layout.locks.appending(
                    "cache-prune.lock"),
                retention: "the most recent successful and active run records are retained"),
            StorageDeclaration(
                id: "downloads",
                owner: "collider-downloads",
                storageClass: .download,
                root: cache.appending("downloads"),
                safetyRoot: cache,
                cleanupPolicy: .protected,
                retention:
                    "pinned downloads remain until graph-aware pruning proves them unreferenced"),
            StorageDeclaration(
                id: "native-sdk",
                owner: "native-sdk-publishers",
                storageClass: .published,
                root: context.nativeSDKRoot.removingLastComponent(),
                safetyRoot: context.nativeSDKRoot.removingLastComponent(),
                cleanupPolicy: .protected,
                retention: "validated per-target SDKs remain published"),
            StorageDeclaration(
                id: "swift-target-sdk-generations",
                owner: "swift-target-sdk",
                storageClass: .generation,
                root: sdkPaths.artifactRoot.appending("generations"),
                safetyRoot: sdkPaths.artifactRoot,
                cleanupPolicy: .explicitPrune,
                workflowLock: sdkPaths.rebuildLock,
                activeGenerationLink: sdkPaths.artifactRoot.appending("current"),
                retention:
                    "the active immutable generation is protected; abandoned candidates and inactive generations are prunable"
            ),
            StorageDeclaration(
                id: "swift-platforms",
                owner: "swift-platform-runtime",
                storageClass: .generation,
                root: cache.appending("swift-platforms"),
                safetyRoot: cache,
                cleanupPolicy: .protected,
                retention: "active runtime generations remain until graph-aware retention lands"),
            StorageDeclaration(
                id: "swift-build-workspaces",
                owner: "swift-platform-runtime",
                storageClass: .incremental,
                root: cache.appending("swift-build-workspaces"),
                safetyRoot: cache,
                cleanupPolicy: .explicitClean,
                workflowLock: context.layout.locks.appending(
                    "swift-build-workspaces.lock"),
                retention:
                    "architecture-specific runtime build trees remain reusable until explicit clean"
            ),
            StorageDeclaration(
                id: "builder-metadata",
                owner: "collider-recipes",
                storageClass: .cache,
                root: cache.appending("build-containers"),
                safetyRoot: cache,
                cleanupPolicy: .explicitClean,
                workflowLock: context.layout.locks.appending(
                    "builder-metadata.lock"),
                retention: "builder image identities remain reusable until explicit clean"),
            StorageDeclaration(
                id: "incremental-builds",
                owner: "collider-recipes",
                storageClass: .incremental,
                root: cache.appending("build"),
                safetyRoot: cache,
                cleanupPolicy: .explicitClean,
                workflowLock: context.layout.locks.appending(
                    "incremental-builds.lock"),
                retention: "reused until an explicit component clean"),
            StorageDeclaration(
                id: "compiler-caches",
                owner: "collider-recipes",
                storageClass: .cache,
                root: cache.appending("ccache"),
                safetyRoot: cache,
                cleanupPolicy: .explicitClean,
                workflowLock: context.layout.locks.appending(
                    "compiler-caches.lock"),
                retention: "reused until an explicit component clean"),
            StorageDeclaration(
                id: "host-compiler-cache",
                owner: "collider-recipes",
                storageClass: .cache,
                root: cache.appending("host-ccache"),
                safetyRoot: cache,
                cleanupPolicy: .explicitClean,
                workflowLock: context.layout.locks.appending(
                    "host-compiler-cache.lock"),
                retention: "host compiler results remain reusable until explicit clean"),
            StorageDeclaration(
                id: "android-sdk",
                owner: "android-toolchain",
                storageClass: .published,
                root: FilePath(
                    context.environment["ANDROID_SDK_ROOT"]
                        ?? context.cacheRoot.appending("android-sdk").string),
                safetyRoot: FilePath(
                    context.environment["ANDROID_SDK_ROOT"]
                        ?? context.cacheRoot.appending("android-sdk").string),
                cleanupPolicy: .protected,
                retention: "the pinned Android SDK remains provisioned"),
        ]
        try StorageCatalog.validate(
            declarations,
            forbiddenRemovalRoots: [
                FilePath("/"), root, cache,
                FilePath(FileManager.default.homeDirectoryForCurrentUser),
            ])
        return declarations
    }

    private func swiftSDKCandidates() throws -> [URL] {
        let paths = SwiftTargetSDKStoragePaths(cacheRoot: context.cacheRoot)
        let generations = paths.artifactRoot.appending("generations")
        guard FileManager.default.fileExists(atPath: generations.string) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: generations.string, isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        .filter { url in
            guard isSwiftSDKCandidateName(url.lastPathComponent),
                let values = try? url.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func inactiveSwiftSDKGenerations() throws -> [URL] {
        let paths = SwiftTargetSDKStoragePaths(cacheRoot: context.cacheRoot)
        let generations = paths.artifactRoot.appending("generations")
        guard FileManager.default.fileExists(atPath: generations.string) else { return [] }
        let activeName = try activeSwiftSDKGenerationName(paths: paths)
        let pattern = try NSRegularExpression(pattern: #"^[0-9a-f]{24}$"#)
        return try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: generations.string, isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        .filter { url in
            let name = url.lastPathComponent
            let range = NSRange(name.startIndex..., in: name)
            guard name != activeName,
                pattern.firstMatch(in: name, range: range) != nil,
                let values = try? url.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func activeSwiftSDKGenerationName(
        paths: SwiftTargetSDKStoragePaths
    ) throws -> String? {
        let current = paths.artifactRoot.appending("current")
        let currentURL = URL(fileURLWithPath: current.string)
        guard let values = try? currentURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
            values.isSymbolicLink == true
        else { return nil }
        let destination = try FileManager.default.destinationOfSymbolicLink(
            atPath: current.string)
        return URL(
            fileURLWithPath: destination,
            relativeTo: currentURL.deletingLastPathComponent()
        ).standardizedFileURL.lastPathComponent
    }

    private func runReclamation(keeping count: Int) async -> (
        runs: [RecordedRun], bytes: UInt64
    ) {
        let registry = RunRegistry(root: context.layout.state)
        let runs = await registry.reclaimableRuns(keeping: count)
        let bytes =
            (try? allocatedSize(
                of: runs.map {
                    URL(fileURLWithPath: $0.directory.string)
                })) ?? 0
        return (runs, bytes)
    }

    private func apfsVolumes() async throws -> [String: APFSStorageInventory.Volume] {
        guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/diskutil") else {
            return [:]
        }
        let output = try await context.run(
            "/usr/sbin/diskutil", ["apfs", "list", "-plist"], capture: true)
        return try APFSStorageInventory.decode(output)
    }

    private func containerDiskUsage() async throws -> AppleContainerDiskUsage? {
        try? await appleContainerDiskUsage()
    }

    private func storageState(
        declaration: StorageDeclaration,
        allocatedBytes: UInt64,
        reclaimableBytes: UInt64
    ) -> String {
        if reclaimableBytes > 0 { return "reclaimable" }
        if let link = declaration.activeGenerationLink,
            FileManager.default.fileExists(atPath: link.string)
        {
            return "active"
        }
        if declaration.cleanupPolicy == .protected { return "protected" }
        return allocatedBytes == 0 ? "missing" : "reusable"
    }

    private func emit(_ report: StorageStatusReport, json: Bool) throws {
        if json {
            print(String(decoding: try JSONEncoder.sorted.encode(report), as: UTF8.self))
            return
        }
        for entry in report.storage {
            let capacity =
                entry.quotaBytes.map {
                    " / \(formatted($0)) quota"
                } ?? ""
            let reclaimable =
                entry.reclaimableBytes > 0
                ? ", \(formatted(entry.reclaimableBytes)) reclaimable"
                : ""
            print(
                "\(entry.id): \(entry.state), \(formatted(entry.allocatedBytes))\(capacity)\(reclaimable)"
            )
            print(
                "  \(entry.storageClass.rawValue) · \(entry.owner) · \(entry.cleanupPolicy.rawValue)"
            )
            print("  \(entry.path)")
            print("  \(entry.retention)")
        }
        if let usage = report.appleContainer {
            print(
                "apple-container: \(formatted(usage.images.sizeInBytes)) images, "
                    + "\(formatted(usage.containers.sizeInBytes)) containers, "
                    + "\(formatted(usage.reclaimableBytes)) reclaimable")
        }
    }

    private func emit(_ result: PruneResult, json: Bool) throws {
        if json {
            print(String(decoding: try JSONEncoder.sorted.encode(result), as: UTF8.self))
            return
        }
        let action = result.dryRun ? "would remove" : "removed"
        print(
            "cache prune: \(action) \(result.removedRuns.count) run(s), "
                + "\(result.removedSwiftSDKCandidates.count) abandoned Swift SDK candidate(s), and "
                + "\(result.removedSwiftSDKGenerations.count) inactive Swift SDK generation(s), "
                + formatted(result.reclaimedBytes))
        for run in result.removedRuns { print("  run \(run)") }
        for candidate in result.removedSwiftSDKCandidates {
            print("  Swift SDK candidate \(candidate)")
        }
        for generation in result.removedSwiftSDKGenerations {
            print("  Swift SDK generation: \(generation)")
        }
        if result.appleContainerReclaimableBytes > 0 {
            let verb = result.dryRun ? "reports" : "reported before dangling-image pruning"
            print(
                "  Apple Container \(verb) "
                    + "\(formatted(result.appleContainerReclaimableBytes)) reclaimable")
        }
    }
}

private func isSwiftSDKCandidateName(_ name: String) -> Bool {
    let pattern = #"^\.candidate-[0-9a-f]{24}-[0-9TZ-]+-[0-9]+$"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
        return false
    }
    let range = NSRange(name.startIndex..., in: name)
    return expression.firstMatch(in: name, range: range) != nil
}

private func allocatedSize(of roots: [URL]) throws -> UInt64 {
    try roots.reduce(into: UInt64(0)) { total, root in
        total &+= try allocatedSize(root)
    }
}

private func allocatedSize(_ root: URL) throws -> UInt64 {
    guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileAllocatedSizeKey, .fileSizeKey]
    guard
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in false })
    else { return 0 }
    var total: UInt64 = 0
    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: Set(keys))
        guard values.isRegularFile == true else { continue }
        total &+= UInt64(values.fileAllocatedSize ?? values.fileSize ?? 0)
    }
    return total
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
