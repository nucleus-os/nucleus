import ColliderCore
import ColliderPersistence
import Foundation
import Synchronization
import SystemPackage
import Testing

@testable import ColliderCLI
@testable import ColliderWorkspaceCommands

private final class ProgressCapture: Sendable {
    private let data = Mutex(Data())

    func write(_ bytes: Data) {
        data.withLock { $0.append(bytes) }
    }

    var text: String {
        data.withLock { String(decoding: $0, as: UTF8.self) }
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
        run: run,
        workspaceRoot: FilePath(directory.path))
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

/// A stage log that blames a source line the checkout actually contains must
/// annotate that line, so the failure lands on the file rather than only naming
/// the task. The compiler saw the file at its own mount point, which is why the
/// annotation path is resolved against the checkout instead of taken as given.
@Test func githubReporterAnnotatesAResolvedSourceLocation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-github-diagnostic-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let checkout = directory.appendingPathComponent("checkout")
    let source = checkout.appendingPathComponent("core/swift/Sources")
    try FileManager.default.createDirectory(
        at: source, withIntermediateDirectories: true)
    FileManager.default.createFile(
        atPath: source.appendingPathComponent("A.swift").path, contents: nil)

    let registry = RunRegistry(root: FilePath(directory.appendingPathComponent("runs").path))
    let run = try await registry.begin(command: ["collider", "build", "fixture"])
    let task = TaskID(rawValue: "fixture.build")
    try await registry.appendLog(
        Array(
            ("/nucleus-workspace/core/swift/Sources/A.swift:12:5: "
                + "error: cannot find 'x' in scope\n").utf8),
        stage: task,
        in: run)
    let capture = ProgressCapture()
    let console = CommandConsole(
        progress: .always,
        environment: ["GITHUB_ACTIONS": "true"],
        standardOutput: { _ in },
        standardError: capture.write)
    let reporter = GitHubActionsRunReporter(
        console: console,
        registry: registry,
        run: run,
        workspaceRoot: FilePath(checkout.path))
    let failure = ExecutionFailure(
        task: task,
        logPath: await registry.stageLogPath(for: task, in: run).string,
        reason: "Swift package command failed")

    await reporter.consume(
        .event(
            RunEvent(
                sequence: 1,
                timestamp: "2026-08-17T00:00:00Z",
                runID: run.id,
                payload: .task(.failed(task: task, failure: failure)))))

    #expect(
        capture.text.contains(
            "::error file=core/swift/Sources/A.swift,line=12,col=5,"
                + "title=Collider task fixture.build::"))
    #expect(capture.text.contains("cannot find 'x' in scope"))
    try await registry.finish(run, status: .failed, failedTask: task)
}

// MARK: - Merged run-observation consumption

private func mergedFixture() -> (ProgressCapture, CommandConsole, RunRegistry, URL) {
    let capture = ProgressCapture()
    // Dynamic presentation renders only on a pulse or on the final render, so
    // every rendered row in the capture is one of the two.
    let console = CommandConsole(
        progress: .always,
        standardErrorIsTerminal: true,
        standardOutput: { _ in },
        standardError: capture.write)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-merged-observations-\(UUID().uuidString)",
        isDirectory: true)
    return (capture, console, RunRegistry(root: FilePath(directory.path)), directory)
}

/// A plan alone renders nothing: an active row needs a dirty planned task that
/// has also started, and the rendered row is what the render count matches on.
private func yieldFixture(into continuation: AsyncStream<RunObservation>.Continuation) {
    let task = TaskID(rawValue: "fixture.build")
    continuation.yield(
        .plan(
            RunPlanObservation(
                runID: RunID(rawValue: "fixture"),
                entries: [
                    TaskPlanEntry(
                        task: task,
                        identity: ArtifactDigest(bytes: [1]),
                        isClean: false,
                        explanation: "artifact is dirty",
                        coordinates: nil)
                ])))
    continuation.yield(
        .event(
            RunEvent(
                sequence: 0,
                timestamp: "2026-08-17T00:00:00Z",
                runID: RunID(rawValue: "fixture"),
                payload: .task(.started(task)))))
}

