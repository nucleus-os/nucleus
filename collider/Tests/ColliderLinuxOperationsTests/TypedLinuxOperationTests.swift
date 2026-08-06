#if os(Linux)
import Foundation
import SystemPackage
import Testing

import ColliderCore

@testable import ColliderLinuxOperations
@testable import ColliderWorkspaceCommands

private let completeTaskControls = [
    "--dry-run",
    "--rebuild",
    "--verbose",
    "--json",
    "--run-id", "linux-operation-capability-test",
]

@Test
func installedHostPlanningLeavesAcceptTheCompleteTaskControlSet() throws {
    let session = try InstallSession.parse(completeTaskControls)
    assertCompleteTaskControls(session.taskOptions)

    let addon = try AndroidRuntimePackageAddon.parse(
        [
            "--compatibility", "/tmp/compatibility.json",
            "--aosp-signing-key", "/tmp/aosp.pem",
            "--addon-signing-key", "/tmp/addon.pem",
            "--output", "/tmp/addon",
        ] + completeTaskControls)
    assertCompleteTaskControls(addon.taskOptions)
}

@Test
func installedHostPlanningLeavesRejectConflictingOutputControls() {
    #expect(throws: (any Error).self) {
        try InstallSession.parse(["--quiet", "--verbose"])
    }
    #expect(throws: (any Error).self) {
        try AndroidRuntimePackageAddon.parse([
            "--compatibility", "/tmp/compatibility.json",
            "--aosp-signing-key", "/tmp/aosp.pem",
            "--addon-signing-key", "/tmp/addon.pem",
            "--output", "/tmp/addon",
            "--quiet", "--verbose",
        ])
    }
}

private func assertCompleteTaskControls(_ options: TaskControlOptions) {
    #expect(options.dryRun)
    #expect(options.rebuild)
    #expect(options.verbose)
    #expect(!options.quiet)
    #expect(options.json)
    #expect(
        options.runID?.value
            == RunID(rawValue: "linux-operation-capability-test"))
}

@Test
func compositorPassthroughRequiresTheTerminatorAndRemainsOpaque() throws {
    let command = try Run.parse([
        "--scale", "1.5",
        "--",
        "--run-id", "owned-by-compositor",
        "--fixture-output", "DP-1",
    ])
    let options = try command.options.validated()
    #expect(options.scale == 1.5)
    #expect(
        options.compositorArguments == [
            "--run-id", "owned-by-compositor",
            "--fixture-output", "DP-1",
        ])

    #expect(throws: (any Error).self) {
        try Run.parse(["--fixture-output", "DP-1"])
    }
}

@Test
func runRejectsUnknownBoundedValues() {
    for arguments in [
        ["--optimize", "fast"],
        ["--sanitize", "memory"],
        ["--present-mode", "immediate"],
    ] {
        #expect(throws: (any Error).self) {
            try Run.parse(arguments)
        }
    }
}

@Test
func runtimeInstallationNormalizesTheTypedLeafPrefix() throws {
    let command = InstallCommand(
        context: WorkspaceContext(
            root: FilePath("/workspace"),
            environment: [:]))

    #expect(
        command.resolvedPrefix(explicit: "out/runtime").path
            == "/workspace/out/runtime")
    #expect(
        command.resolvedPrefix(explicit: nil).path
            == "/workspace/.install")
}

@Test
func runtimeInstallationUsesTheRelocatableFrameworkLayout() {
    let installation = RuntimeInstallation(
        prefix: URL(fileURLWithPath: "/runtime", isDirectory: true))

    #expect(installation.compositor.path == "/runtime/bin/NucleusCompositor")
    #expect(installation.shell.path == "/runtime/bin/NucleusShell")
    #expect(installation.controlCLI.path == "/runtime/bin/nucleus")
    #expect(
        installation.configService.path
            == "/runtime/libexec/NucleusConfigService")
    #expect(
        installation.controlService.path
            == "/runtime/libexec/NucleusControlService")
    #expect(
        installation.sessionSupervisor.path
            == "/runtime/libexec/NucleusSessionSupervisor")
    #expect(
        installation.pamHelper.path
            == "/runtime/libexec/NucleusShellPamHelper")
}
#endif
