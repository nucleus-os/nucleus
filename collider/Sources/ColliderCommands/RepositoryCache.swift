import Foundation

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

    func prune(keepingRuns keepCount: Int, dryRun: Bool, json: Bool) throws {
        let runs = context.root.appendingPathComponent(".nucleus/runs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: runs.path) else {
            try emit(PruneResult(removedRuns: [], reclaimedBytes: 0, dryRun: dryRun), json: json)
            return
        }
        let values = try FileManager.default.contentsOfDirectory(
            at: runs,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
            .compactMap { url -> (URL, RepositoryRun)? in
                let manifest = url.appendingPathComponent("manifest.json")
                guard let data = try? Data(contentsOf: manifest),
                      let run = try? JSONDecoder().decode(RepositoryRun.self, from: data)
                else { return nil }
                return (url, run)
            }
            .sorted { $0.1.startedAt > $1.1.startedAt }

        let protectedIDs = Set(values.prefix(keepCount).map { $0.1.runID })
        var removed: [String] = []
        var reclaimed: UInt64 = 0
        for (directory, run) in values {
            guard run.status == "succeeded", !protectedIDs.contains(run.runID) else {
                continue
            }
            reclaimed &+= try allocatedSize(directory)
            removed.append(run.runID)
            if !dryRun { try FileManager.default.removeItem(at: directory) }
        }
        try emit(
            PruneResult(
                removedRuns: removed,
                reclaimedBytes: reclaimed,
                dryRun: dryRun),
            json: json)
    }

    private func ownedRoots() -> [(String, URL)] {
        let cache = cacheRoot()
        return [
            ("checkout-state", context.root.appendingPathComponent(".nucleus")),
            ("downloads", cache.appendingPathComponent("downloads")),
            ("native-sdk", cache.appendingPathComponent("nucleus-native-sdk")),
            ("swift-platforms", cache.appendingPathComponent("swift-platforms")),
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
            print("cache prune: \(action) \(result.removedRuns.count) run(s), \(formatted(result.reclaimedBytes))")
            for run in result.removedRuns { print("  \(run)") }
        }
    }
}

private func allocatedSize(_ root: URL) throws -> UInt64 {
    guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileAllocatedSizeKey, .fileSizeKey]
    guard let enumerator = FileManager.default.enumerator(
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
    return String(format: index == 0 ? "%.0f %@" : "%.1f %@", value, units[index])
}
