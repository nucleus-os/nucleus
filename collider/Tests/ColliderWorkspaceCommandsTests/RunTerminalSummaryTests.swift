import ColliderCore
import ColliderPersistence
import Foundation
import Synchronization
import SystemPackage
import Testing

@testable import ColliderWorkspaceCommands

private enum TerminalFixtureOutcome: CaseIterable, Sendable {
    case succeeded
    case failed
    case cancelled
    case interrupted
}

private final class TerminalConsoleCapture: Sendable {
    private let storage = Mutex(Data())

    func write(_ data: Data) {
        storage.withLock { $0.append(data) }
    }

    var text: String {
        storage.withLock { String(decoding: $0, as: UTF8.self) }
    }
}

@Test func terminalSummaryUsesRecordedTaskOutcomes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-terminal-summary-\(UUID().uuidString)",
        isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = RunRegistry(root: FilePath(directory.path))
    let run = try await registry.begin(command: ["collider", "build", "fixture"])
    let clean = TaskID(rawValue: "fixture.clean")
    let executed = TaskID(rawValue: "fixture.executed")
    let failed = TaskID(rawValue: "fixture.failed")
    let cancelled = TaskID(rawValue: "fixture.cancelled")
    let digest = ArtifactDigest(bytes: [1])
    try await registry.recordPlan(
        [
            plan(clean, digest: digest, isClean: true),
            plan(executed, digest: digest, isClean: false),
            plan(failed, digest: digest, isClean: false),
            plan(cancelled, digest: digest, isClean: false),
        ],
        in: run)
    try await registry.record(
        .task(.skipped(task: clean, explanation: "artifact is clean")),
        in: run)
    try await registry.record(.task(.started(executed)), in: run)
    try await registry.recordTaskOutcome(.executed, task: executed, in: run)
    try await registry.recordTaskDuration(40, task: executed, in: run)
    try await registry.record(.task(.succeeded(executed)), in: run)
    try await registry.record(.task(.started(failed)), in: run)
    try await registry.recordTaskDuration(30, task: failed, in: run)
    try await registry.record(
        .task(
            .failed(
                task: failed,
                failure: ExecutionFailure(task: failed, reason: "fixture failed"))),
        in: run)
    try await registry.record(.task(.started(cancelled)), in: run)
    try await registry.recordTaskDuration(20, task: cancelled, in: run)
    try await registry.record(.task(.cancelled(cancelled)), in: run)
    try await registry.finish(run, status: .failed, failedTask: failed)

    let snapshot = try await registry.recordedRun(run.id)
    let observed = try await registry.reducedEvents(in: snapshot)
    let summary = RunTerminalSummary(
        snapshot: snapshot,
        observedState: observed)

    #expect(summary.status == .failed)
    #expect(summary.cleanTasks == 1)
    #expect(summary.executedTasks == 1)
    #expect(summary.failedTasks == 1)
    #expect(summary.cancelledTasks == 1)
    #expect(summary.slowestTasks.map(\.outcome) == ["executed", "failed", "cancelled"])
}

@Test(arguments: TerminalFixtureOutcome.allCases)
private func terminalReportsRemainScriptableForEveryOutcome(
    _ outcome: TerminalFixtureOutcome
) async throws {
    let summary = try await terminalSummary(outcome)
    let jsonOutput = TerminalConsoleCapture()
    let jsonError = TerminalConsoleCapture()
    let jsonConsole = CommandConsole(
        format: .json,
        progress: .always,
        standardOutputIsTerminal: false,
        standardErrorIsTerminal: false,
        standardOutput: jsonOutput.write,
        standardError: jsonError.write)

    try jsonConsole.progress("working")
    try jsonConsole.report(
        summary,
        text: summary.text,
        humanDestination: .standardError)

    let jsonLines = jsonOutput.text.split(separator: "\n")
    #expect(jsonLines.count == 1)
    #expect(
        try JSONDecoder().decode(
            RunTerminalSummary.self,
            from: Data(jsonLines[0].utf8)) == summary)
    #expect(jsonError.text.isEmpty)
    #expect(!jsonOutput.text.contains("\u{001B}"))
    #expect(!jsonError.text.contains("\u{001B}"))

    let textOutput = TerminalConsoleCapture()
    let textError = TerminalConsoleCapture()
    let textConsole = CommandConsole(
        format: .text,
        progress: .never,
        standardOutputIsTerminal: false,
        standardErrorIsTerminal: false,
        standardOutput: textOutput.write,
        standardError: textError.write)
    try textConsole.report(
        summary,
        text: summary.text,
        humanDestination: .standardError)

    #expect(textOutput.text.isEmpty)
    #expect(textError.text == summary.text + "\n")
    #expect(!textError.text.contains("\u{001B}"))

    let dynamicError = TerminalConsoleCapture()
    let dynamicConsole = CommandConsole(
        progress: .always,
        standardErrorIsTerminal: true,
        standardOutput: { _ in },
        standardError: dynamicError.write)
    try dynamicConsole.progress("working")
    try dynamicConsole.completeProgress(summary)
    try dynamicConsole.finishProgress()
    #expect(dynamicError.text.components(separatedBy: summary.text).count == 2)
    #expect(dynamicError.text.hasSuffix(summary.text + "\n"))

    let machineOutput = TerminalConsoleCapture()
    let machineError = TerminalConsoleCapture()
    let machineConsole = CommandConsole(
        progress: .always,
        progressFormat: .json,
        standardErrorIsTerminal: false,
        standardOutput: machineOutput.write,
        standardError: machineError.write)
    try machineConsole.completeProgress(summary)
    let machineObject = try #require(
        JSONSerialization.jsonObject(with: Data(machineError.text.utf8))
            as? [String: Any])
    #expect(machineObject["kind"] as? String == "summary")
    #expect(machineOutput.text.isEmpty)
}

