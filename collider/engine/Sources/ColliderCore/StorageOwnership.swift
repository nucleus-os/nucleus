import Foundation
import SystemPackage

public enum StorageClass: String, Codable, Hashable, Sendable {
    case source
    case identity
    case sourceSnapshot
    case incremental
    case cache
    case container
    case published
    case diagnostic
    case generation
    case download
    case runRecord
}

public enum StorageCleanupPolicy: String, Codable, Hashable, Sendable {
    case protected
    case explicitClean
    case explicitPrune
    case automaticRetention
}

public enum StorageProducer: Hashable, Sendable {
    case task(TaskID)
    case runtime(String)
}

public struct StorageDeclaration: Hashable, Sendable {
    public let id: String
    public let owner: ComponentID
    public let producers: Set<StorageProducer>
    public let storageClass: StorageClass
    public let root: FilePath
    public let safetyRoot: FilePath
    public let cleanupPolicy: StorageCleanupPolicy
    public let activeGenerationLink: FilePath?
    public let rollbackGenerationCount: UInt32?
    public let interruptedCandidateNaming: DirectoryNamePattern?
    public let retention: String

    public init(
        id: String,
        owner: ComponentID,
        producers: Set<StorageProducer>,
        storageClass: StorageClass,
        root: FilePath,
        safetyRoot: FilePath,
        cleanupPolicy: StorageCleanupPolicy,
        activeGenerationLink: FilePath? = nil,
        rollbackGenerationCount: UInt32? = nil,
        interruptedCandidateNaming: DirectoryNamePattern? = nil,
        retention: String
    ) {
        self.id = id
        self.owner = owner
        self.producers = producers
        self.storageClass = storageClass
        self.root = root
        self.safetyRoot = safetyRoot
        self.cleanupPolicy = cleanupPolicy
        self.activeGenerationLink = activeGenerationLink
        self.rollbackGenerationCount = rollbackGenerationCount
        self.interruptedCandidateNaming = interruptedCandidateNaming
        self.retention = retention
    }
}

