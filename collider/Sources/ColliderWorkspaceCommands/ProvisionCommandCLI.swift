import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

enum ProvisionTarget: String, CaseIterable, ExpressibleByArgument {
    case macOSBuilder = "macos-builder"
}

extension MacOSBuilderProvisioning.Operation: ExpressibleByArgument {}

struct Provision: ColliderWorkspaceCommand {
    static let configuration = CommandConfiguration(
        abstract: "Provision and retire the trusted host builder identity.")

    @OptionGroup var outputOptions: CommandOutputOptions

    @Argument(help: "Provisioning target: macos-builder.")
    var target: ProvisionTarget

    @Argument(
        help: ArgumentHelp(
            "Provisioning operation.",
            discussion: """
                prepare acquires and verifies the pinned Actions runner archive.
                handoff reconciles the protected runner group and provisions, \
                finalizes, or re-verifies the host identity.
                retire removes the runner registration, the installed service, \
                and machine-wide builder state.
                """))
    var operation: MacOSBuilderProvisioning.Operation

    var requiresExecutionAdmission: Bool { false }

    mutating func run(in context: WorkspaceContext) async throws {
        #if os(macOS)
        switch target {
        case .macOSBuilder:
            try await MacOSBuilderProvisioning(context: context).run(operation)
        }
        #else
        throw WorkspaceFailure.message(
            "the trusted builder identity is provisioned only on its macOS host")
        #endif
    }
}
