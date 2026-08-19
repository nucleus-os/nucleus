import ColliderCore
import SystemPackage

/// Compares a committed generated source against regenerating it.
///
/// Generation is an authoring act: it writes declared storage, and a human
/// adopts the result into the checkout and commits it. A build therefore never
/// writes generated source; it reads both copies and fails when they disagree,
/// which is what makes the committed copy trustworthy rather than assumed.
struct VerifyVulkanGeneratedSourceAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let generated: FilePath
        let committed: FilePath

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: generated)
            encoder.append(path: committed)
        }
    }

    // An action kind is namespaced to the component that owns the task.
    static let kind: ActionKind = "vulkan.verify-generated-sources"

    let generated: FilePath
    let committed: FilePath

    var identity: Identity {
        Identity(generated: generated, committed: committed)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            effects: [
                ActionEffect(.read, scope: .input(generated)),
                ActionEffect(.read, scope: .checkout(committed)),
            ],
            executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        guard try context.files.metadata(for: committed) != nil else {
            throw GeneratedSourceFailure.absent(committed: committed)
        }
        guard try context.files.contentsEqual(at: generated, and: committed) else {
            throw GeneratedSourceFailure.stale(
                committed: committed,
                generated: generated)
        }
    }
}

enum GeneratedSourceFailure: Error, CustomStringConvertible {
    case absent(committed: FilePath)
    case stale(committed: FilePath, generated: FilePath)

    var description: String {
        switch self {
        case .absent(let committed):
            "generated source is not committed: \(committed)"
        case .stale(let committed, let generated):
            "committed generated source is stale: \(committed)\n"
                + "  regenerated: \(generated)\n"
                + "  run 'collider generate' and adopt the result"
        }
    }
}
