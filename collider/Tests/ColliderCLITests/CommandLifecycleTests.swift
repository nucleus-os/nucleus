import ColliderCore
import ColliderPersistence
import ColliderRuntime
import Foundation
import SystemPackage
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
func interruptedCommandsReturnTheConventionalSignalExitStatus() {
    #expect(
        commandExitCode(status: .interrupted, interruptionSignal: 2).rawValue
            == 130)
    #expect(
        commandExitCode(status: .interrupted, interruptionSignal: 15).rawValue
            == 143)
    #expect(
        commandExitCode(status: .failed, interruptionSignal: nil)
            == .failure)
    #expect(
        commandExitCode(status: .superseded, interruptionSignal: nil)
            == .failure)
}

@Test
func changedEffectiveSourceSupersedesTheRun() throws {
    let provenance = try ProductArtifactProvenance(
        baseCommit: String(repeating: "a", count: 40),
        branch: "refs/heads/main",
        dirtyPaths: [],
        sourceAuthority: .localDevelopment)
    let initial = ProductArtifactSourceSnapshot(
        closure: ArtifactDigest(bytes: [1]),
        submoduleClosures: [],
        provenance: provenance)
    let unchanged = ProductArtifactSourceSnapshot(
        closure: ArtifactDigest(bytes: [1]),
        submoduleClosures: [],
        provenance: provenance)
    let changed = ProductArtifactSourceSnapshot(
        closure: ArtifactDigest(bytes: [2]),
        submoduleClosures: [],
        provenance: provenance)

    #expect(!sourceIdentityWasSuperseded(initial, unchanged))
    #expect(sourceIdentityWasSuperseded(initial, changed))
    #expect(sourceIdentityWasSuperseded(initial, nil))
    #expect(!sourceIdentityWasSuperseded(nil, changed))
}

@Test
func everyRecordedCommandFailureNamesItsDurableLog() {
    let fallback = recordedExecutionFailure(
        WorkspaceFailure.message("planning failed"),
        runLogPath: "/runs/fixture/run.log")
    #expect(fallback.logPath == "/runs/fixture/run.log")

    let stage = recordedExecutionFailure(
        ExecutionFailure(
            task: TaskID(rawValue: "fixture.build"),
            logPath: "/runs/fixture/stages/fixture-build.log",
            reason: "build failed"),
        runLogPath: "/runs/fixture/run.log")
    #expect(stage.logPath == "/runs/fixture/stages/fixture-build.log")
}

@Test
func interruptedCommandsDoNotRenderCancellationAsFailure() {
    #expect(
        reportedExecutionFailure(
            CancellationError(),
            status: .interrupted,
            runLogPath: "/runs/fixture/run.log") == nil)
    #expect(
        reportedExecutionFailure(
            WorkspaceFailure.message("failed"),
            status: .failed,
            runLogPath: "/runs/fixture/run.log")?.logPath
            == "/runs/fixture/run.log")
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
func rootGrammarRejectsEveryReplacedNamespace() {
    for arguments in [
        ["toolchain", "status"],
        ["swift-sdk", "rebuild"],
        ["swift-sdk", "status"],
        ["android", "build"],
        ["android", "native"],
        ["android", "verify"],
        ["android-runtime", "source-lock"],
        ["android-runtime", "source"],
        ["android-runtime", "image"],
        ["browser", "doctor"],
        ["browser", "bootstrap"],
        ["browser", "build"],
        ["browser", "test"],
        ["browser", "build", "cef"],
        ["browser", "package-only"],
        ["generate", "vulkan", "vulkan"],
        ["sanitize"],
    ] {
        #expect(throws: (any Error).self) {
            try ColliderCommand.parseAsRoot(arguments)
        }
    }
}

