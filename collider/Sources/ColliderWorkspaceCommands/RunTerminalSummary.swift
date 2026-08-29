import ColliderCore
import ColliderPersistence
import Foundation

package struct RunTerminalTaskSummary: Codable, Equatable, Sendable {
    package let task: String
    package let outcome: String
    package let durationNanoseconds: UInt64
}

package struct RunTerminalContainerSummary: Codable, Equatable, Sendable {
    package let task: String
    package let executionIndex: Int
    package let timings: OCIExecutionTimings
}

/// One test case a run observed failing, named by the task that ran it.
///
/// Test results are already decoded from the xUnit files the test tasks write,
/// so this reports recorded observations rather than parsed console output.
package struct RunTerminalFailedTestSummary: Codable, Equatable, Sendable {
    package let task: String
    package let suite: String?
    package let name: String
    package let durationNanoseconds: UInt64

    package var qualifiedName: String {
        guard let suite, !suite.isEmpty else { return name }
        return "\(suite).\(name)"
    }
}

package struct RunTerminalSummary: Codable, Equatable, Sendable {
    package let runID: String
    package let status: RunStatus
    package let cleanTasks: Int
    package let executedTasks: Int
    package let failedTasks: Int
    package let cancelledTasks: Int
    package let elapsedDurationNanoseconds: UInt64?
    package let planningDurationNanoseconds: UInt64?
    package let selectedInputHashingDurationNanoseconds: UInt64?
    package let swiftPMInvocationCount: Int?
    package let executionDurationNanoseconds: UInt64?
    package let criticalPathDurationNanoseconds: UInt64?
    package let schedulingWaitDurationNanoseconds: UInt64?
    package let slowestTasks: [RunTerminalTaskSummary]
    package let slowestContainerExecutions: [RunTerminalContainerSummary]
    /// Every observed test failure, up to the reported cap.
    package let failedTestCases: [RunTerminalFailedTestSummary]
    /// How many test failures the run observed, which exceeds `failedTestCases`
    /// when a run fails more tests than are worth naming in a summary.
    package let failedTestCaseCount: Int

    package init(
        snapshot: RecordedRunSnapshot,
        observedState: ReducedRunState
    ) {
        let manifest = snapshot.manifest
        runID = manifest.runID.rawValue
        status = manifest.status
        cleanTasks =
            manifest.tasks?.values.count(where: { record in
                if case .localClean? = record.outcome { return true }
                return false
            }) ?? 0
        executedTasks =
            manifest.tasks?.values.count(where: { record in
                if case .executed? = record.outcome { return true }
                return false
            }) ?? 0
        failedTasks = observedState.tasks.values.count(where: { state in
            if case .failed = state { return true }
            return false
        })
        cancelledTasks = observedState.tasks.values.count(where: { state in
            if case .cancelled = state { return true }
            return false
        })
        elapsedDurationNanoseconds = Self.elapsedDuration(manifest)
        planningDurationNanoseconds = manifest.planningDurationNanoseconds
        selectedInputHashingDurationNanoseconds =
            manifest.selectedInputHashingDurationNanoseconds
        swiftPMInvocationCount = manifest.swiftPMInvocationCount
        executionDurationNanoseconds = manifest.executionDurationNanoseconds
        criticalPathDurationNanoseconds = manifest.criticalPathDurationNanoseconds
        schedulingWaitDurationNanoseconds = manifest.schedulingWaitDurationNanoseconds

        slowestTasks = (manifest.tasks ?? [:]).compactMap { task, record in
            guard let duration = record.durationNanoseconds else { return nil }
            return RunTerminalTaskSummary(
                task: task,
                outcome: Self.outcome(
                    observedState.tasks[TaskID(rawValue: task)],
                    recorded: record.outcome),
                durationNanoseconds: duration)
        }.sorted {
            if $0.durationNanoseconds == $1.durationNanoseconds {
                return $0.task < $1.task
            }
            return $0.durationNanoseconds > $1.durationNanoseconds
        }.prefix(5).map { $0 }

        slowestContainerExecutions = (manifest.tasks ?? [:]).flatMap { task, record in
            (record.observations?.containerExecutions ?? []).enumerated().compactMap {
                index, observation in
                guard let timings = observation.timings else { return nil }
                return RunTerminalContainerSummary(
                    task: task,
                    executionIndex: index,
                    timings: timings)
            }
        }.sorted {
            if $0.timings.totalDurationNanoseconds == $1.timings.totalDurationNanoseconds {
                if $0.task == $1.task { return $0.executionIndex < $1.executionIndex }
                return $0.task < $1.task
            }
            return $0.timings.totalDurationNanoseconds
                > $1.timings.totalDurationNanoseconds
        }.prefix(5).map { $0 }

        let failures = (manifest.tasks ?? [:]).flatMap { task, record in
            (record.observations?.testCases ?? []).lazy.filter {
                $0.outcome == .failed
            }.map {
                RunTerminalFailedTestSummary(
                    task: task,
                    suite: $0.suite,
                    name: $0.name,
                    durationNanoseconds: $0.durationNanoseconds)
            }
        }.sorted {
            if $0.task == $1.task {
                return $0.qualifiedName < $1.qualifiedName
            }
            return $0.task < $1.task
        }
        failedTestCaseCount = failures.count
        failedTestCases = Array(failures.prefix(Self.reportedFailedTestCap))
    }

    /// Naming every failure in a run that fails thousands of tests buries the
    /// rest of the summary, so the count stays exact while the list is capped.
    package static let reportedFailedTestCap = 20

    package var text: String {
        var outcome = [
            "\(cleanTasks) clean",
            "\(executedTasks) executed",
            "\(failedTasks) failed",
            "\(cancelledTasks) cancelled",
        ]
        if let elapsedDurationNanoseconds {
            outcome.append("elapsed \(formatDuration(elapsedDurationNanoseconds))")
        }
        var lines = ["\(status.rawValue)  " + outcome.joined(separator: ", ")]
        if let planningDurationNanoseconds {
            var planning = "planning  \(formatDuration(planningDurationNanoseconds))"
            if let selectedInputHashingDurationNanoseconds {
                planning +=
                    " (input hashing "
                    + "\(formatDuration(selectedInputHashingDurationNanoseconds)))"
            }
            lines.append(planning)
        }
        if let swiftPMInvocationCount {
            lines.append("SwiftPM invocations  \(swiftPMInvocationCount)")
        }
        if let executionDurationNanoseconds {
            lines.append("execution  \(formatDuration(executionDurationNanoseconds))")
        }
        if let criticalPathDurationNanoseconds {
            lines.append("critical path  \(formatDuration(criticalPathDurationNanoseconds))")
        }
        if let schedulingWaitDurationNanoseconds {
            lines.append("scheduling wait  \(formatDuration(schedulingWaitDurationNanoseconds))")
        }
        if !failedTestCases.isEmpty {
            lines.append(
                failedTestCaseCount == failedTestCases.count
                    ? "failed tests"
                    : "failed tests (\(failedTestCases.count) of \(failedTestCaseCount))")
            for test in failedTestCases {
                lines.append("  \(test.qualifiedName)  \(test.task)")
            }
        }
        if !slowestTasks.isEmpty {
            lines.append("slowest tasks")
            for task in slowestTasks {
                lines.append(
                    "  \(formatDuration(task.durationNanoseconds))  "
                        + "\(task.outcome)  \(task.task)")
            }
        }
        if !slowestContainerExecutions.isEmpty {
            lines.append("slowest container executions")
            for execution in slowestContainerExecutions {
                let timings = execution.timings
                let setup =
                    timings.configurationDurationNanoseconds
                    &+ timings.creationDurationNanoseconds
                    &+ timings.bootstrapDurationNanoseconds
                lines.append(
                    "  \(formatDuration(timings.totalDurationNanoseconds))  "
                        + "process \(formatDuration(timings.processDurationNanoseconds)), "
                        + "setup \(formatDuration(setup)), "
                        + "cleanup \(formatDuration(timings.cleanupDurationNanoseconds))  "
                        + "\(execution.task)#\(execution.executionIndex + 1)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func outcome(
        _ observed: ReducedTaskState?,
        recorded: TaskRunOutcome?
    ) -> String {
        switch observed {
        case .running?: "running"
        case .skipped?: "clean"
        case .succeeded?: "executed"
        case .cancelled?: "cancelled"
        case .failed?: "failed"
        case nil:
            switch recorded {
            case .localClean?: "clean"
            case .executed?: "executed"
            case nil: "pending"
            }
        }
    }

    private static func elapsedDuration(_ manifest: RunManifest) -> UInt64? {
        guard let finishedAt = manifest.finishedAt else { return nil }
        guard
            let started = parseTimestamp(manifest.startedAt),
            let finished = parseTimestamp(finishedAt)
        else { return nil }
        return UInt64(max(0, finished.timeIntervalSince(started) * 1_000_000_000))
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

package func formatDuration(_ nanoseconds: UInt64) -> String {
    let milliseconds = nanoseconds / 1_000_000
    if milliseconds < 1_000 { return "\(milliseconds) ms" }
    let tenths = milliseconds / 100
    return "\(tenths / 10).\(tenths % 10) s"
}
