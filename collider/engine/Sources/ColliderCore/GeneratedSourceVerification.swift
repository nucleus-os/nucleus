import SystemPackage

/// Proves a component's committed generated sources still match generation.
///
/// Every component that commits generated sources runs this, through its own
/// action kind: the kind is namespaced to the component that owns the task, but
/// the question each one asks is identical, and asking it in one place is what
/// keeps the answers consistent. In particular this is the same predicate
/// adoption uses to decide a tree is already current, so verification cannot
/// call stale what adoption calls current.
public enum GeneratedSourceVerification {
    public static func check(
        _ mappings: [GeneratedSourceMapping],
        component: String,
        in context: ActionContext
    ) throws {
        for mapping in mappings {
            guard try context.files.metadata(for: mapping.committed) != nil else {
                throw GeneratedSourceFailure.absent(committed: mapping.committed)
            }
            guard
                try context.files.contentsEqual(
                    at: mapping.generated,
                    and: mapping.committed)
            else {
                throw GeneratedSourceFailure.stale(mapping, component: component)
            }
        }
    }
}

public enum GeneratedSourceFailure: Error, CustomStringConvertible, Sendable {
    case absent(committed: FilePath)
    case stale(GeneratedSourceMapping, component: String)

    public var description: String {
        switch self {
        case .absent(let committed):
            "generated sources are not committed: \(committed)"
        case .stale(let mapping, let component):
            "committed generated sources are stale: \(mapping.committed)\n"
                + "  regenerated: \(mapping.generated)\n"
                + "  run 'collider generate \(component)', "
                + "then 'collider adopt \(component)'"
        }
    }
}
