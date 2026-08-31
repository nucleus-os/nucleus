import ColliderCore
import Foundation
import SystemPackage

/// What image content collection would return if it ran now.
///
/// Blobs and unpacked filesystems are counted separately because they are
/// orphaned by different events and are wildly different sizes. A rebuilt image
/// replaces the reference a snapshot belonged to and leaves the snapshot behind,
/// so snapshots dominate: they are the extracted trees, while blobs are the
/// compressed layers they came from.
public struct OCIOrphanedImageContent: Equatable, Sendable {
    public let orphanedBlobs: Int
    public let orphanedBlobBytes: UInt64
    public let orphanedSnapshots: Int
    public let orphanedSnapshotBytes: UInt64

    public var totalBytes: UInt64 { orphanedBlobBytes &+ orphanedSnapshotBytes }

    public init(
        orphanedBlobs: Int,
        orphanedBlobBytes: UInt64,
        orphanedSnapshots: Int,
        orphanedSnapshotBytes: UInt64
    ) {
        self.orphanedBlobs = orphanedBlobs
        self.orphanedBlobBytes = orphanedBlobBytes
        self.orphanedSnapshots = orphanedSnapshots
        self.orphanedSnapshotBytes = orphanedSnapshotBytes
    }
}

/// Whether any execution holds the machine's single admission.
///
/// Nothing in the container store records whether a container is running. The
/// records hold configuration, and they outlive the containers that wrote them
/// -- one on this host is four days older than the last container that ran. A
/// reader that took a record's existence for liveness would pin every workspace
/// it mounted and every image it referenced against collection permanently,
/// which is the failure the runtime's own image listing already guards against
/// by asking which containers are *running* rather than which exist.
///
/// The machine already serializes execution behind one lease, so liveness is a
/// property of that lease rather than of any record: while it is free, no
/// Collider container is running and every record is history. While it is held,
/// the records describe what is running now, and a reader that cannot tell
/// which is which reports the conservative answer.
public enum OCIExecutionLiveness: Equatable, Sendable {
    /// No execution holds the lease; every container record is history.
    case idle
    /// An execution holds the lease, named by the run recorded in it.
    case executing(run: String?)
}

/// Inspection of the container store, answered from the store itself.
///
/// Inspection stays in the invoking account, and the container service runs in
/// the builder's launchd domain, so an inspection routed through the service is
/// only available to the account that owns the builds. Every answer here is
/// already on disk under the build store, readable by the group that owns it:
/// volume entity records and their images, container configuration records, the
/// image state record, the blob store, and the snapshot directories.
///
/// This reads; it never mutates. The service remains the only writer, so an
/// inspection cannot start a container, and a store this reads while the
/// builder writes is read at whatever consistency the filesystem gives -- which
/// is why a reader reports what it found rather than asserting a total.
public protocol OCIStoreInspection: Sendable {
    func executionLiveness() async -> OCIExecutionLiveness
    func persistentWorkspaces(
        configuration: OCIRuntimeConfiguration
    ) async throws -> [OCIPersistentWorkspaceState]
    func containers() async throws -> [OCIContainerState]
    func images() async throws -> [OCIImageState]
    func orphanedImageContent() async throws -> OCIOrphanedImageContent
    func infrastructureImages() async throws -> OCIInfrastructureImages
    func diskUsage(
        configuration: OCIRuntimeConfiguration
    ) async throws -> OCIRuntimeDiskUsage
}
