import Foundation
import SystemPackage
import Testing

@testable import ColliderCommands

@Test
func androidLeavesConstructOneOpinionatedOperationPerEntrypoint() throws {
    let build = try Android.Build.parse(["--dry-run"])
    #expect(build.operation == .build)
    #expect(build.taskOptions.dryRun)

    let native = try Android.Native.parse([])
    #expect(native.operation == .native)

    let verify = try Android.Verify.parse([])
    #expect(verify.operation == .verify)

    #expect(throws: (any Error).self) {
        try Android.Build.parse(["--", "--stacktrace"])
    }
    #expect(throws: (any Error).self) {
        try Android.Verify.parse(["/tmp/libNucleusAndroid.so"])
    }
}

@Test
func swiftSDKRebuildAlwaysBuildsTheCompleteTargetSet() throws {
    _ = try SwiftSDK.Rebuild.parse([])
    #expect(throws: (any Error).self) {
        try SwiftSDK.Rebuild.parse(["--arch", "aarch64"])
    }
    #expect(throws: (any Error).self) {
        try SwiftSDK.Rebuild.parse(["--reconfigure"])
    }
}

@Test
func retiredToolchainCommandIsRejected() {
    #expect(throws: (any Error).self) {
        try ColliderCommand.parseAsRoot(["toolchain", "status"])
    }
}

@Test
func boundedCommandValuesRejectUnknownSpellingsDuringParsing() {
    for arguments in [
        ["doctor", "unknown"],
        ["run", "--optimize", "fast"],
        ["run", "--sanitize", "memory"],
        ["run", "--present-mode", "immediate"],
        ["sanitize", "memory"],
    ] {
        #expect(throws: (any Error).self) {
            try ColliderCommand.parseAsRoot(arguments)
        }
    }
}

#if os(Linux)
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
func runtimeInstallationNormalizesTheTypedLeafPrefix() throws {
    let command = InstallCommand(
        context: WorkspaceContext(
            root: FilePath("/workspace"),
            environment: [:]))

    #expect(
        command.resolvedPrefix(
            explicit: "out/runtime"
        ).path
            == "/workspace/out/runtime")
    #expect(
        command.resolvedPrefix(
            explicit: nil
        ).path
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
