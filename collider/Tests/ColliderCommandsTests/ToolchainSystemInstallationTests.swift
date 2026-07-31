import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage
import Testing

@testable import ColliderCommands

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

@Test func toolchainSystemInstallerPublishesAndUninstallsTransactionally() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        "nucleus-toolchain-install-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    let fixture = root.appendingPathComponent("fixture", isDirectory: true)
    let usr = fixture.appendingPathComponent("usr", isDirectory: true)
    for directory in [
        "bin",
        "lib/swift/linux",
        "lib/swift_static/linux",
    ] {
        try fileManager.createDirectory(
            at: usr.appendingPathComponent(directory),
            withIntermediateDirectories: true)
    }
    let swift = usr.appendingPathComponent("bin/swift")
    try Data("#!/bin/sh\nprintf 'Nucleus Swift fixture\\n'\n".utf8).write(to: swift)
    try fileManager.setAttributes(
        [.posixPermissions: NSNumber(value: 0o755)],
        ofItemAtPath: swift.path)
    for archive in [
        "lib/swift/linux/lib_CFXMLInterface.a",
        "lib/swift_static/linux/lib_CFXMLInterface.a",
    ] {
        try Data("fixture\n".utf8).write(
            to: usr.appendingPathComponent(archive))
    }
    try Data(
        "-lswift_StringProcessing\n-l_CFXMLInterface\n-lxml2\n".utf8
    ).write(
        to: usr.appendingPathComponent(
            "lib/swift_static/linux/static-stdlib-args.lnk"))

    let tarball = root.appendingPathComponent("toolchain.tar.gz")
    try runFixtureProcess(
        "/usr/bin/tar",
        ["--create", "--gzip", "--file", tarball.path, "usr"],
        workingDirectory: fixture)
    let artifactID = try ArtifactHasher.digest(
        file: FilePath(tarball.path)
    ).description
    let prefix = root.appendingPathComponent("installed", isDirectory: true)
    let profile = root.appendingPathComponent("nucleus-swift.sh")
    let version = "0123456789abcdef01234567"
    let install = ToolchainSystemRequest(
        operation: .install,
        version: version,
        prefix: prefix,
        tarball: tarball,
        artifactID: artifactID)

    try ToolchainSystemInstaller(
        request: install,
        profile: profile,
        ownerAccountID: getuid(),
        groupOwnerAccountID: getgid()
    ).run()

    #expect(
        try fileManager.destinationOfSymbolicLink(
            atPath: prefix.appendingPathComponent("current").path) == version)
    #expect(
        fileManager.isExecutableFile(
            atPath: prefix.appendingPathComponent(
                "\(version)/usr/bin/swift"
            ).path))
    #expect(
        try String(contentsOf: profile, encoding: .utf8).contains(
            prefix.appendingPathComponent("current/usr/bin").path))

    let uninstall = ToolchainSystemRequest(
        operation: .uninstall,
        version: version,
        prefix: prefix,
        tarball: nil,
        artifactID: nil)
    try ToolchainSystemInstaller(
        request: uninstall,
        profile: profile,
        ownerAccountID: getuid(),
        groupOwnerAccountID: getgid()
    ).run()

    #expect(!fileManager.fileExists(atPath: prefix.path))
    #expect(!fileManager.fileExists(atPath: profile.path))
}

private func runFixtureProcess(
    _ executable: String,
    _ arguments: [String],
    workingDirectory: URL
) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = workingDirectory
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw WorkspaceFailure.process(
            [executable] + arguments, process.terminationStatus)
    }
}
