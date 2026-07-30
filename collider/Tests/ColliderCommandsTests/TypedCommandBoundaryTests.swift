import Foundation
import Testing
@testable import ColliderCommands

@Test
func androidLeavesConstructTypedOperationsAndPreserveGradlePassthrough() throws {
    let build = try Android.Build.parse([
        "--dry-run",
        "--",
        "--stacktrace",
        "-Pfixture=value",
    ])
    #expect(build.operation == .build(gradleArguments: [
        "--stacktrace",
        "-Pfixture=value",
    ]))
    #expect(build.taskOptions.dryRun)

    let native = try Android.Native.parse([])
    #expect(native.operation == .native)

    let verify = try Android.Verify.parse([
        "/tmp/libNucleusAndroid.so",
    ])
    #expect(
        verify.operation
            == .verify(library: "/tmp/libNucleusAndroid.so"))

    #expect(throws: (any Error).self) {
        try Android.Build.parse(["--stacktrace"])
    }
}

@Test
func toolchainRebuildParsesTypedArchitecturesAndNormalizesDuplicates() throws {
    let command = try Toolchain.Rebuild.parse([
        "--reconfigure",
        "--arch", "x86_64",
        "--arch", "aarch64",
        "--arch", "x86_64",
    ])
    #expect(command.rebuildOptions.reconfigure)
    #expect(command.rebuildOptions.architectures == [
        .x86_64,
        .aarch64,
    ])
    #expect(
        (try Toolchain.Rebuild.parse([])).rebuildOptions.architectures
            == [.aarch64])

    #expect(throws: (any Error).self) {
        try Toolchain.Rebuild.parse(["--arch", "armv7"])
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

@Test
func compositorPassthroughRequiresTheTerminatorAndRemainsOpaque() throws {
    let command = try Run.parse([
        "--scale", "1.5",
        "--",
        "--run-id", "owned-by-compositor",
        "--fixture-output", "DP-1",
    ])
    let options = try command.resolvedOptions().validated()
    #expect(options.scale == 1.5)
    #expect(options.compositorArguments == [
        "--run-id", "owned-by-compositor",
        "--fixture-output", "DP-1",
    ])

    #expect(throws: (any Error).self) {
        try Run.parse(["--fixture-output", "DP-1"])
    }
}

@Test
func runtimeInstallationNormalizesTheTypedLeafPrefix() throws {
    let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
    let command = InstallCommand(context: WorkspaceContext(
        root: root,
        environment: [:]))

    #expect(
        command.resolvedPrefix(
            explicit: "out/runtime").path
            == "/workspace/out/runtime")
    #expect(
        command.resolvedPrefix(
            explicit: nil).path
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
