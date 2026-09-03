import ColliderCore
import ColliderRuntime
import Dispatch
import Foundation
import Synchronization
import Testing

@testable import ColliderWorkspaceCommands

private final class ConsoleCapture: Sendable {
    private let storage = Mutex(Data())

    func write(_ data: Data) {
        storage.withLock { $0.append(data) }
    }

    var text: String {
        storage.withLock { String(decoding: $0, as: UTF8.self) }
    }
}

private final class ConsoleRecording: Sendable {
    struct Entry: Sendable {
        let destination: ConsoleHumanDestination
        let text: String
    }

    private let storage = Mutex<[Entry]>([])

    func writer(for destination: ConsoleHumanDestination) -> CommandConsole.Writer {
        { [self] data in
            storage.withLock {
                $0.append(
                    Entry(
                        destination: destination,
                        text: String(decoding: data, as: UTF8.self)))
            }
        }
    }

    var entries: [Entry] {
        storage.withLock { $0 }
    }
}

private final class GeometryFixture: Sendable {
    private let storage: Mutex<TerminalGeometry>

    init(_ geometry: TerminalGeometry) {
        storage = Mutex(geometry)
    }

    func set(_ geometry: TerminalGeometry) {
        storage.withLock { $0 = geometry }
    }

    func read() -> TerminalGeometry {
        storage.withLock { $0 }
    }
}

private struct FixtureReport: Codable, Equatable {
    let value: String
}

@Test func jsonReportWritesOneValueToStandardOutput() throws {
    let standardOutput = ConsoleCapture()
    let standardError = ConsoleCapture()
    let console = CommandConsole(
        format: .json,
        color: .never,
        progress: .never,
        standardOutput: standardOutput.write,
        standardError: standardError.write)

    try console.report(FixtureReport(value: "fixture"), text: "human fixture")

    #expect(standardOutput.text == #"{"value":"fixture"}"# + "\n")
    #expect(standardError.text.isEmpty)
}

@Test func jsonReportScrubsCredentialValuesWithoutBreakingThePayload() throws {
    let standardOutput = ConsoleCapture()
    let console = CommandConsole(
        format: .json,
        standardOutput: standardOutput.write,
        standardError: { _ in })

    try console.report(
        FixtureReport(value: "token=secret"),
        text: "unused")

    let decoded = try JSONDecoder().decode(
        FixtureReport.self,
        from: Data(standardOutput.text.utf8))
    #expect(decoded == FixtureReport(value: "token=<redacted>"))
}

@Test func humanDiagnosticsUseOnlyStandardError() throws {
    let standardOutput = ConsoleCapture()
    let standardError = ConsoleCapture()
    let console = CommandConsole(
        standardOutput: standardOutput.write,
        standardError: standardError.write)

    try console.diagnostic("diagnostic")

    #expect(standardOutput.text.isEmpty)
    #expect(standardError.text == "diagnostic\n")
}

@Test func redirectedProgressIsAppendOnlyWithoutCursorControl() throws {
    let standardError = ConsoleCapture()
    let console = CommandConsole(
        progress: .always,
        standardErrorIsTerminal: false,
        standardOutput: { _ in },
        standardError: standardError.write)

    try console.progress("first")
    try console.progress("second")
    try console.finishProgress()

    #expect(console.progressPresentation == .appendOnly)
    #expect(standardError.text == "first\nsecond\n")
    #expect(!standardError.text.contains("\u{001B}"))
}

@Test func unrecognizedCIEnvironmentPreservesPlainAppendOnlyBytes() throws {
    let baseline = ConsoleCapture()
    let unrecognized = ConsoleCapture()
    let baselineConsole = CommandConsole(
        progress: .always,
        environment: [:],
        standardOutput: { _ in },
        standardError: baseline.write)
    let unrecognizedConsole = CommandConsole(
        progress: .always,
        environment: ["CI": "true", "GITHUB_ACTIONS": "false"],
        standardOutput: { _ in },
        standardError: unrecognized.write)

    try baselineConsole.progress("first")
    try baselineConsole.progress("second")
    try unrecognizedConsole.progress("first")
    try unrecognizedConsole.progress("second")

    #expect(baselineConsole.progressPresentation == .appendOnly)
    #expect(unrecognizedConsole.progressPresentation == .appendOnly)
    #expect(unrecognized.text == baseline.text)
}

