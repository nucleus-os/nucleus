import ColliderCore
import Foundation
import SystemPackage

/// A planning-local memoization layer backed by a durable file metadata index.
/// Mutation is confined to one synchronous planning operation; callers persist
/// the updated index only after planning has produced a complete plan.
package final class PlanningArtifactDigestCache: @unchecked Sendable {
    private struct FileSignature: Codable, Equatable {
        let device: String
        let inode: String
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let statusChangeSeconds: Int64
        let statusChangeNanoseconds: Int64

        init(_ metadata: Stat) {
            device = String(describing: metadata.deviceID.rawValue)
            inode = String(describing: metadata.inode.rawValue)
            size = metadata.size
            modificationSeconds = Int64(metadata.st_mtim.tv_sec)
            modificationNanoseconds = Int64(metadata.st_mtim.tv_nsec)
            statusChangeSeconds = Int64(metadata.st_ctim.tv_sec)
            statusChangeNanoseconds = Int64(metadata.st_ctim.tv_nsec)
        }
    }

    private struct FileEntry: Codable {
        let signature: FileSignature
        let digest: ArtifactDigest
    }

    private struct TreeKey: Hashable {
        let root: FilePath
        let excludedRelativePaths: [String]
    }

    private let persistentFile: FilePath?
    private var files: [String: FileEntry]
    private var trees: [TreeKey: ArtifactDigest] = [:]
    private var persistentStateChanged = false
    private var measurementDepth = 0
    package private(set) var fileMissCount = 0
    package private(set) var treeMissCount = 0
    package private(set) var hashingDurationNanoseconds: UInt64 = 0

    package init(persistentFile: FilePath? = nil) {
        self.persistentFile = persistentFile
        guard let persistentFile,
            let data = try? Data(
                contentsOf: URL(fileURLWithPath: persistentFile.string)),
            let decoded = try? JSONDecoder().decode(
                [String: FileEntry].self,
                from: data)
        else {
            files = [:]
            return
        }
        files = decoded
    }

    package func digest(
        file path: FilePath,
        metadata suppliedMetadata: Stat? = nil
    ) throws -> ArtifactDigest {
        try measured {
            try digestFile(path, metadata: suppliedMetadata)
        }
    }

    private func digestFile(
        _ path: FilePath,
        metadata suppliedMetadata: Stat?
    ) throws -> ArtifactDigest {
        let metadata = try suppliedMetadata ?? path.stat(followTargetSymlink: true)
        let signature = FileSignature(metadata)
        if let entry = files[path.string], entry.signature == signature {
            return entry.digest
        }
        let digest = try ArtifactHasher.digest(file: path)
        files[path.string] = FileEntry(signature: signature, digest: digest)
        persistentStateChanged = true
        fileMissCount += 1
        return digest
    }

    package func digest(
        tree root: FilePath,
        excluding excludedRelativePaths: Set<String> = []
    ) throws -> ArtifactDigest {
        try measured {
            try digestTree(root, excluding: excludedRelativePaths)
        }
    }

    private func digestTree(
        _ root: FilePath,
        excluding excludedRelativePaths: Set<String>
    ) throws -> ArtifactDigest {
        let key = TreeKey(
            root: root,
            excludedRelativePaths: excludedRelativePaths.sorted())
        if let digest = trees[key] {
            return digest
        }
        let digest = try ArtifactHasher.digest(
            tree: root,
            excluding: excludedRelativePaths,
            digestFile: { try self.digest(file: $0, metadata: $1) })
        trees[key] = digest
        treeMissCount += 1
        return digest
    }

    private func measured<Result>(
        _ operation: () throws -> Result
    ) rethrows -> Result {
        let recordsDuration = measurementDepth == 0
        let start = recordsDuration ? ContinuousClock().now : nil
        measurementDepth += 1
        defer {
            measurementDepth -= 1
            if let start {
                hashingDurationNanoseconds &+= elapsedNanoseconds(since: start)
            }
        }
        return try operation()
    }

    package func persist() throws {
        guard persistentStateChanged, let persistentFile else { return }
        try DurableFile.writeJSON(files, to: persistentFile)
        persistentStateChanged = false
    }
}

private func elapsedNanoseconds(
    since start: ContinuousClock.Instant
) -> UInt64 {
    let components = start.duration(to: ContinuousClock().now).components
    let seconds = UInt64(max(0, components.seconds))
    let nanoseconds = UInt64(max(0, components.attoseconds / 1_000_000_000))
    return seconds &* 1_000_000_000 &+ nanoseconds
}
