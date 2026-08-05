import ColliderCore
import ColliderPlatformC
import Foundation
import SystemPackage

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct PortableArtifactStore: Sendable {
    public struct Limits: Hashable, Sendable {
        public let maximumSnapshotBytes: UInt64
        public let maximumTotalBytes: UInt64
        public let maximumSnapshots: Int
        public let maximumQuarantinedSnapshots: Int

        public init(
            maximumSnapshotBytes: UInt64,
            maximumTotalBytes: UInt64,
            maximumSnapshots: Int,
            maximumQuarantinedSnapshots: Int
        ) {
            precondition(maximumSnapshotBytes > 0)
            precondition(maximumTotalBytes >= maximumSnapshotBytes)
            precondition(maximumSnapshots > 0)
            precondition(maximumQuarantinedSnapshots >= 0)
            self.maximumSnapshotBytes = maximumSnapshotBytes
            self.maximumTotalBytes = maximumTotalBytes
            self.maximumSnapshots = maximumSnapshots
            self.maximumQuarantinedSnapshots = maximumQuarantinedSnapshots
        }

        public static let production = Limits(
            maximumSnapshotBytes: 4 * 1_024 * 1_024 * 1_024,
            maximumTotalBytes: 100 * 1_024 * 1_024 * 1_024,
            maximumSnapshots: 256,
            maximumQuarantinedSnapshots: 16)
    }

    public let root: FilePath
    public let limits: Limits

    public init(root: FilePath, limits: Limits = .production) {
        self.root = root
        self.limits = limits
    }

    public func state(
        task: TaskID,
        identity: ArtifactDigest
    ) -> PortableSnapshotState {
        let snapshot = snapshotPath(identity)
        guard pathExists(snapshot) else { return .missing }
        guard pathExists(snapshot.appending("manifest.json")) else {
            return .corrupt
        }
        do {
            let manifest = try loadManifest(at: snapshot)
            guard manifest.task == task, manifest.identity == identity else {
                return .corrupt
            }
            return .available
        } catch is DecodingError {
            return .corrupt
        } catch {
            // Planning is read-only and cannot surface an availability error.
            // Let execution attempt the restore so transient I/O failures do
            // not classify a good snapshot as corrupt and destroy it.
            return .available
        }
    }

    @discardableResult
    public func capture(
        task: TaskDeclaration,
        identity: ArtifactDigest
    ) throws -> [String: ArtifactDigest] {
        let outputDigests = try withSnapshotLock(identity) {
            try FileManager.default.createDirectory(
                atPath: root.string,
                withIntermediateDirectories: true)
            let final = snapshotPath(identity)
            if pathExists(final) {
                do {
                    let manifest = try validateSnapshot(
                        at: final,
                        task: task,
                        identity: identity)
                    return try snapshotDigests(manifest)
                } catch let failure as PortableArtifactStoreFailure
                    where failure.isSnapshotCorruption
                {
                    try quarantineUnlocked(identity)
                }
            }

            let candidate = root.appending(
                ".candidate-\(identity.hexadecimal)-\(UUID().uuidString)")
            try? FileManager.default.removeItem(atPath: candidate.string)
            do {
                let manifest = try materializeSnapshot(
                    task: task,
                    identity: identity,
                    at: candidate)
                try DurableFile.writeJSON(
                    manifest,
                    to: candidate.appending("manifest.json"))
                try validateSnapshot(
                    at: candidate,
                    task: task,
                    identity: identity)
                try synchronizeTree(candidate)
                guard unsafe collider_replace(candidate.string, final.string) == 0 else {
                    throw Errno(rawValue: errno)
                }
                try DurableFile.synchronizeDirectory(root)
                return try snapshotDigests(manifest)
            } catch {
                try? FileManager.default.removeItem(atPath: candidate.string)
                throw error
            }
        }
        try prune()
        return outputDigests
    }

    @discardableResult
    public func restore(
        task: TaskDeclaration,
        identity: ArtifactDigest
    ) throws -> [String: ArtifactDigest] {
        try withSnapshotLock(identity) {
            let snapshot = snapshotPath(identity)
            let manifest = try validateSnapshot(
                at: snapshot,
                task: task,
                identity: identity)
            let slots = sortedOutputSlots(task)
            var candidates: [(candidate: FilePath, destination: FilePath)] = []
            do {
                for (index, slot) in slots.enumerated() {
                    let source = payloadPath(snapshot: snapshot, index: index)
                    let candidate = FilePath(
                        slot.path.string + ".collider-restore-\(UUID().uuidString)")
                    try? FileManager.default.removeItem(atPath: candidate.string)
                    try FileManager.default.createDirectory(
                        atPath: candidate.removingLastComponent().string,
                        withIntermediateDirectories: true)
                    try FileManager.default.copyItem(
                        atPath: source.string,
                        toPath: candidate.string)
                    try applyPermissions(
                        manifest.outputs[index].entries,
                        to: candidate)
                    let restoredEntries = try snapshotEntries(at: candidate).entries
                    guard restoredEntries == manifest.outputs[index].entries else {
                        throw PortableArtifactStoreFailure.corruptSnapshot(
                            task: task.id,
                            reason: "restored payload does not match its manifest")
                    }
                    candidates.append((candidate, slot.path))
                }
                for value in candidates {
                    try synchronizeTree(value.candidate)
                }
                for value in candidates {
                    try publishAtomically(
                        candidate: value.candidate,
                        destination: value.destination)
                }
            } catch {
                for value in candidates {
                    try? FileManager.default.removeItem(
                        atPath: value.candidate.string)
                }
                throw error
            }
            return try snapshotDigests(manifest)
        }
    }

    public func quarantine(identity: ArtifactDigest) throws {
        try withSnapshotLock(identity) {
            try quarantineUnlocked(identity)
        }
        try pruneQuarantine()
    }

    public func prune() throws {
        try withLock(path: root.appending("locks/retention.lock")) {
            guard pathExists(root) else { return }
            try removeAbandonedCandidates()
            let snapshots = try snapshotRecords().sorted {
                $0.capturedAt < $1.capturedAt
            }
            var totalBytes = snapshots.reduce(UInt64(0)) { total, snapshot in
                let (sum, overflow) = total.addingReportingOverflow(
                    snapshot.totalBytes)
                return overflow ? UInt64.max : sum
            }
            var retained = snapshots.count
            for snapshot in snapshots
            where retained > limits.maximumSnapshots
                || totalBytes > limits.maximumTotalBytes
            {
                try withSnapshotLock(snapshot.identity) {
                    guard pathExists(snapshot.path) else { return }
                    try FileManager.default.removeItem(atPath: snapshot.path.string)
                }
                totalBytes =
                    totalBytes >= snapshot.totalBytes
                    ? totalBytes - snapshot.totalBytes : 0
                retained -= 1
            }
        }
        try pruneQuarantine()
    }

    private func materializeSnapshot(
        task: TaskDeclaration,
        identity: ArtifactDigest,
        at candidate: FilePath
    ) throws -> PortableArtifactManifest {
        let slots = try eligibleOutputSlots(task)
        let payload = candidate.appending("payload")
        try FileManager.default.createDirectory(
            atPath: payload.string,
            withIntermediateDirectories: true)
        var outputs: [PortableArtifactOutput] = []
        var totalBytes: UInt64 = 0
        for (index, slot) in slots.enumerated() {
            let snapshot = try snapshotEntries(at: slot.path)
            guard snapshot.totalBytes <= limits.maximumSnapshotBytes,
                totalBytes <= limits.maximumSnapshotBytes - snapshot.totalBytes
            else {
                throw PortableArtifactStoreFailure.snapshotTooLarge(
                    task: task.id,
                    maximumBytes: limits.maximumSnapshotBytes)
            }
            totalBytes += snapshot.totalBytes
            let destination = payloadPath(snapshot: candidate, index: index)
            try FileManager.default.copyItem(
                atPath: slot.path.string,
                toPath: destination.string)
            outputs.append(
                PortableArtifactOutput(
                    slot: slot.id,
                    validation: slot.validation,
                    kind: slot.kind,
                    entries: snapshot.entries))
        }
        return PortableArtifactManifest(
            task: task.id,
            identity: identity,
            capturedAt: ISO8601DateFormatter().string(from: Date()),
            totalBytes: totalBytes,
            outputs: outputs)
    }

    @discardableResult
    private func validateSnapshot(
        at snapshot: FilePath,
        task: TaskDeclaration,
        identity: ArtifactDigest
    ) throws -> PortableArtifactManifest {
        let manifest: PortableArtifactManifest
        guard pathExists(snapshot.appending("manifest.json")) else {
            throw PortableArtifactStoreFailure.corruptSnapshot(
                task: task.id,
                reason: "manifest is missing")
        }
        do {
            manifest = try loadManifest(at: snapshot)
        } catch let error as DecodingError {
            throw PortableArtifactStoreFailure.corruptSnapshot(
                task: task.id,
                reason: "manifest cannot be decoded: \(error)")
        }
        guard manifest.task == task.id, manifest.identity == identity else {
            throw PortableArtifactStoreFailure.corruptSnapshot(
                task: task.id,
                reason: "manifest task or identity does not match its storage key")
        }
        let slots = try eligibleOutputSlots(task)
        guard manifest.outputs.count == slots.count else {
            throw PortableArtifactStoreFailure.corruptSnapshot(
                task: task.id,
                reason: "manifest output count does not match the task declaration")
        }
        var totalBytes: UInt64 = 0
        for (index, slot) in slots.enumerated() {
            let output = manifest.outputs[index]
            guard output.slot == slot.id,
                output.validation == slot.validation,
                output.kind == slot.kind
            else {
                throw PortableArtifactStoreFailure.corruptSnapshot(
                    task: task.id,
                    reason: "manifest output contract does not match slot '\(slot.id)'")
            }
            let stored = payloadPath(snapshot: snapshot, index: index)
            let actual = try snapshotEntries(at: stored)
            guard actual.entries == output.entries else {
                throw PortableArtifactStoreFailure.corruptSnapshot(
                    task: task.id,
                    reason: "payload for slot '\(slot.id)' does not match its manifest")
            }
            totalBytes &+= actual.totalBytes
        }
        guard totalBytes == manifest.totalBytes,
            totalBytes <= limits.maximumSnapshotBytes
        else {
            throw PortableArtifactStoreFailure.corruptSnapshot(
                task: task.id,
                reason: "manifest byte count is invalid")
        }
        return manifest
    }

    private func eligibleOutputSlots(
        _ task: TaskDeclaration
    ) throws -> [AnyTaskOutputSlot] {
        let slots = sortedOutputSlots(task)
        guard !slots.isEmpty, slots.count == task.outputs.count else {
            throw PortableArtifactStoreFailure.invalidDeclaration(
                task: task.id,
                reason: "portable tasks require typed output slots for every output")
        }
        for slot in slots {
            guard
                task.outputs.contains(where: {
                    $0.path == slot.path && $0.validation == slot.validation
                })
            else {
                throw PortableArtifactStoreFailure.invalidDeclaration(
                    task: task.id,
                    reason: "output slot '\(slot.id)' has no matching declaration")
            }
        }
        return slots
    }

    private func sortedOutputSlots(
        _ task: TaskDeclaration
    ) -> [AnyTaskOutputSlot] {
        task.outputSlots.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    private func snapshotEntries(
        at root: FilePath
    ) throws -> (entries: [PortableArtifactEntry], totalBytes: UInt64) {
        guard pathExists(root) else {
            throw PortableArtifactStoreFailure.corruptSnapshot(
                task: TaskID(rawValue: "unknown"),
                reason: "snapshot payload is missing at \(root)")
        }
        var paths = [(relative: "", path: root)]
        if try root.stat(followTargetSymlink: false).type == .directory {
            guard let enumerator = FileManager.default.enumerator(atPath: root.string) else {
                throw CocoaError(.fileReadUnknown)
            }
            paths += enumerator.compactMap { value in
                (value as? String).map { ($0, root.appending($0)) }
            }
        }
        paths.sort { $0.relative.utf8.lexicographicallyPrecedes($1.relative.utf8) }
        var entries: [PortableArtifactEntry] = []
        var totalBytes: UInt64 = 0
        for value in paths {
            let metadata = try value.path.stat(followTargetSymlink: false)
            let permissions = UInt16(
                truncatingIfNeeded: metadata.permissions.rawValue)
            switch metadata.type {
            case .regular:
                let size = UInt64(max(0, metadata.size))
                guard totalBytes <= UInt64.max - size else {
                    throw PortableArtifactStoreFailure.invalidSize(value.path)
                }
                totalBytes += size
                entries.append(
                    PortableArtifactEntry(
                        relativePath: value.relative,
                        type: .file,
                        permissions: permissions,
                        digest: try ArtifactHasher.digest(file: value.path),
                        symlinkTarget: nil))
            case .directory:
                entries.append(
                    PortableArtifactEntry(
                        relativePath: value.relative,
                        type: .directory,
                        permissions: permissions,
                        digest: nil,
                        symlinkTarget: nil))
            case .symbolicLink:
                let target = try FileManager.default.destinationOfSymbolicLink(
                    atPath: value.path.string)
                guard !FilePath(target).isAbsolute else {
                    throw PortableArtifactStoreFailure.absoluteSymlink(
                        path: value.path,
                        target: target)
                }
                guard !value.relative.isEmpty else {
                    throw PortableArtifactStoreFailure.escapingSymlink(
                        path: value.path,
                        target: target)
                }
                let resolved = value.path.removingLastComponent()
                    .appending(target).lexicallyNormalized()
                let normalizedRoot = root.lexicallyNormalized()
                guard
                    resolved == normalizedRoot
                        || contains(resolved.string, in: normalizedRoot.string)
                else {
                    throw PortableArtifactStoreFailure.escapingSymlink(
                        path: value.path,
                        target: target)
                }
                entries.append(
                    PortableArtifactEntry(
                        relativePath: value.relative,
                        type: .symlink,
                        permissions: permissions,
                        digest: nil,
                        symlinkTarget: target))
            default:
                throw PortableArtifactStoreFailure.unsupportedFileType(value.path)
            }
        }
        return (entries, totalBytes)
    }

    private func applyPermissions(
        _ entries: [PortableArtifactEntry],
        to root: FilePath
    ) throws {
        for entry in entries where entry.type != .symlink {
            let path =
                entry.relativePath.isEmpty
                ? root : root.appending(entry.relativePath)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: entry.permissions)],
                ofItemAtPath: path.string)
        }
    }

    private func publishAtomically(
        candidate: FilePath,
        destination: FilePath
    ) throws {
        if pathExists(destination) {
            guard unsafe collider_exchange(candidate.string, destination.string) == 0 else {
                throw Errno(rawValue: errno)
            }
            try FileManager.default.removeItem(atPath: candidate.string)
        } else {
            guard unsafe collider_replace(candidate.string, destination.string) == 0 else {
                throw Errno(rawValue: errno)
            }
        }
        try DurableFile.synchronizeDirectory(destination.removingLastComponent())
    }

    private func synchronizeTree(_ root: FilePath) throws {
        let snapshot = try snapshotEntries(at: root)
        for entry in snapshot.entries where entry.type == .file {
            let path =
                entry.relativePath.isEmpty
                ? root : root.appending(entry.relativePath)
            let descriptor = try FileDescriptor.open(path, .readOnly)
            guard collider_sync_file(descriptor.rawValue) == 0 else {
                let code = errno
                try? descriptor.close()
                throw Errno(rawValue: code)
            }
            try descriptor.close()
        }
        let directories = snapshot.entries.filter { $0.type == .directory }
            .sorted { $0.relativePath.count > $1.relativePath.count }
        for entry in directories {
            let path =
                entry.relativePath.isEmpty
                ? root : root.appending(entry.relativePath)
            try DurableFile.synchronizeDirectory(path)
        }
    }

    private func quarantineUnlocked(_ identity: ArtifactDigest) throws {
        try quarantinePathUnlocked(snapshotPath(identity))
    }

    private func quarantinePathUnlocked(_ snapshot: FilePath) throws {
        guard pathExists(snapshot) else { return }
        let quarantine = root.appending("quarantine")
        try FileManager.default.createDirectory(
            atPath: quarantine.string,
            withIntermediateDirectories: true)
        let destination = quarantine.appending(
            "\(snapshot.lastComponent?.string ?? "snapshot")-\(UUID().uuidString)")
        guard unsafe collider_replace(snapshot.string, destination.string) == 0 else {
            throw Errno(rawValue: errno)
        }
        try DurableFile.synchronizeDirectory(quarantine)
        try DurableFile.synchronizeDirectory(root)
    }

    private func pruneQuarantine() throws {
        try withLock(path: root.appending("locks/quarantine-retention.lock")) {
            let quarantine = root.appending("quarantine")
            guard pathExists(quarantine) else { return }
            let names = try FileManager.default.contentsOfDirectory(
                atPath: quarantine.string)
            let records = names.map { name -> (path: FilePath, date: Date) in
                let path = quarantine.appending(name)
                let attributes = try? FileManager.default.attributesOfItem(
                    atPath: path.string)
                return (path, attributes?[.modificationDate] as? Date ?? .distantPast)
            }.sorted { $0.date < $1.date }
            for record in records.dropLast(limits.maximumQuarantinedSnapshots) {
                try FileManager.default.removeItem(atPath: record.path.string)
            }
        }
    }

    private func snapshotRecords() throws -> [PortableSnapshotRecord] {
        var records: [PortableSnapshotRecord] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: root.string)
        where name.hasPrefix("sha256-") {
            let path = root.appending(name)
            guard let identity = snapshotIdentity(name) else {
                try quarantinePathUnlocked(path)
                continue
            }
            try withSnapshotLock(identity) {
                guard pathExists(path) else { return }
                guard pathExists(path.appending("manifest.json")) else {
                    try quarantineUnlocked(identity)
                    return
                }
                let manifest: PortableArtifactManifest
                do {
                    manifest = try loadManifest(at: path)
                } catch let error as DecodingError {
                    _ = error
                    try quarantineUnlocked(identity)
                    return
                }
                guard manifest.identity == identity,
                    manifest.totalBytes <= limits.maximumSnapshotBytes
                else {
                    try quarantineUnlocked(identity)
                    return
                }
                records.append(
                    PortableSnapshotRecord(
                        identity: identity,
                        path: path,
                        capturedAt: ISO8601DateFormatter().date(
                            from: manifest.capturedAt) ?? .distantPast,
                        totalBytes: try diskUsage(of: path)))
            }
        }
        return records
    }

    private func removeAbandonedCandidates() throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: root.string)
        where name.hasPrefix(".candidate-") {
            let path = root.appending(name)
            let digestStart = name.index(name.startIndex, offsetBy: ".candidate-".count)
            let digestEnd = name.index(
                digestStart,
                offsetBy: 64,
                limitedBy: name.endIndex)
            guard let digestEnd,
                digestEnd < name.endIndex,
                name[digestEnd] == "-",
                let identity = ArtifactDigest(
                    sha256Hex: String(name[digestStart..<digestEnd]))
            else {
                try quarantinePathUnlocked(path)
                continue
            }
            try withSnapshotLock(identity) {
                if pathExists(path) {
                    try FileManager.default.removeItem(atPath: path.string)
                }
            }
        }
    }

    private func diskUsage(of path: FilePath) throws -> UInt64 {
        var paths = [path]
        if try path.stat(followTargetSymlink: false).type == .directory {
            guard let enumerator = FileManager.default.enumerator(atPath: path.string)
            else {
                throw CocoaError(.fileReadUnknown)
            }
            paths += enumerator.compactMap { value in
                (value as? String).map(path.appending)
            }
        }
        var total: UInt64 = 0
        for item in paths {
            let metadata = try item.stat(followTargetSymlink: false)
            guard metadata.type == .regular else { continue }
            let size = UInt64(max(0, metadata.size))
            let (sum, overflow) = total.addingReportingOverflow(size)
            guard !overflow else {
                throw PortableArtifactStoreFailure.invalidSize(item)
            }
            total = sum
        }
        return total
    }

    private func snapshotIdentity(_ name: String) -> ArtifactDigest? {
        let prefix = "sha256-"
        guard name.hasPrefix(prefix) else { return nil }
        return ArtifactDigest(sha256Hex: String(name.dropFirst(prefix.count)))
    }

    private func loadManifest(
        at snapshot: FilePath
    ) throws -> PortableArtifactManifest {
        try JSONDecoder().decode(
            PortableArtifactManifest.self,
            from: Data(
                contentsOf: URL(
                    fileURLWithPath: snapshot.appending("manifest.json").string)))
    }

    private func snapshotDigests(
        _ manifest: PortableArtifactManifest
    ) throws -> [String: ArtifactDigest] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try Dictionary(
            uniqueKeysWithValues: manifest.outputs.map { output in
                (
                    output.slot.rawValue,
                    ArtifactDigest.sha256(try encoder.encode(output))
                )
            })
    }

    private func payloadPath(
        snapshot: FilePath,
        index: Int
    ) -> FilePath {
        let value = String(index)
        let padded = String(repeating: "0", count: max(0, 6 - value.count)) + value
        return snapshot.appending("payload/\(padded)")
    }

    private func snapshotPath(_ identity: ArtifactDigest) -> FilePath {
        root.appending("\(identity.algorithm.rawValue)-\(identity.hexadecimal)")
    }

    private func withSnapshotLock<Result>(
        _ identity: ArtifactDigest,
        _ body: () throws -> Result
    ) throws -> Result {
        let shard = String(identity.hexadecimal.prefix(2))
        return try withLock(
            path: root.appending("locks/snapshot-\(shard).lock"),
            body)
    }

    private func withLock<Result>(
        path: FilePath,
        _ body: () throws -> Result
    ) throws -> Result {
        let lock = try PortableStoreLock(path: path)
        defer { withExtendedLifetime(lock) {} }
        return try body()
    }
}

