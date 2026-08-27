public struct AssessedTaskDeclaration: Sendable {
    public let task: TaskDeclaration
    public let isClean: Bool

    public init(
        task: TaskDeclaration,
        isClean: Bool
    ) {
        self.task = task
        self.isClean = isClean
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
    /// The bytes this task's name was derived from.
    ///
    /// Returned rather than reported, because a lowering is required to be
    /// deterministic and free of side effects and observing is neither its
    /// concern nor its permission. Planning already holds the observer, and a
    /// lowered task is the one kind planning never encoded itself, so without
    /// this the identity behind a lowered name can only be inferred. Empty
    /// where a lowering derives a name some other way.
    public let identityBytes: [UInt8]

    public init(
        task: TaskDeclaration,
        attribution: String,
        logicalOwners: Set<TaskID>,
        prerequisites: Set<TaskID>,
        identityBytes: [UInt8] = []
    ) {
        self.task = task
        self.attribution = attribution
        self.logicalOwners = logicalOwners
        self.prerequisites = prerequisites
        self.identityBytes = identityBytes
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
