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
        let mappings: [GeneratedSourceMapping]

        func encode(into encoder: inout IdentityEncoder) {
            encoder.appendSequence(mappings) {
                $0.append(path: $1.generated)
                $0.append(path: $1.committed)
            }
        }
    }

    // An action kind is namespaced to the component that owns the task.
    static let kind: ActionKind = "vulkan.verify-generated-sources"

    let mappings: [GeneratedSourceMapping]

    var identity: Identity { Identity(mappings: mappings) }

    var requirements: ActionRequirements {
        ActionRequirements(
            effects: mappings.flatMap {
                [
                    ActionEffect(.read, scope: .input($0.generated)),
                    ActionEffect(.read, scope: .checkout($0.committed)),
                ]
            },
            executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        try GeneratedSourceVerification.check(
            mappings,
            component: "vulkan",
            in: context)
    }
}
