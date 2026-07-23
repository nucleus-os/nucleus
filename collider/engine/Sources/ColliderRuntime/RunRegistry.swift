import ColliderCore
import ColliderPlatformC
import Foundation
import SystemPackage
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct RunHandle: Sendable {
    public let id: RunID
    public let directory: FilePath

    public init(id: RunID, directory: FilePath) {
        self.id = id
        self.directory = directory
    }
}

public actor RunRegistry {
    private let root: FilePath
    private var sequences: [RunID: UInt64] = [:]

    public init(root: FilePath) { self.root = root }

    public func begin(command: [String]) throws -> RunHandle {
        let id = RunID(rawValue: runIdentifier())
        let runs = root.appending("runs")
        let directory = runs.appending(id.rawValue)
        try createDirectory(root.appending("locks"))
        try createDirectory(directory.appending("stages"))
        let manifest = RunManifest(
            runID: id,
            command: CredentialScrubber.command(command),
            startedAt: timestamp())
        try writeJSON(manifest, to: directory.appending("manifest.json"))
        try replaceLatest(runID: id, runs: runs)
        sequences[id] = 0
        let handle = RunHandle(id: id, directory: directory)
        try append(
            ColliderEvent(
                sequence: nextSequence(id), timestamp: timestamp(),
                kind: .runStarted, runID: id),
            to: handle)
        return handle
    }

    public func resume(_ id: RunID) throws -> RunHandle {
        let directory = root.appending("runs").appending(id.rawValue)
        let manifestPath = directory.appending("manifest.json")
        var manifest = try JSONDecoder().decode(
            RunManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: manifestPath.string)))
        guard manifest.status == .interrupted else {
            throw RunRegistryFailure.notResumable(id, manifest.status)
        }
        manifest.status = .running
        manifest.finishedAt = nil
        manifest.failedTask = nil
        manifest.resumeCount = (manifest.resumeCount ?? 0) + 1
        manifest.resumedAt = (manifest.resumedAt ?? []) + [timestamp()]
        try writeJSON(manifest, to: manifestPath)
        let handle = RunHandle(id: id, directory: directory)
        sequences[id] = existingEventCount(handle)
        try replaceLatest(runID: id, runs: root.appending("runs"))
        try append(
            ColliderEvent(
                sequence: nextSequence(id),
                timestamp: timestamp(),
                kind: .runStarted,
                runID: id,
                message: "resumed"),
            to: handle)
        return handle
    }

    public func recordPlan(
        _ plan: [TaskPlanEntry],
        in run: RunHandle
    ) throws {
        let path = run.directory.appending("manifest.json")
        var manifest = try JSONDecoder().decode(
            RunManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: path.string)))
        let identities = Dictionary(uniqueKeysWithValues: plan.map {
            ($0.task.rawValue, $0.identity)
        })
        if (manifest.resumeCount ?? 0) > 0,
           let recorded = manifest.plannedTasks,
           recorded != identities
        {
            throw RunRegistryFailure.resumptionIdentityChanged(run.id)
        }
        manifest.plannedTasks = identities
        try writeJSON(manifest, to: path)
    }

    public func record(
        kind: ColliderEvent.Kind,
        task: TaskID? = nil,
        message: String? = nil,
        in run: RunHandle
    ) throws {
        if kind == .taskFailed, let task {
            try updateManifest(run) { $0.failedTask = task }
        }
        try append(
            ColliderEvent(
                sequence: nextSequence(run.id), timestamp: timestamp(),
                kind: kind,
                runID: run.id,
                task: task,
                message: message.map(CredentialScrubber.text)),
            to: run)
    }

    public func recordTaskDuration(
        _ nanoseconds: UInt64,
        task: TaskID,
        in run: RunHandle
    ) throws {
        try updateManifest(run) {
            $0.taskDurationsNanoseconds[task.rawValue] = nanoseconds
        }
    }

    public func recordActiveArtifact(
        _ digest: ArtifactDigest,
        name: String,
        in run: RunHandle
    ) throws {
        try updateManifest(run) { $0.activeArtifacts[name] = digest }
    }

    public func finish(
        _ run: RunHandle,
        status: RunStatus,
        failedTask: TaskID? = nil
    ) throws {
        let manifestPath = run.directory.appending("manifest.json")
        var manifest = try JSONDecoder().decode(
            RunManifest.self, from: Data(contentsOf: URL(fileURLWithPath: manifestPath.string)))
        manifest.status = status
        manifest.failedTask = failedTask
        manifest.finishedAt = timestamp()
        try writeJSON(manifest, to: manifestPath)
        try record(kind: .runFinished, task: failedTask, message: status.rawValue, in: run)
    }

    public func appendLog(_ bytes: [UInt8], stage: TaskID? = nil, in run: RunHandle) throws {
        let scrubbed = CredentialScrubber.bytes(bytes)
        try appendBytes(scrubbed, to: run.directory.appending("run.log"))
        if let stage {
            try appendBytes(
                scrubbed,
                to: run.directory.appending("stages")
                    .appending(safeName(stage.rawValue) + ".log"))
        }
    }

    private func nextSequence(_ id: RunID) -> UInt64 {
        let value = sequences[id, default: 0]
        sequences[id] = value + 1
        return value
    }

    private func existingEventCount(_ run: RunHandle) -> UInt64 {
        guard let data = try? Data(contentsOf: URL(
            fileURLWithPath: run.directory.appending("events.jsonl").string))
        else { return 0 }
        return UInt64(data.reduce(into: 0) { count, byte in
            if byte == 0x0a { count += 1 }
        })
    }

    private func updateManifest(
        _ run: RunHandle,
        _ update: (inout RunManifest) -> Void
    ) throws {
        let path = run.directory.appending("manifest.json")
        var manifest = try JSONDecoder().decode(
            RunManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: path.string)))
        update(&manifest)
        try writeJSON(manifest, to: path)
    }

    private func append(_ event: ColliderEvent, to run: RunHandle) throws {
        var data = try JSONEncoder.stable.encode(event)
        data.append(0x0a)
        try appendBytes(Array(data), to: run.directory.appending("events.jsonl"))
    }

    private func replaceLatest(runID: RunID, runs: FilePath) throws {
        let candidate = root.appending(".latest-\(getpid())")
        try? FileManager.default.removeItem(atPath: candidate.string)
        guard collider_symlink("runs/\(runID.rawValue)", candidate.string) == 0 else {
            throw Errno(rawValue: errno)
        }
        do {
            try replace(candidate, with: root.appending("latest"))
        } catch {
            try? FileManager.default.removeItem(atPath: candidate.string)
            throw error
        }
        try synchronizeDirectory(root)
        _ = runs
    }
}

