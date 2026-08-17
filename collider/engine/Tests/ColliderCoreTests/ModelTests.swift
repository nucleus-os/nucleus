import Foundation
import Testing

@testable import ColliderCore

@Test func runEventReducerReconstructsTerminalTaskState() throws {
    let runID = RunID(rawValue: "fixture")
    let clean = TaskID(rawValue: "fixture.clean")
    let failed = TaskID(rawValue: "fixture.failed")
    let failure = ExecutionFailure(
        task: failed,
        operation: "swift build",
        command: ["swift", "build"],
        status: 1,
        invocation: "swift build",
        workingDirectory: "/workspace",
        logPath: "/runs/fixture/stages/fixture-failed.log",
        reason: "child command failed")
    let events = [
        RunEvent(
            sequence: 0,
            timestamp: "2026-08-08T00:00:00Z",
            runID: runID,
            payload: .runStarted(resumed: false)),
        RunEvent(
            sequence: 1,
            timestamp: "2026-08-08T00:00:01Z",
            runID: runID,
            payload: .task(.skipped(task: clean, explanation: "inputs unchanged"))),
        RunEvent(
            sequence: 2,
            timestamp: "2026-08-08T00:00:02Z",
            runID: runID,
            payload: .task(.started(failed))),
        RunEvent(
            sequence: 3,
            timestamp: "2026-08-08T00:00:03Z",
            runID: runID,
            payload: .task(.failed(task: failed, failure: failure))),
        RunEvent(
            sequence: 4,
            timestamp: "2026-08-08T00:00:04Z",
            runID: runID,
            payload: .terminal(
                TerminalRunEvent(status: .failed, failedTask: failed))),
    ]

    let state = try RunEventReducer.reduce(events)

    #expect(state.runID == runID)
    #expect(state.status == .failed)
    #expect(state.tasks[clean] == .skipped(explanation: "inputs unchanged"))
    #expect(state.tasks[failed] == .failed(failure))
    #expect(state.failedTask == failed)
}

@Test func runEventReducerRejectsSequenceGaps() {
    let event = RunEvent(
        sequence: 1,
        timestamp: "2026-08-08T00:00:00Z",
        runID: RunID(rawValue: "fixture"),
        payload: .runStarted(resumed: false))

    #expect(throws: RunEventReductionFailure.self) {
        try RunEventReducer.reduce([event])
    }
}

@Test func runProgressSnapshotTracksPlanLanesDetailsAndMonotonicCompletion() throws {
    let runID = RunID(rawValue: "progress")
    let clean = TaskID(rawValue: "clean")
    let first = TaskID(rawValue: "first")
    let second = TaskID(rawValue: "second")
    let identity = ArtifactDigest(bytes: [UInt8](repeating: 1, count: 32))
    var reducer = RunEventReducer()
    try reducer.consume(
        runEvent(0, runID: runID, payload: .runStarted(resumed: false)))
    #expect(reducer.progressSnapshot(at: progressDate(0)).phase == .planning)

    try reducer.consumePlan(
        [
            TaskPlanEntry(
                task: clean,
                identity: identity,
                isClean: true,
                explanation: "clean",
                coordinates: nil),
            TaskPlanEntry(
                task: first,
                identity: identity,
                isClean: false,
                explanation: "dirty",
                coordinates: nil,
                lane: .oci),
            TaskPlanEntry(
                task: second,
                identity: identity,
                isClean: false,
                explanation: "dirty",
                coordinates: nil,
                lane: .hostExclusive),
        ],
        runID: runID)
    var snapshot = reducer.progressSnapshot(at: progressDate(1))
    #expect(snapshot.phase == .executing)
    #expect(snapshot.totalTaskCount == 2)
    #expect(snapshot.completedTaskCount == 0)

    try reducer.consume(
        runEvent(
            1,
            runID: runID,
            payload: .task(.skipped(task: clean, explanation: "clean"))))
    try reducer.consume(
        runEvent(2, runID: runID, payload: .task(.started(first))))
    try reducer.consume(
        runEvent(
            3,
            runID: runID,
            payload: .operation(.started(progressOperation(task: first)))))
    snapshot = reducer.progressSnapshot(at: progressDate(3))
    #expect(snapshot.activeRows.first?.lane == .oci)
    #expect(snapshot.activeRows.first?.detail == .operation("compile"))

    try reducer.consume(
        runEvent(
            4,
            runID: runID,
            payload: .wait(.started(task: first, resource: "workspace"))))
    #expect(
        reducer.progressSnapshot(at: progressDate(4)).activeRows.first?.detail
            == .waiting("workspace"))
    try reducer.consume(
        runEvent(
            5,
            runID: runID,
            payload: .wait(.finished(task: first, resource: "workspace"))))
    try reducer.consume(
        runEvent(
            6,
            runID: runID,
            payload: .download(
                DownloadEvent(
                    task: first,
                    digest: identity,
                    receivedBytes: 512,
                    expectedBytes: 1_024))))
    #expect(
        reducer.progressSnapshot(at: progressDate(6)).activeRows.first?.detail
            == .download(receivedBytes: 512, expectedBytes: 1_024))

    try reducer.consume(
        runEvent(7, runID: runID, payload: .task(.succeeded(first))))
    let half = reducer.progressSnapshot(at: progressDate(7))
    #expect(half.completedTaskCount == 1)
    #expect(half.completionFraction == 0.5)
    try reducer.consume(
        runEvent(8, runID: runID, payload: .task(.started(second))))
    try reducer.consume(
        runEvent(9, runID: runID, payload: .task(.cancelled(second))))
    let complete = reducer.progressSnapshot(at: progressDate(9))
    #expect(complete.completedTaskCount == 2)
    #expect(complete.completionFraction == 1)
    #expect(complete.completionFraction >= half.completionFraction)
}

