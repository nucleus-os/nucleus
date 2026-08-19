import ColliderCore
import SystemPackage

/// Compares committed generated sources against regenerating them.
///
/// Generation is an authoring act: it writes storage, a human adopts the result
/// into the checkout, and a build proves the two agree without writing either.
struct VerifyWaylandGeneratedSourcesAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let mappings: [GeneratedSourceMapping]

        func encode(into encoder: inout IdentityEncoder) {
            encoder.appendSequence(mappings) {
                $0.append(path: $1.generated)
                $0.append(path: $1.committed)
            }
        }
    }

    // An action kind is namespaced to the component that owns the task, so each
    // component verifies under its own kind even though the check is shared.
    static let kind: ActionKind = "wayland.verify-generated-sources"

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
            component: "wayland",
            in: context)
    }
}
