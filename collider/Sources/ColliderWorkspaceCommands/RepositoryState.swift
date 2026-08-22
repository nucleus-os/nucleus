import ColliderCore
import ColliderPersistence
import Foundation
import SystemPackage

struct RunListEntry: Codable, Equatable, Sendable {
    let runID: String
    let command: [String]
    let startedAt: String
    let finishedAt: String?
    let status: RunStatus
    let failedTask: String?
    let domain: String
    let sourceAuthority: ProductArtifactSourceAuthority
    let sourceCommit: String?
}

struct RunListReport: Codable, Equatable, Sendable {
    let runs: [RunListEntry]
}

struct RunLogEntry: Codable, Equatable, Sendable {
    let kind: String
    let task: String?
    let relativePath: String
    let path: String
    let byteCount: UInt64
}

struct RunShowReport: Codable, Sendable {
    let manifest: RunManifest
    let observedState: ReducedRunState
    let progress: RunProgressSnapshot
    let logs: [RunLogEntry]
}

struct RepositoryStatusReport: Codable, Sendable {
    let status: String
    let activeRun: RunListEntry?
    let observedState: ReducedRunState?
    let progress: RunProgressSnapshot?
    let latestRun: RunListEntry?
}

struct RunLogPathReport: Codable, Equatable, Sendable {
    let runID: String
    let task: String?
    let path: String
}

struct RepositoryState {
    let context: WorkspaceContext

    private var registry: RunRegistry {
        RunRegistry(root: context.logRoot.appending("runs"))
    }

    func status() async throws {
        let snapshots = try await registry.recordedRuns()
        let active = snapshots.first(where: { $0.manifest.status == .running })
        let latest = snapshots.first
        let observed: ReducedRunState?
        let progress: RunProgressSnapshot?
        if let active {
            observed = try await registry.reducedEvents(in: active)
            progress = try await registry.progressSnapshot(in: active)
        } else {
            observed = nil
            progress = nil
        }
        let report = RepositoryStatusReport(
            status: active == nil ? "idle" : "running",
            activeRun: active.map(listEntry),
            observedState: observed,
            progress: progress,
            latestRun: latest.map(listEntry))
        var lines = ["status: \(report.status)"]
        if let activeRun = report.activeRun {
            lines += runLines(activeRun)
            if let progress {
                lines += progressLines(progress)
            }
        } else if let latestRun = report.latestRun {
            lines.append("latest run: \(latestRun.runID) (\(latestRun.status.rawValue))")
        }
        try context.console.report(report, text: lines.joined(separator: "\n"))
    }

    func listRuns(limit: Int) async throws {
        let entries = try await registry.recordedRuns(limit: limit).map(listEntry)
        let text = entries.map {
            "\($0.runID)\t\($0.status.rawValue)\t\($0.domain)\t"
                + CommandConsole.render(command: Array($0.command.dropFirst()))
                + verificationSuffix($0)
        }.joined(separator: "\n")
        try context.console.report(RunListReport(runs: entries), text: text)
    }

    func showRun(_ requested: String?) async throws {
        let snapshot = try await resolve(requested)
        let observed = try await registry.reducedEvents(in: snapshot)
        let progress = try await registry.progressSnapshot(in: snapshot)
        let logs = try await registry.logs(in: snapshot).map(logEntry)
        let report = RunShowReport(
            manifest: snapshot.manifest,
            observedState: observed,
            progress: progress,
            logs: logs)
        var lines = runLines(listEntry(snapshot))
        lines += progressLines(progress)
        if let tasks = snapshot.manifest.tasks {
            for (task, record) in tasks.sorted(by: { $0.key < $1.key }) {
                lines.append(
                    "task: \(task)\t\(taskState(record))\t\(record.plan.explanation)")
            }
        }
        if !snapshot.manifest.activeArtifacts.isEmpty {
            for (name, digest) in snapshot.manifest.activeArtifacts.sorted(by: {
                $0.key < $1.key
            }) {
                lines.append("artifact: \(name)\t\(digest)")
            }
        }
        lines.append("logs: \(logs.count)")
        try context.console.report(report, text: lines.joined(separator: "\n"))
    }

    func listLogs(_ requested: String?) async throws {
        let snapshot = try await resolve(requested)
        let logs = try await registry.logs(in: snapshot).map(logEntry)
        let text = logs.map {
            let task = $0.task.map { "\t\($0)" } ?? ""
            return "\($0.byteCount)\t\($0.relativePath)\(task)"
        }.joined(separator: "\n")
        try context.console.report(logs, text: text)
    }

