import ColliderCore
import Crypto
import Foundation
import SystemPackage

public enum ArtifactHasher {
    public static func digest(bytes: some DataProtocol) -> ArtifactDigest {
        ArtifactDigest(bytes: Array(SHA256.hash(data: bytes)))
    }

    public static func digest(file path: FilePath) throws -> ArtifactDigest {
        let descriptor = try FileDescriptor.open(path, .readOnly)
        defer { try? descriptor.close() }
        var hasher = SHA256()
        var storage = [UInt8](repeating: 0, count: 256 * 1_024)
        while true {
            let count = try storage.withUnsafeMutableBytes {
                try unsafe descriptor.read(into: $0)
            }
            if count == 0 { break }
            hasher.update(data: storage[..<count])
        }
        return ArtifactDigest(bytes: Array(hasher.finalize()))
    }

    public static func digest(
        tree root: FilePath,
        excluding excludedRelativePaths: Set<String> = []
    ) throws -> ArtifactDigest {
        try digest(
            tree: root,
            excluding: excludedRelativePaths,
            digestFile: { path, _ in try digest(file: path) })
    }

    package static func digest(
        tree root: FilePath,
        excluding excludedRelativePaths: Set<String> = [],
        digestFile: (FilePath, Stat) throws -> ArtifactDigest
    ) throws -> ArtifactDigest {
        guard let enumerator = FileManager.default.enumerator(atPath: root.string) else {
            throw CocoaError(.fileReadUnknown)
        }
        let entries = enumerator.compactMap { $0 as? String }
            .filter { !excludedRelativePaths.contains($0) }
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        var framing = IdentityEncoder()
        try framing.appendSequence(entries) { entry, relative in
            let path = root.appending(relative)
            let metadata = try path.stat(followTargetSymlink: false)
            entry.append(relative)
            entry.append(metadata.permissions.contains(.ownerExecute))
            if metadata.type == .regular {
                entry.append("file")
                entry.append(bytes: try digestFile(path, metadata).bytes)
            } else if metadata.type == .directory {
                entry.append("directory")
            } else if metadata.type == .symbolicLink {
                entry.append("symlink")
                entry.append(
                    try FileManager.default.destinationOfSymbolicLink(
                        atPath: path.string))
            } else {
                entry.append("other:\(metadata.type.rawValue)")
            }
        }
        return digest(bytes: framing.bytes)
    }
}
