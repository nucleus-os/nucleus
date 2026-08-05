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

public enum ArtifactValueKind: String, Hashable, Codable, Sendable {
    case file
    case directory
    case executable
    case json
    case path

    public func accepts(_ validation: PathValidation) -> Bool {
        switch self {
        case .file: validation == .regularFile
        case .directory: validation == .nonEmptyDirectory
        case .executable: validation == .executableFile
        case .json: validation == .json
        case .path: true
        }
    }
}

public protocol TaskArtifactValue: Sendable {
    static var artifactKind: ArtifactValueKind { get }
}

public enum FileArtifact: TaskArtifactValue {
    public static let artifactKind = ArtifactValueKind.file
}

public enum DirectoryArtifact: TaskArtifactValue {
    public static let artifactKind = ArtifactValueKind.directory
}

public enum ExecutableArtifact: TaskArtifactValue {
    public static let artifactKind = ArtifactValueKind.executable
}

public enum JSONArtifact: TaskArtifactValue {
    public static let artifactKind = ArtifactValueKind.json
}

public enum PathArtifact: TaskArtifactValue {
    public static let artifactKind = ArtifactValueKind.path
}

public struct ArtifactReference<Value: TaskArtifactValue>: Hashable, Sendable {
    public let path: FilePath
    let producer: TaskID
    let slot: OutputSlotID

    fileprivate init(producer: TaskID, slot: OutputSlotID, path: FilePath) {
        self.producer = producer
        self.slot = slot
        self.path = path
    }
}

extension ArtifactReference where Value == ExecutableArtifact {
    public var executable: CommandSpec.Executable {
        .artifact(AnyArtifactReference(self))
    }
}

public struct AnyArtifactReference: Hashable, Sendable {
    package let producer: TaskID
    package let slot: OutputSlotID
    public let path: FilePath
    package let kind: ArtifactValueKind

    fileprivate init<Value>(_ reference: ArtifactReference<Value>) {
        producer = reference.producer
        slot = reference.slot
        path = reference.path
        kind = Value.artifactKind
    }
}

public struct ArtifactReferenceSet: Hashable, Sendable {
    fileprivate var references: [AnyArtifactReference]

    public init() {
        references = []
    }

    public init<Value>(_ reference: ArtifactReference<Value>) {
        references = [AnyArtifactReference(reference)]
    }

    public init<Value>(_ references: [ArtifactReference<Value>]) {
        self.references = references.map(AnyArtifactReference.init)
    }

    public mutating func append<Value>(_ reference: ArtifactReference<Value>) {
        let reference = AnyArtifactReference(reference)
        if !references.contains(reference) {
            references.append(reference)
        }
    }

    public mutating func append(contentsOf other: ArtifactReferenceSet) {
        for reference in other.references where !references.contains(reference) {
            references.append(reference)
        }
    }
}

public struct AnyTaskOutputSlot: Hashable, Sendable {
    public let id: OutputSlotID
    public let path: FilePath
    public let validation: PathValidation
    public let kind: ArtifactValueKind

    fileprivate init(
        id: OutputSlotID,
        path: FilePath,
        validation: PathValidation,
        kind: ArtifactValueKind
    ) {
        self.id = id
        self.path = path
        self.validation = validation
        self.kind = kind
    }
}

public struct TaskOrderingReference: Hashable, Sendable {
    let producer: TaskID

    fileprivate init(producer: TaskID) {
        self.producer = producer
    }
}

public protocol TaskResultValue: Sendable {}

public struct TaskResultReference<Value: TaskResultValue>: Hashable, Sendable {
    let producer: TaskID
    let slot: OutputSlotID

    fileprivate init(producer: TaskID, slot: OutputSlotID) {
        self.producer = producer
        self.slot = slot
    }
}

public struct AnyTaskResultReference: Hashable, Sendable {
    package let producer: TaskID
    package let slot: OutputSlotID
    package let valueType: String

    fileprivate init<Value>(_ reference: TaskResultReference<Value>) {
        producer = reference.producer
        slot = reference.slot
        valueType = String(reflecting: Value.self)
    }
}

public struct AnyTaskResultSlot: Hashable, Sendable {
    public let id: OutputSlotID
    public let valueType: String