public enum RunRegistryFailure: Error, CustomStringConvertible, Sendable {
    case notResumable(RunID, RunStatus)
    case resumptionIdentityChanged(RunID)

    public var description: String {
        switch self {
        case .notResumable(let id, let status):
            "run '\(id)' has status '\(status.rawValue)' and cannot be resumed"
        case .resumptionIdentityChanged(let id):
            "run '\(id)' cannot resume because its resolved task identities changed"
        }
    }
}

private extension JSONEncoder {
    static var stable: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private func writeJSON<T: Encodable>(_ value: T, to path: FilePath) throws {
    var data = try JSONEncoder.stable.encode(value)
    data.append(0x0a)
    let candidate = FilePath(path.string + ".candidate-\(getpid())")
    let descriptor = try FileDescriptor.open(
        candidate, .writeOnly, options: [.create, .truncate], permissions: .ownerReadWrite)
    do {
        try descriptor.writeAll(data)
        guard collider_sync_file(descriptor.rawValue) == 0 else { throw Errno(rawValue: errno) }
        try descriptor.close()
        try replace(candidate, with: path)
        try synchronizeDirectory(path.removingLastComponent())
    } catch {
        try? descriptor.close()
        try? FileManager.default.removeItem(atPath: candidate.string)
        throw error
    }
}

private func appendBytes(_ bytes: [UInt8], to path: FilePath) throws {
    let descriptor = try FileDescriptor.open(
        path, .writeOnly, options: [.create, .append], permissions: .ownerReadWrite)
    defer { try? descriptor.close() }
    try descriptor.writeAll(bytes)
    guard collider_sync_file(descriptor.rawValue) == 0 else {
        throw Errno(rawValue: errno)
    }
}

private func replace(_ source: FilePath, with destination: FilePath) throws {
    guard collider_replace(source.string, destination.string) == 0 else {
        throw Errno(rawValue: errno)
    }
}

private func synchronizeDirectory(_ path: FilePath) throws {
    let descriptor = try FileDescriptor.open(path, .readOnly)
    defer { try? descriptor.close() }
    guard collider_sync_directory(descriptor.rawValue) == 0 else {
        throw Errno(rawValue: errno)
    }
}

private func createDirectory(_ path: FilePath) throws {
    try FileManager.default.createDirectory(
        atPath: path.string, withIntermediateDirectories: true)
}

private func safeName(_ value: String) -> String {
    value.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
        .reduce(into: "") { $0.append($1) }
}

private func timestamp() -> String {
    ISO8601DateFormatter().string(from: Date())
}

private func runIdentifier() -> String {
    timestamp().replacingOccurrences(of: ":", with: "-") + "-\(getpid())"
}
