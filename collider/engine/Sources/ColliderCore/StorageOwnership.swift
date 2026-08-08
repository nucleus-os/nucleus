import Foundation
import SystemPackage

public enum StorageClass: String, Codable, Hashable, Sendable {
    case source
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
    public let workflowLock: FilePath?
    public let activeGenerationLink: FilePath?
    public let retention: String

    public init(
        id: String,
        owner: ComponentID,
        producers: Set<StorageProducer>,
        storageClass: StorageClass,
        root: FilePath,
        safetyRoot: FilePath,
        cleanupPolicy: StorageCleanupPolicy,
        workflowLock: FilePath? = nil,
        activeGenerationLink: FilePath? = nil,
        retention: String
    ) {
        self.id = id
        self.owner = owner
        self.producers = producers
        self.storageClass = storageClass
        self.root = root
        self.safetyRoot = safetyRoot
        self.cleanupPolicy = cleanupPolicy
        self.workflowLock = workflowLock
        self.activeGenerationLink = activeGenerationLink
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
                guard declaration.workflowLock != nil else {
                    throw StorageCatalogFailure.invalid(
                        "removable storage requires its producer workflow lock: \(declaration.id)")
                }
            }
            if declaration.activeGenerationLink != nil,
                declaration.storageClass != .generation
            {
                throw StorageCatalogFailure.invalid(
                    "only generation storage may declare an active link: \(declaration.id)")
            }
            roots.append((declaration, root))
        }

        for leftIndex in roots.indices {
            for rightIndex in roots.indices where rightIndex > leftIndex {
                let left = roots[leftIndex]
                let right = roots[rightIndex]
                guard left.1.overlaps(right.1) else { continue }
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
            }
        }
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
