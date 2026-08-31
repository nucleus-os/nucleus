import ColliderCore
import ColliderRuntime
import ContainerPersistence
import ContainerizationOCI
import Foundation
import SystemPackage

/// Reads the container store the Apple container service owns.
///
/// The service is the only writer. Everything it would answer about what the
/// store holds is already in the store: a volume's identity, capacity, and
/// backing image; a container's configuration and the workspaces it mounts; the
/// image state record, the blob store, and the unpacked snapshot directories.
/// Reading them here is what lets inspection stay in the account that asked,
/// rather than requiring the account whose launchd domain runs the service.
///
/// Consistency is whatever the filesystem gives a reader while a builder
/// writes. That is sufficient for every question asked of it -- what is
/// retained, what is unreachable, how close a workspace is to its ceiling --
/// and it is why nothing here is presented as an instantaneous total.
public struct AppleContainerStore: OCIStoreInspection {
    private let applicationRoot: FilePath
    private let installRoot: FilePath
    private let executionLease: FilePath?

    /// - Parameters:
    ///   - applicationRoot: the container service's application root.
    ///   - executionLease: the machine's single execution admission, which is
    ///     what says whether any container is running. Without it every record
    ///     is reported as possibly live, because a store with no liveness
    ///     signal cannot distinguish a running container from a leftover.
    public init(
        applicationRoot: FilePath,
        installRoot: FilePath = "/usr/local",
        executionLease: FilePath?
    ) {
        self.applicationRoot = applicationRoot
        self.installRoot = installRoot
        self.executionLease = executionLease
    }

    private var volumesRoot: FilePath { applicationRoot.appending("volumes") }
    private var containersRoot: FilePath { applicationRoot.appending("containers") }
    private var blobsRoot: FilePath {
        applicationRoot.appending("content/blobs/sha256")
    }
    private var snapshotsRoot: FilePath { applicationRoot.appending("snapshots") }
    private var stateRecord: FilePath { applicationRoot.appending("state.json") }

