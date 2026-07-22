import Foundation
import Testing
@testable import NucleusWorkspace

@Test
func capturedCommandsKeepDiagnosticsOutOfMachineReadableOutput() throws {
    let context = WorkspaceContext(
        root: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        environment: ProcessInfo.processInfo.environment)

    let output = try context.run(
        "sh",
        ["-c", "printf 'binary-directory\\n'; printf 'lock diagnostic\\n' >&2"],
        capture: true)

    #expect(output == "binary-directory")
}

#if os(Linux)
@Test
func workflowLockExcludesAnotherFileDescription() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "nucleus-workflow-lock-test-\(UUID().uuidString)",
        isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("workflow.lock").path

    var owner: WorkspaceFileLock? = try WorkspaceFileLock(
        path: path,
        purpose: "test workflow")
    do {
        _ = try WorkspaceFileLock(
            path: path,
            purpose: "test workflow",
            waitForExistingOwner: false)
        Issue.record("a second file description acquired an owned workflow lock")
    } catch {
        #expect(String(describing: error) == "test workflow is already running")
    }

    owner = nil
    let replacement = try WorkspaceFileLock(
        path: path,
        purpose: "test workflow",
        waitForExistingOwner: false)
    withExtendedLifetime(replacement) {}
    _ = owner
}
#endif