@Test func runProgressSnapshotReducesNestedHostPhasesCountersAndTasklessWork() throws {
    let runID = RunID(rawValue: "host-progress")
    let outer = HostPhaseID(rawValue: "outer")
    let inner = HostPhaseID(rawValue: "inner")
    var reducer = RunEventReducer()
    try reducer.consume(
        runEvent(0, runID: runID, payload: .runStarted(resumed: false)))
    try reducer.consume(
        runEvent(
            1,
            runID: runID,
            payload: .hostPhase(
                .started(id: outer, name: "cache status", totalItems: nil))))
    #expect(reducer.progressSnapshot(at: progressDate(1)).hostPhase?.name == "cache status")

    try reducer.consume(
        runEvent(
            2,
            runID: runID,
            payload: .hostPhase(
                .started(id: inner, name: "measuring storage", totalItems: 4))))
    try reducer.consume(
        runEvent(
            3,
            runID: runID,
            payload: .hostPhase(
                .advanced(id: inner, completedItems: 2, totalItems: 4))))
    let snapshot = reducer.progressSnapshot(at: progressDate(3))
    #expect(snapshot.hostPhase?.name == "measuring storage")
    #expect(snapshot.hostPhase?.completedItems == 2)
    #expect(snapshot.hostPhase?.totalItems == 4)
    #expect(snapshot.completionFraction == 0)

    try reducer.consume(
        runEvent(4, runID: runID, payload: .hostPhase(.finished(inner))))
    #expect(reducer.progressSnapshot(at: progressDate(4)).hostPhase?.name == "cache status")
    try reducer.consume(
        runEvent(5, runID: runID, payload: .hostPhase(.finished(outer))))
    try reducer.consume(
        runEvent(
            6,
            runID: runID,
            payload: .wait(.started(task: nil, resource: "host execution admission"))))
    #expect(
        reducer.progressSnapshot(at: progressDate(6)).hostPhase?.name
            == "waiting for host execution admission")
    try reducer.consume(
        runEvent(
            7,
            runID: runID,
            payload: .wait(.finished(task: nil, resource: "host execution admission"))))
    let operation = progressOperation(task: nil)
    try reducer.consume(
        runEvent(8, runID: runID, payload: .operation(.started(operation))))
    #expect(reducer.progressSnapshot(at: progressDate(8)).hostPhase?.name == "compile")
    try reducer.consume(
        runEvent(
            9,
            runID: runID,
            payload: .operation(
                .finished(
                    OperationResult(
                        context: operation,
                        status: 0,
                        signal: nil,
                        timedOut: false)))))
    #expect(reducer.progressSnapshot(at: progressDate(9)).hostPhase == nil)
}