@Test
func everyRetiredOperationHasOneNormalizedSpelling() throws {
    let replacements = [
        ["build", "swift-sdk", "--rebuild"],
        ["status", "swift-sdk"],
        ["build", "android"],
        ["build", "android-native"],
        ["test", "android"],
        ["check", "android-source-lock"],
        ["check", "protected-main-source"],
        ["bootstrap", "android-source"],
        ["build", "android-image"],
        ["doctor", "browser"],
        ["bootstrap", "browser"],
        ["build", "browser"],
        ["test", "browser"],
        ["package", "linux-runtime"],
        ["check", "sanitizers"],
    ]
    for arguments in replacements {
        _ = try ColliderCommand.parseAsRoot(arguments)
    }
}

@Test
func inspectionCommandsDoNotCreateRunRecords() throws {
    for arguments in [
        ["status"],
        ["status", "swift-sdk"],
        ["runs", "list"],
        ["runs", "show"],
        ["logs", "list"],
        ["logs", "path"],
        ["logs", "tail"],
        ["tasks"],
        ["graph", "build", "all"],
    ] {
        let parsed = try ColliderCommand.parseAsRoot(arguments)
        let command = try #require(parsed as? any ColliderWorkspaceCommand)
        #expect(!command.recordsRun)
        #expect(!command.requiresExecutionAdmission)
    }
    let cacheStatus = try ColliderCommand.parseAsRoot(["cache", "status"])
    let cacheStatusCommand = try #require(cacheStatus as? any ColliderWorkspaceCommand)
    #expect(cacheStatusCommand.recordsRun)
    #expect(!cacheStatusCommand.requiresExecutionAdmission)
    let build = try ColliderCommand.parseAsRoot(["build", "core"])
    let buildCommand = try #require(build as? any ColliderWorkspaceCommand)
    #expect(buildCommand.recordsRun)
    #expect(buildCommand.requiresExecutionAdmission)
    let package = try ColliderCommand.parseAsRoot(["package", "linux-runtime"])
    let packageCommand = try #require(package as? any ColliderWorkspaceCommand)
    #expect(packageCommand.recordsRun)
    #expect(packageCommand.requiresExecutionAdmission)
}

@Test
func dryRunsDoNotAcquireHostExecutionAdmission() throws {
    for arguments in [
        ["build", "core", "--dry-run"],
        ["clean", "core", "--dry-run"],
        ["cache", "prune", "--dry-run"],
        ["doctor", "all"],
        ["doctor", "all", "--dry-run"],
    ] {
        let parsed = try ColliderCommand.parseAsRoot(arguments)
        let command = try #require(parsed as? any ColliderWorkspaceCommand)
        #expect(!command.requiresExecutionAdmission)
    }
}

@Test
func mutatingCommandsAcquireHostExecutionAdmission() throws {
    for arguments in [
        ["build", "core"],
        ["clean", "core"],
        ["cache", "prune"],
    ] {
        let parsed = try ColliderCommand.parseAsRoot(arguments)
        let command = try #require(parsed as? any ColliderWorkspaceCommand)
        #expect(command.requiresExecutionAdmission)
    }
}

@Test
func hostExecutionAdmissionLivesOutsideTheCheckout() {
    let hostBuildRoot = FilePath("/host/build")
    #expect(
        hostExecutionAdmissionLockPath(
            hostBuildRoot: hostBuildRoot,
            provisionedMachineLease: nil)
            == FilePath("/host/build/state/locks/host-execution.lock"))
    #expect(
        hostExecutionAdmissionLockPath(
            hostBuildRoot: hostBuildRoot,
            provisionedMachineLease: FilePath("/absent/host-execution.lock"))
            == FilePath("/host/build/state/locks/host-execution.lock"))
}

/// A provisioned host serializes every account against one inode, so the
/// installed lease supersedes the per-user lock whenever it is present.
@Test
func provisionedMachineLeaseSupersedesPerUserAdmission() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-machine-lease-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let lease = FilePath(directory.appendingPathComponent("host-execution.lock").path)
    try Data().write(to: URL(fileURLWithPath: lease.string))

    #expect(
        hostExecutionAdmissionLockPath(
            hostBuildRoot: FilePath("/host/build"),
            provisionedMachineLease: lease) == lease)
}
