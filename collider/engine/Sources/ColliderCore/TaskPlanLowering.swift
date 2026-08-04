public struct AssessedTaskDeclaration: Sendable {
    public let task: TaskDeclaration
    public let isClean: Bool
    public let isSubsumed: Bool

    public init(
        task: TaskDeclaration,
        isClean: Bool,
        isSubsumed: Bool
    ) {
        self.task = task
        self.isClean = isClean
        self.isSubsumed = isSubsumed
    }
}

/// One physical task introduced after logical task assessment. Runtime uses
/// only the owner and prerequisite sets; the lowering remains the sole owner
/// of the logical domain that caused the expansion.
public struct LoweredExecutionTask: Sendable {
    public let task: TaskDeclaration
    public let attribution: String
    public let logicalOwners: Set<TaskID>
    public let prerequisites: Set<TaskID>

    public init(
        task: TaskDeclaration,
        attribution: String,
        logicalOwners: Set<TaskID>,
        prerequisites: Set<TaskID>
    ) {
        self.task = task
        self.attribution = attribution
        self.logicalOwners = logicalOwners
        self.prerequisites = prerequisites
    }
}

/// A deterministic, side-effect-free expansion installed by the composition
/// root. Lowerings receive only the selected, assessed logical closure and may
/// not resolve tools, hash new inputs, mutate persistence, or execute work.
public protocol TaskPlanLowering: Sendable {
    func lower(
        _ tasks: [AssessedTaskDeclaration]
    ) throws -> [LoweredExecutionTask]
}
