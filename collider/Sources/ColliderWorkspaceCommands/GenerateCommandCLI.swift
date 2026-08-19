import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

struct Generate: TaskControlledCommand {
    static let configuration = CommandConfiguration(
        abstract: "Regenerate a component's generated sources into the build store.")

    @OptionGroup var taskOptions: TaskControlOptions
    @Argument(help: "Generator target: android-runtime, vulkan, or wayland.")
    var target: String

    mutating func run(in context: WorkspaceContext) async throws {
        try await ComponentRegistry(context: context).generate(
            target, controls: taskOptions.controls)
    }
}

/// Copies generation's output into the checkout.
///
/// Separate from `generate` because the two run as different identities on a
/// provisioned host: generation executes into the build store, which only the
/// builder may write, and adoption writes the checkout, which only the
/// developer may write. Neither account can do both, so neither command can.
struct Adopt: ColliderWorkspaceCommand {
    static let configuration = CommandConfiguration(
        abstract: "Adopt generated sources from the build store into the checkout.")

    @OptionGroup var outputOptions: CommandOutputOptions
    @Argument(help: "Generator target: android-runtime, vulkan, or wayland.")
    var target: String

    /// Reads the store and writes the checkout, so it needs no store write
    /// access, no run record, and no execution lease. Editing tracked files is
    /// not an execution.
    var recordsRun: Bool { false }
    var requiresExecutionAdmission: Bool { false }
    var presentationKind: CommandPresentationKind { .none }

    mutating func run(in context: WorkspaceContext) async throws {
        let adoption = try ComponentRegistry(context: context)
            .adoptGeneratedSources(target)
        try context.console.report(adoption, text: adoption.summary)
    }
}

/// What adoption changed in the checkout.
package struct GeneratedSourceAdoption: Encodable, Sendable {
    package let component: String
    package let adopted: [String]
    package let current: [String]

    package var summary: String {
        guard !adopted.isEmpty else {
            return "generated sources are already current: \(component)"
        }
        return
            (["adopted generated sources into the checkout:"]
            + adopted.map { "  \($0)" }
            + (current.isEmpty ? [] : ["  (\(current.count) already current)"]))
            .joined(separator: "\n")
    }
}
