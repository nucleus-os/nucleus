import ColliderCore
import ColliderPersistence
import ColliderWorkspaceCommands
import Foundation

struct RunProgressSemanticState: Equatable, Sendable {
    let runID: RunID?
    let phase: RunProgressPhase
    let completionFraction: Double
    let completedTaskCount: Int
    let totalTaskCount: Int
    let hostPhase: RunHostPhase?
    let activeRows: [RunProgressRow]
    let residualActiveRowCount: Int

    init(_ snapshot: RunProgressSnapshot) {
        runID = snapshot.runID
        phase = snapshot.phase
        let quantum = 0.05
        completionFraction = min(
            1,
            floor((snapshot.completionFraction + .ulpOfOne) / quantum) * quantum)
        completedTaskCount = snapshot.completedTaskCount
        totalTaskCount = snapshot.totalTaskCount
        hostPhase = snapshot.hostPhase
        activeRows = snapshot.activeRows
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
                try? console.progress("still running  \(task.rawValue)")
                self.lastEmissionDate = date
            }
        case .githubActions:
            presentSemanticChange(snapshot, at: date)
            if let pendingAppendSnapshot,
                canEmit(at: date)
            {
                self.pendingAppendSnapshot = nil
                emit(pendingAppendSnapshot, at: date)
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
            let semantic = RunProgressSemanticState(snapshot)
            if semantic != lastSemanticState || pendingAppendSnapshot != nil {
                pendingAppendSnapshot = nil
                emit(snapshot, at: date)
            }
        case .githubActions:
            let semantic = RunProgressSemanticState(snapshot)
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
        let semantic = RunProgressSemanticState(snapshot)
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

    private func canEmit(at date: Date) -> Bool {
        guard let lastEmissionDate else { return true }
        return date.timeIntervalSince(lastEmissionDate) >= minimumAppendInterval
    }

    private func emit(_ snapshot: RunProgressSnapshot, at date: Date) {
        lastSemanticState = RunProgressSemanticState(snapshot)
        lastEmissionDate = date
        try? console.progress(snapshot)
    }
}

func consumeRunObservations(
    _ observations: AsyncStream<RunObservation>,
    console: CommandConsole,
    registry: RunRegistry,
    run: RunHandle?
) async {
    let reporter = RunProgressReporter(console: console)
    let githubReporter = run.map {
        GitHubActionsRunReporter(
            console: console,
            registry: registry,
            run: $0)
    }
    let ticker = Task {
        while !Task.isCancelled {
            try? await Task.sleep(for: RunProgressReporter.repaintInterval)
            guard !Task.isCancelled else { return }
            await reporter.pulse()
        }
    }
    defer { ticker.cancel() }
    for await observation in observations {
        await reporter.consume(observation)
        await githubReporter?.consume(observation)
    }
    await reporter.finish()
}
