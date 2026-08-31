import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage
import Testing

@testable import ColliderAppleContainer

/// A store shaped like the one the service writes, with only what these
/// assertions read.
private struct StoreFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-container-store-\(UUID().uuidString)")
        for directory in ["volumes", "containers", "content/blobs/sha256", "snapshots"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory),
                withIntermediateDirectories: true)
        }
    }

    var applicationRoot: FilePath { FilePath(root.path) }

    func write(_ json: String, to relative: String) throws {
        let file = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(json.utf8).write(to: file)
    }

    func writeVolume(
        name: String,
        key: String,
        role: String,
        capacityBytes: UInt64,
        contentBytes: Int
    ) throws {
        try write(
            """
            {"name":"\(name)","sizeInBytes":\(capacityBytes),"labels":{
              "dev.collider.managed":"true",
              "dev.collider.persistent-workspace":"true",
              "dev.collider.persistent-workspace.owner":"\(Self.owner)",
              "dev.collider.persistent-workspace.key":"\(key)",
              "dev.collider.persistent-workspace.target":"",
              "dev.collider.persistent-workspace.role":"\(role)"}}
            """,
            to: "volumes/\(name)/entity.json")
        try Data(repeating: 7, count: contentBytes).write(
            to: root.appendingPathComponent("volumes/\(name)/volume.img"))
    }

    func writeLease(pid: pid_t) throws -> FilePath {
        let file = root.appendingPathComponent("host-execution.lock")
        try Data("pid=\(pid) user=builder run=example started=now\n".utf8).write(to: file)
        return FilePath(file.path)
    }

    static let owner = String(repeating: "a", count: 64)

    var configuration: OCIRuntimeConfiguration {
        OCIRuntimeConfiguration(
            isolatedNetwork: "net",
            guestHome: "/home/collider",
            managedLabels: ["dev.collider.managed=true"],
            managedLabelNamespace: "dev.collider",
            persistentWorkspaceOwner: Self.owner,
            loggerLabel: "test")
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Test func theStoreReportsWorkspaceCapacityAndAllocationWithoutTheService() async throws {
    let fixture = try StoreFixture()
    defer { fixture.remove() }
    try fixture.writeVolume(
        name: "collider-\(StoreFixture.owner)-build-any-build",
        key: "build",
        role: "build",
        capacityBytes: 1_000_000,
        contentBytes: 40_000)
    // Not this one: an unowned volume belongs to something else, and reporting
    // it would make another owner's storage look like a cleanup candidate.
    try fixture.write(
        """
        {"name":"someone-elses","sizeInBytes":10,"labels":{}}
        """,
        to: "volumes/someone-elses/entity.json")
    let store = AppleContainerStore(
        applicationRoot: fixture.applicationRoot,
        executionLease: nil)

    let workspaces = try await store.persistentWorkspaces(
        configuration: fixture.configuration)

    #expect(workspaces.count == 1)
    #expect(workspaces.first?.identity.key == "build")
    #expect(workspaces.first?.capacityBytes == 1_000_000)
    // Allocation is what the image has written, not the ceiling it was created
    // with, which is the difference between a workspace's cost to the host and
    // its declaration.
    #expect((workspaces.first?.allocatedBytes ?? 0) > 0)
    #expect((workspaces.first?.allocatedBytes ?? .max) < 1_000_000)
}

@Test func aContainerRecordIsHistoryWhileNothingHoldsTheExecutionLease() async throws {
    let fixture = try StoreFixture()
    defer { fixture.remove() }
    try fixture.writeVolume(
        name: "collider-\(StoreFixture.owner)-build-any-build",
        key: "build",
        role: "build",
        capacityBytes: 1_000_000,
        contentBytes: 4_096)
    // A record naming the workspace, exactly as one left behind by a container
    // that exited days ago does.
    try fixture.write(
        """
        {"id":"leftover","image":{"reference":"localhost/example:latest"},
         "mounts":[{"source":"/store/volumes/collider-\(StoreFixture.owner)-build-any-build/volume.img"}]}
        """,
        to: "containers/leftover/config.json")

    // A lease naming a process that cannot exist. Nothing is running, so the
    // record is history and the workspace it names is not in use -- which is
    // what keeps a leftover from pinning a workspace against collection for
    // good.
    let deadLease = try fixture.writeLease(pid: .max)
    let idle = AppleContainerStore(
        applicationRoot: fixture.applicationRoot,
        executionLease: deadLease)
    #expect(await idle.executionLiveness() == .idle)
    let whileIdle = try await idle.persistentWorkspaces(
        configuration: fixture.configuration)
    #expect(whileIdle.first?.active == false)
    #expect(try await idle.containers().first?.running == false)

    // The same records, while an execution holds the lease.
    let liveLease = try fixture.writeLease(pid: getpid())
    let executing = AppleContainerStore(
        applicationRoot: fixture.applicationRoot,
        executionLease: liveLease)
    #expect(await executing.executionLiveness() == .executing(run: "example"))
    let whileExecuting = try await executing.persistentWorkspaces(
        configuration: fixture.configuration)
    #expect(whileExecuting.first?.active == true)
    #expect(try await executing.containers().first?.running == true)
}

@Test func theStoreSizesWhatImageCollectionWouldReturn() async throws {
    let fixture = try StoreFixture()
    defer { fixture.remove() }
    let layer = String(repeating: "1", count: 64)
    let config = String(repeating: "2", count: 64)
    let manifestDigest = String(repeating: "3", count: 64)
    let indexDigest = String(repeating: "4", count: 64)
    let orphan = String(repeating: "5", count: 64)
    let orphanedSnapshot = String(repeating: "6", count: 64)

    try fixture.write(
        """
        {"localhost/example:latest":{"digest":"sha256:\(indexDigest)"}}
        """,
        to: "state.json")
    try fixture.write(
        """
        {"manifests":[{"digest":"sha256:\(manifestDigest)"}]}
        """,
        to: "content/blobs/sha256/\(indexDigest)")
    try fixture.write(
        """
        {"config":{"digest":"sha256:\(config)"},
         "layers":[{"digest":"sha256:\(layer)"}]}
        """,
        to: "content/blobs/sha256/\(manifestDigest)")
    try fixture.write("{}", to: "content/blobs/sha256/\(config)")
    try fixture.write("{}", to: "content/blobs/sha256/\(layer)")
    // Reachable from nothing: the layer of an image a rebuild replaced.
    try Data(repeating: 9, count: 8_192).write(
        to: fixture.root.appendingPathComponent("content/blobs/sha256/\(orphan)"))
    // The unpacked filesystem of a live manifest, and one of a manifest no
    // reference reaches any more.
    for snapshot in [manifestDigest, orphanedSnapshot] {
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("snapshots/\(snapshot)"),
            withIntermediateDirectories: true)
        try Data(repeating: 3, count: 16_384).write(
            to: fixture.root.appendingPathComponent("snapshots/\(snapshot)/rootfs"))
    }

    let store = AppleContainerStore(
        applicationRoot: fixture.applicationRoot,
        executionLease: nil)
    let orphaned = try await store.orphanedImageContent()

    #expect(orphaned.orphanedBlobs == 1)
    #expect(orphaned.orphanedBlobBytes > 0)
    #expect(orphaned.orphanedSnapshots == 1)
    #expect(orphaned.orphanedSnapshotBytes > 0)
    // The figure exists before anything is deleted, which is what makes a dry
    // run able to state a size rather than state that collection runs.
    #expect(orphaned.totalBytes == orphaned.orphanedBlobBytes &+ orphaned.orphanedSnapshotBytes)

    let images = try await store.images()
    #expect(images.map(\.reference) == ["localhost/example:latest"])
    #expect(images.first?.repository == "localhost/example")
    #expect(images.first?.tag == "latest")
}

/// The registry scheme we hand the container stack has to be one it accepts.
///
/// It was `auto` until the stack removed that case, and a string the stack no
/// longer parses fails inside container creation rather than at build time:
/// `invalidArgument: "unsupported scheme auto"`, eight tasks into a sweep. The
/// stack's own parser is the authority, so this asks it directly.
@Test func theRegistrySchemeIsOneTheContainerStackParses() throws {
    #expect(throws: Never.self) {
        _ = try AppleContainerLifecycle.parsedRegistryScheme()
    }
}