    func logPath(_ requested: String?, task: String?) async throws -> RunLogPathReport {
        let snapshot = try await resolve(requested)
        let logs = try await registry.logs(in: snapshot)
        let selected: RecordedRunLog?
        if let task {
            selected = logs.first { $0.task?.rawValue == task }
        } else {
            selected = logs.first { $0.kind == .run }
        }
        guard let selected else {
            let description = task.map { "task '\($0)'" } ?? "run"
            throw WorkspaceFailure.message(
                "\(description) has no retained log in run '\(snapshot.run.id)'")
        }
        return RunLogPathReport(
            runID: snapshot.run.id.rawValue,
            task: selected.task?.rawValue,
            path: selected.path.string)
    }

    func reportLogPath(_ requested: String?, task: String?) async throws {
        let report = try await logPath(requested, task: task)
        try context.console.report(report, text: report.path)
    }

    func tail(
        _ requested: String?,
        task: String?,
        lineCount: Int,
        follow: Bool
    ) async throws {
        let report = try await logPath(requested, task: task)
        var arguments = ["-n", String(lineCount)]
        if follow { arguments.append("-f") }
        arguments.append(report.path)
        try await context.run(
            "tail",
            arguments,
            acceptedExitStatuses: [0, interruptedProcessExitStatus])
    }

    private func resolve(_ requested: String?) async throws -> RecordedRunSnapshot {
        let id = requested.flatMap { $0 == "latest" ? nil : RunID(rawValue: $0) }
        return try await registry.recordedRun(id)
    }

    private func listEntry(_ snapshot: RecordedRunSnapshot) -> RunListEntry {
        let manifest = snapshot.manifest
        let provenance = manifest.provenance ?? .local
        return RunListEntry(
            runID: manifest.runID.rawValue,
            command: manifest.command,
            startedAt: manifest.startedAt,
            finishedAt: manifest.finishedAt,
            status: manifest.status,
            failedTask: manifest.failedTask?.rawValue,
            domain: domain(of: manifest),
            sourceAuthority: provenance.sourceAuthority,
            sourceCommit: provenance.sourceCommit)
    }

    private func logEntry(_ log: RecordedRunLog) -> RunLogEntry {
        RunLogEntry(
            kind: log.kind.rawValue,
            task: log.task?.rawValue,
            relativePath: log.relativePath,
            path: log.path.string,
            byteCount: log.byteCount)
    }

    private func runLines(_ run: RunListEntry) -> [String] {
        var lines = [
            "run: \(run.runID)",
            "status: \(run.status.rawValue)",
            "started: \(run.startedAt)",
            "command: \(CommandConsole.render(command: run.command))",
        ]
        if let finishedAt = run.finishedAt { lines.append("finished: \(finishedAt)") }
        if let failedTask = run.failedTask { lines.append("failed task: \(failedTask)") }
        lines.append("source authority: \(run.sourceAuthority.rawValue)")
        if let sourceCommit = run.sourceCommit {
            lines.append("source commit: \(sourceCommit)")
        }
        return lines
    }

    /// Local runs are the ordinary case and carry no marker. A verification
    /// run names the revision it verified, so a listing answers which record
    /// belongs to a given push without correlating timestamps.
    private func verificationSuffix(_ run: RunListEntry) -> String {
        guard run.sourceAuthority == .protectedMain else { return "" }
        guard let commit = run.sourceCommit else { return "\tprotected-main" }
        return "\tprotected-main \(commit.prefix(12))"
    }

    private func taskState(_ record: RunTaskRecord) -> String {
        if let outcome = record.outcome { return outcome.rawValue }
        return record.plan.isClean ? TaskRunOutcome.localClean.rawValue : "pending"
    }

    private func progressLines(_ progress: RunProgressSnapshot) -> [String] {
        let percent = Int((progress.completionFraction * 100).rounded(.down))
        var lines = [
            "progress: \(progress.phase.rawValue)  "
                + "\(progress.completedTaskCount)/\(progress.totalTaskCount)  \(percent)%"
        ]
        if let hostPhase = progress.hostPhase {
            let count =
                if let completed = hostPhase.completedItems,
                    let total = hostPhase.totalItems
                {
                    " \(completed)/\(total)"
                } else {
                    ""
                }
            lines.append("host phase: \(hostPhase.name)\(count)")
        }
        for row in progress.activeRows {
            lines.append("active task: \(row.task.rawValue) [\(row.lane.rawValue)]")
        }
        if progress.residualActiveRowCount > 0 {
            lines.append("active tasks omitted: \(progress.residualActiveRowCount)")
        }
        return lines
    }

    private func domain(of run: RunManifest) -> String {
        guard run.command.count > 1 else { return "runtime" }
        return switch run.command[1] {
        case "swift-sdk": "swift-sdk"
        case "android", "android-runtime": "android"
        case "browser": "browser"
        default: "runtime"
        }
    }
}