@Test func githubActionsGroupsDurableTaskLogsAndEscapesAnnotations() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-github-console-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    let log = directory.appendingPathComponent("stage.log")
    try Data("line one\n::warning::not a workflow command\n".utf8).write(to: log)
    let standardError = ConsoleCapture()
    let console = CommandConsole(
        progress: .always,
        environment: ["GITHUB_ACTIONS": "true"],
        standardOutput: { _ in },
        standardError: standardError.write)
    let task = TaskID(rawValue: "fixture.build")

    try console.githubTaskLog(task: task, path: log.path)
    try console.githubFailure(
        task: task,
        reason: "compile failed\nwith context",
        logPath: log.path)

    #expect(console.progressPresentation == .githubActions)
    #expect(standardError.text.contains("::group::fixture.build\n"))
    #expect(standardError.text.contains("line one\n"))
    #expect(standardError.text.contains(" ::warning::not a workflow command\n"))
    #expect(standardError.text.contains("::endgroup::\n"))
    #expect(standardError.text.contains("::error title=Collider task fixture.build::"))
    #expect(standardError.text.contains("compile failed%0Awith context"))
    #expect(standardError.text.contains("stage log: "))
}

@Test func githubActionsGroupsUnstructuredImagePreparationOutput() throws {
    let standardError = ConsoleCapture()
    let console = CommandConsole(
        progress: .always,
        environment: ["GITHUB_ACTIONS": "true"],
        standardOutput: { _ in },
        standardError: standardError.write)
    let task = TaskID(rawValue: "fixture.image")

    try console.unstructuredOutputWillBegin(task: task)
    try console.progress("must not interleave with BuildKit")
    standardError.write(Data("#1 resolving image\n".utf8))
    try console.unstructuredOutputDidEnd(task: task)
    try console.progress("visible after image preparation")

    #expect(
        standardError.text.contains(
            "::group::fixture.image image preparation\n#1 resolving image\n::endgroup::\n"))
    #expect(!standardError.text.contains("must not interleave with BuildKit"))
    #expect(standardError.text.contains("visible after image preparation"))
}

/// The two halves of a workflow command are escaped by different rules, and a
/// task named by a digest exercises both: `:` ends a property list, so it is
/// escaped in `title=`, and means nothing in a message, so it is not.
@Test func githubActionsNamesTasksByLabelAndEscapesEachHalfOfACommand() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-github-labels-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    let log = directory.appendingPathComponent("stage.log")
    try Data("line one\n".utf8).write(to: log)
    let standardError = ConsoleCapture()
    let console = CommandConsole(
        progress: .always,
        environment: ["GITHUB_ACTIONS": "true"],
        standardOutput: { _ in },
        standardError: standardError.write)
    let task = TaskID(rawValue: "swift.package.test.sha256:abc123")
    console.recordTaskLabels([task: "collider:collider-cliPackageTests"])

    try console.githubTaskLog(task: task, path: log.path)
    try console.githubFailure(
        task: task,
        reason: "no space left on device (28)",
        logPath: log.path)

    #expect(
        standardError.text.contains(
            "::group::collider:collider-cliPackageTests"
                + "  (swift.package.test.sha256:abc123)\n"))
    #expect(
        standardError.text.contains(
            "::error title=Collider task collider%3Acollider-cliPackageTests"
                + "  (swift.package.test.sha256%3Aabc123)::"))
    #expect(standardError.text.contains("no space left on device (28) (stage log: "))
}

