import ColliderCore
import ColliderRuntime
import Foundation

extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

package struct TaskControls: Sendable {
    package var dryRun = false
    var rebuild = false
    var verbose = false
    var quiet = false
    var format: ConsoleOutputFormat = .text

    package init(
        dryRun: Bool = false,
        rebuild: Bool = false,
        verbose: Bool = false,
        quiet: Bool = false,
        format: ConsoleOutputFormat = .text
    ) {
        self.dryRun = dryRun
        self.rebuild = rebuild
        self.verbose = verbose
        self.quiet = quiet
        self.format = format
    }

    var executionOptions: TaskExecutionOptions {
        TaskExecutionOptions(
            dryRun: dryRun,
            rebuildSelected: rebuild,
            verbose: verbose,
            quiet: quiet,
            machineReadable: format == .json)
    }

    func render(_ report: TaskExecutionReport, console: CommandConsole) throws {
        let text: String
        if dryRun {
            let planningMicroseconds = report.planningDurationNanoseconds / 1_000
            let fractionalMilliseconds = String(planningMicroseconds % 1_000)
            let paddedFraction =
                String(
                    repeating: "0",
                    count: 3 - fractionalMilliseconds.count) + fractionalMilliseconds
            var lines = ["planning  \(planningMicroseconds / 1_000).\(paddedFraction) ms"]
            lines.append(
                "input hashing  "
                    + "\(report.selectedInputHashingDurationNanoseconds / 1_000) us")
            lines.append("SwiftPM invocations  \(report.swiftPMInvocationCount)")
            for entry in report.plan {
                let state = entry.isClean ? "clean" : "dirty"
                lines.append(
                    "\(state)  \(entry.task.rawValue)"
                        + executionCoordinateSummary(entry.coordinates)
                        + "  \(entry.explanation)")
            }
            text = lines.joined(separator: "\n")
        } else {
            let skipped = report.plan.count(where: \.isClean)
            var lines = [
                "completed  \(report.taskTimings.count) executed, \(skipped) skipped",
                "planning  \(formatDuration(report.planningDurationNanoseconds))"
                    + " (input hashing "
                    + "\(formatDuration(report.selectedInputHashingDurationNanoseconds)))",
                "SwiftPM invocations  \(report.swiftPMInvocationCount)",
                "execution  \(formatDuration(report.executionDurationNanoseconds))",
                "critical path  "
                    + "\(formatDuration(report.criticalPathDurationNanoseconds))",
                "scheduling wait  "
                    + "\(formatDuration(report.schedulingWaitDurationNanoseconds))",
            ]
            let slowest = report.taskTimings.sorted {
                if $0.durationNanoseconds == $1.durationNanoseconds {
                    return $0.task.rawValue < $1.task.rawValue
                }
                return $0.durationNanoseconds > $1.durationNanoseconds
            }.prefix(5)
            if !slowest.isEmpty {
                lines.append("slowest tasks")
                for timing in slowest {
                    lines.append(
                        "  \(formatDuration(timing.durationNanoseconds))  "
                            + timing.task.rawValue)
                }
            }
            let slowestContainers = report.containerExecutionTimings.sorted {
                if $0.timings.totalDurationNanoseconds
                    == $1.timings.totalDurationNanoseconds
                {
                    if $0.task == $1.task {
                        return $0.executionIndex < $1.executionIndex
                    }
                    return $0.task.rawValue < $1.task.rawValue
                }
                return $0.timings.totalDurationNanoseconds
                    > $1.timings.totalDurationNanoseconds
            }.prefix(5)
            if !slowestContainers.isEmpty {
                lines.append("slowest container executions")
                for execution in slowestContainers {
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
                            + "\(execution.task.rawValue)#\(execution.executionIndex + 1)")
                }
            }
            text = lines.joined(separator: "\n")
        }
        if quiet && format == .text { return }
        try console.report(report, text: text, humanDestination: .standardError)
    }
}

private func formatDuration(_ nanoseconds: UInt64) -> String {
    let milliseconds = nanoseconds / 1_000_000
    if milliseconds < 1_000 {
        return "\(milliseconds) ms"
    }
    let tenths = milliseconds / 100
    return "\(tenths / 10).\(tenths % 10) s"
}

private func executionCoordinateSummary(
    _ coordinates: TaskExecutionCoordinates?
) -> String {
    guard let coordinates else { return "" }
    var values = [
        "runner=\(coordinates.runner.operatingSystem.rawValue)/"
            + coordinates.runner.architecture.rawValue,
        "executor=\(coordinates.backend.rawValue):"
            + "\(coordinates.execution.operatingSystem.rawValue)/"
            + coordinates.execution.architecture.rawValue,
    ]
    if let artifact = coordinates.artifact {
        var value =
            "artifact=\(artifact.operatingSystem.rawValue)/"
            + artifact.architecture.rawValue
        if let abi = artifact.abi { value += "/\(abi)" }
        if let apiLevel = artifact.androidAPILevel { value += "@api\(apiLevel)" }
        values.append(value)
    }
    return "  [\(values.joined(separator: " "))]"
}
