import SystemPackage

public struct OutputSlotID: RawRepresentable, Hashable, Codable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public var description: String { rawValue }
}

public struct ArtifactReference: Hashable, Sendable {
    public let path: FilePath
    package let producer: TaskID
    package let slot: OutputSlotID
    package let validation: PathValidation

    fileprivate init(
        producer: TaskID,
        slot: OutputSlotID,
        path: FilePath,
        validation: PathValidation
    ) {
        self.producer = producer
        self.slot = slot
        self.path = path
        self.validation = validation
    }
}

public struct ExecutableReference: Hashable, Sendable {
    public let artifact: ArtifactReference

    public var path: FilePath { artifact.path }

    public var executable: CommandSpec.Executable {
        .artifact(artifact)
    }

    fileprivate init(_ artifact: ArtifactReference) {
        self.artifact = artifact
    }
}

public struct ArtifactReferenceSet: Hashable, Sendable {
    fileprivate var references: [ArtifactReference]

    public init() {
        references = []
    }

    public init(_ reference: ArtifactReference) {
        references = [reference]
    }

    public init(_ references: [ArtifactReference]) {
        self.references = references
    }

    public mutating func append(_ reference: ArtifactReference) {
        if !references.contains(reference) {
            references.append(reference)
        }
    }

    public mutating func append(_ reference: ExecutableReference) {
        append(reference.artifact)
    }

    public mutating func append(contentsOf other: ArtifactReferenceSet) {
        for reference in other.references where !references.contains(reference) {
            references.append(reference)
        }
    }
}

public struct TaskOutputSlot: Hashable, Sendable {
    public let id: OutputSlotID
    public let path: FilePath
    public let validation: PathValidation

    fileprivate init(
        id: OutputSlotID,
        path: FilePath,
        validation: PathValidation
    ) {
        self.id = id
        self.path = path
        self.validation = validation
    }
}

public struct TaskOrderingReference: Hashable, Sendable {
    package let producer: TaskID

    fileprivate init(producer: TaskID) {
        self.producer = producer
    }
}

public enum TaskBuilderFailure: Error, CustomStringConvertible, Sendable {
    case duplicateOutputSlot(OutputSlotID)

    public var description: String {
        switch self {
        case .duplicateOutputSlot(let slot):
            "duplicate output slot '\(slot)'"
        }
    }
}

public struct TaskBuilder: Sendable {
    public let id: TaskID
    public let component: ComponentID

    private var artifactReferences: [ArtifactReference] = []
    private var orderingReferences: [TaskOrderingReference] = []
    private var outputSlots: [TaskOutputSlot] = []

    public init(id: TaskID, component: ComponentID) {
        self.id = id
        self.component = component
    }

    public var ordering: TaskOrderingReference {
        TaskOrderingReference(producer: id)
    }

    public mutating func output(
        _ slot: OutputSlotID,
        path: FilePath,
        validation: PathValidation
    ) throws -> ArtifactReference {
        guard !outputSlots.contains(where: { $0.id == slot }) else {
            throw TaskBuilderFailure.duplicateOutputSlot(slot)
        }
        outputSlots.append(
            TaskOutputSlot(
                id: slot,
                path: path,
                validation: validation))
        return ArtifactReference(
            producer: id,
            slot: slot,
            path: path,
            validation: validation)
    }

    public mutating func executableOutput(
        _ slot: OutputSlotID,
        path: FilePath
    ) throws -> ExecutableReference {
        let artifact = try output(slot, path: path, validation: .executableFile)
        return ExecutableReference(artifact)
    }

    public mutating func consume(_ reference: ArtifactReference) {
        if !artifactReferences.contains(reference) {
            artifactReferences.append(reference)
        }
    }

    public mutating func consume(_ reference: ExecutableReference) {
        consume(reference.artifact)
    }

    public mutating func consume(_ references: ArtifactReferenceSet) {
        for reference in references.references where !artifactReferences.contains(reference) {
            artifactReferences.append(reference)
        }
    }

    public mutating func after(_ reference: TaskOrderingReference) {
        if !orderingReferences.contains(reference) {
            orderingReferences.append(reference)
        }
    }

    public func build(
        swiftProducts: [SwiftProductRequirement] = [],
        swiftTests: [SwiftTestRequirement] = [],
        inputs: [ArtifactInput] = [],
        postconditions: [PathPostcondition] = [],
        locks: [TaskLock] = [],
        assessmentPolicy: TaskAssessmentPolicy = .incremental,
        recordsActiveArtifact: Bool = false,
        action: AnyColliderAction? = nil
    ) -> TaskDeclaration {
        TaskDeclaration(
            id: id,
            component: component,
            dependencies: [],
            orderingDependencies: orderingReferences,
            artifactReferences: artifactReferences,
            outputSlots: outputSlots,
            swiftProducts: swiftProducts,
            swiftTests: swiftTests,
            inputs: inputs,
            outputs: outputSlots.map {
                OutputDeclaration(path: $0.path, validation: $0.validation)
            },
            postconditions: postconditions,
            locks: locks,
            assessmentPolicy: assessmentPolicy,
            recordsActiveArtifact: recordsActiveArtifact,
            action: action)
    }
}
