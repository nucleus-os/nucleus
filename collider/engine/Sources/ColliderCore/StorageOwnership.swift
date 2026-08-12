import Foundation
import SystemPackage

public enum StorageClass: String, Codable, Hashable, Sendable {
    case source
    case identity
    case incremental
    case cache
    case container
    case published
    case diagnostic
    case generation
    case download
    case runRecord
}

public enum StorageRetentionPolicy: Codable, Hashable, Sendable {
    case protected
    case explicitClean
    case singleWorkingSet
    case keepActiveAndRollback(count: UInt32)
    case taskIdentityContexts
    case toolManagedLimit(maximumBytes: UInt64)
    case boundedHistory(maximumEntries: UInt32)

    public var name: String {
        switch self {
        case .protected: "protected"
        case .explicitClean: "explicitClean"
        case .singleWorkingSet: "singleWorkingSet"
        case .keepActiveAndRollback: "keepActiveAndRollback"
        case .taskIdentityContexts: "taskIdentityContexts"
        case .toolManagedLimit: "toolManagedLimit"
        case .boundedHistory: "boundedHistory"
        }
    }

    public var description: String {
        switch self {
        case .protected:
            "authoritative state is never a cleanup candidate"
        case .explicitClean:
            "the finite working set remains reusable until explicit clean"
        case .singleWorkingSet:
            "the producer replaces one current reusable working set in place"
        case .keepActiveAndRollback(let count):
            "the active generation and \(count) rollback generation(s) remain"
        case .taskIdentityContexts:
            "contexts reachable from current task identities remain"
        case .toolManagedLimit(let maximumBytes):
            "the owning tool limits the cache to \(maximumBytes) bytes"
        case .boundedHistory(let maximumEntries):
            "the newest \(maximumEntries) history entries remain"
        }
    }

    public var isProtected: Bool {
        if case .protected = self { return true }
        return false
    }

    public var allowsExplicitClean: Bool {
        !isProtected
    }

    public var hasAutomaticPruneTargets: Bool {
        switch self {
        case .keepActiveAndRollback, .taskIdentityContexts, .boundedHistory:
            true
        default:
            false
        }
    }
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
    public let retentionPolicy: StorageRetentionPolicy
    public let activeGenerationLink: FilePath?
    public let interruptedCandidateNaming: DirectoryNamePattern?