private func renderCount(_ capture: ProgressCapture) -> Int {
    capture.text.components(separatedBy: "fixture.build").count - 1
}

/// Polls until `condition` holds, bounded so a broken merge fails rather than
/// hanging the suite.
private func waitFor(
    _ condition: @Sendable () -> Bool,
    within limit: Duration = .seconds(5)
) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return condition()
}

@Test func mergedObservationsRenderOnceWhenTheStreamCompletesNaturally() async {
    let (capture, console, registry, directory) = mergedFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (stream, continuation) = AsyncStream<RunObservation>.makeStream()
    yieldFixture(into: continuation)
    continuation.finish()

    await consumeRunObservations(
        stream,
        console: console,
        registry: registry,
        run: nil,
        workspaceRoot: FilePath("/"),
        // No pulse can fire, so the only render is the final one.
        repaintInterval: .seconds(3_600))

    #expect(renderCount(capture) == 1)
}

@Test func mergedObservationsRepaintOnTheTimerCadence() async {
    let (capture, console, registry, directory) = mergedFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (stream, continuation) = AsyncStream<RunObservation>.makeStream()
    yieldFixture(into: continuation)

    let consumer = Task {
        await consumeRunObservations(
            stream,
            console: console,
            registry: registry,
            run: nil,
            workspaceRoot: FilePath("/"),
            repaintInterval: .milliseconds(10))
    }
    // The stream is still open, so repeated renders can only be pulses.
    #expect(await waitFor { renderCount(capture) >= 3 })
    continuation.finish()
    await consumer.value
}

@Test func mergedObservationsStopPulsingAfterTheTerminalEvent() async {
    let (capture, console, registry, directory) = mergedFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (stream, continuation) = AsyncStream<RunObservation>.makeStream()
    yieldFixture(into: continuation)

    let consumer = Task {
        await consumeRunObservations(
            stream,
            console: console,
            registry: registry,
            run: nil,
            workspaceRoot: FilePath("/"),
            repaintInterval: .milliseconds(10))
    }
    #expect(await waitFor { renderCount(capture) >= 2 })
    continuation.finish()
    await consumer.value

    // The timer branch outlives the observations, so a surviving pulse would
    // keep rendering well past the terminal event.
    let settled = renderCount(capture)
    try? await Task.sleep(for: .milliseconds(120))
    #expect(renderCount(capture) == settled)
}

