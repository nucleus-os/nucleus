import Foundation

public enum RunProgressPhase: String, Codable, Hashable, Sendable {
    case planning
    case executing
    case succeeded
    case failed
    case interrupted
    case superseded
}

public enum RunProgressDetail: Codable, Hashable, Sendable {
    case running
    case operation(String)
    case waiting(String)
    case download(receivedBytes: Int64, expectedBytes: Int64?)
}

public struct RunProgressRow: Codable, Hashable, Sendable {
    public let task: TaskID
    public let lane: TaskExecutionLane
    public let startedAt: String
    public let detail: RunProgressDetail

    public init(
        task: TaskID,
        lane: TaskExecutionLane,
        startedAt: String,
        detail: RunProgressDetail
    ) {
        self.task = task
        self.lane = lane
        self.startedAt = startedAt
        self.detail = detail
    }
}

public struct RunHostPhase: Codable, Hashable, Sendable {
    public let name: String
    public let completedItems: Int?
    public let totalItems: Int?

    public init(name: String, completedItems: Int?, totalItems: Int?) {
        self.name = name
        self.completedItems = completedItems
        self.totalItems = totalItems
    }
}

public struct RunProgressSnapshot: Codable, Hashable, Sendable {
    public let runID: RunID?
    public let phase: RunProgressPhase
    public let completionFraction: Double
    public let completedTaskCount: Int
    public let totalTaskCount: Int
    public let elapsedNanoseconds: UInt64
    public let hostPhase: RunHostPhase?
    public let activeRows: [RunProgressRow]
    public let residualActiveRowCount: Int

    public init(
        runID: RunID?,
        phase: RunProgressPhase,
        completionFraction: Double,
        completedTaskCount: Int,
        totalTaskCount: Int,
        elapsedNanoseconds: UInt64,
        hostPhase: RunHostPhase? = nil,
        activeRows: [RunProgressRow],
        residualActiveRowCount: Int
    ) {
        self.runID = runID
        self.phase = phase
        self.completionFraction = completionFraction
        self.completedTaskCount = completedTaskCount
        self.totalTaskCount = totalTaskCount
        self.elapsedNanoseconds = elapsedNanoseconds
        self.hostPhase = hostPhase
        self.activeRows = activeRows
        self.residualActiveRowCount = residualActiveRowCount
    }
}

struct RunProgressReductionState: Sendable {
    private var plan: [TaskID: TaskPlanEntry] = [:]
    private var planOrder: [TaskID: Int] = [:]
    private var runStartedAt: Date?
    private var runFinishedAt: Date?
    private var taskStartedAt: [TaskID: (text: String, date: Date?)] = [:]
    private var operations: [TaskID: OperationContext] = [:]
    private var downloads: [TaskID: DownloadEvent] = [:]
    private var waits: [TaskID: String] = [:]
    private var hostPhases: [HostPhaseID: (phase: RunHostPhase, order: UInt64)] = [:]
    private var nextHostActivityOrder: UInt64 = 0
    private var hostOperations: [(context: OperationContext, order: UInt64)] = []
    private var hostWaits: [(resource: String, order: UInt64)] = []

    mutating func consumePlan(_ entries: [TaskPlanEntry]) {
        plan = Dictionary(uniqueKeysWithValues: entries.map { ($0.task, $0) })
        planOrder = Dictionary(
            uniqueKeysWithValues: entries.enumerated().map { ($0.element.task, $0.offset) })
    }

    mutating func consumeRunStarted(_ timestamp: String) {
        runStartedAt = Self.date(timestamp) ?? runStartedAt
        runFinishedAt = nil
    }

    mutating func consumeRunTerminal(_ timestamp: String) {
        runFinishedAt = Self.date(timestamp) ?? runFinishedAt
    }

    mutating func consumeTaskStarted(_ task: TaskID, timestamp: String) {
        taskStartedAt[task] = (timestamp, Self.date(timestamp))
    }

    mutating func consumeTaskTerminal(_ task: TaskID) {
        operations[task] = nil
        downloads[task] = nil
        waits[task] = nil
    }

    mutating func consumeOperation(_ event: OperationEvent) {
        switch event {
        case .started(let context):
            if let task = context.task {
                operations[task] = context
            } else {
                nextHostActivityOrder += 1
                hostOperations.append((context, nextHostActivityOrder))
            }
        case .finished(let result):
            if let task = result.context.task {
                operations[task] = nil
            } else if let index = hostOperations.lastIndex(where: {
                $0.context == result.context
            }) {
                hostOperations.remove(at: index)
            }
        case .failed(let failure):
            if let task = failure.task {
                operations[task] = nil
            } else if let index = hostOperations.lastIndex(where: {
                $0.context.operation == failure.operation
                    && $0.context.invocation == failure.invocation
            }) {
                hostOperations.remove(at: index)
            }
        }
    }

    mutating func consumeHostPhase(_ event: HostPhaseEvent) {
        switch event {
        case .started(let id, let name, let totalItems):
            nextHostActivityOrder += 1
            hostPhases[id] = (
                RunHostPhase(
                    name: name,
                    completedItems: totalItems.map { _ in 0 },
                    totalItems: totalItems),
                nextHostActivityOrder
            )
        case .advanced(let id, let completedItems, let totalItems):
            guard let active = hostPhases[id] else { return }
            hostPhases[id] = (
                RunHostPhase(
                    name: active.phase.name,
                    completedItems: completedItems,
                    totalItems: totalItems ?? active.phase.totalItems),
                active.order
            )
        case .finished(let id), .failed(let id):
            hostPhases[id] = nil
        }
    }