/// A progress row has to fit a line beside the output it reports, so it carries
/// the label alone. An unlabelled task is already named for what it does.
@Test func progressRowsNameALoweredTaskByItsLabel() throws {
    let standardError = ConsoleCapture()
    let console = CommandConsole(
        progress: .always,
        standardErrorIsTerminal: false,
        standardOutput: { _ in },
        standardError: standardError.write)
    let lowered = TaskID(rawValue: "swift.package.build.sha256:abc123")
    let plain = TaskID(rawValue: "core.skia")
    console.recordTaskLabels([lowered: "core:NucleusCore"])

    try console.progress(
        progressSnapshot(task: lowered, additionalActiveTask: plain))

    #expect(standardError.text.contains("core:NucleusCore [oci]  compile\n"))
    #expect(standardError.text.contains("core.skia [lightweight]  running\n"))
    #expect(!standardError.text.contains("swift.package.build.sha256:abc123"))
}

@Test func explicitMachineProgressKeepsJSONReportsPureOnStandardOutput() throws {
    let standardOutput = ConsoleCapture()
    let standardError = ConsoleCapture()
    let console = CommandConsole(
        format: .json,
        progress: .always,
        progressFormat: .json,
        standardErrorIsTerminal: false,
        standardOutput: standardOutput.write,
        standardError: standardError.write)

    try console.progress(progressSnapshot(task: TaskID(rawValue: "fixture.machine")))
    try console.report(FixtureReport(value: "report"), text: "unused")

    #expect(standardOutput.text == #"{"value":"report"}"# + "\n")
    let progress = try #require(
        JSONSerialization.jsonObject(with: Data(standardError.text.utf8))
            as? [String: Any])
    #expect(progress["kind"] as? String == "progress")
    #expect(!standardError.text.contains("\u{001B}"))
    #expect(!standardError.text.contains("\r"))
}

@Test func commandPresentationAndDryRunSelectProgressPolicyOnce() {
    let inspection = CommandConsole(
        progress: .always,
        presentationKind: .none,
        standardErrorIsTerminal: true,
        standardOutput: { _ in },
        standardError: { _ in })
    let dryRun = CommandConsole(
        progress: .always,
        presentationKind: .taskGraph,
        dryRun: true,
        standardErrorIsTerminal: true,
        standardOutput: { _ in },
        standardError: { _ in })
    let jsonReport = CommandConsole(
        format: .json,
        progress: .always,
        presentationKind: .taskGraph,
        standardErrorIsTerminal: true,
        standardOutput: { _ in },
        standardError: { _ in })

    #expect(inspection.progressPresentation == .disabled)
    #expect(dryRun.progressPresentation == .disabled)
    #expect(jsonReport.progressPresentation == .disabled)
}

@Test func phasePresentationOmitsTaskCompletionFraction() throws {
    let standardError = ConsoleCapture()
    let console = CommandConsole(
        progress: .always,
        presentationKind: .phase,
        standardErrorIsTerminal: false,
        standardOutput: { _ in },
        standardError: standardError.write)

    try console.progress(progressSnapshot(task: TaskID(rawValue: "fixture.phase")))

    #expect(standardError.text.hasPrefix("executing  1.0s\n"))
    #expect(!standardError.text.contains("0/1"))
    #expect(!standardError.text.contains("0%"))
}

@Test func hostPhasePresentationIncludesDurableItemCounters() throws {
    let standardError = ConsoleCapture()
    let console = CommandConsole(
        progress: .always,
        presentationKind: .phase,
        standardErrorIsTerminal: false,
        standardOutput: { _ in },
        standardError: standardError.write)
    let snapshot = RunProgressSnapshot(
        runID: RunID(rawValue: "fixture"),
        phase: .planning,
        completionFraction: 0,
        completedTaskCount: 0,
        totalTaskCount: 0,
        elapsedNanoseconds: 2_000_000_000,
        hostPhase: RunHostPhase(
            name: "measuring storage allocation",
            completedItems: 3,
            totalItems: 8),
        activeRows: [],
        residualActiveRowCount: 0)

    try console.progress(snapshot)

    #expect(standardError.text == "measuring storage allocation  3/8  2.0s\n")
}

