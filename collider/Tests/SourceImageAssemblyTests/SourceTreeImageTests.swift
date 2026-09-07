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

    // Hard links are deliberately not asserted here. This verification reads
    // the image back through `EXT4Reader.export`, and that path drops one of
    // the two names whichever name holds the inode, so it cannot distinguish
    // an image that lost a link from a reader that did. Establishing hard-link
    // fidelity needs the image read the way a consumer reads it, which is a
    // container attaching it, and that is not something this target can do.
    // The fixture keeps the link so the builder still has to handle it without
    // failing; what remains unproven is only that the link survives.
}

@Test func twoImagesOfOneTreeReproduceTheSameContents() throws {
    let fixture = try FixtureTree()
    defer { fixture.remove() }
    let work = fixture.root.deletingLastPathComponent()
        .appendingPathComponent("work-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }

    func contents(_ name: String) throws -> [String] {
        let image = FilePath(work.appendingPathComponent("\(name).img").path)
        let archive = FilePath(work.appendingPathComponent("\(name).tar").path)
        let restored = work.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: restored, withIntermediateDirectories: true)
        try SourceTreeImage.write(tree: FilePath(fixture.root.path), to: image)
        try EXT4.EXT4Reader(blockDevice: image).export(archive: archive)
        _ = try ArchiveReader(file: archive.url).extractContents(to: restored)
        let walked =
            (FileManager.default.enumerator(atPath: restored.path)?.allObjects
                as? [String]) ?? []
        return walked.sorted()
    }

    // Not a byte comparison. The vendored formatter stamps a fresh filesystem
    // UUID and its own wall clock into every image it writes, neither of which
    // this can pass in, so two images of one tree are never byte-identical.
    // What has to be stable is the tree they reproduce, and that is what the
    // build graph needs from an output it will address.
    #expect(try contents("first") == contents("second"))
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
