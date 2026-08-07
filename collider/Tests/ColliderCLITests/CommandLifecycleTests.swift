import ColliderCore
import ColliderPersistence
import ColliderRuntime
import Testing

@testable import ColliderCLI
@testable import ColliderWorkspaceCommands

@Test
func commandFailuresPreserveRunFinalizationSemantics() {
    let runID = RunID(rawValue: "fixture")

    #expect(
        commandFailureStatus(
            WorkspaceFailure.message("failed"),
            wasInterrupted: false) == .failed)
    #expect(
        commandFailureStatus(
            WorkspaceFailure.message("signal"),
            wasInterrupted: true) == .interrupted)
    #expect(
        commandFailureStatus(
            CancellationError(),
            wasInterrupted: false) == .interrupted)
    #expect(
        commandFailureStatus(
            RunRegistryFailure.resumptionIdentityChanged(runID),
            wasInterrupted: false) == .interrupted)
}

@Test
func executableRequiresTheWorkspaceLauncher() throws {
    #expect(throws: (any Error).self) {
        try validateColliderEntrypoint(environment: [:])
    }
    try validateColliderEntrypoint(
        environment: ["COLLIDER_ENTRYPOINT": "workspace-launcher"])
    try validateColliderEntrypoint(
        environment: ["COLLIDER_ENTRYPOINT": "setup-bootstrap"])
}

@Test
func rootGrammarRejectsRetiredAndUnsupportedBrowserOperations() {
    for arguments in [
        ["toolchain", "status"],
        ["browser", "build", "cef"],
        ["browser", "package-only"],
    ] {
        #expect(throws: (any Error).self) {
            try ColliderCommand.parseAsRoot(arguments)
        }
    }
}