@Test func runProgressSnapshotBoundsRowsAndAcceptsResumedSequencePrefixes() throws {
    let runID = RunID(rawValue: "resumed")
    let identity = ArtifactDigest(bytes: [UInt8](repeating: 2, count: 32))
    let tasks = (0..<3).map { TaskID(rawValue: "task-\($0)") }
    var reducer = RunEventReducer(startingAtSequence: 20)
    try reducer.consume(
        runEvent(
            20,
            runID: runID,
            payload: .runStarted(resumed: true),
            second: 0))
    try reducer.consumePlan(
        tasks.map {
            TaskPlanEntry(
                task: $0,
                identity: identity,
                isClean: false,
                explanation: "dirty",
                coordinates: nil)
        },
        runID: runID)
    for (offset, task) in tasks.enumerated() {
        try reducer.consume(
            runEvent(
                UInt64(21 + offset),
                runID: runID,
                payload: .task(.started(task)),
                second: offset + 1))
    }
    let snapshot = reducer.progressSnapshot(
        at: progressDate(5),
        maximumRows: 2)
    #expect(snapshot.activeRows.map(\.task) == Array(tasks.prefix(2)))
    #expect(snapshot.residualActiveRowCount == 1)
    #expect(snapshot.elapsedNanoseconds == 5_000_000_000)

    var cleanOnly = RunEventReducer()
    try cleanOnly.consume(
        runEvent(0, runID: runID, payload: .runStarted(resumed: false)))
    try cleanOnly.consumePlan(
        [
            TaskPlanEntry(
                task: tasks[0],
                identity: identity,
                isClean: true,
                explanation: "clean",
                coordinates: nil)
        ],
        runID: runID)
    #expect(cleanOnly.progressSnapshot(at: progressDate(0)).completionFraction == 1)
}

@Test func runProgressElapsedTimeParsesFractionalEventsAndStopsAtTerminal() throws {
    let runID = RunID(rawValue: "fractional-time")
    var reducer = RunEventReducer()
    try reducer.consume(
        RunEvent(
            sequence: 0,
            timestamp: "2026-08-08T00:00:00.100Z",
            runID: runID,
            payload: .runStarted(resumed: false)))
    try reducer.consume(
        RunEvent(
            sequence: 1,
            timestamp: "2026-08-08T00:00:02.600Z",
            runID: runID,
            payload: .terminal(TerminalRunEvent(status: .succeeded))))

    let snapshot = reducer.progressSnapshot(
        at: ISO8601DateFormatter().date(from: "2026-08-08T00:01:00Z")!)
    #expect(snapshot.phase == .succeeded)
    #expect(snapshot.elapsedNanoseconds == 2_500_000_000)
}

@Test func weightedProgressAdvancesRunningTasksWithoutCompletingEarly() throws {
    let runID = RunID(rawValue: "weighted")
    let heavy = TaskID(rawValue: "heavy")
    let light = TaskID(rawValue: "light")
    let identity = ArtifactDigest(bytes: [4])
    func entry(
        _ task: TaskID,
        estimate: UInt64
    ) -> TaskPlanEntry {
        let workload = TaskDurationWorkload(
            task: task,
            lane: .oci,
            coordinates: nil,
            mode: "release")
        return TaskPlanEntry(
            task: task,
            identity: identity,
            isClean: false,
            explanation: "dirty",
            coordinates: nil,
            lane: .oci,
            durationWorkload: workload,
            durationEstimate: TaskDurationEstimate(
                workload: workload,
                durationNanoseconds: estimate))
    }
    var reducer = RunEventReducer()
    try reducer.consume(
        runEvent(0, runID: runID, payload: .runStarted(resumed: false)))
    try reducer.consumePlan(
        [
            entry(heavy, estimate: 10_000_000_000),
            entry(light, estimate: 1_000_000_000),
        ],
        runID: runID)
    try reducer.consume(
        runEvent(1, runID: runID, payload: .task(.started(heavy)), second: 0))

    let halfway = reducer.progressSnapshot(at: progressDate(5))
    #expect(abs(halfway.completionFraction - 4.5 / 11.0) < 0.000_001)
    let exceeded = reducer.progressSnapshot(at: progressDate(20))
    #expect(abs(exceeded.completionFraction - 9.0 / 11.0) < 0.000_001)
    #expect(exceeded.completionFraction < 1)

    try reducer.consume(
        runEvent(2, runID: runID, payload: .task(.started(light)), second: 21))
    let overlapping = reducer.progressSnapshot(at: progressDate(22))
    #expect(overlapping.completionFraction >= exceeded.completionFraction)
    #expect(abs(overlapping.completionFraction - 9.9 / 11.0) < 0.000_001)

    try reducer.consume(
        runEvent(3, runID: runID, payload: .task(.succeeded(heavy)), second: 23))
    let heavyFinished = reducer.progressSnapshot(at: progressDate(23))
    #expect(heavyFinished.completionFraction >= overlapping.completionFraction)
    #expect(heavyFinished.completionFraction < 1)
    try reducer.consume(
        runEvent(4, runID: runID, payload: .task(.cancelled(light)), second: 24))
    #expect(reducer.progressSnapshot(at: progressDate(24)).completionFraction == 1)
}

