import ColliderCore

public enum RunObservation: Sendable {
    case plan(RunPlanObservation)
    case event(RunEvent)
}

public struct RunPlanObservation: Sendable {
    public let runID: RunID
    public let entries: [TaskPlanEntry]

    public init(runID: RunID, entries: [TaskPlanEntry]) {
        self.runID = runID
        self.entries = entries
    }
}
