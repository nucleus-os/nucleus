import AsyncAlgorithms
import ColliderCore
import ColliderPersistence
import ColliderWorkspaceCommands
import Foundation
import SystemPackage

struct RunProgressSemanticState: Equatable, Sendable {
    let runID: RunID?
    let phase: RunProgressPhase
    let completionFraction: Double
    let completedTaskCount: Int
    let totalTaskCount: Int
    let hostPhase: RunHostPhase?
    let activeRows: [RunProgressRow]
    let residualActiveRowCount: Int

    /// `includingRowDetail: false` keeps which tasks are running but drops what
    /// each is currently doing, so a transition means a task started or
    /// finished rather than a task emitted a line. Sinks that append rather
    /// than repaint need that coarser notion: the detail changes continuously
    /// for the whole life of a long compile, and every change would otherwise
    /// become another permanent line.
    init(_ snapshot: RunProgressSnapshot, includingRowDetail: Bool = true) {
        runID = snapshot.runID
        phase = snapshot.phase
        let quantum = 0.05
        completionFraction = min(
            1,
            floor((snapshot.completionFraction + .ulpOfOne) / quantum) * quantum)
        completedTaskCount = snapshot.completedTaskCount
        totalTaskCount = snapshot.totalTaskCount
        hostPhase = snapshot.hostPhase
        activeRows =
            includingRowDetail
            ? snapshot.activeRows
            : snapshot.activeRows.map {
                RunProgressRow(
                    task: $0.task,
                    lane: $0.lane,
                    startedAt: $0.startedAt,
                    detail: .running)
            }
        residualActiveRowCount = snapshot.residualActiveRowCount
    }
}