public enum PortableArtifactStoreFailure: Error, CustomStringConvertible, Sendable {
    case absoluteSymlink(path: FilePath, target: String)
    case corruptSnapshot(task: TaskID, reason: String)
    case escapingSymlink(path: FilePath, target: String)
    case invalidDeclaration(task: TaskID, reason: String)
    case invalidSize(FilePath)
    case snapshotTooLarge(task: TaskID, maximumBytes: UInt64)
    case unsupportedFileType(FilePath)

    public var description: String {
        switch self {
        case .absoluteSymlink(let path, let target):
            "portable snapshot contains absolute symlink '\(path)' -> '\(target)'"
        case .corruptSnapshot(let task, let reason):
            "portable snapshot for '\(task)' is corrupt: \(reason)"
        case .escapingSymlink(let path, let target):
            "portable snapshot contains escaping symlink '\(path)' -> '\(target)'"
        case .invalidDeclaration(let task, let reason):
            "task '\(task)' is not eligible for portable caching: \(reason)"
        case .invalidSize(let path):
            "portable snapshot size overflows at '\(path)'"
        case .snapshotTooLarge(let task, let maximumBytes):
            "portable snapshot for '\(task)' exceeds \(maximumBytes) bytes"
        case .unsupportedFileType(let path):
            "portable snapshot cannot represent the file type at '\(path)'"
        }
    }

