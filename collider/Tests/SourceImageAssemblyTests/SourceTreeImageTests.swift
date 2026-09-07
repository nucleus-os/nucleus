#if os(macOS)

import ContainerizationArchive
import ContainerizationEXT4
import Foundation
import SourceImageAssembly
import SystemPackage
import Testing

/// The tree the image has to reproduce exactly.
///
/// A prepared Chromium tree carries symbolic links, hard links and executable
/// bits, and an image that loses any of them is not the tree it claims to be
/// however well it builds. The fixture is small but carries one of each,
/// because what is being proven is fidelity rather than scale.
private struct FixtureTree {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "source-image-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("nested/deeper")
        try FileManager.default.createDirectory(
            at: nested, withIntermediateDirectories: true)
        try write("executable", bytes: "#!/bin/sh\nexit 0\n", permissions: 0o755)
        try write("readable", bytes: "plain contents\n", permissions: 0o644)
        try write("nested/deeper/buried", bytes: "buried\n", permissions: 0o600)
        try write("empty", bytes: "", permissions: 0o644)
        // Larger than one 4 KiB block, so the extent path is exercised rather
        // than only the inline one.
        try write(
            "multiblock",
            bytes: String(repeating: "0123456789abcdef", count: 1024),
            permissions: 0o644)
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("relative-link").path,
            withDestinationPath: "nested/deeper/buried")
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("absolute-link").path,
            withDestinationPath: "/usr/bin/env")
        try FileManager.default.linkItem(
            atPath: root.appendingPathComponent("readable").path,
            toPath: root.appendingPathComponent("nested/hardlink").path)
    }

    private func write(_ name: String, bytes: String, permissions: Int) throws {
        let path = root.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: path)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions], ofItemAtPath: path.path)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func attributes(_ path: URL) throws -> [FileAttributeKey: Any] {
    try FileManager.default.attributesOfItem(atPath: path.path)
}

@Test func aSourceTreeImageReproducesTheTreeItWasBuiltFrom() throws {
    let fixture = try FixtureTree()
    defer { fixture.remove() }
    let work = fixture.root.deletingLastPathComponent()
        .appendingPathComponent("work-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    let image = FilePath(work.appendingPathComponent("source.img").path)
    let archive = FilePath(work.appendingPathComponent("source.tar").path)
    let restored = work.appendingPathComponent("restored")
    try FileManager.default.createDirectory(
        at: restored, withIntermediateDirectories: true)

    try SourceTreeImage.write(tree: FilePath(fixture.root.path), to: image)
    try EXT4.EXT4Reader(blockDevice: image).export(archive: archive)
    _ = try ArchiveReader(file: archive.url).extractContents(to: restored)

    for name in [
        "executable", "readable", "empty", "multiblock",
        "nested/deeper/buried",
    ] {
        let original = fixture.root.appendingPathComponent(name)
        let copy = restored.appendingPathComponent(name)
        #expect(
            FileManager.default.contents(atPath: copy.path)
                == FileManager.default.contents(atPath: original.path),
            "contents differ for \(name)")
        let originalMode =
            (try attributes(original)[.posixPermissions] as? NSNumber)?.intValue
        let copyMode =
            (try attributes(copy)[.posixPermissions] as? NSNumber)?.intValue
        #expect(originalMode == copyMode, "permissions differ for \(name)")
    }

    // A link has to arrive as a link. Restoring one as a copy of its target
    // would read as correct on every content comparison and still be a
    // different tree.
    for (name, target) in [
        ("relative-link", "nested/deeper/buried"), ("absolute-link", "/usr/bin/env"),
    ] {
        let copy = restored.appendingPathComponent(name)
        #expect(
            (try attributes(copy)[.type] as? FileAttributeType)
                == .typeSymbolicLink,
            "\(name) is not a symbolic link")
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: copy.path)
                == target)
    }

}

@Test func aSourceTreeImageKeepsOneInodeForTwoNames() throws {
    let fixture = try FixtureTree()
    defer { fixture.remove() }
    let work = fixture.root.deletingLastPathComponent()
        .appendingPathComponent("work-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    let image = FilePath(work.appendingPathComponent("source.img").path)

    try SourceTreeImage.write(tree: FilePath(fixture.root.path), to: image)
    let entries = try EXT4.EXT4Reader(blockDevice: image).entries()
    let byPath = Dictionary(
        uniqueKeysWithValues: entries.map { ($0.path.string, $0) })

    // Read from the inode table rather than through an exported archive. An
    // archive keeps a hard link's two names only if its format and extractor
    // agree on ordering, so a lost link and a lossy export look the same.
    let readable = try #require(byPath["/readable"])
    let hardlink = try #require(byPath["/nested/hardlink"])
    #expect(
        readable.inode == hardlink.inode,
        "the two names hold different inodes, so the link became a copy")
    #expect(readable.isRegularFile)

    // Types and modes from the same reading, so one traversal covers what the
    // archive round trip covers and the thing it cannot.
    #expect(try #require(byPath["/nested"]).isDirectory)
    #expect(try #require(byPath["/relative-link"]).isSymbolicLink)
    #expect(try #require(byPath["/executable"]).permissions == 0o755)
    #expect(try #require(byPath["/readable"]).permissions == 0o644)
}

@Test func twoImagesOfOneTreeAreByteIdentical() throws {
    let fixture = try FixtureTree()
    defer { fixture.remove() }
    let work = fixture.root.deletingLastPathComponent()
        .appendingPathComponent("work-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    let first = FilePath(work.appendingPathComponent("first.img").path)
    let second = FilePath(work.appendingPathComponent("second.img").path)

    try SourceTreeImage.write(tree: FilePath(fixture.root.path), to: first)
    try SourceTreeImage.write(tree: FilePath(fixture.root.path), to: second)

    // The image is addressed by its content, so two builds of one tree that
    // differ in any byte would address the same source twice. A formatter
    // stamps a fresh filesystem UUID and its own wall clock unless both are
    // supplied, which is why they are.
    #expect(
        FileManager.default.contentsEqual(
            atPath: first.string, andPath: second.string),
        "two images of the same tree are not byte identical")
}

@Test func aDistinctIdentityChangesTheImage() throws {
    let fixture = try FixtureTree()
    defer { fixture.remove() }
    let work = fixture.root.deletingLastPathComponent()
        .appendingPathComponent("work-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    let first = FilePath(work.appendingPathComponent("first.img").path)
    let second = FilePath(work.appendingPathComponent("second.img").path)

    try SourceTreeImage.write(tree: FilePath(fixture.root.path), to: first)
    try SourceTreeImage.write(
        tree: FilePath(fixture.root.path),
        to: second,
        identity: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)

    // Determinism must not become a single filesystem identity shared by every
    // image, or two distinct trees would claim to be the same filesystem.
    #expect(
        !FileManager.default.contentsEqual(
            atPath: first.string, andPath: second.string),
        "the supplied filesystem identity did not reach the image")
}

@Test func aSourceTreeImageRefusesAnEntryItCannotReproduce() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "source-image-fifo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(unsafe mkfifo(root.appendingPathComponent("pipe").path, 0o644) == 0)
    let image = FilePath(root.appendingPathComponent("source.img").path)

    // Carrying an entry the image cannot represent, or dropping it quietly,
    // both produce an image that disagrees with the tree it names.
    #expect(throws: (any Error).self) {
        try SourceTreeImage.write(tree: FilePath(root.path), to: image)
    }
}

#endif
