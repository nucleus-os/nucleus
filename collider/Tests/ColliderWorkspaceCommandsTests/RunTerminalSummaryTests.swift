import ColliderCore
import ColliderPersistence
import Foundation
import SystemPackage
import Testing

@testable import ColliderWorkspaceCommands

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