actor RunProgressReporter {
    static let repaintInterval = Duration.milliseconds(100)
    static let minimumAppendInterval: TimeInterval = 0.5
    static let livenessInterval: TimeInterval = 60

    private let console: CommandConsole
    private let minimumAppendInterval: TimeInterval
    private let livenessInterval: TimeInterval
    private var reducer: RunEventReducer?
    private var latestSnapshot: RunProgressSnapshot?
    private var lastSemanticState: RunProgressSemanticState?
    private var pendingAppendSnapshot: RunProgressSnapshot?
    private var lastEmissionDate: Date?

    init(
        console: CommandConsole,
        minimumAppendInterval: TimeInterval = RunProgressReporter.minimumAppendInterval,
        livenessInterval: TimeInterval = RunProgressReporter.livenessInterval
    ) {
        self.console = console
        self.minimumAppendInterval = minimumAppendInterval
        self.livenessInterval = livenessInterval
    }

    func consume(_ observation: RunObservation, at date: Date = Date()) {
        do {
            switch observation {
            case .plan(let plan):
                if reducer == nil { reducer = RunEventReducer() }
                // Planning is the only place a lowered task's component and
                // product survive: the name it carries from here on is the
                // digest of its identity. Handing them to the console once is
                // what lets every later human rendering of that task say what
                // it is.
                console.recordTaskLabels(
                    Dictionary(
                        plan.entries.compactMap { entry in
                            entry.attribution.map { (entry.task, $0) }
                        },
                        uniquingKeysWith: { existing, _ in existing }))
                try reducer?.consumePlan(plan.entries, runID: plan.runID)
            case .event(let event):
                if reducer == nil {
                    reducer = RunEventReducer(startingAtSequence: event.sequence)
                }
                try reducer?.consume(event)
            }
            guard let snapshot = reducer?.progressSnapshot(at: date) else { return }
            latestSnapshot = snapshot
            presentSemanticChange(snapshot, at: date)
        } catch {
            return
        }
    }

    func present(_ snapshot: RunProgressSnapshot, at date: Date = Date()) {
        latestSnapshot = snapshot
        presentSemanticChange(snapshot, at: date)
    }

    func pulse(at date: Date = Date()) {
        guard let snapshot = reducer?.progressSnapshot(at: date) ?? latestSnapshot else { return }
        latestSnapshot = snapshot
        switch console.progressPresentation {
        case .dynamic:
            try? console.progress(snapshot)
        case .appendOnly:
            presentSemanticChange(snapshot, at: date)
            if let pendingAppendSnapshot,
                canEmit(at: date)
            {
                self.pendingAppendSnapshot = nil
                emit(pendingAppendSnapshot, at: date)
            } else if pendingAppendSnapshot == nil,
                let lastEmissionDate,
                date.timeIntervalSince(lastEmissionDate) >= livenessInterval,
                let task = snapshot.activeRows.first?.task
            {
                try? console.progress(
                    "still running  \(console.displayName(for: task))")
                self.lastEmissionDate = date
            }
        case .githubActions:
            presentSemanticChange(snapshot, at: date)
            if let pendingAppendSnapshot,
                canEmit(at: date)
            {
                self.pendingAppendSnapshot = nil
                emit(pendingAppendSnapshot, at: date)
            } else if pendingAppendSnapshot == nil,
                let lastEmissionDate,
                date.timeIntervalSince(lastEmissionDate) >= livenessInterval,
                let task = snapshot.activeRows.first?.task
            {
                // Transitions alone can leave hours of silence while one task
                // compiles, which is indistinguishable from a hang.
                try? console.progress(
                    "still running  \(console.displayName(for: task))")
                self.lastEmissionDate = date
            }
        case .disabled, .machine:
            break
        }
    }

    func finish(at date: Date = Date()) {
        guard let snapshot = reducer?.progressSnapshot(at: date) ?? latestSnapshot else { return }
        latestSnapshot = snapshot
        switch console.progressPresentation {
        case .dynamic:
            try? console.progress(snapshot)
        case .appendOnly:
            let semantic = semanticState(snapshot)
            if semantic != lastSemanticState || pendingAppendSnapshot != nil {
                pendingAppendSnapshot = nil
                emit(snapshot, at: date)
            }
        case .githubActions:
            let semantic = semanticState(snapshot)
            if semantic != lastSemanticState || pendingAppendSnapshot != nil {
                pendingAppendSnapshot = nil
                emit(snapshot, at: date)
            }
        case .disabled, .machine:
            break
        }
    }

    private func presentSemanticChange(
        _ snapshot: RunProgressSnapshot,
        at date: Date
    ) {
        let semantic = semanticState(snapshot)
        guard semantic != lastSemanticState else { return }
        switch console.progressPresentation {
        case .dynamic:
            break
        case .appendOnly:
            if canEmit(at: date) {
                pendingAppendSnapshot = nil
                emit(snapshot, at: date)
            } else {
                pendingAppendSnapshot = snapshot
            }
        case .githubActions:
            if canEmit(at: date) {
                pendingAppendSnapshot = nil
                emit(snapshot, at: date)
            } else {
                pendingAppendSnapshot = snapshot
            }
        case .machine:
            lastSemanticState = semantic
            try? console.progress(snapshot)
            lastEmissionDate = date
        case .disabled:
            lastSemanticState = semantic
        }
    }

    /// GitHub Actions renders an append-only log, so a repaint there is a new
    /// permanent line. Task output must not drive emissions in that sink: the
    /// completed output of every task already reaches the log in full, inside
    /// the collapsible group `GitHubActionsRunReporter` writes when the task
    /// finishes, so sampling it again at the top level only duplicates it where
    /// nothing can fold it away.
    private func semanticState(_ snapshot: RunProgressSnapshot) -> RunProgressSemanticState {
        RunProgressSemanticState(
            snapshot,
            includingRowDetail: console.progressPresentation != .githubActions)
    }

    private func canEmit(at date: Date) -> Bool {
        guard let lastEmissionDate else { return true }
        return date.timeIntervalSince(lastEmissionDate) >= minimumAppendInterval
    }

    private func emit(_ snapshot: RunProgressSnapshot, at date: Date) {
        lastSemanticState = semanticState(snapshot)
        lastEmissionDate = date
        try? console.progress(snapshot)
    }
}

/// Observations, repaints, and the end of the run reach the reporter as one
/// event kind, so a single consumer orders them instead of two tasks racing.
private enum RunProgressEvent: Sendable {
    case observation(RunObservation)
    case pulse
    case finished
}

func consumeRunObservations(
    _ observations: AsyncStream<RunObservation>,
    console: CommandConsole,
    registry: RunRegistry,
    run: RunHandle?,
    workspaceRoot: FilePath,
    repaintInterval: Duration = RunProgressReporter.repaintInterval
) async {
    let reporter = RunProgressReporter(console: console)
    let githubReporter = run.map {
        GitHubActionsRunReporter(
            console: console,
            registry: registry,
            run: $0,
            workspaceRoot: workspaceRoot)
    }
    // The observation branch is finite, so chaining one terminal event gives the
    // merged sequence an explicit end. The timer branch never ends on its own:
    // leaving the loop retires the merged iterator, which cancels it.
    let events = merge(
        chain(
            observations.map(RunProgressEvent.observation),
            [RunProgressEvent.finished].async),
        AsyncTimerSequence(interval: repaintInterval, clock: .continuous)
            .map { _ in RunProgressEvent.pulse })
    consumption: for await event in events {
        switch event {
        case .observation(let observation):
            await reporter.consume(observation)
            await githubReporter?.consume(observation)
        case .pulse:
            await reporter.pulse()
        case .finished:
            break consumption
        }
    }
    // Reached once, by both the terminal event and caller cancellation.
    await reporter.finish()
}
