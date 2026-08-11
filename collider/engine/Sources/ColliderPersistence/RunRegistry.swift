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

/// A run the registry has on disk, named by its manifest rather than by the
/// shape of its directory name.
public struct RecordedRun: Hashable, Sendable {
    public let id: RunID
    public let directory: FilePath

    public init(id: RunID, directory: FilePath) {
        self.id = id
        self.directory = directory
    }
}

public struct RecordedRunSnapshot: Sendable {
    public let run: RecordedRun
    public let manifest: RunManifest

    public init(run: RecordedRun, manifest: RunManifest) {
        self.run = run
        self.manifest = manifest
    }
}

public struct RecordedRunLog: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case run
        case stage
    }

    public let kind: Kind
    public let task: TaskID?
    public let relativePath: String
    public let path: FilePath
    public let byteCount: UInt64

    public init(
        kind: Kind,
        task: TaskID?,
        relativePath: String,
        path: FilePath,
        byteCount: UInt64
    ) {
        self.kind = kind
        self.task = task
        self.relativePath = relativePath
        self.path = path
        self.byteCount = byteCount
    }
}

public actor RunRegistry {
    public static let defaultRetainedRunCount = 20

    private let root: FilePath
    private var sequences: [RunID: UInt64] = [:]
    private var leases: [RunID: RunLease] = [:]

    public init(root: FilePath) { self.root = root }

    public func begin(command: [String]) throws -> RunHandle {
        let id = RunID(rawValue: runIdentifier())
        let runs = root.appending("runs")
        let directory = runs.appending(id.rawValue)
        try createDirectory(root.appending("locks"))
        try createDirectory(directory.appending("stages"))
        guard let lease = try RunLease.tryAcquire(in: directory) else {
            throw RunRegistryFailure.activeRunOwned(id)
        }
        let manifest = RunManifest(
            runID: id,
            command: CredentialScrubber.command(command),
            startedAt: timestamp())
        try writeJSON(manifest, to: directory.appending("manifest.json"))
        try replaceLatest(runID: id, runs: runs)
        sequences[id] = 0
        leases[id] = lease
        let handle = RunHandle(id: id, directory: directory)
        try append(.runStarted(resumed: false), to: handle)
        return handle
    }

    public func resume(_ id: RunID) throws -> RunHandle {
        let directory = root.appending("runs").appending(id.rawValue)
        guard let lease = try RunLease.tryAcquire(in: directory) else {
            throw RunRegistryFailure.activeRunOwned(id)
        }
        let manifestPath = directory.appending("manifest.json")
        var manifest = try JSONDecoder().decode(
            RunManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: manifestPath.string)))
        guard manifest.status == .interrupted || manifest.status == .failed else {
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
        leases[id] = lease
        try replaceLatest(runID: id, runs: root.appending("runs"))
        try append(.runStarted(resumed: true), to: handle)
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
        if (manifest.resumeCount ?? 0) > 0,
            let recorded = manifest.tasks
        {
            for entry in plan where entry.isClean {
                guard recorded[entry.task.rawValue]?.plan.identity == entry.identity else {
                    throw RunRegistryFailure.resumptionIdentityChanged(run.id)
                }
            }
        }
        manifest.tasks = Dictionary(
            uniqueKeysWithValues: plan.map { entry in
                let outcome: TaskRunOutcome?
                if entry.isClean {
                    outcome = .localClean
                } else {
                    outcome = nil
                }
                return (
                    entry.task.rawValue,
                    RunTaskRecord(plan: entry, outcome: outcome)
                )
            })
        try writeJSON(manifest, to: path)
    }

    public func record(
        _ payload: RunEvent.Payload,
        in run: RunHandle
    ) throws {
        if case .task(.failed(let task, _)) = payload {
            try updateManifest(run) { $0.failedTask = task }
        }
        try append(scrubbed(payload), to: run)
    }

    public func recordTaskDuration(
        _ nanoseconds: UInt64,
        task: TaskID,
        in run: RunHandle
    ) throws {
        try updateManifest(run) {
            guard var record = $0.tasks?[task.rawValue] else {
                throw RunRegistryFailure.unplannedTaskMetadata(task)
            }
            record.durationNanoseconds = nanoseconds
            $0.tasks?[task.rawValue] = record
        }
    }

    public func recordTaskOutcome(
        _ outcome: TaskRunOutcome,
        task: TaskID,
        in run: RunHandle
    ) throws {
        try updateManifest(run) {
            guard var record = $0.tasks?[task.rawValue] else {
                throw RunRegistryFailure.unplannedTaskMetadata(task)
            }
            record.outcome = outcome
            $0.tasks?[task.rawValue] = record
        }
    }

    public func recordTaskObservations(
        _ observations: TaskExecutionObservations,
        task: TaskID,
        in run: RunHandle
    ) throws {
        guard !observations.isEmpty else { return }
        let scrubbed = TaskExecutionObservations(
            containerExecutions: observations.containerExecutions)
        try updateManifest(run) {
            guard var record = $0.tasks?[task.rawValue] else {
                throw RunRegistryFailure.unplannedTaskMetadata(task)
            }
            record.observations = scrubbed
            $0.tasks?[task.rawValue] = record
        }
    }

    public func recordPlanningDuration(
        _ nanoseconds: UInt64,
        in run: RunHandle
    ) throws {
        try updateManifest(run) {
            $0.planningDurationNanoseconds = nanoseconds
        }
    }

    public func recordPlanningMetrics(
        selectedInputHashingDurationNanoseconds: UInt64,
        swiftPMInvocationCount: Int,
        in run: RunHandle
    ) throws {
        try updateManifest(run) {
            $0.selectedInputHashingDurationNanoseconds =
                selectedInputHashingDurationNanoseconds
            $0.swiftPMInvocationCount = swiftPMInvocationCount
        }
    }

    public func recordExecutionDuration(
        _ nanoseconds: UInt64,
        in run: RunHandle
    ) throws {
        try updateManifest(run) {
            $0.executionDurationNanoseconds = nanoseconds
        }
    }

    public func recordExecutionMetrics(
        criticalPathDurationNanoseconds: UInt64,
        schedulingWaitDurationNanoseconds: UInt64,
        in run: RunHandle
    ) throws {
        try updateManifest(run) {
            $0.criticalPathDurationNanoseconds = criticalPathDurationNanoseconds
            $0.schedulingWaitDurationNanoseconds = schedulingWaitDurationNanoseconds
        }
    }

    public func recordActiveArtifact(
        _ digest: ArtifactDigest,
        name: String,
        in run: RunHandle
    ) throws {
        try updateManifest(run) { $0.activeArtifacts[name] = digest }
        try record(
            .artifact(ArtifactEvent(name: name, digest: digest)),
            in: run)
    }

    public func finish(
        _ run: RunHandle,
        status: RunStatus,
        failedTask: TaskID? = nil,
        retainingRuns: Int = RunRegistry.defaultRetainedRunCount
    ) throws {
        defer { leases[run.id] = nil }
        let manifestPath = run.directory.appending("manifest.json")
        var manifest = try JSONDecoder().decode(
            RunManifest.self, from: Data(contentsOf: URL(fileURLWithPath: manifestPath.string)))
        manifest.status = status
        manifest.failedTask = failedTask
        manifest.finishedAt = timestamp()
        try writeJSON(manifest, to: manifestPath)
        try record(
            .terminal(TerminalRunEvent(status: status, failedTask: failedTask)),
            in: run)
        try remove(reclaimableRuns(keeping: retainingRuns))
    }

    /// Converts a running record whose process lease no longer exists into an
    /// interrupted run. The kernel owns lease release, so this does not infer
    /// liveness from timestamps or process identifiers.
    @discardableResult
    public func reconcileAbandonedRuns() throws -> [RunID] {
        var reconciled: [RunID] = []
        for snapshot in try recordedRuns().reversed()
        where snapshot.manifest.status == .running {
            let id = snapshot.run.id
            if leases[id] != nil { continue }
            guard let lease = try RunLease.tryAcquire(in: snapshot.run.directory) else {
                continue
            }
            try withExtendedLifetime(lease) {
                let handle = RunHandle(id: id, directory: snapshot.run.directory)
                sequences[id] = existingEventCount(handle)
                try updateManifest(handle) {
                    $0.status = .interrupted
                    $0.finishedAt = timestamp()
                }
                try append(
                    .interruption(
                        InterruptionEvent(
                            reason: "owning Collider process exited before finalization")),
                    to: handle)
                try append(
                    .terminal(TerminalRunEvent(status: .interrupted)),
                    to: handle)
            }
            reconciled.append(id)
        }
        return reconciled
    }

    public func stageLogPath(for task: TaskID, in run: RunHandle) -> FilePath {
        run.directory.appending("stages")
            .appending(safeName(task.rawValue) + ".log")
    }

    /// Captured task output arrives in whatever chunks the task writes, and the
    /// writer blocks until the chunk lands. Synchronizing each chunk would put
    /// storage latency in the path of every line a build prints; the manifest
    /// and the event stream carry the durable record of a run instead.
    public func appendLog(_ bytes: [UInt8], stage: TaskID? = nil, in run: RunHandle) throws {
        let scrubbed = CredentialScrubber.bytes(bytes)
        try appendBytes(
            scrubbed,
            to: run.directory.appending("run.log"),
            synchronized: false)
        if let stage {
            try appendBytes(
                scrubbed,
                to: run.directory.appending("stages")
                    .appending(safeName(stage.rawValue) + ".log"),
                synchronized: false)
        }
    }

    public func recordedRuns(limit: Int? = nil) throws -> [RecordedRunSnapshot] {
        let runs = root.appending("runs")
        let snapshots =
            ((try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: runs.string),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])) ?? [])
            .compactMap { url -> RecordedRunSnapshot? in
                guard
                    let data = try? Data(
                        contentsOf: url.appendingPathComponent("manifest.json")),
                    let manifest = try? JSONDecoder().decode(
                        RunManifest.self, from: data)
                else { return nil }
                return RecordedRunSnapshot(
                    run: RecordedRun(
                        id: manifest.runID,
                        directory: FilePath(url.path)),
                    manifest: manifest)
            }
            .sorted {
                if $0.manifest.startedAt != $1.manifest.startedAt {
                    return $0.manifest.startedAt > $1.manifest.startedAt
                }
                return $0.run.id.rawValue > $1.run.id.rawValue
            }
        guard let limit else { return snapshots }
        return Array(snapshots.prefix(max(0, limit)))
    }

    public func recordedRun(
        _ id: RunID? = nil,
        preferRunning: Bool = false
    ) throws -> RecordedRunSnapshot {
        let runs = try recordedRuns()
        if let id {
            guard let run = runs.first(where: { $0.run.id == id }) else {
                throw RunRegistryFailure.unknownRun(id)
            }
            return run
        }
        if preferRunning, let running = runs.first(where: { $0.manifest.status == .running }) {
            return running
        }
        guard let latest = runs.first else { throw RunRegistryFailure.noRuns }
        return latest
    }

    public func logs(in snapshot: RecordedRunSnapshot) throws -> [RecordedRunLog] {
        let manager = FileManager.default
        var tasksByPath: [String: TaskID] = [:]
        for taskName in snapshot.manifest.tasks.map({ Array($0.keys) }) ?? [] {
            let task = TaskID(rawValue: taskName)
            tasksByPath["stages/\(safeName(taskName)).log"] = task
        }
        var paths: [(RecordedRunLog.Kind, String)] = []
        let runLog = snapshot.run.directory.appending("run.log")
        if manager.fileExists(atPath: runLog.string) {
            paths.append((.run, "run.log"))
        }
        let stages = snapshot.run.directory.appending("stages")
        let stageNames =
            (try? manager.contentsOfDirectory(atPath: stages.string)) ?? []
        paths +=
            stageNames
            .filter { $0.hasSuffix(".log") }
            .sorted()
            .map { (.stage, "stages/\($0)") }
        return try paths.map { kind, relativePath in
            let path = snapshot.run.directory.appending(relativePath)
            let attributes = try manager.attributesOfItem(atPath: path.string)
            return RecordedRunLog(
                kind: kind,
                task: tasksByPath[relativePath],
                relativePath: relativePath,
                path: path,
                byteCount: (attributes[.size] as? NSNumber)?.uint64Value ?? 0)
        }
    }

    public func reducedEvents(
        in snapshot: RecordedRunSnapshot,
        maximumEventBytes: Int = 1_048_576
    ) throws -> ReducedRunState {
        let path = snapshot.run.directory.appending("events.jsonl")
        guard FileManager.default.fileExists(atPath: path.string) else {
            return ReducedRunState()
        }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path.string))
        defer { try? handle.close() }
        var reducer = RunEventReducer()
        var pending = Data()
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0a) {
                let line = pending[..<newline]
                pending.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                guard line.count <= maximumEventBytes else {
                    throw RunRegistryFailure.eventTooLarge(snapshot.run.id)
                }
                do {
                    try reducer.consume(
                        JSONDecoder().decode(RunEvent.self, from: Data(line)))
                } catch {
                    throw RunRegistryFailure.invalidEvent(
                        snapshot.run.id, String(describing: error))
                }
            }
            guard pending.count <= maximumEventBytes else {
                throw RunRegistryFailure.eventTooLarge(snapshot.run.id)
            }
        }
        return reducer.state
    }

    /// Terminal run history the registry may reclaim, oldest first. The newest
    /// `keeping` terminal runs and the newest failed run are preserved. Every
    /// running record is excluded because another process may still own it.
    /// Recency is the recorded start, not directory metadata.
    public func reclaimableRuns(keeping: Int) -> [RecordedRun] {
        let runs = root.appending("runs")
        let recorded =
            ((try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: runs.string),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])) ?? [])
            .compactMap { url -> (RecordedRun, RunManifest)? in
                guard
                    let data = try? Data(
                        contentsOf: url.appendingPathComponent(
                            "manifest.json")),
                    let manifest = try? JSONDecoder().decode(
                        RunManifest.self, from: data)
                else { return nil }
                return (
                    RecordedRun(id: manifest.runID, directory: FilePath(url.path)),
                    manifest
                )
            }
            .sorted {
                if $0.1.startedAt != $1.1.startedAt {
                    return $0.1.startedAt > $1.1.startedAt
                }
                return $0.0.id.rawValue > $1.0.id.rawValue
            }
        let terminal = recorded.filter { $0.1.status != .running }
        var retained = Set(terminal.prefix(max(0, keeping)).map(\.0.id))
        if let newestFailed = terminal.first(where: { $0.1.status == .failed }) {
            retained.insert(newestFailed.0.id)
        }
        return
            terminal
            .filter { !retained.contains($0.0.id) }
            .reversed()
            .map(\.0)
    }

    public func remove(_ runs: [RecordedRun]) throws {
        for run in runs {
            if FileManager.default.fileExists(atPath: run.directory.string) {
                try FileManager.default.removeItem(atPath: run.directory.string)
            }
        }
    }

    private func existingEventCount(_ run: RunHandle) -> UInt64 {
        guard
            let data = try? Data(
                contentsOf: URL(
                    fileURLWithPath: run.directory.appending("events.jsonl").string))
        else { return 0 }
        return UInt64(
            data.reduce(into: 0) { count, byte in
                if byte == 0x0a { count += 1 }
            })
    }

    private func updateManifest(
        _ run: RunHandle,
        _ update: (inout RunManifest) throws -> Void
    ) throws {
        let path = run.directory.appending("manifest.json")
        var manifest = try JSONDecoder().decode(
            RunManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: path.string)))
        try update(&manifest)
        try writeJSON(manifest, to: path)
    }

    private func append(_ event: RunEvent, to run: RunHandle) throws {
        var data = try JSONEncoder.stable.encode(event)
        data.append(0x0a)
        try appendBytes(
            Array(data),
            to: run.directory.appending("events.jsonl"),
            synchronized: false)
    }

    private func append(_ payload: RunEvent.Payload, to run: RunHandle) throws {
        let sequence = sequences[run.id, default: 0]
        try append(
            RunEvent(
                sequence: sequence,
                timestamp: timestamp(),
                runID: run.id,
                payload: payload),
            to: run)
        sequences[run.id] = sequence + 1
    }

    private func scrubbed(_ payload: RunEvent.Payload) -> RunEvent.Payload {
        switch payload {
        case .runStarted, .download, .artifact, .terminal:
            payload
        case .task(let event):
            switch event {
            case .started, .succeeded, .cancelled:
                payload
            case .skipped(let task, let explanation):
                .task(
                    .skipped(
                        task: task,
                        explanation: CredentialScrubber.text(explanation)))
            case .failed(let task, let failure):
                .task(.failed(task: task, failure: scrubbed(failure)))
            }
        case .operation(let event):
            switch event {
            case .started(let context):
                .operation(.started(scrubbed(context)))
            case .finished(let result):
                .operation(
                    .finished(
                        OperationResult(
                            context: scrubbed(result.context),
                            status: result.status,
                            signal: result.signal,
                            timedOut: result.timedOut)))
            case .failed(let failure):
                .operation(.failed(scrubbed(failure)))
            }
        case .wait(let event):
            switch event {
            case .started(let task, let resource):
                .wait(
                    .started(
                        task: task,
                        resource: CredentialScrubber.text(resource)))
            case .finished(let task, let resource):
                .wait(
                    .finished(
                        task: task,
                        resource: CredentialScrubber.text(resource)))
            }
        case .interruption(let event):
            .interruption(
                InterruptionEvent(
                    signal: event.signal,
                    reason: CredentialScrubber.text(event.reason)))
        }
    }

    private func scrubbed(_ context: OperationContext) -> OperationContext {
        let command = CredentialScrubber.command(context.command)
        return OperationContext(
            task: context.task,
            operation: CredentialScrubber.text(context.operation),
            command: command,
            invocation: CredentialScrubber.renderedCommand(command),
            workingDirectory: CredentialScrubber.text(context.workingDirectory),
            logPath: context.logPath.map(CredentialScrubber.text))
    }

    private func scrubbed(_ failure: ExecutionFailure) -> ExecutionFailure {
        ExecutionFailure(
            task: failure.task,
            operation: failure.operation,
            command: failure.command,
            status: failure.status,
            signal: failure.signal,
            invocation: failure.invocation,
            workingDirectory: failure.workingDirectory,
            logPath: failure.logPath,
            reason: failure.reason)
    }

    private func replaceLatest(runID: RunID, runs: FilePath) throws {
        let candidate = root.appending(".latest-\(getpid())")
        try? FileManager.default.removeItem(atPath: candidate.string)
        guard
            unsafe collider_symlink(
                "runs/\(runID.rawValue)",
                candidate.string) == 0
        else {
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
    case noRuns
    case unknownRun(RunID)
    case invalidEvent(RunID, String)
    case eventTooLarge(RunID)
    case notResumable(RunID, RunStatus)
    case activeRunOwned(RunID)
    case resumptionIdentityChanged(RunID)
    case unplannedTaskMetadata(TaskID)

    public var description: String {
        switch self {
        case .noRuns:
            "no Collider runs have been recorded"
        case .unknownRun(let id):
            "unknown Collider run '\(id)'"
        case .invalidEvent(let id, let reason):
            "run '\(id)' contains an invalid event: \(reason)"
        case .eventTooLarge(let id):
            "run '\(id)' contains an event larger than the inspection limit"
        case .notResumable(let id, let status):
            "run '\(id)' has status '\(status.rawValue)' and cannot be resumed"
        case .activeRunOwned(let id):
            "run '\(id)' is still owned by another Collider process"
        case .resumptionIdentityChanged(let id):
            "run '\(id)' cannot resume because its resolved task identities changed"
        case .unplannedTaskMetadata(let task):
            "cannot record execution metadata for unplanned task '\(task)'"
        }
    }
}

private final class RunLease {
    private let descriptor: FileDescriptor

    private init(descriptor: FileDescriptor) {
        self.descriptor = descriptor
    }

    static func tryAcquire(in directory: FilePath) throws -> RunLease? {
        let descriptor = try FileDescriptor.open(
            directory.appending("run.lock"),
            .readWrite,
            options: .create,
            permissions: [.ownerReadWrite, .groupRead, .otherRead])
        guard collider_lock_exclusive(descriptor.rawValue, 0) == 0 else {
            let code = errno
            try? descriptor.close()
            if code == EWOULDBLOCK || code == EAGAIN { return nil }
            throw Errno(rawValue: code)
        }
        return RunLease(descriptor: descriptor)
    }

    deinit {
        _ = collider_unlock(descriptor.rawValue)
        try? descriptor.close()
    }
}

extension JSONEncoder {
    fileprivate static var stable: JSONEncoder {
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
    } catch {
        try? descriptor.close()
        try? FileManager.default.removeItem(atPath: candidate.string)
        throw error
    }
    try descriptor.close()
    do {
        try replace(candidate, with: path)
        try synchronizeDirectory(path.removingLastComponent())
    } catch {
        try? FileManager.default.removeItem(atPath: candidate.string)
        throw error
    }
}

private func appendBytes(
    _ bytes: [UInt8],
    to path: FilePath,
    synchronized: Bool = true
) throws {
    let descriptor = try FileDescriptor.open(
        path, .writeOnly, options: [.create, .append], permissions: .ownerReadWrite)
    defer { try? descriptor.close() }
    try descriptor.writeAll(bytes)
    guard synchronized else { return }
    guard collider_sync_file(descriptor.rawValue) == 0 else {
        throw Errno(rawValue: errno)
    }
}

private func replace(_ source: FilePath, with destination: FilePath) throws {
    guard unsafe collider_replace(source.string, destination.string) == 0 else {
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
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}

private func runIdentifier() -> String {
    timestamp().replacingOccurrences(of: ":", with: "-") + "-\(getpid())"
}
