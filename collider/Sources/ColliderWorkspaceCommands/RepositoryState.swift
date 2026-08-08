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
    let logs: [RunLogEntry]
}

struct RepositoryStatusReport: Codable, Sendable {
    let status: String
    let activeRun: RunListEntry?
    let observedState: ReducedRunState?
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
        RunRegistry(root: context.layout.state)
    }

    func status() async throws {
        let snapshots = try await registry.recordedRuns()
        let active = snapshots.first(where: { $0.manifest.status == .running })
        let latest = snapshots.first
        let observed: ReducedRunState?
        if let active {
            observed = try await registry.reducedEvents(in: active)
        } else {
            observed = nil
        }
        let report = RepositoryStatusReport(
            status: active == nil ? "idle" : "running",
            activeRun: active.map(listEntry),
            observedState: observed,
            latestRun: latest.map(listEntry))
        var lines = ["status: \(report.status)"]
        if let activeRun = report.activeRun {
            lines += runLines(activeRun)
            if let observed {
                let runningTasks = observed.tasks.compactMap { task, state in
                    if case .running = state { return task.rawValue }
                    return nil
                }.sorted()
                for task in runningTasks { lines.append("running task: \(task)") }
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
        }.joined(separator: "\n")
        try context.console.report(RunListReport(runs: entries), text: text)
    }

    func showRun(_ requested: String?) async throws {
        let snapshot = try await resolve(requested)
        let observed = try await registry.reducedEvents(in: snapshot)
        let logs = try await registry.logs(in: snapshot).map(logEntry)
        let report = RunShowReport(
            manifest: snapshot.manifest,
            observedState: observed,
            logs: logs)
        var lines = runLines(listEntry(snapshot))
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
        return RunListEntry(
            runID: manifest.runID.rawValue,
            command: manifest.command,
            startedAt: manifest.startedAt,
            finishedAt: manifest.finishedAt,
            status: manifest.status,
            failedTask: manifest.failedTask?.rawValue,
            domain: domain(of: manifest))
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
        return lines
    }

    private func taskState(_ record: RunTaskRecord) -> String {
        if let outcome = record.outcome { return outcome.rawValue }
        return record.plan.isClean ? TaskRunOutcome.localClean.rawValue : "pending"
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