    mutating func consumeDownload(_ event: DownloadEvent) {
        if let task = event.task { downloads[task] = event }
    }

    mutating func consumeWait(_ event: WaitEvent) {
        switch event {
        case .started(let task?, let resource): waits[task] = resource
        case .finished(let task?, _): waits[task] = nil
        case .started(nil, let resource):
            nextHostActivityOrder += 1
            hostWaits.append((resource, nextHostActivityOrder))
        case .finished(nil, let resource):
            if let index = hostWaits.lastIndex(where: { $0.resource == resource }) {
                hostWaits.remove(at: index)
            }
        }
    }

    func snapshot(
        runID: RunID?,
        status: RunStatus?,
        tasks: [TaskID: ReducedTaskState],
        date: Date,
        maximumRows: Int
    ) -> RunProgressSnapshot {
        let dirtyTasks = plan.values.filter { !$0.isClean }.map(\.task)
        let completed = dirtyTasks.filter { task in
            guard let state = tasks[task] else { return false }
            return switch state {
            case .running: false
            case .skipped, .succeeded, .cancelled, .failed: true
            }
        }.count
        let total = dirtyTasks.count
        let completion = completionFraction(
            dirtyTasks: dirtyTasks,
            tasks: tasks,
            date: date)
        let active = dirtyTasks.compactMap { task -> RunProgressRow? in
            guard tasks[task] == .running,
                let entry = plan[task],
                let started = taskStartedAt[task]
            else { return nil }
            let detail: RunProgressDetail =
                if let wait = waits[task] {
                    .waiting(wait)
                } else if let download = downloads[task] {
                    .download(
                        receivedBytes: download.receivedBytes,
                        expectedBytes: download.expectedBytes)
                } else if let operation = operations[task] {
                    .operation(operation.operation)
                } else {
                    .running
                }
            return RunProgressRow(
                task: task,
                lane: entry.lane,
                startedAt: started.text,
                detail: detail)
        }.sorted { left, right in
            let leftDate = taskStartedAt[left.task]?.date
            let rightDate = taskStartedAt[right.task]?.date
            if leftDate != rightDate {
                return (leftDate ?? .distantFuture) < (rightDate ?? .distantFuture)
            }
            return planOrder[left.task, default: .max] < planOrder[right.task, default: .max]
        }
        let bounded = Array(active.prefix(max(0, maximumRows)))
        let elapsed: UInt64 =
            runStartedAt.map { started in
                let end = runFinishedAt ?? date
                return UInt64(max(0, end.timeIntervalSince(started)) * 1_000_000_000)
            } ?? 0
        return RunProgressSnapshot(
            runID: runID,
            phase: phase(status: status),
            completionFraction: completion,
            completedTaskCount: completed,
            totalTaskCount: total,
            elapsedNanoseconds: elapsed,
            hostPhase: activeHostPhase(status: status),
            activeRows: bounded,
            residualActiveRowCount: active.count - bounded.count)
    }

    private func activeHostPhase(status: RunStatus?) -> RunHostPhase? {
        guard status == nil || status == .running else { return nil }
        let explicit = hostPhases.values.max(by: { $0.order < $1.order })
        let wait = hostWaits.max(by: { $0.order < $1.order })
        let operation = hostOperations.max(by: { $0.order < $1.order })
        let candidates: [(phase: RunHostPhase, order: UInt64)] = [
            explicit,
            wait.map {
                (
                    RunHostPhase(
                        name: "waiting for \($0.resource)",
                        completedItems: nil,
                        totalItems: nil),
                    $0.order
                )
            },
            operation.map {
                (
                    RunHostPhase(
                        name: $0.context.operation,
                        completedItems: nil,
                        totalItems: nil),
                    $0.order
                )
            },
        ].compactMap { $0 }
        return candidates.max(by: { $0.order < $1.order })?.phase
    }

    private func phase(status: RunStatus?) -> RunProgressPhase {
        switch status {
        case .succeeded: .succeeded
        case .failed: .failed
        case .interrupted: .interrupted
        case .superseded: .superseded
        case .running: plan.isEmpty ? .planning : .executing
        case nil: .planning
        }
    }

    private func completionFraction(
        dirtyTasks: [TaskID],
        tasks: [TaskID: ReducedTaskState],
        date: Date
    ) -> Double {
        guard !dirtyTasks.isEmpty else { return plan.isEmpty ? 0 : 1 }
        let estimates = dirtyTasks.compactMap { plan[$0]?.durationEstimate }
        guard estimates.count == dirtyTasks.count else {
            let completed = dirtyTasks.count { task in
                guard let state = tasks[task] else { return false }
                return state != .running
            }
            return Double(completed) / Double(dirtyTasks.count)
        }
        let totalWeight = estimates.reduce(0.0) {
            $0 + Double($1.durationNanoseconds)
        }
        guard totalWeight > 0 else { return 0 }
        let earned = dirtyTasks.reduce(0.0) { result, task in
            guard let estimate = plan[task]?.durationEstimate else { return result }
            let weight = Double(estimate.durationNanoseconds)
            guard let state = tasks[task] else { return result }
            switch state {
            case .running:
                guard let started = taskStartedAt[task]?.date else { return result }
                let elapsed = max(0, date.timeIntervalSince(started)) * 1_000_000_000
                return result + min(weight * 0.9, elapsed * 0.9)
            case .skipped, .succeeded, .cancelled, .failed:
                return result + weight
            }
        }
        return min(1, earned / totalWeight)
    }

    private static func date(_ timestamp: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: timestamp) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: timestamp)
    }
}
