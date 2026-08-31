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

/// Where a root's identity contexts sit beneath it, and what one is named.
///
/// Collection has to address a context rather than search for it. A walk of
/// however many levels happened to suit the first root that needed one reaches
/// that root's layout and reports nothing for a root nesting its contexts
/// deeper -- not an error, just an empty result that looks like a clean store.
/// The layout is therefore stated by the declaration that owns it.
public struct ContextLocation: Codable, Hashable, Sendable {
    /// Directory levels between the root and a context. Contexts written as
    /// `unsanitized/sha256-…` sit one level down; contexts written as
    /// `linux-arm64/unsanitized/sha256-…` sit two.
    public let intermediateLevels: UInt32
    public let naming: DirectoryNamePattern

    public init(intermediateLevels: UInt32, naming: DirectoryNamePattern) {
        self.intermediateLevels = intermediateLevels
        self.naming = naming
    }
}

public enum StorageRetentionPolicy: Codable, Hashable, Sendable {
    case protected
    case explicitClean
    case singleWorkingSet
    case keepActiveAndRollback(count: UInt32)
    /// Contexts a current identity reaches are always retained; the count
    /// bounds how many of the remainder survive, newest first.
    case taskIdentityContexts(ContextLocation, retaining: UInt32)
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

/// Whether a materialized tree stays between builds.
///
/// Materialized source is the largest multiplier on this store's size -- AOSP
/// alone exists three times, as a host input cache, a guest source workspace,
/// and an output workspace -- and none of it was a decision. It was a
/// consequence of what had been built last, which is the same thing as saying
/// nobody had decided.
///
/// The two answers carry different obligations. A tree that stays states why it
/// stays, so its cost is attributable. A tree that does not stay names the task
/// that rebuilds it, so collecting it is a delay rather than a loss, and the
/// claim that it is reconstructible is checkable rather than asserted.
public enum StorageResidency: Codable, Hashable, Sendable {
    /// Stays between builds, for the stated reason.
    case resident(reason: String)
    /// Collectable under pressure; the named task materializes it again.
    case onDemand(reconstructedBy: TaskID)

    public var isResident: Bool {
        if case .resident = self { return true }
        return false
    }

