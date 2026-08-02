import ColliderRuntime
import Foundation
import SystemPackage

private struct CacheEntry: Codable {
    let name: String
    let path: String
    let bytes: UInt64
}

private struct PruneResult: Codable {
    let removedRuns: [String]
    let reclaimedBytes: UInt64
    let dryRun: Bool
}

struct RepositoryCache {
    let context: WorkspaceContext

    func status(json: Bool) throws {
        let entries = try ownedRoots().map { name, url in
            CacheEntry(name: name, path: url.path, bytes: try allocatedSize(url))
        }
        if json {
            print(String(decoding: try JSONEncoder.sorted.encode(entries), as: UTF8.self))
            return
        }
        for entry in entries {
            print("\(entry.name): \(formatted(entry.bytes))  \(entry.path)")
        }
    }

    /// Reclaim run history down to `keepCount`. The registry owns the retention
    /// policy it applies on every run; this is the same policy on demand, at
    /// whatever depth the caller asks for.
    func prune(keepingRuns keepCount: Int, dryRun: Bool, json: Bool) async throws {
        let registry = RunRegistry(root: FilePath(context.layout.state.path))
        let reclaimable = await registry.reclaimableRuns(keeping: keepCount)
        let reclaimed = try reclaimable.reduce(into: UInt64(0)) { total, run in
            total &+= try allocatedSize(URL(fileURLWithPath: run.directory.string))
        }
        if !dryRun {
            try await registry.remove(reclaimable)
        }
        try emit(
            PruneResult(
                removedRuns: reclaimable.map(\.id.rawValue),
                reclaimedBytes: reclaimed,
                dryRun: dryRun),
            json: json)
    }

    private func ownedRoots() -> [(String, URL)] {
        let cache = cacheRoot()
        return [
            ("checkout-state", context.layout.state),
            ("downloads", cache.appendingPathComponent("downloads")),
            ("native-sdk", cache.appendingPathComponent("nucleus-native-sdk")),
            (
                "swift-target-sdks",
                cache.appendingPathComponent("swift-target-sdks")
            ),
            ("chromium", cache.appendingPathComponent("chromium")),
        ]
    }

    private func cacheRoot() -> URL {
        context.cacheRoot.appendingPathComponent("nucleus")
    }

    private func emit(_ result: PruneResult, json: Bool) throws {
        if json {
            print(String(decoding: try JSONEncoder.sorted.encode(result), as: UTF8.self))
        } else {
            let action = result.dryRun ? "would remove" : "removed"
            print(
                "cache prune: \(action) \(result.removedRuns.count) run(s), \(formatted(result.reclaimedBytes))"
            )
            for run in result.removedRuns { print("  \(run)") }
        }
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
