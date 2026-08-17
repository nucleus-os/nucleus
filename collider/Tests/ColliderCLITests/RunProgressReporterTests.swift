import ColliderCore
import ColliderPersistence
import Foundation
import SystemPackage
import Testing

@testable import ColliderCLI
@testable import ColliderWorkspaceCommands

private final class ProgressCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func write(_ bytes: Data) {
        lock.withLock { data.append(bytes) }
    }

    var text: String {
        lock.withLock { String(decoding: data, as: UTF8.self) }
    }
}

@Test func appendOnlyReporterCoalescesElapsedAndBoundsStateChangesAndLiveness() async {
    let capture = ProgressCapture()
    let console = CommandConsole(
        progress: .always,
        standardErrorIsTerminal: false,
        standardOutput: { _ in },
        standardError: capture.write)
    let reporter = RunProgressReporter(
        console: console,
        minimumAppendInterval: 10,
        livenessInterval: 20)
    let start = Date(timeIntervalSince1970: 1_000)

    await reporter.present(snapshot(elapsed: 0, detail: .running), at: start)
    let firstOutput = capture.text
    await reporter.present(
        snapshot(elapsed: 9_000_000_000, detail: .running),
        at: start.addingTimeInterval(1))
    #expect(capture.text == firstOutput)

    await reporter.present(
        snapshot(elapsed: 2_000_000_000, detail: .operation("compile")),
        at: start.addingTimeInterval(2))
    await reporter.pulse(at: start.addingTimeInterval(9))
    #expect(capture.text == firstOutput)
    await reporter.pulse(at: start.addingTimeInterval(10))
    #expect(capture.text.contains("compile"))

    let afterChange = capture.text
    await reporter.pulse(at: start.addingTimeInterval(29))
    #expect(capture.text == afterChange)
    await reporter.pulse(at: start.addingTimeInterval(30))
    #expect(capture.text.hasSuffix("still running  fixture.build\n"))
}

@Test func dynamicReporterCoalescesEventsUntilItsPulse() async {
    let capture = ProgressCapture()
    let console = CommandConsole(
        progress: .always,
        standardErrorIsTerminal: true,
        standardOutput: { _ in },
        standardError: capture.write)
    let reporter = RunProgressReporter(console: console)
    let date = Date(timeIntervalSince1970: 2_000)

    await reporter.present(snapshot(elapsed: 0, detail: .running), at: date)
    await reporter.present(snapshot(elapsed: 0, detail: .operation("compile")), at: date)
    #expect(capture.text.isEmpty)
    await reporter.pulse(at: date)
    #expect(capture.text.contains("compile"))
}

@Test func appendOnlyReporterQuantizesWeightedCompletion() async {
    let capture = ProgressCapture()
    let console = CommandConsole(
        progress: .always,
        standardErrorIsTerminal: false,
        standardOutput: { _ in },
        standardError: capture.write)
    let reporter = RunProgressReporter(
        console: console,
        minimumAppendInterval: 0,
        livenessInterval: 1_000)
    let date = Date(timeIntervalSince1970: 3_000)

    await reporter.present(
        snapshot(elapsed: 0, completionFraction: 0.01, detail: .running),
        at: date)
    let initial = capture.text
    await reporter.present(
        snapshot(elapsed: 0, completionFraction: 0.049, detail: .running),
        at: date)
    #expect(capture.text == initial)
    await reporter.present(
        snapshot(elapsed: 0, completionFraction: 0.051, detail: .running),
        at: date)
    #expect(capture.text != initial)
    #expect(capture.text.hasSuffix("fixture.build [oci]  running\n"))
}

@Test func githubReporterEmitsDurableOutputGroupAndFailureAnnotation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-github-reporter-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = RunRegistry(root: FilePath(directory.path))
    let run = try await registry.begin(command: ["collider", "build", "fixture"])
    let task = TaskID(rawValue: "fixture.build")
    try await registry.appendLog(Array("durable output\n".utf8), stage: task, in: run)
    let capture = ProgressCapture()
    let console = CommandConsole(
        progress: .always,
        environment: ["GITHUB_ACTIONS": "true"],
        standardOutput: { _ in },
        standardError: capture.write)
    let reporter = GitHubActionsRunReporter(
        console: console,
        registry: registry,
        run: run)
    let failure = ExecutionFailure(
        task: task,
        logPath: await registry.stageLogPath(for: task, in: run).string,
        reason: "fixture failed")

    await reporter.consume(
        .event(
            RunEvent(
                sequence: 1,
                timestamp: "2026-08-17T00:00:00Z",
                runID: run.id,
                payload: .task(.failed(task: task, failure: failure)))))

    #expect(capture.text.contains("::group::fixture.build"))
    #expect(capture.text.contains("durable output"))
    #expect(capture.text.contains("::error title=Collider task fixture.build::"))
    #expect(capture.text.contains("fixture failed"))
    try await registry.finish(run, status: .failed, failedTask: task)
}

private func snapshot(
    elapsed: UInt64,
    completionFraction: Double = 0,
    detail: RunProgressDetail
) -> RunProgressSnapshot {
    RunProgressSnapshot(
        runID: RunID(rawValue: "fixture"),
        phase: .executing,
        completionFraction: completionFraction,
        completedTaskCount: 0,
        totalTaskCount: 1,
        elapsedNanoseconds: elapsed,
        activeRows: [
            RunProgressRow(
                task: TaskID(rawValue: "fixture.build"),
                lane: .oci,
                startedAt: "2026-08-17T00:00:00Z",
                detail: detail)
        ],
        residualActiveRowCount: 0)
}