    public init(
        id: String,
        owner: ComponentID,
        producers: Set<StorageProducer>,
        storageClass: StorageClass,
        root: FilePath,
        safetyRoot: FilePath,
        retentionPolicy: StorageRetentionPolicy,
        activeGenerationLink: FilePath? = nil,
        interruptedCandidateNaming: DirectoryNamePattern? = nil
    ) {
        self.id = id
        self.owner = owner
        self.producers = producers
        self.storageClass = storageClass
        self.root = root
        self.safetyRoot = safetyRoot
        self.retentionPolicy = retentionPolicy
        self.activeGenerationLink = activeGenerationLink
        self.interruptedCandidateNaming = interruptedCandidateNaming
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
            guard declaration.root == root, declaration.safetyRoot == safetyRoot else {
                throw StorageCatalogFailure.invalid(
                    "storage roots must be lexically normalized: \(declaration.id)")
            }
            guard root.isAbsolute, safetyRoot.isAbsolute, safetyRoot != FilePath("/") else {
                throw StorageCatalogFailure.invalid(
                    "storage roots must be absolute and the safety root cannot be /: \(declaration.id)"
                )
            }
            guard root.isContained(in: safetyRoot) else {
                throw StorageCatalogFailure.invalid(
                    "storage root escapes its safety root: \(declaration.id)")
            }
            if !declaration.retentionPolicy.isProtected {
                guard root != safetyRoot, !forbidden.contains(root) else {
                    throw StorageCatalogFailure.invalid(
                        "removable storage cannot name a safety or forbidden root: \(declaration.id)"
                    )
                }
            }
            if declaration.storageClass == .source || declaration.storageClass == .identity {
                guard declaration.retentionPolicy.isProtected else {
                    throw StorageCatalogFailure.invalid(
                        "source and identity storage must be protected: \(declaration.id)")
                }
            }
            switch declaration.retentionPolicy {
            case .keepActiveAndRollback:
                guard declaration.storageClass == .generation,
                    declaration.activeGenerationLink != nil
                else {
                    throw StorageCatalogFailure.invalid(
                        "generation retention requires generation storage with an active link: "
                            + declaration.id)
                }
            case .boundedHistory:
                guard
                    declaration.storageClass == .runRecord
                        || declaration.storageClass == .diagnostic
                else {
                    throw StorageCatalogFailure.invalid(
                        "bounded history requires run-record or diagnostic storage: "
                            + declaration.id)
                }
            case .taskIdentityContexts:
                guard
                    declaration.storageClass == .incremental
                else {
                    throw StorageCatalogFailure.invalid(
                        "task identity retention requires incremental storage: "
                            + declaration.id)
                }
            case .singleWorkingSet:
                guard declaration.storageClass != .runRecord,
                    declaration.storageClass != .diagnostic,
                    declaration.storageClass != .generation
                else {
                    throw StorageCatalogFailure.invalid(
                        "single-working-set retention is incompatible with history and generation storage: "
                            + declaration.id)
                }
            case .toolManagedLimit(let maximumBytes):
                guard declaration.storageClass == .cache, maximumBytes > 0 else {
                    throw StorageCatalogFailure.invalid(
                        "tool-managed retention requires cache storage with a positive limit: "
                            + declaration.id)
                }
            case .explicitClean:
                throw StorageCatalogFailure.invalid(
                    "host storage requires an enforceable retention policy: " + declaration.id)
            case .protected:
                break
            }
            if let activeGenerationLink = declaration.activeGenerationLink {
                let active = activeGenerationLink.normalizedForComparison()
                guard activeGenerationLink == active else {
                    throw StorageCatalogFailure.invalid(
                        "active generation links must be lexically normalized: \(declaration.id)"
                    )
                }
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
            if declaration.storageClass == .generation,
                declaration.activeGenerationLink != nil,
                {
                    if case .keepActiveAndRollback = declaration.retentionPolicy { return false }
                    return true
                }()
            {
                throw StorageCatalogFailure.invalid(
                    "active generation storage requires generation retention: "
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
                if (leftProtectsContent && !right.0.retentionPolicy.isProtected)
                    || (rightProtectsContent && !left.0.retentionPolicy.isProtected)
                {
                    throw StorageCatalogFailure.invalid(
                        "removable storage overlaps source or identity storage: "
                            + "\(left.0.id), \(right.0.id)")
                }
                if !left.0.retentionPolicy.isProtected,
                    !right.0.retentionPolicy.isProtected
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
                if !declaration.retentionPolicy.isProtected, task.locks.isEmpty {
                    throw StorageCatalogFailure.invalid(
                        "removable storage producer has no workflow lock: "
                            + "\(declaration.id), \(taskID)")
                }
            }
        }
    }

    public static func validateWritableEffects(
        _ declarations: [StorageDeclaration],
        tasks: [TaskDeclaration]
    ) throws {
        struct IndexedDeclaration {
            let declaration: StorageDeclaration
            let root: String
        }

        let indexedDeclarations = declarations.map {
            IndexedDeclaration(
                declaration: $0,
                root: $0.root.string)
        }
        var declarationsByProducerTask: [TaskID: [IndexedDeclaration]] = [:]
        var sharedRuntimeDeclarationsByForeignOwner: [ComponentID: [IndexedDeclaration]] = [:]
        for indexedDeclaration in indexedDeclarations {
            for producer in indexedDeclaration.declaration.producers {
                guard case .task(let taskID) = producer else { continue }
                declarationsByProducerTask[taskID, default: []].append(indexedDeclaration)
            }
        }

        var failures: [String] = []
        for task in tasks {
            guard let action = task.action else { continue }
            let sharedRuntimeDeclarations = sharedRuntimeDeclarationsByForeignOwner[
                task.component,
                default: indexedDeclarations.filter {
                    $0.declaration.owner != task.component
                        && $0.declaration.producers.contains {
                            if case .runtime = $0 { return true }
                            return false
                        }
                }
            ]
            sharedRuntimeDeclarationsByForeignOwner[task.component] = sharedRuntimeDeclarations
            let candidates =
                declarationsByProducerTask[task.id, default: []]
                + sharedRuntimeDeclarations
            let writableRoots = action.requirements.effects.compactMap { effect -> FilePath? in
                if case .unrestricted = effect.scope { return nil }
                switch effect.access {
                case .read:
                    return nil
                case .write, .readWrite:
                    return effect.scope.root
                }
            }
            for writableRoot in writableRoots {
                let writableRootString = writableRoot.string
                let matches = candidates.filter { candidate in
                    writableRootString == candidate.root
                        || writableRootString.hasPrefix(candidate.root + "/")
                }
                guard matches.count == 1 else {
                    failures.append("\(task.id), \(writableRoot), matched \(matches.count)")
                    continue
                }
            }
        }
        guard failures.isEmpty else {
            throw StorageCatalogFailure.invalid(
                "writable action effects must map to exactly one storage declaration:\n  "
                    + failures.sorted().joined(separator: "\n  "))
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