private func runEvent(
    _ sequence: UInt64,
    runID: RunID,
    payload: RunEvent.Payload,
    second: Int? = nil
) -> RunEvent {
    let value = second ?? Int(sequence)
    return RunEvent(
        sequence: sequence,
        timestamp: progressTimestamp(value),
        runID: runID,
        payload: payload)
}

private func progressDate(_ second: Int) -> Date {
    ISO8601DateFormatter().date(from: progressTimestamp(second))!
}

private func progressTimestamp(_ second: Int) -> String {
    let value = second < 10 ? "0\(second)" : "\(second)"
    return "2026-08-08T00:00:\(value)Z"
}

private func progressOperation(task: TaskID?) -> OperationContext {
    OperationContext(
        task: task,
        operation: "compile",
        command: ["swift", "build"],
        invocation: "swift build",
        workingDirectory: "/workspace",
        logPath: nil)
}

@Test func artifactDigestHasAnAlgorithmLabel() {
    #expect(
        ArtifactDigest(bytes: [0, 1, 254, 255]).description
            == "sha256:0001feff")
}

@Test func artifactDigestParsesOnlyCompleteLowercaseSHA256() {
    let value = String(repeating: "0a", count: 32)
    #expect(ArtifactDigest(sha256Hex: value)?.description == "sha256:" + value)
    #expect(ArtifactDigest(sha256Hex: String(repeating: "0A", count: 32)) == nil)
    #expect(ArtifactDigest(sha256Hex: "00") == nil)
}

@Test func downloadSpecificationsRejectUnboundedOrUnverifiedInputs() throws {
    let digest = ArtifactDigest(bytes: [UInt8](repeating: 0, count: 32))
    #expect(throws: DownloadSpecFailure.self) {
        try DownloadSpec(
            url: URL(string: "http://example.invalid/archive")!,
            permittedRedirectOrigins: [],
            expectedDigest: digest,
            maximumResponseSize: 1,
            acceptedMediaTypes: ["application/octet-stream"])
    }
    #expect(throws: DownloadSpecFailure.self) {
        try DownloadSpec(
            url: URL(string: "https://user:secret@example.invalid/archive")!,
            permittedRedirectOrigins: [],
            expectedDigest: digest,
            maximumResponseSize: 1,
            acceptedMediaTypes: ["application/octet-stream"])
    }
    #expect(throws: DownloadSpecFailure.self) {
        try DownloadSpec(
            url: URL(string: "https://example.invalid/archive")!,
            permittedRedirectOrigins: [],
            expectedDigest: ArtifactDigest(bytes: [0]),
            maximumResponseSize: 1,
            acceptedMediaTypes: ["application/octet-stream"])
    }
    #expect(throws: DownloadSpecFailure.self) {
        try DownloadSpec(
            url: URL(string: "https://example.invalid/archive")!,
            permittedRedirectOrigins: [],
            expectedDigest: digest,
            maximumResponseSize: 0,
            acceptedMediaTypes: ["application/octet-stream"])
    }
}
