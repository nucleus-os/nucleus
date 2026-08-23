#if os(Linux)
import Foundation
import SystemPackage
import Testing

import ColliderCore
import ColliderRuntime

@testable import ColliderLinuxOperations
@testable import ColliderWorkspaceCommands

private let completeTaskControls = [
    "--dry-run",
    "--rebuild",
    "--verbose",
    "--format", "json",
    "--run-id", "linux-operation-capability-test",
]

@Test
func installedHostPlanningLeavesAcceptTheCompleteTaskControlSet() throws {
    let session = try InstallSession.parse(completeTaskControls)
    assertCompleteTaskControls(session.taskOptions)
}

@Test
func installedHostPlanningLeavesRejectConflictingOutputControls() {
    #expect(throws: (any Error).self) {
        try InstallSession.parse(["--quiet", "--verbose"])
    }
}

private func assertCompleteTaskControls(_ options: TaskControlOptions) {
    #expect(options.dryRun)
    #expect(options.rebuild)
    #expect(options.verbose)
    #expect(!options.quiet)
    #expect(options.outputOptions.format == .json)
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
func developmentRuntimePublicationNormalizesTheTypedLeafPrefix() throws {
    let command = InstallCommand(
        context: WorkspaceContext(
            root: FilePath("/workspace"),
            environment: [:],
            runtime: ColliderRuntime()))

    #expect(
        command.resolvedPrefix(explicit: "out/runtime").path
            == "/workspace/out/runtime")
    #expect(
        command.resolvedPrefix(explicit: nil).path
            == "/workspace/.nucleus/runtime/development-runtime/current")
}

@Test
func developmentRuntimeUsesTheRelocatableFrameworkLayout() {
    let runtime = DevelopmentRuntimeGeneration(
        prefix: URL(fileURLWithPath: "/runtime", isDirectory: true))

    #expect(runtime.compositor.path == "/runtime/bin/NucleusCompositor")
    #expect(runtime.shell.path == "/runtime/bin/NucleusShell")
    #expect(runtime.controlCLI.path == "/runtime/bin/nucleus")
    #expect(
        runtime.configService.path
            == "/runtime/libexec/NucleusConfigService")
    #expect(
        runtime.controlService.path
            == "/runtime/libexec/NucleusControlService")
    #expect(
        runtime.sessionSupervisor.path
            == "/runtime/libexec/NucleusSessionSupervisor")
    #expect(
        runtime.pamHelper.path
            == "/runtime/libexec/NucleusShellPamHelper")
}
#endif
