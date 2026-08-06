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
    var explain = false
    var verbose = false
    var quiet = false
    var json = false

    package init(
        dryRun: Bool = false,
        rebuild: Bool = false,
        explain: Bool = false,
        verbose: Bool = false,
        quiet: Bool = false,
        json: Bool = false
    ) {
        self.dryRun = dryRun
        self.rebuild = rebuild
        self.explain = explain
        self.verbose = verbose
        self.quiet = quiet
        self.json = json
    }

    var executionOptions: TaskExecutionOptions {
        TaskExecutionOptions(
            dryRun: dryRun,
            rebuildSelected: rebuild,
            explain: explain,
            verbose: verbose,
            quiet: quiet,
            machineReadable: json)
    }

    func render(_ report: TaskExecutionReport) throws {
        if json {
            print(String(decoding: try JSONEncoder.sorted.encode(report), as: UTF8.self))
        } else if dryRun || explain {
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
                let state = entry.isClean ? "clean" : entry.isSubsumed ? "subsumed" : "dirty"
                print(
                    "\(state)  \(entry.task.rawValue)"
                        + executionCoordinateSummary(entry.coordinates)
                        + "  \(entry.explanation)")
            }
        }
    }
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