@Test func githubActionsAppendsExactlyOneMarkdownStepSummary() async throws {
    let summary = try await terminalSummary(.succeeded)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-github-summary-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("summary.md")
    let standardError = TerminalConsoleCapture()
    let console = CommandConsole(
        progress: .always,
        environment: [
            "GITHUB_ACTIONS": "true",
            "GITHUB_STEP_SUMMARY": path.path,
        ],
        standardOutput: { _ in },
        standardError: standardError.write)

    try console.completeProgress(summary)
    try console.completeProgress(summary)

    let markdown = try String(contentsOf: path, encoding: .utf8)
    #expect(console.progressPresentation == .githubActions)
    #expect(markdown.components(separatedBy: "## Collider run").count == 2)
    #expect(markdown.contains("**Status:** succeeded"))
    #expect(markdown.contains(summary.text))
}

private func terminalSummary(
    _ outcome: TerminalFixtureOutcome
) async throws -> RunTerminalSummary {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-terminal-contract-\(UUID().uuidString)",
        isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = RunRegistry(root: FilePath(directory.path))
    let run = try await registry.begin(command: ["collider", "build", "fixture"])
    let task = TaskID(rawValue: "fixture.build")
    try await registry.recordPlan(
        [plan(task, digest: ArtifactDigest(bytes: [2]), isClean: false)],
        in: run)
    try await registry.record(.task(.started(task)), in: run)

    let status: RunStatus
    let failedTask: TaskID?
    switch outcome {
    case .succeeded:
        try await registry.recordTaskOutcome(.executed, task: task, in: run)
        try await registry.record(.task(.succeeded(task)), in: run)
        status = .succeeded
        failedTask = nil
    case .failed:
        try await registry.record(
            .task(
                .failed(
                    task: task,
                    failure: ExecutionFailure(task: task, reason: "fixture failed"))),
            in: run)
        status = .failed
        failedTask = task
    case .cancelled:
        try await registry.record(.task(.cancelled(task)), in: run)
        status = .interrupted
        failedTask = nil
    case .interrupted:
        try await registry.record(.task(.cancelled(task)), in: run)
        try await registry.record(
            .interruption(InterruptionEvent(signal: 2, reason: "run interrupted")),
            in: run)
        status = .interrupted
        failedTask = nil
    }
    try await registry.recordTaskDuration(1_000_000, task: task, in: run)
    try await registry.finish(run, status: status, failedTask: failedTask)
    let snapshot = try await registry.recordedRun(run.id)
    let observed = try await registry.reducedEvents(in: snapshot)
    return RunTerminalSummary(snapshot: snapshot, observedState: observed)
}

private func plan(
    _ task: TaskID,
    digest: ArtifactDigest,
    isClean: Bool
) -> TaskPlanEntry {
    TaskPlanEntry(
        task: task,
        identity: digest,
        isClean: isClean,
        explanation: isClean ? "artifact is clean" : "artifact is dirty",
        coordinates: nil)
}

@Test func terminalSummaryNamesTasksDeferredLongerThanTheyRan() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-terminal-deferred-\(UUID().uuidString)",
        isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = RunRegistry(root: FilePath(directory.path))
    let run = try await registry.begin(command: ["collider", "verify", "all"])
    let deferredLongest = TaskID(rawValue: "fixture.deferred-longest")
    let deferred = TaskID(rawValue: "fixture.deferred")
    let blocked = TaskID(rawValue: "fixture.blocked")
    let expensive = TaskID(rawValue: "fixture.expensive")
    let digest = ArtifactDigest(bytes: [2])
    try await registry.recordPlan(
        [
            plan(deferredLongest, digest: digest, isClean: false),
            plan(deferred, digest: digest, isClean: false),
            plan(blocked, digest: digest, isClean: false),
            plan(expensive, digest: digest, isClean: false),
        ],
        in: run)
    for task in [deferredLongest, deferred, blocked, expensive] {
        try await registry.record(.task(.started(task)), in: run)
        try await registry.recordTaskOutcome(.executed, task: task, in: run)
        try await registry.record(.task(.succeeded(task)), in: run)
    }
    let second: UInt64 = 1_000_000_000
    try await registry.recordTaskDuration(10 * second, task: deferredLongest, in: run)
    try await registry.recordTaskSchedulingWait(900 * second, task: deferredLongest, in: run)
    try await registry.recordTaskDuration(10 * second, task: deferred, in: run)
    try await registry.recordTaskSchedulingWait(300 * second, task: deferred, in: run)
    // A task the graph held back is ready only once its dependencies finish, so
    // it records no wait and is not evidence of an ordering decision.
    try await registry.recordTaskDuration(500 * second, task: blocked, in: run)
    try await registry.recordTaskSchedulingWait(0, task: blocked, in: run)
    // Waiting is not by itself a deferral worth naming; waiting longer than the
    // work takes is.
    try await registry.recordTaskDuration(900 * second, task: expensive, in: run)
    try await registry.recordTaskSchedulingWait(400 * second, task: expensive, in: run)
    try await registry.finish(run, status: .succeeded, failedTask: nil)

    let snapshot = try await registry.recordedRun(run.id)
    let observed = try await registry.reducedEvents(in: snapshot)
    let summary = RunTerminalSummary(snapshot: snapshot, observedState: observed)

    #expect(
        summary.deferredTasks.map(\.task) == [
            "fixture.deferred-longest", "fixture.deferred",
        ])
    #expect(summary.deferredTaskCount == 2)
    // The report has to carry both numbers, because the deferral is only
    // legible against what the work itself cost.
    #expect(
        summary.text.contains(
            "waited 900.0 s, ran 10.0 s  executed  fixture.deferred-longest"))
}