    package var isSnapshotCorruption: Bool {
        switch self {
        case .absoluteSymlink, .corruptSnapshot, .escapingSymlink,
            .invalidSize, .unsupportedFileType:
            true
        case .invalidDeclaration, .snapshotTooLarge:
            false
        }
    }
}

private struct PortableArtifactManifest: Codable, Equatable, Sendable {
    let task: TaskID
    let identity: ArtifactDigest
    let capturedAt: String
    let totalBytes: UInt64
    let outputs: [PortableArtifactOutput]
}

private struct PortableArtifactOutput: Codable, Equatable, Sendable {
    let slot: OutputSlotID
    let validation: PathValidation
    let kind: ArtifactValueKind
    let entries: [PortableArtifactEntry]
}

private struct PortableArtifactEntry: Codable, Equatable, Sendable {
    enum FileType: String, Codable, Sendable {
        case file
        case directory
        case symlink
    }

    let relativePath: String
    let type: FileType
    let permissions: UInt16
    let digest: ArtifactDigest?
    let symlinkTarget: String?
}

private struct PortableSnapshotRecord: Sendable {
    let identity: ArtifactDigest
    let path: FilePath
    let capturedAt: Date
    let totalBytes: UInt64
}

private final class PortableStoreLock: @unchecked Sendable {
    private let descriptor: FileDescriptor

    init(path: FilePath) throws {
        try FileManager.default.createDirectory(
            atPath: path.removingLastComponent().string,
            withIntermediateDirectories: true)
        descriptor = try FileDescriptor.open(
            path,
            .readWrite,
            options: .create,
            permissions: [.ownerReadWrite, .groupRead, .otherRead])
        guard collider_lock_exclusive(descriptor.rawValue, 1) == 0 else {
            let code = errno
            try? descriptor.close()
            throw Errno(rawValue: code)
        }
    }

    deinit {
        _ = collider_unlock(descriptor.rawValue)
        try? descriptor.close()
    }
}

private func pathExists(_ path: FilePath) -> Bool {
    (try? path.stat(followTargetSymlink: false)) != nil
}

private func contains(_ child: String, in parent: String) -> Bool {
    let prefix = parent.hasSuffix("/") ? parent : parent + "/"
    return child.hasPrefix(prefix)
}