    public func executionLiveness() async -> OCIExecutionLiveness {
        guard let executionLease,
            let contents = try? String(
                contentsOfFile: executionLease.string, encoding: .utf8)
        else { return .idle }
        // The lease records the process holding it. Asking whether that process
        // exists is a read; probing the lock itself is not, because acquiring
        // it even momentarily can fail a concurrent acquisition that is using
        // the same non-blocking attempt.
        var pid: pid_t?
        var run: String?
        for field in contents.split(whereSeparator: \.isWhitespace) {
            let parts = field.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "pid": pid = pid_t(parts[1])
            case "run": run = String(parts[1])
            default: break
            }
        }
        guard let pid, pid > 0 else { return .idle }
        // ESRCH is the only answer that means gone. EPERM means the process
        // exists and belongs to another account, which is the ordinary case
        // here: the builder holds the lease and the reader does not.
        if kill(pid, 0) == 0 { return .executing(run: run) }
        return errno == ESRCH ? .idle : .executing(run: run)
    }

    public func persistentWorkspaces(
        configuration: OCIRuntimeConfiguration
    ) async throws -> [OCIPersistentWorkspaceState] {
        let manager = ApplePersistentWorkspaceManager(configuration: configuration)
        let mounted = try await mountedWorkspaceVolumeNames()
        var states: [OCIPersistentWorkspaceState] = []
        for directory in try directoryNames(in: volumesRoot).sorted() {
            let record = volumesRoot.appending(directory).appending("entity.json")
            guard let entity = try? decode(VolumeEntity.self, from: record),
                try manager.isOwned(labels: entity.labels),
                let identity = manager.identity(from: entity.labels),
                let capacity = entity.sizeInBytes
            else { continue }
            states.append(
                OCIPersistentWorkspaceState(
                    name: entity.name,
                    identity: identity,
                    capacityBytes: capacity,
                    allocatedBytes: allocatedBytes(
                        of: volumesRoot.appending(directory).appending("volume.img")),
                    active: mounted.contains(entity.name)))
        }
        return states
    }

    public func containers() async throws -> [OCIContainerState] {
        let live = await executionLiveness() != .idle
        var states: [OCIContainerState] = []
        for directory in try directoryNames(in: containersRoot).sorted() {
            let record = containersRoot.appending(directory).appending("config.json")
            guard let configuration = try? decode(ContainerRecord.self, from: record)
            else { continue }
            states.append(
                OCIContainerState(
                    name: configuration.id,
                    imageReference: configuration.image.reference,
                    running: live,
                    infrastructure: false))
        }
        return states
    }

    public func images() async throws -> [OCIImageState] {
        let state = try decode([String: Descriptor].self, from: stateRecord)
        let referenced = try await runningImageReferences()
        return state.keys.sorted().compactMap { reference in
            guard let descriptor = state[reference] else { return nil }
            let (repository, tag) = parsed(reference)
            return OCIImageState(
                reference: reference,
                repository: repository,
                tag: tag,
                digest: descriptor.digest,
                creationDate: descriptor.creationDate,
                active: referenced.contains(reference))
        }
    }

    /// The init and builder images the service is configured to run.
    ///
    /// The configuration is layered TOML on disk. The service is asked for it
    /// only to discover where the roots are, and this host declares both, so
    /// the daemon is not in the way of reading a file.
    public func infrastructureImages() async throws -> OCIInfrastructureImages {
        let configuration = try await ConfigurationLoader.load(
            configurationFiles: [
                ConfigurationLoader.configurationFile(
                    in: applicationRoot, of: .appRoot),
                ConfigurationLoader.configurationFile(
                    in: installRoot, of: .installRoot),
            ])
        var current: [String: String] = [:]
        for reference in [configuration.build.image, configuration.vminit.image] {
            let parsed = try ContainerizationOCI.Reference.parse(reference)
            current[parsed.name] = reference
        }
        return OCIInfrastructureImages(currentByRepository: current)
    }

    public func orphanedImageContent() async throws -> OCIOrphanedImageContent {
        let reachable = try await reachableContent()
        var orphanedBlobs = 0
        var orphanedBlobBytes: UInt64 = 0
        for name in try fileNames(in: blobsRoot) where !reachable.blobs.contains(name) {
            orphanedBlobs += 1
            orphanedBlobBytes &+= allocatedBytes(of: blobsRoot.appending(name))
        }
        var orphanedSnapshots = 0
        var orphanedSnapshotBytes: UInt64 = 0
        for name in try directoryNames(in: snapshotsRoot)
        where !reachable.snapshots.contains(name) {
            orphanedSnapshots += 1
            orphanedSnapshotBytes &+= allocatedBytes(
                ofTree: snapshotsRoot.appending(name))
        }
        return OCIOrphanedImageContent(
            orphanedBlobs: orphanedBlobs,
            orphanedBlobBytes: orphanedBlobBytes,
            orphanedSnapshots: orphanedSnapshots,
            orphanedSnapshotBytes: orphanedSnapshotBytes)
    }

    /// What the store holds and what of it is unreachable.
    ///
    /// Reported against the store rather than against the service's own
    /// accounting, which counted an image's content as reclaimable only once a
    /// reference was deleted. Content is orphaned by every image rebuild --
    /// the new reference takes the name and the old unpacked filesystem stays
    /// behind -- so the honest figure is what nothing reaches, whether or not
    /// anything has been deleted.
    public func diskUsage(
        configuration: OCIRuntimeConfiguration
    ) async throws -> OCIRuntimeDiskUsage {
        let images = try await images()
        let orphaned = try await orphanedImageContent()
        var imageBytes: UInt64 = 0
        for name in try fileNames(in: blobsRoot) {
            imageBytes &+= allocatedBytes(of: blobsRoot.appending(name))
        }
        for name in try directoryNames(in: snapshotsRoot) {
            imageBytes &+= allocatedBytes(ofTree: snapshotsRoot.appending(name))
        }
        var containerBytes: UInt64 = 0
        let containerRecords = try await containers()
        for name in try directoryNames(in: containersRoot) {
            containerBytes &+= allocatedBytes(
                ofTree: containersRoot.appending(name))
        }
        let workspaces = try await persistentWorkspaces(configuration: configuration)
        let workspaceBytes = workspaces.reduce(into: UInt64(0)) {
            $0 &+= $1.allocatedBytes
        }
        // A retained workspace is not reclaimable. It holds incremental state a
        // declaration claims, and the only bytes collection returns from one
        // are the free blocks inside its image.
        return OCIRuntimeDiskUsage(
            containers: OCIRuntimeResourceUsage(
                active: containerRecords.count(where: \.running),
                reclaimable: containerRecords.contains(where: \.running)
                    ? 0 : containerBytes,
                sizeInBytes: containerBytes,
                total: containerRecords.count),
            images: OCIRuntimeResourceUsage(
                active: images.count(where: \.active),
                reclaimable: orphaned.totalBytes,
                sizeInBytes: imageBytes,
                total: images.count),
            volumes: OCIRuntimeResourceUsage(
                active: workspaces.count(where: \.active),
                reclaimable: 0,
                sizeInBytes: workspaceBytes,
                total: workspaces.count))
    }

    /// Everything a named image reaches: its index, the manifests under it, and
    /// each manifest's configuration and layers. A snapshot is the unpacked
    /// form of a manifest and is named for it, so the manifests are also
    /// exactly the snapshots that are still reachable.
    private func reachableContent() async throws -> (blobs: Set<String>, snapshots: Set<String>) {
        let state = try decode([String: Descriptor].self, from: stateRecord)
        var blobs: Set<String> = []
        var snapshots: Set<String> = []
        for descriptor in state.values {
            var pending = [descriptor.digest]
            while let digest = pending.popLast() {
                guard let name = digestName(digest), blobs.insert(name).inserted
                else { continue }
                guard
                    let document = try? decode(
                        ContentDocument.self, from: blobsRoot.appending(name))
                else { continue }
                for manifest in document.manifests ?? [] {
                    pending.append(manifest.digest)
                    if let name = digestName(manifest.digest) {
                        snapshots.insert(name)
                    }
                }
                if let configuration = document.config {
                    pending.append(configuration.digest)
                }
                for layer in document.layers ?? [] { pending.append(layer.digest) }
            }
        }
        return (blobs, snapshots)
    }

    /// The images containers are running from.
    ///
    /// A container record is configuration, not liveness, and outlives the
    /// container that wrote it, so a record only names a running image while
    /// the machine's execution admission is held. Treating a leftover as active
    /// would pin its image against collection for good.
    private func runningImageReferences() async throws -> Set<String> {
        guard await executionLiveness() != .idle else { return [] }
        return Set(try await containers().map(\.imageReference))
    }

    /// The workspaces containers currently mount, for the same reason.
    private func mountedWorkspaceVolumeNames() async throws -> Set<String> {
        guard await executionLiveness() != .idle else { return [] }
        var names: Set<String> = []
        for directory in try directoryNames(in: containersRoot) {
            let record = containersRoot.appending(directory).appending("config.json")
            guard let configuration = try? decode(ContainerRecord.self, from: record)
            else { continue }
            for mount in configuration.mounts {
                if let name = mount.volumeName { names.insert(name) }
            }
        }
        return names
    }

    private func parsed(_ reference: String) -> (repository: String, tag: String?) {
        guard let separator = reference.lastIndex(of: ":"),
            !reference[reference.index(after: separator)...].contains("/")
        else { return (reference, nil) }
        return (
            String(reference[..<separator]),
            String(reference[reference.index(after: separator)...])
        )
    }

    private func digestName(_ digest: String) -> String? {
        let parts = digest.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0] == "sha256", !parts[1].isEmpty else {
            return nil
        }
        return String(parts[1])
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        from path: FilePath
    ) throws -> Value {
        let data = try Data(contentsOf: URL(fileURLWithPath: path.string))
        return try JSONDecoder().decode(type, from: data)
    }

    private func directoryNames(in root: FilePath) throws -> [String] {
        try entries(in: root, directories: true)
    }

    private func fileNames(in root: FilePath) throws -> [String] {
        try entries(in: root, directories: false)
    }

    private func entries(in root: FilePath, directories: Bool) throws -> [String] {
        let url = URL(fileURLWithPath: root.string)
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        return contents.compactMap { entry in
            let isDirectory =
                (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory)
                ?? false
            return isDirectory == directories ? entry.lastPathComponent : nil
        }
    }

    /// Blocks, not length. A workspace is a sparse image whose apparent size is
    /// its ceiling and whose cost to the host is what it has ever written, and
    /// the two differ by two orders of magnitude on a fresh one.
    private func allocatedBytes(of path: FilePath) -> UInt64 {
        let url = URL(fileURLWithPath: path.string)
        guard
            let values = try? url.resourceValues(
                forKeys: [.fileAllocatedSizeKey]),
            let allocated = values.fileAllocatedSize
        else { return 0 }
        return UInt64(allocated)
    }

    private func allocatedBytes(ofTree root: FilePath) -> UInt64 {
        let url = URL(fileURLWithPath: root.string)
        guard
            let walker = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.fileAllocatedSizeKey],
                options: [],
                errorHandler: { _, _ in true })
        else { return allocatedBytes(of: root) }
        var total: UInt64 = 0
        for case let entry as URL in walker {
            total &+= allocatedBytes(of: FilePath(entry.path))
        }
        return total
    }
}