@Test func diagnosticsLandAboveAndRepaintDynamicProgress() throws {
    let standardError = ConsoleCapture()
    let console = CommandConsole(
        progress: .auto,
        standardErrorIsTerminal: true,
        standardOutput: { _ in },
        standardError: standardError.write)

    try console.progress("working")
    try console.diagnostic("failed")

    #expect(console.progressPresentation == .dynamic)
    #expect(
        standardError.text.hasSuffix(
            "\r\u{001B}[2Kfailed\n\r\u{001B}[2Kworking"))
}

@Test func dynamicProgressNeutralizesUntrustedTerminalControls() throws {
    let standardError = ConsoleCapture()
    let console = CommandConsole(
        progress: .always,
        standardErrorIsTerminal: true,
        standardOutput: { _ in },
        standardError: standardError.write)

    try console.progress("safe\u{001B}[2Jbad\u{0007}")

    #expect(standardError.text.contains("safebad"))
    #expect(!standardError.text.contains("\u{001B}[2J"))
    #expect(!standardError.text.contains("\u{0007}"))
}

@Test func dynamicProgressTruncatesUnicodeByTerminalCells() throws {
    let standardError = ConsoleCapture()
    let console = CommandConsole(
        progress: .always,
        standardErrorIsTerminal: true,
        geometry: { TerminalGeometry(columns: 6, rows: 4) },
        standardOutput: { _ in },
        standardError: standardError.write)

    try console.progress("界e\u{0301}xyz")

    #expect(standardError.text.hasSuffix("界e\u{0301}xy"))
    #expect(!standardError.text.contains("界e\u{0301}xyz"))
}

@Test func dynamicProgressBoundsItsTrailingRegionToTerminalHeight() throws {
    let standardError = ConsoleCapture()
    let console = CommandConsole(
        progress: .always,
        standardErrorIsTerminal: true,
        geometry: { TerminalGeometry(columns: 20, rows: 3) },
        standardOutput: { _ in },
        standardError: standardError.write)

    try console.progress("first\nsecond\nthird")

    #expect(!standardError.text.contains("first"))
    #expect(standardError.text.contains("second\n\r\u{001B}[2Kthird"))
}

@Test func finishingDynamicProgressIsIdempotentAndRestoresTheCursor() throws {
    let standardError = ConsoleCapture()
    let console = CommandConsole(
        progress: .always,
        standardErrorIsTerminal: true,
        standardOutput: { _ in },
        standardError: standardError.write)

    try console.progress("working")
    try console.finishProgress()
    #expect(standardError.text.hasSuffix("\r\u{001B}[2K\u{001B}[?25h"))

    let finished = standardError.text
    try console.finishProgress()
    #expect(standardError.text == finished)
}

@Test func terminalLifecycleRepaintsAndThenTearsDownTheRegion() throws {
    let geometry = GeometryFixture(TerminalGeometry(columns: 12, rows: 4))
    let standardError = ConsoleCapture()
    let console = CommandConsole(
        progress: .always,
        standardErrorIsTerminal: true,
        geometry: geometry.read,
        standardOutput: { _ in },
        standardError: standardError.write)

    try console.progress("long progress")
    try console.terminalWillSuspend()
    #expect(standardError.text.hasSuffix("\u{001B}[?25h"))

    try console.terminalDidResume()
    #expect(standardError.text.hasSuffix("long progre"))

    geometry.set(TerminalGeometry(columns: 6, rows: 4))
    try console.terminalDidResize()
    #expect(standardError.text.hasSuffix("long "))

    try console.terminalWillInterrupt()
    #expect(standardError.text.hasSuffix("\u{001B}[?25h"))
    let afterInterrupt = standardError.text
    try console.terminalDidResume()
    #expect(standardError.text == afterInterrupt)
}