    fileprivate init(id: OutputSlotID, valueType: String) {
        self.id = id
        self.valueType = valueType
    }
}

public enum TaskBuilderFailure: Error, CustomStringConvertible, Sendable {
    case duplicateOutputSlot(OutputSlotID)
    case duplicateResultSlot(OutputSlotID)
    case invalidOutputType(
        slot: OutputSlotID,
        kind: ArtifactValueKind,
        validation: PathValidation)

    public var description: String {
        switch self {
        case .duplicateOutputSlot(let slot):
            "duplicate output slot '\(slot)'"
        case .duplicateResultSlot(let slot):
            "duplicate result slot '\(slot)'"
        case .invalidOutputType(let slot, let kind, let validation):
            "output slot '\(slot)' of type '\(kind.rawValue)' cannot use "
                + "'\(validation.rawValue)' validation"
        }
    }
}

public struct TaskBuilder: Sendable {
    public let id: TaskID
    public let component: ComponentID

    private var artifactReferences: [AnyArtifactReference] = []
    private var resultReferences: [AnyTaskResultReference] = []
    private var orderingReferences: [TaskOrderingReference] = []
    private var outputSlots: [AnyTaskOutputSlot] = []
    private var resultSlots: [AnyTaskResultSlot] = []

    public init(id: TaskID, component: ComponentID) {
        self.id = id
        self.component = component
    }

    public var ordering: TaskOrderingReference {
        TaskOrderingReference(producer: id)
    }

    public mutating func output<Value: TaskArtifactValue>(
        _ slot: OutputSlotID,
        path: FilePath,
        validation: PathValidation,
        as _: Value.Type = Value.self
    ) throws -> ArtifactReference<Value> {
        guard !outputSlots.contains(where: { $0.id == slot }) else {
            throw TaskBuilderFailure.duplicateOutputSlot(slot)
        }
        guard Value.artifactKind.accepts(validation) else {
            throw TaskBuilderFailure.invalidOutputType(
                slot: slot,
                kind: Value.artifactKind,
                validation: validation)
        }
        outputSlots.append(
            AnyTaskOutputSlot(
                id: slot,
                path: path,
                validation: validation,
                kind: Value.artifactKind))
        return ArtifactReference(producer: id, slot: slot, path: path)
    }

    public mutating func result<Value: TaskResultValue>(
        _ slot: OutputSlotID,
        as _: Value.Type = Value.self
    ) throws -> TaskResultReference<Value> {
        guard !resultSlots.contains(where: { $0.id == slot }) else {
            throw TaskBuilderFailure.duplicateResultSlot(slot)
        }
        resultSlots.append(
            AnyTaskResultSlot(
                id: slot,
                valueType: String(reflecting: Value.self)))
        return TaskResultReference(producer: id, slot: slot)
    }

    public mutating func consume<Value>(_ reference: ArtifactReference<Value>) {
        let reference = AnyArtifactReference(reference)
        if !artifactReferences.contains(reference) {
            artifactReferences.append(reference)
        }
    }

    public mutating func consume(_ reference: AnyArtifactReference) {
        if !artifactReferences.contains(reference) {
            artifactReferences.append(reference)
        }
    }

    public mutating func consume(_ references: ArtifactReferenceSet) {
        for reference in references.references where !artifactReferences.contains(reference) {
            artifactReferences.append(reference)
        }
    }

    public mutating func consume<Value>(_ reference: TaskResultReference<Value>) {
        let reference = AnyTaskResultReference(reference)
        if !resultReferences.contains(reference) {
            resultReferences.append(reference)
        }
    }

    public mutating func consume(_ reference: AnyTaskResultReference) {
        if !resultReferences.contains(reference) {
            resultReferences.append(reference)
        }
    }

    public mutating func after(_ reference: TaskOrderingReference) {
        if !orderingReferences.contains(reference) {
            orderingReferences.append(reference)
        }
    }

    public func build(
        subsumedDependencies: [TaskID] = [],
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
            resultReferences: resultReferences,
            outputSlots: outputSlots,
            resultSlots: resultSlots,
            subsumedDependencies: subsumedDependencies,
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