public enum StorageCatalog {
    public static func validate(
        _ declarations: [StorageDeclaration],
        forbiddenRemovalRoots: [FilePath]
    ) throws {
        var identifiers = Set<String>()
        var roots: [(StorageDeclaration, FilePath)] = []
        let forbidden = Set(forbiddenRemovalRoots.map { $0.normalizedForComparison() })

        for declaration in declarations {
            guard !declaration.id.isEmpty, identifiers.insert(declaration.id).inserted else {
                throw StorageCatalogFailure.invalid(
                    "storage declaration identifiers must be nonempty and unique: \(declaration.id)"
                )
            }
            guard !declaration.owner.rawValue.isEmpty else {
                throw StorageCatalogFailure.invalid(
                    "storage declaration owner is empty: \(declaration.id)")
            }
            guard !declaration.producers.isEmpty else {
                throw StorageCatalogFailure.invalid(
                    "storage declaration has no producer: \(declaration.id)")
            }
            let root = declaration.root.normalizedForComparison()
            let safetyRoot = declaration.safetyRoot.normalizedForComparison()
            guard root.isAbsolute, safetyRoot.isAbsolute, safetyRoot != FilePath("/") else {
                throw StorageCatalogFailure.invalid(
                    "storage roots must be absolute and the safety root cannot be /: \(declaration.id)"
                )
            }
            guard root.isContained(in: safetyRoot) else {
                throw StorageCatalogFailure.invalid(
                    "storage root escapes its safety root: \(declaration.id)")
            }
            if declaration.cleanupPolicy != .protected {
                guard root != safetyRoot, !forbidden.contains(root) else {
                    throw StorageCatalogFailure.invalid(
                        "removable storage cannot name a safety or forbidden root: \(declaration.id)"
                    )
                }
            }
            if declaration.storageClass == .source || declaration.storageClass == .identity {
                guard declaration.cleanupPolicy == .protected else {
                    throw StorageCatalogFailure.invalid(
                        "source and identity storage must be protected: \(declaration.id)")
                }
            }
            if declaration.cleanupPolicy == .automaticRetention,
                declaration.storageClass != .generation
                    && declaration.storageClass != .runRecord
            {
                throw StorageCatalogFailure.invalid(
                    "automatic retention requires generation or run-record storage: "
                        + declaration.id)
            }
            if declaration.cleanupPolicy == .explicitPrune,
                declaration.storageClass != .generation
            {
                throw StorageCatalogFailure.invalid(
                    "explicit pruning requires generation storage: " + declaration.id)
            }
            if declaration.cleanupPolicy == .automaticRetention,
                declaration.storageClass == .generation,
                declaration.activeGenerationLink == nil
            {
                throw StorageCatalogFailure.invalid(
                    "automatically retained generation storage requires an active link: "
                        + declaration.id)
            }
            if let activeGenerationLink = declaration.activeGenerationLink {
                let active = activeGenerationLink.normalizedForComparison()
                guard active.isAbsolute, active.isContained(in: safetyRoot) else {
                    throw StorageCatalogFailure.invalid(
                        "active generation link escapes its safety root: \(declaration.id)")
                }
            }
            if declaration.activeGenerationLink != nil,
                declaration.storageClass != .generation
            {
                throw StorageCatalogFailure.invalid(
                    "only generation storage may declare an active link: \(declaration.id)")
            }
            if declaration.rollbackGenerationCount != nil,
                declaration.storageClass != .generation
                    || declaration.activeGenerationLink == nil
            {
                throw StorageCatalogFailure.invalid(
                    "rollback retention requires generation storage with an active link: "
                        + declaration.id)
            }
            if declaration.storageClass == .generation,
                declaration.activeGenerationLink != nil,
                declaration.rollbackGenerationCount == nil
            {
                throw StorageCatalogFailure.invalid(
                    "active generation storage requires an explicit rollback count: "
                        + declaration.id)
            }
            if declaration.interruptedCandidateNaming != nil,
                declaration.storageClass != .generation
            {
                throw StorageCatalogFailure.invalid(
                    "only generation storage may declare interrupted candidate naming: "
                        + declaration.id)
            }
            roots.append((declaration, root))
        }

        for leftIndex in roots.indices {
            for rightIndex in roots.indices where rightIndex > leftIndex {
                let left = roots[leftIndex]
                let right = roots[rightIndex]
                guard left.1.overlaps(right.1) else { continue }
                let leftProtectsContent =
                    left.0.storageClass == .source || left.0.storageClass == .identity
                let rightProtectsContent =
                    right.0.storageClass == .source || right.0.storageClass == .identity
                if (leftProtectsContent && right.0.cleanupPolicy != .protected)
                    || (rightProtectsContent && left.0.cleanupPolicy != .protected)
                {
                    throw StorageCatalogFailure.invalid(
                        "removable storage overlaps source or identity storage: "
                            + "\(left.0.id), \(right.0.id)")
                }
                if left.0.cleanupPolicy != .protected,
                    right.0.cleanupPolicy != .protected
                {
                    throw StorageCatalogFailure.invalid(
                        "removable storage declarations overlap: \(left.0.id), \(right.0.id)")
                }
            }
        }
    }

    public static func validateProducers(
        _ declarations: [StorageDeclaration],
        tasks: [TaskDeclaration]
    ) throws {
        let tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        for declaration in declarations {
            for producer in declaration.producers {
                guard case .task(let taskID) = producer else { continue }
                guard let task = tasksByID[taskID] else {
                    throw StorageCatalogFailure.invalid(
                        "storage declaration names unknown producer task: \(declaration.id), \(taskID)"
                    )
                }
                guard task.component == declaration.owner else {
                    throw StorageCatalogFailure.invalid(
                        "storage producer belongs to another component: \(declaration.id), \(taskID)"
                    )
                }
                if declaration.cleanupPolicy != .protected, task.locks.isEmpty {
                    throw StorageCatalogFailure.invalid(
                        "removable storage producer has no workflow lock: "
                            + "\(declaration.id), \(taskID)")
                }
            }
        }
    }

    public static func workflowLocks(
        for declaration: StorageDeclaration,
        tasks: [TaskDeclaration]
    ) throws -> Set<TaskLock> {
        let tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        var locks = Set<TaskLock>()
        for producer in declaration.producers {
            guard case .task(let taskID) = producer else { continue }
            guard let task = tasksByID[taskID] else {
                throw StorageCatalogFailure.invalid(
                    "storage declaration names unknown producer task: \(declaration.id), \(taskID)"
                )
            }
            locks.formUnion(task.locks)
        }
        return locks
    }

}

public enum StorageCatalogFailure: Error, CustomStringConvertible, Sendable {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let message): message
        }
    }
}
