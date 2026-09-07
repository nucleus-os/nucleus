#if os(macOS)

import ColliderCore
import ContainerizationArchive
import ContainerizationEXT4
import Foundation
import SystemPackage

/// Writes a host directory into a read-only ext4 image.
///
/// The prepared source tree is a pure function of pinned inputs and every
/// consumer reads it without writing to it, which makes it an artifact rather
/// than a workspace. Building the image on the host is what removes the file
/// sharing layer from the path: the host reads its own filesystem natively, so
/// the cost that scales with the number of files served -- the cost that
/// exhausted the machine-wide open file table on 2026-09-01 -- is not paid at
/// all.
///
/// The image is written by `ContainerizationEXT4`, which is already vendored,
/// so this needs neither a mount, nor root, nor an `e2fsprogs` the host does
/// not carry.
public enum SourceTreeImage {
    /// Write `tree` into a new ext4 image at `image`.
    ///
    /// - Parameter identity: The filesystem UUID stamped into the image. A
    ///   formatter would otherwise generate one, which makes two images of
    ///   identical content differ in bytes. A caller addressing images by the
    ///   tree they reproduce should derive this from that address, so that two
    ///   distinct trees never claim one filesystem identity; the default keeps
    ///   a single tree's builds identical, which is what the graph compares.
    /// - Parameter owner: The identity every entry is recorded under.
    ///   An ext4 image records an owner per inode, so a reader that is not
    ///   that owner reads only what the mode grants everyone -- and a checkout
    ///   is not uniformly world readable. The copy this replaces untarred with
    ///   `--no-same-owner`, leaving the tree owned by the builder that
    ///   extracted it, which is why the default is the identity a container
    ///   runs as rather than root: it keeps what a consumer can read a
    ///   property of the tree's modes rather than of the transport. Stated as
    ///   the type an execution states it with, so the two cannot drift apart.
    public static func write(
        tree: FilePath,
        to image: FilePath,
        blockSize: UInt32 = 4096,
        identity: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        owner: OCIUserPolicy = .builder
    ) throws {
        guard try entry(at: tree).type == .typeDirectory else {
            throw SourceTreeImageFailure("source tree is not a directory: \(tree)")
        }
        // Writing the image under the tree makes the walk read the image it is
        // still writing, which grows without bound rather than failing.
        guard !image.starts(with: tree) else {
            throw SourceTreeImageFailure(
                "the image would be written inside the tree it reproduces: \(image)")
        }
        try? FileManager.default.removeItem(atPath: image.string)
        guard FileManager.default.createFile(atPath: image.string, contents: nil)
        else {
            throw SourceTreeImageFailure("could not create the image file: \(image)")
        }
        // Every timestamp is fixed and the filesystem identity is supplied.
        // The image is addressed by its content, and a checkout stamps its own
        // mtimes when it materializes, so preserving them would give two
        // builds of identical content two addresses. One epoch also leaves
        // every source older than every output, which is what a build
        // comparing the two should conclude.
        let epoch = Date(timeIntervalSince1970: 0)
        let formatter = try EXT4.Formatter(
            image,
            blockSize: blockSize,
            reproducibility: EXT4.Formatter.Reproducibility(
                uuid: identity, timestamp: epoch))
        let timestamps = FileTimestamps(
            access: epoch, modification: epoch, creation: epoch, now: epoch)
        // A file with more than one link is one content reachable by several
        // names, and writing it once per name would silently turn one inode
        // into several. The shallowest name holds the inode; the rest link.
        var linkedNames: [UInt64: FilePath] = [:]
        for (source, destination, entry) in try entries(tree: tree) {
            switch entry.type {
            case .typeDirectory:
                try unsafe formatter.create(
                    path: destination,
                    mode: EXT4.Inode.Mode(.S_IFDIR, entry.permissions),
                    ts: timestamps,
                    uid: owner.userID,
                    gid: owner.groupID)
            case .typeSymbolicLink:
                try unsafe formatter.create(
                    path: destination,
                    link: FilePath(
                        try FileManager.default.destinationOfSymbolicLink(
                            atPath: source.string)),
                    mode: EXT4.Inode.Mode(.S_IFLNK, entry.permissions),
                    ts: timestamps,
                    uid: owner.userID,
                    gid: owner.groupID)
            case .typeRegular:
                if entry.linkCount > 1, let target = linkedNames[entry.inode] {
                    try formatter.link(link: destination, target: target)
                    continue
                }
                guard let contents = InputStream(fileAtPath: source.string) else {
                    throw SourceTreeImageFailure("could not read: \(source)")
                }
                contents.open()
                defer { contents.close() }
                try unsafe formatter.create(
                    path: destination,
                    mode: EXT4.Inode.Mode(.S_IFREG, entry.permissions),
                    ts: timestamps,
                    buf: contents,
                    uid: owner.userID,
                    gid: owner.groupID)
                if entry.linkCount > 1 {
                    linkedNames[entry.inode] = destination
                }
            default:
                // Sockets, devices and fifos are not what a prepared source
                // tree is made of, and carrying one silently would make the
                // image disagree with the tree it claims to be.
                throw SourceTreeImageFailure(
                    "source tree holds an entry that is not a file, directory "
                        + "or symbolic link: \(source)")
            }
        }
        try formatter.close()
    }

    private struct Entry {
        let type: FileAttributeType
        let permissions: UInt16
        let inode: UInt64
        let linkCount: UInt64
    }

    /// Every entry under `tree`, shallowest first and sorted within a depth.
    ///
    /// Depth order is what makes the shallowest name for a multiply linked
    /// file the one that holds the inode and every other name a link to it. A
    /// depth-first walk instead lets a buried name hold the inode while a name
    /// beside its directory links to it, which is a valid filesystem and an
    /// archive whose link precedes its target. Sorting within a depth is what
    /// keeps two builds of one tree identical, since the image is going to be
    /// addressed by its content and directory order is a property of the host.
    private static func entries(
        tree: FilePath
    ) throws -> [(source: FilePath, destination: FilePath, entry: Entry)] {
        var collected: [(source: FilePath, destination: FilePath, entry: Entry)] = []
        var frontier = [(tree, FilePath("/"))]
        while !frontier.isEmpty {
            var next: [(FilePath, FilePath)] = []
            for (directory, relative) in frontier {
                for name in try FileManager.default.contentsOfDirectory(
                    atPath: directory.string
                ).sorted() {
                    let source = directory.appending(name)
                    let destination = relative.appending(name)
                    let found = try entry(at: source)
                    collected.append((source, destination, found))
                    if found.type == .typeDirectory {
                        next.append((source, destination))
                    }
                }
            }
            frontier = next
        }
        return collected
    }

    /// Metadata for one path, without following it.
    ///
    /// `attributesOfItem` does not resolve a symbolic link, which is what lets
    /// a link be written as a link rather than as a second copy of whatever it
    /// points at.
    private static func entry(at path: FilePath) throws -> Entry {
        let attributes = try FileManager.default.attributesOfItem(atPath: path.string)
        guard let type = attributes[.type] as? FileAttributeType else {
            throw SourceTreeImageFailure("could not read the type of \(path)")
        }
        return Entry(
            type: type,
            permissions: (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0,
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            linkCount: (attributes[.referenceCount] as? NSNumber)?.uint64Value ?? 1)
    }
}

public struct SourceTreeImageFailure: Error, CustomStringConvertible, Sendable {
    public let description: String

    init(_ description: String) {
        self.description = "source tree image failed: \(description)"
    }
}

#endif
