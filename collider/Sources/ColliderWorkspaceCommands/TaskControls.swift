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
    /// Restricts test invocations to matching test names. A filtered run is a
    /// different task from the unfiltered one, so it verifies what it names and
    /// leaves the full gate outstanding.
    package var testFilter: String?
    let identityExplanations: IdentityExplanationCollector

    package init(
        dryRun: Bool = false,
        rebuild: Bool = false,
        verbose: Bool = false,
        quiet: Bool = false,
        format: ConsoleOutputFormat = .text,
        explainIdentity: String? = nil,
        testFilter: String? = nil
    ) {
        self.dryRun = dryRun
        self.rebuild = rebuild
        self.verbose = verbose
        self.quiet = quiet
        self.format = format
        self.testFilter = testFilter
        identityExplanations = IdentityExplanationCollector(
            selection: explainIdentity)
    }

    var executionOptions: TaskExecutionOptions {
        TaskExecutionOptions(
            dryRun: dryRun,
            rebuildSelected: rebuild,
            verbose: verbose,
            quiet: quiet,
            machineReadable: format == .json,
            identityObserver: identityExplanations.observer)
    }

    func renderDryRun(_ report: TaskExecutionReport, console: CommandConsole) throws {
        precondition(dryRun)
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
        lines += identityExplanations.report()
        if quiet && format == .text { return }
        try console.report(
            report,
            text: lines.joined(separator: "\n"),
            humanDestination: .standardError)
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
