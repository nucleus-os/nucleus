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

    static func digest(
        tree root: FilePath,
        excluding excludedRelativePaths: Set<String> = [],
        digestFile: (FilePath, Stat) throws -> ArtifactDigest
    ) throws -> ArtifactDigest {
        let rootURL = URL(fileURLWithPath: root.string, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in false })
        else {
            throw CocoaError(.fileReadUnknown)
        }
        let entries = enumerator.compactMap { $0 as? URL }.filter {
            !excludedRelativePaths.contains(relativePath($0, root: rootURL))
        }.sorted {
            relativePath($0, root: rootURL).utf8.lexicographicallyPrecedes(
                relativePath($1, root: rootURL).utf8)
        }
        var treeHasher = SHA256()

        for entry in entries {
            let relative = relativePath(entry, root: rootURL)
            let path = FilePath(entry.path)
            let metadata = try path.stat(followTargetSymlink: false)
            var framing = CanonicalDigestEncoder()
            framing.append(tag: 1, string: relative)
            framing.append(tag: 2, integer: metadata.permissions.contains(.ownerExecute) ? 1 : 0)
            if metadata.type == .regular {
                framing.append(tag: 3, string: "file")
                framing.append(
                    tag: 4,
                    bytes: try digestFile(path, metadata).bytes)
            } else if metadata.type == .directory {
                framing.append(tag: 3, string: "directory")
            } else if metadata.type == .symbolicLink {
                framing.append(tag: 3, string: "symlink")
                framing.append(
                    tag: 4,
                    string: try FileManager.default.destinationOfSymbolicLink(
                        atPath: entry.path))
            } else {
                framing.append(tag: 3, string: "other:\(metadata.type.rawValue)")
            }
            treeHasher.update(data: framing.bytes)
        }
        return ArtifactDigest(bytes: Array(treeHasher.finalize()))
    }
}

private func relativePath(_ url: URL, root: URL) -> String {
    String(url.path.dropFirst(root.path.count + (root.path.hasSuffix("/") ? 0 : 1)))
}
