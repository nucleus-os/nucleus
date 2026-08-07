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
    var json = false

    package init(
        dryRun: Bool = false,
        rebuild: Bool = false,
        verbose: Bool = false,
        quiet: Bool = false,
        json: Bool = false
    ) {
        self.dryRun = dryRun
        self.rebuild = rebuild
        self.verbose = verbose
        self.quiet = quiet
        self.json = json
    }

    var executionOptions: TaskExecutionOptions {
        TaskExecutionOptions(
            dryRun: dryRun,
            rebuildSelected: rebuild,
            verbose: verbose,
            quiet: quiet,
            machineReadable: json)
    }

    func render(_ report: TaskExecutionReport) throws {
        if json {
            print(String(decoding: try JSONEncoder.sorted.encode(report), as: UTF8.self))
        } else if dryRun {
            let planningMicroseconds = report.planningDurationNanoseconds / 1_000
            let fractionalMilliseconds = String(planningMicroseconds % 1_000)
            let paddedFraction =
                String(
                    repeating: "0",
                    count: 3 - fractionalMilliseconds.count) + fractionalMilliseconds
            print("planning  \(planningMicroseconds / 1_000).\(paddedFraction) ms")
            print(
                "input hashing  "
                    + "\(report.selectedInputHashingDurationNanoseconds / 1_000) us")
            print("SwiftPM invocations  \(report.swiftPMInvocationCount)")
            for entry in report.plan {
                let state = entry.isClean ? "clean" : "dirty"
                print(
                    "\(state)  \(entry.task.rawValue)"
                        + executionCoordinateSummary(entry.coordinates)
                        + "  \(entry.explanation)")
            }
        } else if !quiet {
            let skipped = report.plan.count(where: \.isClean)
            print("completed  \(report.taskTimings.count) executed, \(skipped) skipped")
            print(
                "planning  \(formatDuration(report.planningDurationNanoseconds))"
                    + " (input hashing "
                    + "\(formatDuration(report.selectedInputHashingDurationNanoseconds)))")
            print("SwiftPM invocations  \(report.swiftPMInvocationCount)")
            print("execution  \(formatDuration(report.executionDurationNanoseconds))")
            print(
                "critical path  "
                    + "\(formatDuration(report.criticalPathDurationNanoseconds))")
            print(
                "scheduling wait  "
                    + "\(formatDuration(report.schedulingWaitDurationNanoseconds))")
            let slowest = report.taskTimings.sorted {
                if $0.durationNanoseconds == $1.durationNanoseconds {
                    return $0.task.rawValue < $1.task.rawValue
                }
                return $0.durationNanoseconds > $1.durationNanoseconds
            }.prefix(5)
            if !slowest.isEmpty {
                print("slowest tasks")
                for timing in slowest {
                    print(
                        "  \(formatDuration(timing.durationNanoseconds))  "
                            + timing.task.rawValue)
                }
            }
        }
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