@Test func mergedObservationsFinishWhenTheCallerCancels() async {
    let (capture, console, registry, directory) = mergedFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (stream, continuation) = AsyncStream<RunObservation>.makeStream()
    yieldFixture(into: continuation)

    let consumer = Task {
        await consumeRunObservations(
            stream,
            console: console,
            registry: registry,
            run: nil,
            workspaceRoot: FilePath("/"),
            repaintInterval: .milliseconds(10))
    }
    #expect(await waitFor { renderCount(capture) >= 1 })
    // The stream never finishes; cancellation is the only way out.
    consumer.cancel()
    await consumer.value
    continuation.finish()

    let settled = renderCount(capture)
    try? await Task.sleep(for: .milliseconds(120))
    #expect(renderCount(capture) == settled)
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

/// GitHub Actions renders an append-only log, so every repaint is a permanent
/// line. A running task producing output is therefore not a progress transition
/// there: its complete output already arrives inside the collapsible group
/// written when it finishes, so resampling it at the top level only duplicates
/// it where nothing can fold it away. Only starting and finishing may emit, and
/// a quiet stretch is reported by the liveness line instead.
@Test func githubReporterEmitsTaskTransitionsRatherThanTaskOutput() async {
    let capture = ProgressCapture()
    let console = CommandConsole(
        progress: .always,
        standardErrorIsTerminal: false,
        environment: ["GITHUB_ACTIONS": "true"],
        standardOutput: { _ in },
        standardError: capture.write)
    #expect(console.progressPresentation == ConsoleProgressPresentation.githubActions)
    let reporter = RunProgressReporter(
        console: console,
        minimumAppendInterval: 10,
        livenessInterval: 20)
    let start = Date(timeIntervalSince1970: 1_000)

    await reporter.present(snapshot(elapsed: 0, detail: .running), at: start)
    let afterStart = capture.text
    #expect(!afterStart.isEmpty)

    // The task is still the same task, just further along. Under the appending
    // sink that is not worth another line, however long it goes on.
    await reporter.present(
        snapshot(elapsed: 2_000_000_000, detail: .operation("compile")),
        at: start.addingTimeInterval(1))
    await reporter.pulse(at: start.addingTimeInterval(11))
    #expect(capture.text == afterStart)
    await reporter.present(
        snapshot(elapsed: 5_000_000_000, detail: .operation("link")),
        at: start.addingTimeInterval(12))
    await reporter.pulse(at: start.addingTimeInterval(13))
    #expect(capture.text == afterStart)

    // Silence still has to be distinguishable from a hang.
    await reporter.pulse(at: start.addingTimeInterval(21))
    #expect(capture.text.hasSuffix("still running  fixture.build\n"))

    // Finishing the task is a transition, so it does reach the log.
    let liveness = capture.text
    await reporter.present(
        RunProgressSnapshot(
            runID: RunID(rawValue: "fixture"),
            phase: .executing,
            completionFraction: 1,
            completedTaskCount: 1,
            totalTaskCount: 1,
            elapsedNanoseconds: 6_000_000_000,
            activeRows: [],
            residualActiveRowCount: 0),
        at: start.addingTimeInterval(40))
    await reporter.pulse(at: start.addingTimeInterval(41))
    #expect(capture.text != liveness)
}

/// A stage log exists only once a task writes to it, and plenty of tasks do
/// real work while saying nothing. A group opened over a log that was never
/// created promises output the reader will not find, so a task that succeeds
/// silently gets no group at all. A failure keeps one, because a container that
/// died before anything was captured leaves no log and saying so is the useful
/// report.
@Test func githubReporterOmitsGroupsForTasksThatWroteNothing() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-github-silent-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = RunRegistry(root: FilePath(directory.path))
    let run = try await registry.begin(command: ["collider", "build", "fixture"])
    let silent = TaskID(rawValue: "fixture.publish")
    let capture = ProgressCapture()
    let console = CommandConsole(
        progress: .always,
        environment: ["GITHUB_ACTIONS": "true"],
        standardOutput: { _ in },
        standardError: capture.write)
    let reporter = GitHubActionsRunReporter(
        console: console,
        registry: registry,
        run: run,
        workspaceRoot: FilePath(directory.path))

    await reporter.consume(
        .event(
            RunEvent(
                sequence: 1,
                timestamp: "2026-08-17T00:00:00Z",
                runID: run.id,
                payload: .task(.succeeded(silent)))))
    #expect(capture.text.isEmpty)

    // The same absence under a failure is worth reporting rather than hiding.
    let failed = TaskID(rawValue: "fixture.image")
    let failure = ExecutionFailure(
        task: failed,
        logPath: await registry.stageLogPath(for: failed, in: run).string,
        reason: "image preparation failed")
    await reporter.consume(
        .event(
            RunEvent(
                sequence: 2,
                timestamp: "2026-08-17T00:00:01Z",
                runID: run.id,
                payload: .task(.failed(task: failed, failure: failure)))))
    #expect(capture.text.contains("::group::fixture.image"))
    #expect(capture.text.contains("stage log unavailable"))
    try await registry.finish(run, status: .failed, failedTask: failed)
}