// MARK: - Store records

extension AppleContainerStore {
    private struct VolumeEntity: Decodable {
        let name: String
        let labels: [String: String]
        let sizeInBytes: UInt64?
    }

    private struct Descriptor: Decodable {
        let digest: String
        let annotations: [String: String]?

        var creationDate: Date? {
            guard let value = annotations?["org.opencontainers.image.created"]
            else { return nil }
            return ISO8601DateFormatter().date(from: value)
        }
    }

    private struct ContentDocument: Decodable {
        struct Reference: Decodable { let digest: String }
        let manifests: [Reference]?
        let config: Reference?
        let layers: [Reference]?
    }

    private struct ContainerRecord: Decodable {
        struct Image: Decodable { let reference: String }
        struct Mount: Decodable {
            let source: String?
            let type: MountType?

            struct MountType: Decodable {
                let volume: VolumeSource?
                struct VolumeSource: Decodable { let name: String? }
            }

            var volumeName: String? {
                if let name = type?.volume?.name { return name }
                // A volume mount whose type does not name it still records the
                // image it is backed by, which sits under the volume directory
                // named for the volume itself.
                guard let source, source.contains("/volumes/") else { return nil }
                return
                    source
                    .split(separator: "/")
                    .drop(while: { $0 != "volumes" })
                    .dropFirst()
                    .first
                    .map(String.init)
            }
        }

        let id: String
        let image: Image
        let mounts: [Mount]
    }
}