@Test func taskOutputAssemblesLinesRefinesRowsAndNeutralizesTerminalText() throws {
    let task = TaskID(rawValue: "fixture.build")
    let standardError = ConsoleCapture()
    let console = CommandConsole(
        progress: .always,
        standardErrorIsTerminal: true,
        standardOutput: { _ in },
        standardError: standardError.write)
    try console.progress(progressSnapshot(task: task))
    let beforeOutput = standardError.text

    try console.taskOutput(
        .chunk(
            task: task,
            stream: .standardOutput,
            bytes: Array("partial token=secret".utf8),
            presentation: .default))
    #expect(standardError.text == beforeOutput)
    try console.taskOutput(
        .chunk(
            task: task,
            stream: .standardOutput,
            bytes: Array("\u{001B}[2J line\n".utf8),
            presentation: .default))

    #expect(standardError.text.contains("partial token=<redacted> line"))
    #expect(!standardError.text.contains("secret"))
    #expect(!standardError.text.contains("\u{001B}[2J"))
}

@Test func verboseTaskOutputIsAttributedAboveTheLiveRegion() throws {
    let task = TaskID(rawValue: "fixture.verbose")
    let sibling = TaskID(rawValue: "fixture.sibling")
    let standardError = ConsoleCapture()
    let console = CommandConsole(
        progress: .always,
        standardErrorIsTerminal: true,
        standardOutput: { _ in },
        standardError: standardError.write)
    try console.progress(progressSnapshot(task: task, additionalActiveTask: sibling))
    try console.taskOutput(
        .chunk(
            task: task,
            stream: .standardError,
            bytes: Array("first\nsecond\n".utf8),
            presentation: .verbose))

    #expect(standardError.text.contains("fixture.verbose | first\n"))
    #expect(standardError.text.contains("fixture.verbose | second\n"))
    #expect(standardError.text.contains("fixture.verbose [oci]  second"))
    #expect(standardError.text.hasSuffix("fixture.sibling [lightweight]  running"))
}

@Test func quietTaskOutputAppearsOnlyInABoundedFailureTail() throws {
    let task = TaskID(rawValue: "fixture.failure")
    let standardError = ConsoleCapture()
    let console = CommandConsole(
        progress: .never,
        standardOutput: { _ in },
        standardError: standardError.write)
    for index in 0..<24 {
        try console.taskOutput(
            .chunk(
                task: task,
                stream: .standardError,
                bytes: Array("line-\(index)\n".utf8),
                presentation: .quiet))
    }
    #expect(standardError.text.isEmpty)

    try console.failure(
        ExecutionFailure(
            task: task,
            logPath: "/runs/fixture/stages/fixture-failure.log",
            reason: "fixture failed"))
    #expect(!standardError.text.contains("line-15"))
    #expect(standardError.text.contains("line-16"))
    #expect(standardError.text.contains("line-23"))
    #expect(standardError.text.contains("/runs/fixture/stages/fixture-failure.log"))
}

private func progressSnapshot(
    task: TaskID,
    additionalActiveTask: TaskID? = nil
) -> RunProgressSnapshot {
    var activeRows = [
        RunProgressRow(
            task: task,
            lane: .oci,
            startedAt: "2026-08-08T00:00:00Z",
            detail: .operation("compile"))
    ]
    if let additionalActiveTask {
        activeRows.append(
            RunProgressRow(
                task: additionalActiveTask,
                lane: .lightweight,
                startedAt: "2026-08-08T00:00:01Z",
                detail: .running))
    }
    return RunProgressSnapshot(
        runID: RunID(rawValue: "fixture"),
        phase: .executing,
        completionFraction: 0,
        completedTaskCount: 0,
        totalTaskCount: activeRows.count,
        elapsedNanoseconds: 1_000_000_000,
        activeRows: activeRows,
        residualActiveRowCount: 0)
}

