import ColliderCore
import ColliderPersistence
import Foundation
import SystemPackage
import Testing

@testable import ColliderWorkspaceCommands

private enum TerminalFixtureOutcome: CaseIterable, Sendable {
    case succeeded
    case failed
    case cancelled
    case interrupted
}

private final class TerminalConsoleCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func write(_ data: Data) {
        lock.withLock { storage.append(data) }
    }

    var text: String {
        lock.withLock { String(decoding: storage, as: UTF8.self) }
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
    #expect(jsonError.text == "working\n")
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
