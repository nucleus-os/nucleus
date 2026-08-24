import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage
import Testing

/// A staged tree carries the links it was given.
///
/// A package that declares a path as a symbolic link has to materialize one,
/// and the tree it is staged from records that path as a link rather than as
/// whatever it points at. Copying the target instead produces a directory
/// where the package contract expects a link, and fails outright on a link
/// whose target is absent — both of which reached packaging as failures three
/// steps removed from the copy that caused them.
@Test func copyTreePreservesSymbolicLinksRatherThanTheirTargets() throws {
    let files = ColliderRuntime().actionFileSystem()
    let root = FilePath(
        FileManager.default.temporaryDirectory
            .appendingPathComponent("collider-copytree-\(UUID().uuidString)")
            .path)
    defer { try? FileManager.default.removeItem(atPath: root.string) }

    let source = root.appending("source")
    try files.createDirectory(source.appending("real"))
    try files.createDirectory(source.appending("sub"))
    try files.write(Array("payload".utf8), to: source.appending("real/file.txt"))
    try FileManager.default.createSymbolicLink(
        atPath: source.appending("sub/link-to-directory").string,
        withDestinationPath: "../real")
    try FileManager.default.createSymbolicLink(
        atPath: source.appending("sub/dangling").string,
        withDestinationPath: "./absent")

    let destination = root.appending("destination")
    try files.copyTree(from: source, to: destination)

    let link = destination.appending("sub/link-to-directory")
    #expect(try files.metadataWithoutFollowingSymlinks(for: link)?.type == .symbolicLink)
    #expect(try files.readSymbolicLink(link) == "../real")

    // A link whose target is absent still copies as a link. The copy has no
    // business reading through it, so its target being missing is not the
    // copy's failure to report.
    let dangling = destination.appending("sub/dangling")
    #expect(
        try files.metadataWithoutFollowingSymlinks(for: dangling)?.type == .symbolicLink)
    #expect(try files.readSymbolicLink(dangling) == "./absent")

    #expect(try files.metadata(for: destination.appending("real/file.txt")) != nil)
}