@Test func concurrentWritesRemainWholeAroundTheLiveRegion() throws {
    let recording = ConsoleRecording()
    let failures = Mutex(0)
    let console = CommandConsole(
        progress: .always,
        standardOutputIsTerminal: true,
        standardErrorIsTerminal: true,
        standardOutput: recording.writer(for: .standardOutput),
        standardError: recording.writer(for: .standardError))
    try console.progress("working")

    DispatchQueue.concurrentPerform(iterations: 16) { index in
        do {
            try console.human(
                "message-\(index)",
                destination: index.isMultiple(of: 2) ? .standardOutput : .standardError)
        } catch {
            failures.withLock { $0 += 1 }
        }
    }

    #expect(failures.withLock { $0 } == 0)
    let transactions = recording.entries.dropFirst()
    #expect(transactions.count == 16 * 3)
    for offset in stride(from: 0, to: transactions.count, by: 3) {
        let erase = transactions[transactions.index(transactions.startIndex, offsetBy: offset)]
        let message = transactions[
            transactions.index(transactions.startIndex, offsetBy: offset + 1)]
        let repaint = transactions[
            transactions.index(transactions.startIndex, offsetBy: offset + 2)]
        #expect(erase.destination == .standardError)
        #expect(erase.text == "\r\u{001B}[2K")
        #expect(message.text.hasPrefix("message-"))
        #expect(message.text.hasSuffix("\n"))
        #expect(repaint.destination == .standardError)
        #expect(repaint.text == "\r\u{001B}[2Kworking")
    }
}

@Test func colorPolicyHonorsTerminalCapabilityAndNoColor() {
    let automatic = CommandConsole(
        color: .auto,
        standardErrorIsTerminal: true,
        standardOutput: { _ in },
        standardError: { _ in })
    let redirected = CommandConsole(
        color: .auto,
        standardErrorIsTerminal: false,
        standardOutput: { _ in },
        standardError: { _ in })
    let disabledByEnvironment = CommandConsole(
        color: .always,
        standardErrorIsTerminal: true,
        environment: ["NO_COLOR": "1"],
        standardOutput: { _ in },
        standardError: { _ in })

    #expect(automatic.colorEnabled)
    #expect(!redirected.colorEnabled)
    #expect(!disabledByEnvironment.colorEnabled)
}

@Test func commandRenderingQuotesArgumentsAndScrubsCredentials() {
    let rendered = CommandConsole.render(command: [
        "tool", "--token", "secret value", "path with spaces",
    ])

    #expect(rendered == "tool --token '<redacted>' 'path with spaces'")
    #expect(!rendered.contains("secret value"))
}

@Test func failureRenderingUsesColorOnlyWhenEnabledAndScrubsCredentials() throws {
    let standardError = ConsoleCapture()
    let console = CommandConsole(
        color: .always,
        standardErrorIsTerminal: false,
        standardOutput: { _ in },
        standardError: standardError.write)

    try console.failure(FixtureFailure("token=secret"))

    #expect(standardError.text.contains("\u{001B}[31m"))
    #expect(standardError.text.contains("token=<redacted>"))
    #expect(!standardError.text.contains("token=secret"))
}

@Test func structuredFailureRenderingUsesFieldsWithoutParsingItsDescription() throws {
    let standardError = ConsoleCapture()
    let console = CommandConsole(
        color: .never,
        standardOutput: { _ in },
        standardError: standardError.write)
    let failure = ExecutionFailure(
        task: TaskID(rawValue: "fixture.build"),
        operation: "swift build",
        command: ["swift", "build"],
        status: 137,
        signal: 9,
        invocation: "swift build",
        workingDirectory: "/workspace with spaces",
        logPath: "/runs/fixture/stages/fixture-build.log",
        reason: "child command failed")

    try console.failure(failure)

    #expect(standardError.text.contains("task: fixture.build"))
    #expect(standardError.text.contains("operation: swift build"))
    #expect(standardError.text.contains("command: swift build"))
    #expect(standardError.text.contains("status: 137"))
    #expect(standardError.text.contains("signal: 9"))
    #expect(standardError.text.contains("directory: '/workspace with spaces'"))
    #expect(standardError.text.contains("log: /runs/fixture/stages/fixture-build.log"))
}

private struct FixtureFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
