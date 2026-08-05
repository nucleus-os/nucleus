public enum PersistenceFailure: Error, CustomStringConvertible, Sendable {
    case invalidPath(String)
    case invalidPlanningTool(String)
    case corruptState(String)
    case toolNotFound(String)

    public var description: String {
        switch self {
        case .invalidPath(let message): message
        case .invalidPlanningTool(let message): message
        case .corruptState(let message): message
        case .toolNotFound(let name): "declared task tool '\(name)' was not found"
        }
    }
}
