import ColliderCore
import SystemPackage

/// Compares committed generated sources against regenerating them.
///
/// Generation is an authoring act: it writes storage, a human adopts the result
/// into the checkout, and a build proves the two agree without writing either.
struct VerifyWaylandGeneratedSourcesAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let generated: [FilePath]
        let committed: [FilePath]

        func encode(into encoder: inout IdentityEncoder) {
            encoder.appendSequence(generated) { $0.append(path: $1) }
            encoder.appendSequence(committed) { $0.append(path: $1) }
        }
    }

    static let kind: ActionKind = "wayland.verify-generated-sources"

    let generated: [FilePath]
    let committed: [FilePath]

    var identity: Identity {
        Identity(generated: generated, committed: committed)
    }

    var requirements: ActionRequirements {
        var effects = generated.map { ActionEffect(.read, scope: .input($0)) }
        effects += committed.map { ActionEffect(.read, scope: .checkout($0)) }
        return ActionRequirements(
            effects: effects,
            executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        for (generated, committed) in zip(generated, committed) {
            guard try context.files.metadata(for: committed)?.type == .directory else {
                throw WaylandGeneratedSourceFailure.absent(committed: committed)
            }
            // Tree digests rather than file-by-file comparison: a directory that
            // gained or lost a file is as stale as one whose contents changed.
            let expected = try context.files.digest(tree: generated)
            let actual = try context.files.digest(tree: committed)
            guard expected == actual else {
                throw WaylandGeneratedSourceFailure.stale(
                    committed: committed,
                    generated: generated)
            }
        }
    }
}

enum WaylandGeneratedSourceFailure: Error, CustomStringConvertible {
    case absent(committed: FilePath)
    case stale(committed: FilePath, generated: FilePath)

    var description: String {
        switch self {
        case .absent(let committed):
            "generated sources are not committed: \(committed)"
        case .stale(let committed, let generated):
            "committed generated sources are stale: \(committed)\n"
                + "  regenerated: \(generated)\n"
                + "  run 'collider generate wayland', then "
                + "'collider adopt wayland'"
        }
    }
}