    public var description: String {
        switch self {
        case .resident(let reason): "resident: \(reason)"
        case .onDemand(let task): "on demand, rebuilt by \(task.rawValue)"
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
    /// Required of materialized source, meaningless elsewhere.
    public let residency: StorageResidency?
    public let activeGenerationLink: FilePath?
    public let generationNaming: DirectoryNamePattern?
    public let interruptedCandidateNaming: DirectoryNamePattern?

    public init(
        id: String,
        owner: ComponentID,
        producers: Set<StorageProducer>,
        storageClass: StorageClass,
        root: FilePath,
        safetyRoot: FilePath,
        retentionPolicy: StorageRetentionPolicy,
        residency: StorageResidency? = nil,
        activeGenerationLink: FilePath? = nil,
        generationNaming: DirectoryNamePattern? = nil,
        interruptedCandidateNaming: DirectoryNamePattern? = nil
    ) {
        self.id = id
        self.owner = owner
        self.producers = producers
        self.storageClass = storageClass
        self.root = root
        self.safetyRoot = safetyRoot
        self.retentionPolicy = retentionPolicy
        self.residency = residency
        self.activeGenerationLink = activeGenerationLink
        self.generationNaming = generationNaming
        self.interruptedCandidateNaming = interruptedCandidateNaming
    }
}

private struct IndexedStorageRoot {
    let declaration: StorageDeclaration
    let filesystemRoot: FilePath.Root
    let components: [FilePath.Component]
    let ordinal: Int

    init(
        declaration: StorageDeclaration,
        normalizedRoot: FilePath,
        ordinal: Int
    ) {
        self.declaration = declaration
        filesystemRoot = normalizedRoot.root!
        components = Array(normalizedRoot.components)
        self.ordinal = ordinal
    }
}

private final class StoragePathNode {
    var declarations: [StorageDeclaration] = []
    var children: [FilePath.Component: StoragePathNode] = [:]
}

public enum StorageCatalog {
    public static func validate(
        _ declarations: [StorageDeclaration],
        forbiddenRemovalRoots: [FilePath]
    ) throws {
        var identifiers = Set<String>()
        var roots: [IndexedStorageRoot] = []
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
            if declaration.storageClass == .identity {
                guard declaration.retentionPolicy.isProtected else {
                    throw StorageCatalogFailure.invalid(
                        "identity storage must be protected: \(declaration.id)")
                }
            }
            // Source used to be required to be protected, which made "this is
            // source" and "this can never be collected" the same statement.
            // They are not: a tree materialized from a pinned input is source
            // and is reconstructible, and the store held three copies of AOSP
            // because nothing could say so. Source now states its residency,
            // and the two answers carry the obligations that distinguish them.
            if declaration.storageClass == .source {
                switch declaration.residency {
                case nil:
                    throw StorageCatalogFailure.invalid(
                        "source storage must declare its residency: \(declaration.id)")
                case .resident:
                    guard declaration.retentionPolicy.isProtected else {
                        throw StorageCatalogFailure.invalid(
                            "resident source storage must be protected: \(declaration.id)")
                    }
                case .onDemand(let task):
                    guard !declaration.retentionPolicy.isProtected else {
                        throw StorageCatalogFailure.invalid(
                            "on-demand source storage cannot be protected, or nothing "
                                + "may collect what it promises to rebuild: \(declaration.id)")
                    }
                    guard declaration.producers.contains(.task(task)) else {
                        throw StorageCatalogFailure.invalid(
                            "on-demand source storage must name a producing task as its "
                                + "reconstructor: \(declaration.id)")
                    }
                }
            } else if declaration.residency != nil {
                throw StorageCatalogFailure.invalid(
                    "residency belongs to materialized source, and \(declaration.id) "
                        + "is \(declaration.storageClass.rawValue) storage")
            }
            switch declaration.retentionPolicy {
            case .keepActiveAndRollback:
                guard declaration.storageClass == .generation,
                    declaration.activeGenerationLink != nil,
                    declaration.generationNaming != nil
                else {
                    throw StorageCatalogFailure.invalid(
                        "generation retention requires generation storage with an active link and naming contract: "
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
                // Retention states how entries are keyed; the class states what
                // the bytes are. Both reconstructible classes are keyed this
                // way in practice: build output under an identity is
                // incremental, and the dependency closure that output was
                // compiled against is a cache under the same identity.
                guard
                    declaration.storageClass == .incremental
                        || declaration.storageClass == .cache
                else {
                    throw StorageCatalogFailure.invalid(
                        "task identity retention requires incremental or cache storage: "
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
            if declaration.generationNaming != nil,
                declaration.storageClass != .generation
            {
                throw StorageCatalogFailure.invalid(
                    "only generation storage may declare generation naming: "
                        + declaration.id)
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
            roots.append(
                IndexedStorageRoot(
                    declaration: declaration,
                    normalizedRoot: root,
                    ordinal: roots.count))
        }

        // Parents precede descendants, so inserting a path only needs to inspect
        // declarations on its trie walk. Unrelated sibling roots are never
        // compared.
        roots.sort {
            if $0.components.count != $1.components.count {
                return $0.components.count < $1.components.count
            }
            return $0.ordinal < $1.ordinal
        }
        var pathRoots: [FilePath.Root: StoragePathNode] = [:]
        for root in roots {
            let pathRoot = pathRoots[root.filesystemRoot] ?? StoragePathNode()
            pathRoots[root.filesystemRoot] = pathRoot
            var node = pathRoot
            try validateOverlaps(root.declaration, with: node.declarations)
            for component in root.components {
                let child = node.children[component] ?? StoragePathNode()
                node.children[component] = child
                node = child
                try validateOverlaps(root.declaration, with: node.declarations)
            }
            node.declarations.append(root.declaration)
        }
    }

    private static func validateOverlaps(
        _ declaration: StorageDeclaration,
        with ancestors: [StorageDeclaration]
    ) throws {
        for ancestor in ancestors {
            let ancestorProtectsContent =
                ancestor.storageClass == .source || ancestor.storageClass == .identity
            let declarationProtectsContent =
                declaration.storageClass == .source || declaration.storageClass == .identity
            if (ancestorProtectsContent && !declaration.retentionPolicy.isProtected)
                || (declarationProtectsContent && !ancestor.retentionPolicy.isProtected)
            {
                throw StorageCatalogFailure.invalid(
                    "removable storage overlaps source or identity storage: "
                        + "\(ancestor.id), \(declaration.id)")
            }
            if !ancestor.retentionPolicy.isProtected,
                !declaration.retentionPolicy.isProtected
            {
                throw StorageCatalogFailure.invalid(
                    "removable storage declarations overlap: "
                        + "\(ancestor.id), \(declaration.id)")
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
            // An on-demand root promises that deleting it costs a rebuild
            // rather than a result, and only a declared output makes that
            // promise checkable. A root its producer writes as scratch is
            // invisible to cleanliness: deleting it leaves the task clean, so
            // nothing rebuilds it and whatever consumes it runs against an
            // empty directory. AOSP's seventy-three gigabyte object store was
            // exactly that, and its residency would have been a sentence
            // nothing enforced.
            guard case .onDemand(let reconstructor) = declaration.residency else {
                continue
            }
            guard let task = tasksByID[reconstructor] else {
                throw StorageCatalogFailure.invalid(
                    "on-demand storage names an unknown reconstructing task: "
                        + "\(declaration.id), \(reconstructor)")
            }
            let root = declaration.root.normalizedForComparison()
            // Both spellings of a declared output. A task states most of them
            // as slots, through the builder call that also hands back an
            // artifact reference; a few are stated directly. Checking only one
            // made this rule vacuous for every task that uses the other.
            let declaredOutputs =
                task.outputSlots.map(\.path) + task.outputs.map(\.path)
            guard
                declaredOutputs.contains(where: {
                    // The root itself, or something that contains it. An
                    // output merely sitting under the root is not enough: two
                    // small files under AOSP's source-input root would
                    // otherwise vouch for the seventy-three gigabyte object
                    // store beside them, which is the exact gap this rule
                    // exists to close.
                    let output = $0.normalizedForComparison()
                    return output == root || root.isContained(in: output)
                })
            else {
                throw StorageCatalogFailure.invalid(
                    "on-demand storage must be a declared output of the task that "
                        + "rebuilds it, or nothing observes it as missing: "
                        + "\(declaration.id), \(reconstructor)")
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
